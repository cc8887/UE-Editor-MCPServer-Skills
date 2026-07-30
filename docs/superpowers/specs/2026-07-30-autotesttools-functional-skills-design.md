# AutoTestTools 功能分类 Skill 设计

## 目标

为 AutoTestTools 当前已经实现的 Unreal Editor 自动化测试能力建立一组中文 skill。Skill 的首要作用不是罗列 API，而是约束业务实现保持可测，并把业务实现代理与测试用例代理所需的上下文分开。

## 核心原则

AutoTestTools 的核心价值是约束业务实现具备以下性质：

- 可控制：测试能够显式建立输入、前置状态和资源。
- 可观察：关键结果能够通过稳定状态、快照或事件读取。
- 可隔离：测试不依赖其他用例残留、全局偶然状态或加载顺序。
- 可清理：资源所有权明确，失败、取消和超时后也能幂等释放。
- 可重复：不依赖固定延时、临时对象名、随机枚举顺序或渲染时序。

Core skill 只表达这些核心思想、可测类别和能力边界，不包含具体测试接口。

## 上下文分流

业务逻辑代理只需要读取 Core 和相关功能 skill，获得通用及领域可测性约束，不加载测试 API。

测试用例代理必须同时引入 Core 和相关功能 skill，然后按需读取独立 reference 中的接口、示例和执行命令。

```text
业务逻辑代理
  -> ue-autotesttools-core
  -> 对应功能 skill
  -> 不读取 API reference

测试用例代理
  -> ue-autotesttools-core
  -> 对应功能 skill
  -> 按需读取对应 API reference
```

每个功能 skill 都必须明确写出：编写测试脚本时必须同时使用 `ue-autotesttools-core`。

## Skill 分类

### ue-autotesttools-core

保持最短，只说明：

- 可控制、可观察、可隔离、可清理、可重复五项约束。
- 不依赖临时命名、固定延时、全局残留状态或渲染结果验证逻辑状态。
- 当前可测类别为 Actor、Enhanced Input、Animation、Notify、状态机及可选 Motion Matching。
- FX、Gameplay、UI、Network 尚未形成当前可执行能力，不得误报支持。
- 编写测试时按需读取独立 authoring/execution reference。

### ue-autotesttools-actor-testing

约束 Actor 业务实现使用稳定选择条件、显式 fixture、可逆属性变更、明确生命周期和确定性结果顺序。说明可验证的 Actor 查询、生成、组件、属性及生命周期类别，但不写 Python/C++ 函数签名。

### ue-autotesttools-input-testing

约束输入业务优先暴露语义 InputAction、明确连续输入所有权、允许读取处理后的值并可靠释放输入状态。物理按键只作为兼容性验证，不把键位映射当成业务语义。

### ue-autotesttools-animation-testing

约束动画业务使用显式资源、稳定状态机和 Notify 标识、可读取的 Asset Player/状态快照，并把逻辑动画校验与渲染截图分离。普通 Animation skill 不引入 PoseSearch。

### ue-autotesttools-motion-matching-testing

约束 Motion Matching 作为可选 PoseSearch 能力隔离，要求显式数据库、索引准备、PoseHistory、probe token 和可观测 snapshot。不得让普通动画测试承担 PoseSearch 加载成本。

## 元数据规则

每个 `SKILL.md` 的 YAML frontmatter 只包含 `name` 和 `description`。`description` 只描述何时使用，不概述能力、流程或接口。例如：

```yaml
---
name: ue-autotesttools-actor-testing
description: 在实现、审查或测试 Unreal Editor 中的 Actor 生成、查询、属性变更、组件及生命周期行为时使用。
---
```

Skill 正文和所有 reference 使用中文；目录名、skill 名、代码标识和命令保持原始英文。

## 文件结构

```text
plugins/auto-test-tools/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   ├── ue-autotesttools-core/SKILL.md
│   ├── ue-autotesttools-actor-testing/SKILL.md
│   ├── ue-autotesttools-input-testing/SKILL.md
│   ├── ue-autotesttools-animation-testing/SKILL.md
│   └── ue-autotesttools-motion-matching-testing/SKILL.md
└── references/
    ├── test-authoring-and-execution.md
    ├── actor-testing-api.md
    ├── input-testing-api.md
    ├── animation-testing-api.md
    ├── motion-matching-testing-api.md
    └── legacy-animation-slice-regression.md
```

API reference 负责具体装饰器、能力声明、PIE helper、函数参数、异常、示例、NullRHI 命令、Automation Report 和 Gauntlet 一级运行方式。Skill 只提供任务路由，不复制这些细节。

## 当前能力边界

文档只描述已经实现并验收的能力：

- 装饰器和 AST 发现，不要求测试函数命名约定。
- Editor-only TestContext、PIE 所有权、清理和能力预检。
- Actor fixture、查询、属性恢复和生命周期观察。
- Enhanced Input 语义及物理兼容输入。
- Montage、Asset Player、SyncGroup、状态机和 Notify。
- 可选 PoseSearch/Motion Matching probe。
- Unreal 原生 NullRHI、Automation Report 和 Gauntlet `UE.EditorAutomation` 一级接入。

不为尚未完成的 FX provider、Gameplay、UI、Network 建立可执行 skill。UI/render 在 NullRHI 下也不宣称可验证。

## 旧 Skill 处理

移除可触发的 `ue-autotesttools-animation-slice-regression` skill，将其仍有参考价值的旧版实现与回归说明移入 `references/legacy-animation-slice-regression.md`，并明确标记为历史资料，不作为当前 API 或架构依据。

## 注册与索引

补齐 `plugins/auto-test-tools/.claude-plugin/plugin.json`，在 marketplace 中注册 `auto-test-tools`，并更新根 README 对该插件的能力描述。插件版本从 `1.0.0` 起步。

## 验证策略

采用面向 skill 的 RED-GREEN-REFACTOR：

1. 在新 skill 不存在时，让独立代理分别处理业务可测性设计和测试用例编写场景，记录其遗漏、误用或上下文混合。
2. 编写最小 Core、功能 skill 和 reference。
3. 让新的独立代理在加载对应 skill 后处理同类场景，验证业务代理不加载 API、测试代理会同时使用 Core 与功能 skill，并能找到正确 reference。
4. 校验 YAML frontmatter、skill 命名、内部链接、JSON 清单、marketplace 注册和中文内容。
5. 检查所有能力描述均能从当前 AutoTestTools 源码、README 或已完成验收中得到支持。

不在本任务中修改 AutoTestTools 插件代码、运行时行为或测试资产。
