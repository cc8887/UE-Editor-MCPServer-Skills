---
name: ue-autotesttools-motion-matching-testing
description: 在实现、审查或测试 Unreal Editor 中的 Motion Matching、PoseSearch 数据库、候选结果或探针观测行为时使用。
---

# AutoTestTools Motion Matching 测试

## 前置要求

编写测试脚本时，必须同时使用 `ue-autotesttools-core` 和 `ue-autotesttools-animation-testing`。仅在需要具体接口、AnimBP 接入契约或示例时读取 [Motion Matching 测试接口参考](../../references/motion-matching-testing-api.md)。业务实现阶段不要加载接口参考。

## 可测性约束

- 把 PoseSearch 作为可选能力隔离；普通 Animation 模块、业务和测试不得静态依赖或隐式加载它。
- 显式指定 PoseSearch Database、候选动画与 probe 名称，并在进入 PIE 前完成数据库索引准备。
- 在 AnimGraph 中提供有效 Pose History，让 Motion Matching 节点的状态更新回调发布快照；不能扫描 AnimBP 生成内存或依赖渲染结果。
- 将每次测试返回的 probe token 显式交给对应 AnimInstance。token、AnimInstance、PIE generation 与 probe 必须一一归属，不得存入跨用例全局状态。
- 通过稳定的数据库与候选资源身份、结果有效性和单调观测序列验证选择结果。时间、代价、延续或镜像状态只作为诊断，除非业务明确把它们定义为稳定契约；不得依赖内部 PoseIdx 或回调线程时序。
- probe 必须在成功、失败、取消和超时路径可靠关闭；清理失败应保留为可重试状态。

## 当前可测边界

可验证数据库索引准备、probe 注册、AnimBP token 回传与 Motion Matching 结果快照，逻辑链路支持 Editor `NullRHI`。PoseSearch 不可用时，声明了该能力的测试应明确跳过；普通动画测试仍应运行且不加载 PoseSearch。

本 skill 不验证视觉姿态质量、轨迹预测质量或 GPU 输出，也不承诺运行时动态卸载正在被动画 worker 使用的 PoseSearch bridge。
