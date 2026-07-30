# AutoTestTools 功能分类 Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 AutoTestTools 当前已实现能力创建 5 个中文功能 skill，并通过独立 reference 分离业务可测性约束与测试接口上下文。

**Architecture:** `ue-autotesttools-core` 只保存最小通用约束；Actor、Input、Animation、Motion Matching skill 保存领域约束，并要求测试脚本同时引入 Core。具体 API、示例和执行命令集中在插件级 `references/`，只由测试用例代理按需读取。

**Tech Stack:** Markdown skill、YAML frontmatter、Claude plugin marketplace JSON、Codex `agents/openai.yaml`、Python skill 校验脚本、Git diff 校验。

---

### Task 1: RED 基线验证

**Files:** 不修改文件。

- [x] **Step 1: 运行业务实现基线**

让未获得新 skill 的独立代理设计一个可被 AutoTestTools 验证的 Actor 业务功能，记录是否主动满足可控制、可观察、可隔离、可清理和可重复约束。

- [x] **Step 2: 运行测试编写基线**

让未获得新 skill 的独立代理编写 Actor/Enhanced Input 测试方案，记录是否错误依赖命名约定、固定延时或未确认的 API。

- [x] **Step 3: 运行可选能力基线**

让未获得新 skill 的独立代理设计 NullRHI Motion Matching 测试，记录是否混淆普通 Animation 与可选 PoseSearch、遗漏 token/PoseHistory/索引准备或误报未实现能力。

- [x] **Step 4: 汇总失败模式**

将实际出现的遗漏用于约束最小 skill 内容；不把预设答案传回后续前向测试代理。

### Task 2: 初始化 skill 与插件元数据

**Files:**
- Create: `plugins/auto-test-tools/.claude-plugin/plugin.json`
- Create: `plugins/auto-test-tools/skills/ue-autotesttools-core/SKILL.md`
- Create: `plugins/auto-test-tools/skills/ue-autotesttools-core/agents/openai.yaml`
- Create: `plugins/auto-test-tools/skills/ue-autotesttools-actor-testing/SKILL.md`
- Create: `plugins/auto-test-tools/skills/ue-autotesttools-actor-testing/agents/openai.yaml`
- Create: `plugins/auto-test-tools/skills/ue-autotesttools-input-testing/SKILL.md`
- Create: `plugins/auto-test-tools/skills/ue-autotesttools-input-testing/agents/openai.yaml`
- Create: `plugins/auto-test-tools/skills/ue-autotesttools-animation-testing/SKILL.md`
- Create: `plugins/auto-test-tools/skills/ue-autotesttools-animation-testing/agents/openai.yaml`
- Create: `plugins/auto-test-tools/skills/ue-autotesttools-motion-matching-testing/SKILL.md`
- Create: `plugins/auto-test-tools/skills/ue-autotesttools-motion-matching-testing/agents/openai.yaml`

- [x] **Step 1: 使用官方初始化脚本生成五个 skill**

对每个小写连字符名称运行 `skill-creator/scripts/init_skill.py`，传入中文 `display_name`、25-64 字符中文 `short_description`，以及显式包含 `$skill-name` 的中文 `default_prompt`。

- [x] **Step 2: 写入插件清单**

创建版本 `1.0.0` 的 `plugin.json`，名称为 `auto-test-tools`，描述仅概括这是 AutoTestTools 的可测性约束和测试编写 skill 组。

- [x] **Step 3: 校验生成目录**

确认五个目录名与 frontmatter `name` 完全一致，生成文件没有示例占位资源。

### Task 3: Core 与公共测试参考

**Files:**
- Modify: `plugins/auto-test-tools/skills/ue-autotesttools-core/SKILL.md`
- Create: `plugins/auto-test-tools/references/test-authoring-and-execution.md`

- [x] **Step 1: 编写最小 Core**

正文只保留五项约束、禁止项、当前可测类别、未实现边界和测试作者 reference 路由。不得出现具体函数签名、参数表或完整命令。

- [x] **Step 2: 编写公共接口参考**

记录装饰器、AST 发现、`requires`、TestContext、PIE、能力预检、NullRHI、Automation Report 和 Gauntlet `UE.EditorAutomation` 一级接入。明确装饰器是唯一标识，不要求函数命名约定。

- [x] **Step 3: 核对当前能力边界**

只列出已实现的 `actor`、`enhanced_input`、`animation`、可选 `animation_pose_search`；明确 FX provider、Gameplay、UI、Network 当前不可用。

### Task 4: Actor 功能 skill

**Files:**
- Modify: `plugins/auto-test-tools/skills/ue-autotesttools-actor-testing/SKILL.md`
- Create: `plugins/auto-test-tools/references/actor-testing-api.md`

- [x] **Step 1: 编写 Actor 可测性约束**

覆盖稳定选择器、确定顺序、显式 fixture、延迟生成、可逆属性、生命周期事件、资源所有权和幂等清理。首段明确测试脚本必须同时使用 Core。

- [x] **Step 2: 编写 Actor 接口参考**

记录 `ActorQuery`、spawn/finish/find/component/property/restore、observation、overflow/stale/cleanup 语义和一个完整示例。

### Task 5: Enhanced Input 功能 skill

**Files:**
- Modify: `plugins/auto-test-tools/skills/ue-autotesttools-input-testing/SKILL.md`
- Create: `plugins/auto-test-tools/references/input-testing-api.md`

- [x] **Step 1: 编写 Input 可测性约束**

覆盖语义 InputAction 优先、值类型稳定、控制器/World 绑定、连续输入所有权、释放和 flush；说明物理输入只用于兼容验证。首段明确测试脚本必须同时使用 Core。

- [x] **Step 2: 编写 Input 接口参考**

记录 action 解析、一次性及持续输入、wait/value、物理兼容 helper、异常分类和一个完整示例。

### Task 6: Animation 功能 skill 与历史迁移

**Files:**
- Modify: `plugins/auto-test-tools/skills/ue-autotesttools-animation-testing/SKILL.md`
- Create: `plugins/auto-test-tools/references/animation-testing-api.md`
- Create: `plugins/auto-test-tools/references/legacy-animation-slice-regression.md`
- Delete: `plugins/auto-test-tools/skills/ue-autotesttools-animation-slice-regression/SKILL.md`

- [x] **Step 1: 编写 Animation 可测性约束**

覆盖显式资源、AnimInstance、Montage、Asset Player、SyncGroup、状态机、Notify、事件缓冲、逻辑/渲染分离和清理。首段明确测试脚本必须同时使用 Core，且普通 Animation 不引入 PoseSearch。

- [x] **Step 2: 编写 Animation 接口参考**

记录 mesh/AnimInstance、Montage、asset-player/state-machine snapshot、Notify observer、等待和异常语义，以及一个完整示例。

- [x] **Step 3: 迁移旧 skill**

把旧实现步骤压缩为明确标注“历史资料”的 reference，说明其 Phase 1、ALS 固定资产和旧模块结构已过时；删除旧可触发 `SKILL.md`。

### Task 7: Motion Matching 功能 skill

**Files:**
- Modify: `plugins/auto-test-tools/skills/ue-autotesttools-motion-matching-testing/SKILL.md`
- Create: `plugins/auto-test-tools/references/motion-matching-testing-api.md`

- [x] **Step 1: 编写 Motion Matching 可测性约束**

覆盖可选 PoseSearch 隔离、显式数据库、保存/索引顺序、PoseHistory、probe token、节点回调、snapshot 与跨线程诊断。首段明确测试脚本必须同时使用 Core 和 Animation skill。

- [x] **Step 2: 编写接口参考**

记录 `prepare_database_index`、`arm_probe`、token 写入、Motion Matching 回调、snapshot 等待/过滤、NullRHI 启用/禁用行为和一个完整示例。

### Task 8: Marketplace 与索引

**Files:**
- Modify: `.claude-plugin/marketplace.json`
- Modify: `README.md`

- [x] **Step 1: 注册 auto-test-tools**

添加 `auto-test-tools` marketplace 条目，版本与插件清单保持 `1.0.0`，source 指向 `./plugins/auto-test-tools`，关键词包含 Unreal Engine、automation、PIE、NullRHI、Python。

- [x] **Step 2: 更新 README**

把旧的 input/animation regression 描述改为按功能拆分的可测性约束与测试编写 skill 组，不宣称未实现模块。

- [x] **Step 3: 校验 JSON**

用 PowerShell `ConvertFrom-Json` 和 Python `json.load` 分别解析插件清单与 marketplace。

### Task 9: GREEN 前向测试与修正

**Files:** 按实际发现仅修改相应 skill/reference。

- [x] **Step 1: 前向测试业务实现路径**

让独立代理使用 Core + Actor skill 设计业务实现，确认其不读取 API reference 仍能给出可测试设计。

- [x] **Step 2: 前向测试测试编写路径**

让独立代理使用 Core + Actor/Input skill 编写测试，确认其主动读取正确 reference、不使用命名约定或固定延时。

- [x] **Step 3: 前向测试可选能力路径**

让独立代理使用 Core + Animation/Motion Matching skill 设计 NullRHI 测试，确认 PoseSearch 隔离、token、PoseHistory 和索引流程正确。

- [x] **Step 4: 修正实际缺口并复测**

只针对前向测试暴露的真实遗漏修改 skill，再用同类新代理验证。

### Task 10: 最终静态验证

**Files:** 不新增文件。

- [x] **Step 1: 运行 quick_validate**

对五个 skill 分别运行 `skill-creator/scripts/quick_validate.py`，预期全部 `Skill is valid!`。

- [x] **Step 2: 检查元数据和中文**

确认每个 frontmatter 只有 `name`、`description`，description 只写触发条件；正文包含中文，功能 skill 都包含 Core 必需声明。

- [x] **Step 3: 检查职责分离**

扫描 skill，确认没有函数签名、参数表和完整命令；扫描 reference，确认具体 API 和运行命令均存在。

- [x] **Step 4: 检查链接和注册**

解析所有相对 reference 路径，确认目标存在；确认 marketplace、plugin.json、README 和五个 skill 名称一致。

- [x] **Step 5: 检查差异**

运行 `git diff --check` 和 `git status --short`，确认没有空白错误、临时文件或任务外修改。本计划不创建 commit，因为用户未要求提交。
