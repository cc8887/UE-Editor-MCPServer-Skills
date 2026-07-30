# Enhanced Input 测试接口参考

本文仅供编写或维护输入测试脚本时按需读取。开始前必须同时使用 `ue-autotesttools-core` 和 `ue-autotesttools-input-testing`，并在测试装饰器中声明 `requires=("enhanced_input",)`。

## 入口与上下文

PIE 作用域中的 `pie.input` 是绑定当前 World、运行令牌和会话代次的 `InputHelper`。

| 接口 | 用途 |
| --- | --- |
| `get_player_controller()` | 取得当前 World 的第一个玩家控制器 |
| `get_controlled_pawn(controller=None)` | 取得指定或默认控制器的 Pawn |
| `wait_for_player_controller(timeout=10.0)` | 逐 tick 等待控制器可用 |

需要验证特定玩家时应显式传入 `controller=`，不要依赖默认控制器选择。

## 动作解析

下列参数形式可传给语义动作接口：

- 已加载的 `unreal.InputAction`。
- 以 `/` 开头的绝对资源路径字符串。
- `unreal.SoftObjectPath`。
- 精确、大小写敏感的绑定名字符串或 `unreal.Name`。

`resolve_action(action, controller=None)` 返回唯一的 `UInputAction`。绑定名会检查控制器及其受控 Pawn 当前的 `UEnhancedInputComponent`，同时查看事件绑定和值绑定，并按对象身份去重。无匹配或多于一个候选都会失败；歧义诊断中的候选完整路径稳定排序。

## 值类型

动作值必须与 `UInputAction.value_type` 精确对应：

| 动作类型 | Python 值 |
| --- | --- |
| Boolean | `bool`，不接受 `0` 或 `1` |
| Axis1D | 有限的非布尔 `int` 或 `float` |
| Axis2D | 两个有限数值组成的 `tuple` 或 `list` |
| Axis3D | 三个有限数值组成的 `tuple` 或 `list` |

`get_action_value(action, controller=None)` 读取处理后的值。`wait_for_action_value(action, expected, timeout=10.0, tolerance=1e-4, controller=None)` 先校验期望值类型，再逐 tick 查询并返回实际观测值。数值容差只用于有限数值分量，绝不把布尔、字符串和数字互相转换。

## 一次性与连续语义输入

| 接口 | 行为 |
| --- | --- |
| `trigger_action(action, value, controller=None)` | 注入一次性动作值；值在处理该输入的帧可见 |
| `press_action(action, value=True, controller=None)` | 启动连续动作并返回归当前 helper 所有的句柄 |
| `release_action(action_or_handle)` | 释放指定句柄，或按反向创建顺序释放该动作的全部句柄 |
| `tap_action(action, duration=0.1, value=True, controller=None)` | 持有 Boolean 或指定值一段时间，并在异常或取消时释放 |
| `hold_action(action, value, duration, controller=None)` | 持续指定动作值，并保证离开时释放 |

优先用 `press_action` 返回的句柄释放单个连续输入。未知或已退役的句柄重复释放无害；按动作释放会继续尝试所有匹配句柄，并汇总失败。关闭 helper 时先按反向顺序停止剩余连续动作，再清理物理输入；失败资源保留给下一次关闭重试。

## 物理输入兼容接口

这些接口只适合验证既有键位或硬件映射，不应作为业务语义测试的首选入口：

| 接口 | 行为 |
| --- | --- |
| `press_key(key_name, controller=None, amount=1.0)` | 按下按键并跟踪控制器 |
| `release_key(key_name, controller=None)` | 释放按键，控制器仍保持跟踪以防还有其他按键 |
| `send_axis(key_name, value, controller=None)` | 发送物理轴值并跟踪控制器 |
| `is_key_down(key_name, controller=None)` | 查询物理按键状态 |
| `flush_pressed_keys(controller=None)` | 清理控制器的全部按下状态并解除跟踪 |
| `tap_key(...)`、`hold_key(...)` | 在 `finally` 中释放物理键 |
| `hold_move_forward/backward/left/right(...)`、`jump(...)` | WASD 与空格键的兼容快捷方式 |

所有成功接收过物理注入的控制器都会被强引用并按首次注入的反向顺序清理；无效控制器会安全丢弃。某个控制器清理失败不会阻止其他控制器，并只在下次关闭时重试仍未清理的目标。

## 完整示例

```python
import unreal

from auto_test_tools import test


@test(requires=("enhanced_input",), timeout=45)
async def semantic_input_values(context):
    async with context.pie("/Game/Tests/Input/L_InputTest") as pie:
        controller = await pie.input.wait_for_player_controller(timeout=5.0)
        confirm = unreal.load_asset("/Game/Input/IA_Confirm.IA_Confirm")
        move = unreal.load_asset("/Game/Input/IA_Move.IA_Move")
        assert confirm is not None and move is not None

        pie.input.trigger_action(confirm, True, controller=controller)
        assert await pie.input.wait_for_action_value(
            confirm,
            True,
            timeout=2.0,
            controller=controller,
        ) is True

        handle = pie.input.press_action(
            move,
            (1.0, 0.0),
            controller=controller,
        )
        try:
            observed = await pie.input.wait_for_action_value(
                move,
                (1.0, 0.0),
                timeout=2.0,
                tolerance=1e-4,
                controller=controller,
            )
            assert observed[0] > 0.99
        finally:
            pie.input.release_action(handle)

        await pie.input.wait_for_action_value(
            move,
            (0.0, 0.0),
            timeout=2.0,
            controller=controller,
        )
```

动作值达到期望只证明 Enhanced Input 已处理注入，不能证明业务逻辑已经完成。跨 Actor/Input 测试应声明两个能力，并对持久业务状态再做一次条件等待：

```python
from auto_test_tools import test, wait_until


@test(requires=("actor", "enhanced_input"))
async def confirm_changes_state(context):
    async with context.pie("/Game/Tests/Input/L_InputTest") as pie:
        controller = await pie.input.wait_for_player_controller()
        pawn = pie.input.get_controlled_pawn(controller)
        pie.input.trigger_action(
            "/Game/Input/IA_Confirm.IA_Confirm", True, controller=controller
        )
        await pie.input.wait_for_action_value(
            "/Game/Input/IA_Confirm.IA_Confirm",
            True,
            controller=controller,
        )

        last_state = [None]

        def state_confirmed():
            last_state[0] = pie.actors.read_property(pawn, "ConfirmationState")
            return str(last_state[0]).rsplit("::", 1)[-1] == "Confirmed"

        try:
            await wait_until(
                state_confirmed,
                timeout=5.0,
                message="ConfirmationState did not become Confirmed",
            )
        except TimeoutError as error:
            raise TimeoutError(
                f"{error}; last_observed={last_state[0]!r}"
            ) from error
```

优先观察枚举、布尔值、计数器或其他稳定反射状态，不要把一帧内动作值本身当作业务结果。

## 异常分类

- `ValueError`：空、缺失或歧义绑定名，无效或缺失资源路径，或非有限动作值。
- `TypeError`：资源不是 `UInputAction`，动作参数形式不支持，或 Python 值与动作类型不匹配。
- `RuntimeError`：游戏线程、World、控制器、LocalPlayer、Enhanced Input 子系统、PlayerInput 或原生执行失败；完整原生诊断会保留。
- `TimeoutError`：控制器或动作值未在期限内出现。
- `BaseExceptionGroup`：释放匹配的连续句柄或关闭 helper 时出现一个或多个可重试失败。
