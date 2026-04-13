---
name: animbp2fp-mcp
description: This skill should be used when working in AdvancedLocomotionSystemV and the task is to trigger AnimBP2FP or BlueprintLisp conversions through the `ue-editor-alsv` MCP connection, especially for export, import, update, round-trip validation, and EventGraph DSL generation.
---

# AnimBP2FP MCP

## Overview

在项目中，通过 MCP 触发 AnimBP2FP 转换`ue-editor-> execute_command -> unreal.AnimBP2FPPythonBridge`

当前项目已经在 `AnimBP2FPEditor` 中补齐了 Python 暴露层：

- `UAnimBP2FPPythonBridge`
- 返回结构：`FAnimBP2FPPythonResult`

因此：

- 单资产读写、AI 在打开编辑器时直接读/改蓝图，优先走 **进程内直调**

## 何时使用

在以下场景触发本 skill：

- 需要通过 MCP 触发 AnimBP2FP 导出、导入、更新或 round-trip 测试
- 需要生成 EventGraph 的 BlueprintLisp DSL
- 需要让代理稳定地调用 AnimBP2FP commandlet，而不是每次手拼命令
- 需要排查 "为什么 MCP 里看得到编辑器，但调不到 AnimBP2FP API" 这类问题

## 强制约束

1. 只使用 MCP`ue-editor` 连接编辑器及操作编辑器。
2. 不要在 Python 里直接假设 `FAnimBPExporter` / `FAnimBPImporter` 这些静态类可见；应通过 `unreal.AnimBP2FPPythonBridge` 调用封装后的 `UFUNCTION`。
3. 所有命令、路径、输出目录都使用绝对路径。

## 推荐工作流

### Step 1: 先确认编辑器连接

先检查 MCP `ue-editor` 是否已经连接到编辑器。如果编辑器未连接，不要继续执行转换。

### Step 2: 先选入口，再执行

采用以下决策：

- 要读一个 AnimBlueprint 到 DSL 文本 → `unreal.AnimBP2FPPythonBridge.export_anim_blueprint_to_text(...)`
- 要把 DSL 文本/文件导回现有蓝图 → `update_anim_blueprint_from_text(...)` / `update_anim_blueprint_from_file(...)`
- 要从 DSL 新建蓝图 → `import_anim_blueprint_from_text(...)` / `import_anim_blueprint_from_file(...)`
- 要导出 EventGraph / BlueprintLisp → `export_event_graph_to_text(...)` / `export_event_graph_to_file(...)`
- 要导入/更新 EventGraph 节点 → `unreal.BlueprintLispPythonBridge.import_graph_from_text(...)` / `update_graph_from_text(...)`
- 要批量导出 AnimGraph DSL → `AnimBP2FPExport`
- 要验证导出稳定性 → `AnimBP2FPRoundTrip`
- 要批量导入或回归测试 `.animlang` → `AnimBP2FPImport`
- 要批量导出 EventGraph / 跑 BlueprintLisp round-trip → `AnimBP2FPBlueprintLisp`

### Step 3: 单资产优先走 Python bridge

在 MCP 中执行一段编辑器 Python，直接通过 `unreal.AnimBP2FPPythonBridge` 调用：

```python
import unreal

result = unreal.AnimBP2FPPythonBridge.export_anim_blueprint_to_text(
    "/Game/AdvancedLocomotionV4/Blueprints/CharacterLogic/ALS_AnimBP.ALS_AnimBP"
)
print(result.b_success)
print(result.message)
print(result.dsl_text)
```

### Step 4 检查输出目录

标准输出目录（按项目惯例）：

- AnimLang 导出: `<PROJECT_ROOT>/AnimLang/Exported/`
- EventGraph 导出: `<PROJECT_ROOT>/AnimLang/EventGraph/`

## MCP Python 模板

执行时优先参考 `references/api_reference.md` 里的模板。

## 能力边界

### 当前能做

- 通过 `unreal.AnimBP2FPPythonBridge` 直接在编辑器进程内做单资产导出 / 导入 / 更新
- 结构化返回 import / update 结果，适合 AI 自动化读写蓝图
- 通过 `export_event_graph_to_text/file` 直接导出 EventGraph BlueprintLisp
- 通过 `unreal.BlueprintLispPythonBridge.import_graph_from_text/update_graph_from_text` **导入/更新** EventGraph
- 通过 MCP 间接触发 AnimBP2FP 全套 commandlet
- 批量导出 / round-trip / 导入 / 更新测试

## Python bridge 位置

- AnimBP2FP bridge：`Plugins/AnimBP2FP/Source/AnimBP2FPEditor/Public/AnimBP2FPPythonBridge.h`
  - Python 类名：`unreal.AnimBP2FPPythonBridge` / 结果：`unreal.AnimBP2FPPythonResult`
- BlueprintLisp bridge（EventGraph 导入/更新）：`Plugins/BlueprintLisp/Source/BlueprintLisp/Public/BlueprintLispPythonBridge.h`
  - Python 类名：`unreal.BlueprintLispPythonBridge` / 结果：`unreal.BlueprintLispPythonResult`

## 资源

- 详细命令矩阵、参数说明、MCP Python 模板：`references/api_reference.md`
- 本地命令构造辅助脚本：`scripts/build_command.py`
