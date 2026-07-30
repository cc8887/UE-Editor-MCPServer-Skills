# 旧动画切片回归历史资料

> **已过时：不要将本文作为当前 API、模块结构、测试模板或验收命令的依据。**

## 历史用途

旧 `ue-autotesttools-animation-slice-regression` skill 用于早期 Animation 最小切片落地。当时的目标是在 Phase 1 与 Input 基线上，把 Montage 播放、活动状态和停止能力加入单体 `AutoTestTools` 模块，并用 ALS 示例内容与一次 `ExecutePythonScript` smoke 验证链路。

该流程曾包含以下做法：

- 在单体模块中增加 `UAutoTestAnimationUtils` 与 Python `AnimationHelper`。
- 默认从 `GEditor->PlayWorld` 和 first player pawn 推导目标。
- 硬编码 ALS 地图及 Montage 作为回归 fixture。
- 单独编写 Editor runtime runner，并以 JSON 文件传回结果。
- 只验证 Montage play/active/stop，不覆盖状态机、Notify、资源 generation 或可选 PoseSearch。

## 被替代的原因

当前实现已经改为 Editor-only 的 `AutoTestToolsCore`、`AutoTestToolsAnimation` 与可选 `AutoTestToolsAnimationPoseSearch` 能力 provider：

- 测试由 `@test` 装饰器注册到 Unreal Automation，不再依赖一次性 runtime runner。
- helper 绑定明确的 PIE World、run token 与 session generation。
- 测试显式提供消费项目地图和资产；插件自测使用自有 fixture，不依赖 ALS。
- 当前能力覆盖 Asset Player、SyncGroup、状态机、Notify 和独立 Motion Matching probe。
- NullRHI、报告与清理由统一 Core 契约负责。

旧 skill 因而不再保留可触发入口。需要编写当前测试时，使用 `ue-autotesttools-core` 加对应功能 skill，并读取 `animation-testing-api.md` 或 `motion-matching-testing-api.md`。

本文仅用于代码考古：当旧分支仍出现 ALS 硬编码路径、未绑定的 `AnimationHelper`、单体模块类路径或 `ExecutePythonScript` runner 时，可据此识别其来源，然后按当前架构迁移。不要复制旧步骤或命令。
