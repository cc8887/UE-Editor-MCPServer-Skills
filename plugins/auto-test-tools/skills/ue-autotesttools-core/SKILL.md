---
name: ue-autotesttools-core
description: 在设计、实现或审查使用 AutoTestTools 的 Unreal Editor 业务功能与自动化测试，并需要确认通用可测性约束和能力边界时使用。
---

# AutoTestTools 核心约束

AutoTestTools 的核心不是接口集合，而是约束业务实现始终可测：

- **可控制**：输入、前置状态和依赖资源能够显式建立。
- **可观察**：关键结果通过稳定状态、事件或快照读取。
- **可隔离**：不依赖其他用例残留、加载顺序或全局偶然状态。
- **可清理**：资源所有权明确，失败、取消和超时后也能幂等释放。
- **可重复**：不依赖临时命名、固定延时、随机枚举顺序或渲染时序。

当前可测类别包括 Actor、Enhanced Input、Animation、Notify、状态机及可选 Motion Matching。FX、Gameplay、UI、Network 尚未形成可执行能力，不得宣称支持。

编写测试脚本时，必须同时使用本 Core 与对应功能 skill，再按需读取 [测试编写与执行参考](../../references/test-authoring-and-execution.md)；实现或审查业务逻辑时只需应用约束，不要加载接口参考。
