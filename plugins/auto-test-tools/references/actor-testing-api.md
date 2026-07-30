# Actor 测试接口参考

本文仅供编写或维护 Actor 测试脚本时按需读取。开始前必须同时使用 `ue-autotesttools-core` 和 `ue-autotesttools-actor-testing`，并在测试装饰器中声明 `requires=("actor",)`。

## 入口与选择器

PIE 作用域中的 `pie.actors` 是绑定当前 World、运行令牌和会话代次的 `ActorHelper`。结构化查询使用：

```python
from auto_test_tools.actor import ActorQuery
```

`ActorQuery` 为不可变对象，所有已填写字段按 AND 语义组合：

| 字段 | 含义 |
| --- | --- |
| `exact_object` | 精确对象 |
| `actor_class` | Actor 类 |
| `tags` | 必须全部存在的 Actor 标签 |
| `interface` | 已实现的接口 |
| `component_class` | 必须存在的组件类 |
| `owner`、`instigator` | 对象关系 |
| `local_role`、`remote_role` | 网络角色 |
| `exact_name` | 精确对象名，仅兼容定位，会发出 `UserWarning` |
| `editor_label` | 编辑器标签，仅兼容定位，会发出 `UserWarning` |

空查询会在进入原生层前抛出 `InvalidSelectorError`。`find_all(query_or_class)` 返回按大小写敏感的对象完整路径稳定排序的列表；`find_first(query_or_class)` 与该列表的首项一致；`wait_for(query, timeout=10.0)` 异步等待第一个匹配对象。兼容接口 `wait_for_actor(actor_class, timeout=10.0)` 和 `wait_for_player_spawned(timeout=10.0)` 也使用逐 tick 等待。

## Fixture 与属性

| 接口 | 用途 |
| --- | --- |
| `spawn(actor_class, transform=None, *, owner=None, instigator=None, deferred=False, auto_cleanup=True)` | 在当前 PIE World 生成 fixture；默认登记自动销毁 |
| `finish_spawning(actor, transform=None)` | 完成一次延迟构造；重复完成会失败 |
| `find_component(actor, component_class)` | 查找指定类型组件 |
| `is_valid(actor)` | 检查 Actor 有效性 |
| `destroy(actor)` | 先处理该 Actor 的已登记属性恢复，再销毁 |
| `read_property(target, property_name)` | 以 Unreal 导出文本读取反射属性 |
| `set_property(target, property_name, value, *, auto_restore=True, explicit_cleanup=None)` | 以文本写入属性并返回恢复句柄 |
| `restore_property(handle)` | 显式恢复；重复调用无害 |

自动恢复只支持数值、布尔、枚举、Name、String、Text，以及仅由这些类型递归组成的结构体。对象或接口引用、委托、容器、定长数组和带 setter 的属性会被拒绝，且拒绝时不会发生写入或登记清理。

使用 `auto_restore=False` 时必须传入同步或异步 `explicit_cleanup`，且清理必须幂等、可重试。清理会在写入前登记；登记失败不会写入，写入失败会使已登记包装器成为空操作。显式清理未成功前不能销毁对应 Actor。

## 生命周期观察

`observe(query_or_class, capacity=256)` 返回 `ActorEventStream`，必须在异步上下文中使用或显式关闭：

| 接口 | 行为 |
| --- | --- |
| `poll()` | 消费当前全部待处理事件 |
| `next(timeout=10.0)` | 等待下一事件 |
| `wait_spawned(timeout=10.0)` | 等待 `Spawned` |
| `wait_end_play(reason=None, timeout=10.0)` | 等待 `EndPlay`，可筛选原因 |
| `wait_destroyed(timeout=10.0)` | 等待 `Destroyed` |
| `close()` | 幂等关闭并解绑观察 |

筛选等待会保留不匹配事件，供后续消费者读取。`ActorEvent` 不可变，公开 `sequence`、`world_time`、`frame`、`event_type`、`generation`、`role`、`actor_path`、`component_path` 和 `end_play_reason`。

观察开始后生成但尚未满足完整查询条件的 Actor 会作为弱候选保留，并在后续 game-thread poll 中重新匹配。示例因此可以在 deferred spawn 返回后、完成生成前设置标签；首次满足完整条件时才发出一次生成事件。已在观察开始前存在的 Actor 不会因为后来满足条件而补发生成事件。

观察容量溢出时，当前缓冲区被重置并抛出一次 `ObservationOverflowError`，之后可继续消费新事件。World 清理、运行令牌或会话代次失效会抛出 `StaleHandleError`。关闭失败会保留资源以便下一次清理重试，并阻止属性恢复和 fixture 销毁。

## 完整示例

```python
import unreal

from auto_test_tools import test
from auto_test_tools.actor import ActorQuery


@test(requires=("actor",), timeout=45)
async def character_fixture_lifecycle(context):
    async with context.pie("/Engine/Maps/Entry") as pie:
        owner = pie.actors.find_first(unreal.WorldSettings)
        query = ActorQuery(actor_class=unreal.Character, tags=("AutoTest",))

        async with pie.actors.observe(query, capacity=64) as events:
            character = pie.actors.spawn(
                unreal.Character,
                owner=owner,
                deferred=True,
                auto_cleanup=True,
            )
            character.tags = [unreal.Name("AutoTest")]
            pie.actors.finish_spawning(character)

            spawned = await events.wait_spawned(timeout=5.0)
            assert spawned.actor_path == character.get_path_name()
            assert pie.actors.find_component(character, unreal.CapsuleComponent)

            original = pie.actors.read_property(character, "InitialLifeSpan")
            restore = pie.actors.set_property(
                character,
                "InitialLifeSpan",
                "3.5",
                auto_restore=True,
            )
            assert pie.actors.read_property(character, "InitialLifeSpan") != original
            pie.actors.restore_property(restore)
            assert pie.actors.read_property(character, "InitialLifeSpan") == original

            pie.actors.destroy(character)
            ended = await events.wait_end_play("Destroyed", timeout=5.0)
            destroyed = await events.wait_destroyed(timeout=5.0)
            assert ended.sequence < destroyed.sequence
```

## 异常分类

- `InvalidSelectorError`：查询没有任何选择条件。
- `ObservationOverflowError`：观察缓冲区溢出并已重置。
- `StaleHandleError`：句柄属于过期运行或 PIE 会话。
- `TimeoutError`：异步条件在期限内未成立。
- `RuntimeError`：原生执行、World、线程、资源状态或不安全恢复失败；完整原生诊断会保留。
- `CleanupError`：最终上下文清理仍有失败；原始测试异常不会被清理异常隐藏。
