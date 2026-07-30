# Motion Matching 测试接口参考

本文只供编写 AutoTestTools Motion Matching 测试或接入测试 probe 时按需读取。业务逻辑实现与审查应只加载 `ue-autotesttools-core`、`ue-autotesttools-animation-testing` 和 `ue-autotesttools-motion-matching-testing`。

## 能力与加载边界

- 测试必须声明 `requires=("animation", "animation_pose_search")`。
- PoseSearch 是默认关闭的可选引擎插件；运行此类测试时启用 `PoseSearch`。
- `pie.animation_pose_search` 只在能力预检成功后延迟创建。PoseSearch 未启用时，测试以带 warning 的预期 skip 报告，普通 `animation` 测试不加载 PoseSearch bridge。
- 只在活动 PIE 中使用 helper 和 probe。通用执行方式见 [测试编写与执行](test-authoring-and-execution.md)。

## AnimBP 接入契约

Motion Matching 节点必须具备有效 Pose History，并在其 `On Motion Matching State Updated` 节点函数中调用：

```text
UAutoTestPoseSearchProbeLibrary.RecordPoseSearchSnapshot(Context, Node, ProbeToken)
```

AnimInstance 需要保存当前 `FAutoTestPoseSearchProbeToken`，并提供一个由测试设置 token 的显式入口。入口名称由消费项目决定，不是 AutoTestTools 命名约定。若该入口会被动画 worker 读取，业务实现必须使用适合该线程模型的 POD/原子存储；不要从 worker 读取测试注册表、编辑器状态或跨线程 UObject 路径。

每次 `arm_probe` 都返回新的 token。必须把它设置到与 probe 所绑定 Mesh 相同的 AnimInstance，且不能缓存到跨 PIE、跨测试的全局对象中。原生侧会校验 handle、session generation、registration epoch 与 AnimInstance 所有权。

## Python 接口

先准备数据库索引：

```python
from auto_test_tools.animation_pose_search import prepare_database_index

prepare_database_index(database)
```

`database` 必须是有效 `PoseSearchDatabase`；应在进入 PIE 前调用。缺失数据库抛出 `ValueError`，引擎索引准备失败会保留原生诊断。

活动 PIE 的入口是 `pie.animation_pose_search`：

| 接口 | 作用 |
| --- | --- |
| `arm_probe(skeletal_mesh, probe_name)` | 为精确 Mesh/AnimInstance 注册 probe，返回 `PoseSearchProbe`。 |
| `get_motion_match(probe)` | 读取该 helper 所有的 probe 最新快照。 |
| `wait_for_motion_match(probe, **kwargs)` | 转发到 probe 的等待接口。 |
| `close()` | 逆序关闭仍存活的 probe；失败时保持可重试。 |

`arm_probe` 要求非空 Mesh、非空字符串 probe 名和 `TestContext`。probe 不属于当前 helper 时，读取或等待会抛出 `ValueError`。

`PoseSearchProbe` 提供：

| 成员 | 作用 |
| --- | --- |
| `handle` | Core generation-scoped 资源句柄。 |
| `token` | 交给 AnimInstance 的反射 token。 |
| `get_motion_match()` | 返回最新快照。 |
| `wait_for_motion_match(database=None, animation=None, timeout=10.0)` | 等待有效快照，并可按数据库及选中对象路径过滤。 |
| `close()` | 幂等关闭；原生失败时不伪装为已关闭。 |
| `closed` | probe 是否已成功关闭。 |

token 字段为 `native_handle_id`、`session_generation`、`registration_epoch`。结果快照字段为 `valid`、`probe_name`、`database_path`、`selected_object_path`、`selected_time`、`search_cost`、`continuing_pose`、`mirrored`、`sequence`。

`animation=` 过滤参数沿用历史名称，但实际比较的是 `selected_object_path`；交互结果不保证是 `AnimationAsset`。不要断言未公开的内部 PoseIdx。超时异常包含 `last_observed`，业务 AnimInstance 也可暴露回调次数与成功记录次数以辅助诊断，但这两个诊断入口没有强制命名。

## 示例

```python
import unreal

from auto_test_tools import test
from auto_test_tools.animation_pose_search import prepare_database_index


@test(
    requires=("animation", "animation_pose_search"),
    timeout=45,
    tags=("motion_matching", "nullrhi"),
)
async def locomotion_selects_expected_database(context):
    database = unreal.load_asset(
        "/Game/Animation/PoseSearch/PSD_Locomotion.PSD_Locomotion"
    )
    expected = unreal.load_asset("/Game/Animation/Run/AS_Run.AS_Run")
    assert database is not None and expected is not None
    prepare_database_index(database)

    async with context.pie("/Game/Maps/L_MotionMatchingTest") as pie:
        mesh = await pie.animation.wait_for_player_skeletal_mesh(timeout=5.0)
        anim_instance = await pie.animation.wait_for_anim_instance(
            mesh, timeout=5.0
        )

        async with pie.animation_pose_search.arm_probe(
            mesh, "Locomotion"
        ) as probe:
            # 这是消费项目提供的入口，不是插件要求的函数名。
            anim_instance.set_motion_test_probe_token(probe.token)
            snapshot = await probe.wait_for_motion_match(
                database=database,
                animation=expected,
                timeout=10.0,
            )
            assert snapshot.valid
            assert str(snapshot.probe_name) == "Locomotion"
```

逻辑快照可在 Editor `NullRHI` 下验证。最终姿势观感、运动轨迹质量和截图像素不属于该接口的结论范围。

## NullRHI 启用与隔离验证

运行 Motion Matching 测试时显式启用可选引擎插件：

```powershell
& "<EngineRoot>\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" `
  "<Project.uproject>" `
  -EnablePlugins=PoseSearch `
  -NullRHI -Unattended -NoSplash `
  -ExecCmds="Automation RunTest Project.AutoTest.<TestName>;Quit" `
  -TestExit="Automation Test Queue Empty" `
  -ReportExportPath="<ProjectRoot>\Saved\AutomationReports\MotionMatching" `
  -log
```

隔离验证使用同一命令，将 `-EnablePlugins=PoseSearch` 替换为 `-DisablePlugins=PoseSearch`；仅移除启用参数不能证明隔离，因为消费项目可能已经在配置中启用 PoseSearch。预期结果是声明 `animation_pose_search` 的测试在导入 Python、加载测试资产或启动 PIE 前以 success-with-warning 跳过；仅声明 `animation` 的测试仍正常运行，且 PoseSearch bridge 不应加载。缺失 AutoTestTools 自身必需 feature module 属于配置错误，不应伪装为可选依赖跳过。
