---
name: ue-autotesttools-animation-testing
description: 在实现、审查或测试 Unreal Editor 中的 Montage、动画播放器、动画状态机或 Anim Notify 行为时使用。
---

# AutoTestTools 动画测试

## 前置要求

编写测试脚本时，必须同时使用 `ue-autotesttools-core`。仅在需要具体接口、字段或示例时读取 [动画测试接口参考](../../references/animation-testing-api.md)。业务实现阶段不要加载接口参考。

## 可测性约束

- 显式提供地图、Actor、Skeletal Mesh、Anim Blueprint 与动画资源，不依赖临时对象名、默认关卡内容或偶然加载顺序。
- 用稳定的状态机名、状态名、Sync Group 与 Notify 标识表达业务语义；重命名必须作为契约变更处理。
- 为关键结果保留可读取的 AnimInstance 状态、Asset Player 快照或 Notify 事件，不能只从最终画面推断逻辑状态。
- 让状态转换由明确条件驱动，并等待目标条件成立；不得用固定延时猜测动画推进完成。
- 明确 Montage、观察器及 PIE 资源的所有权，保证成功、失败、取消和超时路径都能幂等清理。
- 让并列结果具备确定性标识或顺序，断言资源路径、来源、权重、状态或事件序列，而不是数组偶然位置。

## 当前可测边界

可验证 Skeletal Mesh 与 AnimInstance 解析、Montage 开始/停止、Montage/SyncGroup/Ungrouped 播放器快照、状态机状态及转换、Notify 的 Instant/Begin/End 事件。逻辑校验支持 Editor `NullRHI`。

本 skill 不验证骨骼最终视觉质量、GPU 渲染或截图像素，也不引入 PoseSearch。涉及 Motion Matching 时，改用 `ue-autotesttools-motion-matching-testing`。
