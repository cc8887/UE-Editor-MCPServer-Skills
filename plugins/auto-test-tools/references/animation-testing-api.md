# 动画测试接口参考

本文只供编写 AutoTestTools 动画测试脚本时按需读取。业务逻辑实现与审查应只加载 `ue-autotesttools-core` 和 `ue-autotesttools-animation-testing`，避免承担接口细节。

## 使用前提

- 测试必须是模块级 `async def`，使用 `@test(requires=("animation",))` 声明能力。
- 只在 `async with context.pie(map_path) as pie:` 范围内访问 `pie.animation`。
- 地图、角色与动画资产属于消费项目；不要引用 AutoTestTools 自测 fixture。
- 通用装饰器、PIE、NullRHI、Automation Report 与 Gauntlet 用法见 [测试编写与执行](test-authoring-and-execution.md)。

## `AnimationHelper`

活动 PIE 中的入口为 `pie.animation`。它绑定当前 World、run token 与 session generation，并由 `TestContext` 管理最终清理。

| 接口 | 作用 |
| --- | --- |
| `get_player_pawn()` | 返回当前 PIE 的 first player pawn。 |
| `get_skeletal_mesh(actor=None)` | 从显式 Actor 或当前 PIE 解析 `SkeletalMeshComponent`。 |
| `wait_for_skeletal_mesh(actor=None, timeout=10.0)` | 按 Editor tick 等待 Mesh。 |
| `wait_for_player_skeletal_mesh(timeout=10.0)` | 等待玩家 Mesh。 |
| `get_anim_instance(skeletal_mesh=None, actor=None)` | 读取目标 Mesh 的 AnimInstance。 |
| `wait_for_anim_instance(skeletal_mesh=None, actor=None, timeout=10.0)` | 按条件等待 AnimInstance。 |
| `play_montage(montage, skeletal_mesh=None, actor=None, play_rate=1.0, start_section_name=None, stop_all_montages=False)` | 播放 Montage，返回播放长度；无法播放时抛出 `RuntimeError`。 |
| `stop_montage(montage=None, skeletal_mesh=None, actor=None, blend_out_time=0.25)` | 停止指定或当前 Montage。 |
| `is_montage_playing(montage=None, skeletal_mesh=None, actor=None)` | 查询指定或任意 Montage 是否播放。 |
| `get_current_active_montage(skeletal_mesh=None, actor=None)` | 返回当前活动 Montage 或 `None`。 |
| `wait_for_montage_started(..., timeout=1.0)` | 等待 Montage 开始。 |
| `wait_for_montage_stopped(..., timeout=1.0)` | 等待 Montage 停止。 |
| `get_asset_players(..., source=("montage", "sync_group", "ungrouped"))` | 返回指定来源的播放器快照。 |
| `wait_for_asset_active(asset, ..., source=..., min_weight=0.01, timeout=10.0)` | 等待指定资源达到最小混合权重。 |
| `get_state_machine(machine_name, ...)` | 返回状态机快照。 |
| `wait_for_state(machine_name, state_name, ..., timeout=10.0)` | 等待指定状态生效。 |
| `observe_notifies(..., coverage="play_montage_notify_only", capacity=256)` | 创建有界 Notify 观察器。 |
| `wait_for_notify(notify_name, ..., phase="instant", coverage="play_montage_notify_only", capacity=256, timeout=10.0)` | 创建临时观察器并等待一个 Notify。 |
| `close()` | 关闭仍存活的观察器；完全成功后关闭 helper。 |

`source` 接受单个字符串或可迭代值：`montage`、`sync_group`、`ungrouped`。当前接口会拒绝非数字或负数 `min_weight`；测试仍应传入有限值，因为 `NaN` 或正无穷不会在入口失败，但通常会使等待只能以超时结束。空来源或未知来源会抛出 `ValueError`。

## 快照字段

Asset Player 快照提供：

- `source`、`asset_path`、`playback_time`、`blend_weight`
- `looping`、`looping_known`
- `group_name`、`player_index`、`group_leader_index`、`leader`
- `montage_instance_id`、`slot_names`、`section_name`
- `active`、`playing`、`anim_instance_path`

状态机快照提供 `valid`、`machine_name`、`machine_index`、`state_name`、`state_index`、`elapsed_time`、`state_weight`、`active_transitions`。每个 transition 包含索引、前一状态和下一状态的索引及名称。

等待接口按规范化 UObject 路径比较资源。超时时会在异常中附带 `last_observed`，应保留该诊断，不要改写成无上下文的断言。

## `NotifyObserver`

推荐使用 `async with`：

- `poll()`：返回并消费当前所有缓冲事件。
- `wait_for(notify_name, phase="instant", timeout=10.0)`：等待匹配事件，同时保留不匹配事件供后续等待。
- `close()`：幂等停止原生观察；原生关闭失败时保持可重试。
- `closed`：观察器是否已成功关闭。

`phase` 接受 `instant`、`begin`、`end`，也可传 `None` 匹配任意阶段。`coverage` 接受 `play_montage_notify_only` 或 `all_dispatched_notifies`。事件字段包括 `sequence`、`coverage`、`phase`、`notify_name`、`notify_class_path`、`source_montage_path`、`anim_instance_id`、`montage_instance_id`、`frame_number`、`animation_time` 与 `animation_time_valid`。

观察缓冲区溢出、handle 跨 generation 使用、World 清理或关闭后的访问都会以明确异常失败。异步上下文中若测试主体和关闭同时失败，主体异常保持为主异常，关闭失败附加为 note。

## 示例：Montage 与 Notify

```python
import unreal

from auto_test_tools import test


@test(requires=("animation",), timeout=30, tags=("animation", "nullrhi"))
async def attack_montage_emits_hit(context):
    montage = unreal.load_asset("/Game/Combat/AM_Attack.AM_Attack")
    assert montage is not None

    async with context.pie("/Game/Maps/L_CombatTest") as pie:
        mesh = await pie.animation.wait_for_player_skeletal_mesh(timeout=5.0)
        await pie.animation.wait_for_anim_instance(mesh, timeout=5.0)

        async with pie.animation.observe_notifies(mesh) as events:
            pie.animation.play_montage(montage, skeletal_mesh=mesh)
            await pie.animation.wait_for_montage_started(
                montage, skeletal_mesh=mesh, timeout=2.0
            )
            hit = await events.wait_for("AttackHit", phase="instant", timeout=3.0)
            assert str(hit.source_montage_path) == montage.get_path_name()

        pie.animation.stop_montage(
            montage, skeletal_mesh=mesh, blend_out_time=0.0
        )
        await pie.animation.wait_for_montage_stopped(
            montage, skeletal_mesh=mesh, timeout=2.0
        )
```

观察器必须在播放前建立，否则可能漏掉已派发事件。状态机测试应由业务条件触发转换，再用 `wait_for_state` 等待目标状态；不要使用 `sleep` 或截图替代逻辑断言。
