---
name: ue-autotesttools-animation-slice-regression
description: Implement and verify the AutoTestTools animation slice for the Unreal Editor plugin at <PLUGIN_ROOT> when Phase 1 PIE/session helpers and the input slice already exist. Use it to add UAutoTestAnimationUtils plus Python AnimationHelper wrappers, then run Python syntax checks, UBT compilation, and an UnrealEditor runtime smoke test that validates montage play/active/stop behavior inside PIE.
description_zh: AutoTestTools 动画切片实现与回归
description_en: AutoTestTools animation slice regression
disable: false
agent_created: true
---

# ue-autotesttools-animation-slice-regression

## When to use

- 用户要在 `<PLUGIN_ROOT>` 现有 Phase 1 + input 切片基线上继续落地 animation 切片。
- 已经具备 `UAutoTestPIESession`、`UAutoTestActorUtils`、`UAutoTestInputUtils`，现在要补动画可观测与 montage 控制能力。
- 需要最小但稳定的回归：Python 语法检查、UBT 编译，以及真实 Unreal Editor 里的 PIE 运行时 smoke。
- 当前工程使用 ALS 样例角色，希望优先验证 `AnimInstance` + montage play/active/stop 链路，而不是一上来就做状态机细粒度断言。

## Steps

1. 先读取现有基线文件：
   - `<PLUGIN_ROOT>/Source/AutoTestTools/Public/AutoTestActorUtils.h`
   - `<PLUGIN_ROOT>/Source/AutoTestTools/Public/AutoTestInputUtils.h`
   - `<PLUGIN_ROOT>/Content/Python/auto_test_tools/actor.py`
   - `<PLUGIN_ROOT>/Content/Python/auto_test_tools/input.py`
   - `<PLUGIN_ROOT>/Content/Python/auto_test_tools/__init__.py`
2. 新增 C++ 动画桥接：
   - `Source/AutoTestTools/Public/AutoTestAnimationUtils.h`
   - `Source/AutoTestTools/Private/AutoTestAnimationUtils.cpp`
     最小接口建议包括：`GetSkeletalMeshComponent`、`GetAnimInstance`、`PlayMontage`、`StopMontage`、`IsMontagePlaying`、`GetCurrentActiveMontage`。
3. C++ 解析策略保持最小化：
   - 未显式传入 actor / skeletal mesh 时，默认回落到 `GEditor->PlayWorld` 的 first player pawn。
   - `ACharacter` 优先走 `GetMesh()`；否则退回 `FindComponentByClass<USkeletalMeshComponent>()`。
4. `PlayMontage` 使用 `UAnimInstance::Montage_Play(...)`；如果传了 `StartSectionName` 再额外 `Montage_JumpToSection(...)`。
5. `StopMontage` 使用 `UAnimInstance::Montage_Stop(...)`；`IsMontagePlaying` 优先支持“指定 montage”与“任意 montage”两种模式。
6. 新增 Python 语义层：`<PLUGIN_ROOT>/Content/Python/auto_test_tools/animation.py`，封装 `AnimationHelper`，至少提供：
   - `get_skeletal_mesh()`
   - `wait_for_player_skeletal_mesh()`
   - `get_anim_instance()` / `wait_for_anim_instance()`
   - `play_montage()` / `stop_montage()`
   - `is_montage_playing()`
   - `get_current_active_montage()`
   - `wait_for_montage_started()` / `wait_for_montage_stopped()`
7. 更新 `auto_test_tools/__init__.py` 导出 `AnimationHelper`。
8. 新增稳定 smoke：`example_animation_montage_smoke_test.py`。
   - 默认地图：`/Game/AdvancedLocomotionV4/Levels/ALS_GridLevel`
   - 默认 montage：`/Game/AdvancedLocomotionV4/CharacterAssets/MannequinSkeleton/AnimationExamples/Actions/ALS_N_LandRoll_F_Montage_Default`
   - 验证顺序：spawn player -> resolve mesh -> resolve anim instance -> play montage -> wait started -> read current active montage -> stop montage -> wait stopped。
9. 先做 Python 语法检查：
   - `python -m py_compile <all autotest_tools python files> <runtime runner>`
10. 构建编辑器目标前，如果 shell 缺失 Windows `ProgramFiles*` 环境变量，先补齐：`ProgramFiles`、`ProgramW6432`、`CommonProgramFiles`、`ProgramFiles(x86)`、`CommonProgramFiles(x86)`。
11. 用 UBT 直接编译编辑器目标：
    - `dotnet "<UE_ENGINE_ROOT>/Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.dll" MCPEditor Win64 Development -Project="<PROJECT_ROOT>/MCP.uproject" -NoHotReloadFromIDE -WaitMutex`
12. 在工作区写一个 runtime runner，例如 `<WORKSPACE>/autotesttools_animation_runtime_regression.py`：
    - 将 `<PLUGIN_ROOT>/Content/Python` 加入 `sys.path`
    - `ensure_event_loop()` 后启动 async smoke task
    - 用 `_unreal_slate.register_slate_pre_tick_callback` 轮询 task 完成
    - 结果写到工作区 JSON 文件
    - 最后调用 `unreal.SystemLibrary.quit_editor()` 退出编辑器
13. 用 Unreal Editor 执行 runtime 回归：
    - `"<UE_ENGINE_ROOT>/Engine/Binaries/Win64/UnrealEditor.exe" "<PROJECT_ROOT>/MCP.uproject" -unattended -stdout -FullStdOutLogOutput -ExecutePythonScript="<WORKSPACE>/autotesttools_animation_runtime_regression.py"`
14. 验证结果 JSON 是否为 passed，并检查 runtime 日志里的关键行。

## Pitfalls

- montage 路径必须是当前 ALS 角色 skeleton 兼容的资源，否则 `Montage_Play` 可能直接返回 `0.0`。
- `ACharacter::GetMesh()` 比通用组件遍历更稳定；如果角色是 `Character`，优先使用它。
- 若 UBT 输出 `Target is up to date`，不要直接当作坏事；最终以 runtime smoke 是否真正调用到新 `AutoTestAnimationUtils` 为准。
- `unreal.Name()` 用于 Python 侧传空 section name，避免把普通空字符串误当成无效参数。
- `UnrealEditor.exe -ExecutePythonScript=...` 下如果要等待 async task 完成，必须显式保持 Python 脚本存活，并在结束后主动退出编辑器。
- 如果 montage 可以开始但停不下来，优先检查 `stop_montage()` 是否传到了同一个 mesh / actor，以及 blend out 时间是否过长。

## Verification

- `python -m py_compile` 覆盖所有 `auto_test_tools/*.py` 与 animation runtime runner 均通过。
- UBT 结果为 `Succeeded`。
- runtime 结果 JSON 为 passed，payload 至少包含：
  - `pawn`
  - `skeletal_mesh`
  - `anim_instance`
  - `montage`
  - `active_montage`
  - `play_length`
- Unreal runtime 日志中应能看到：
  - `Requested Play In Editor`
  - `animation_montage_smoke passed`
  - `Requested PIE shutdown`
  - `animation runtime regression finished`
