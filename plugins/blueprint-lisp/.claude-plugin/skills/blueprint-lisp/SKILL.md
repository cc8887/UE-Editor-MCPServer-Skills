---
name: blueprint-lisp
description: Use this skill when reading, modifying, or generating UE Blueprint EventGraph/FunctionGraph/MacroGraph via BlueprintLisp DSL. Uses unreal.BlueprintLispPythonBridge for Export, Import, Incremental Update, Validate, ListGraphs, ExportGraphToDefaultPath, and ExportStub.
---

# BlueprintLisp — 通用 Blueprint Graph <-> BlueprintLisp DSL

## 定位

**BlueprintLisp** 负责将 UE 任意 Blueprint Graph 与 BlueprintLisp DSL 双向转换。

- 适用于 **任何 UBlueprint 子类**：Actor BP、Widget BP、AnimBlueprint、普通函数库蓝图等
- 关注对象是 **EventGraph / FunctionGraph / MacroGraph**
- AnimBlueprint 的 **AnimGraph** 仍应走 AnimBP2FP；其 EventGraph 可以直接走 BlueprintLisp

Python 类名：`unreal.BlueprintLispPythonBridge`

操作通道：`ue-editor -> execute_command -> unreal.BlueprintLispPythonBridge`

---

## 强制约束

1. 只使用 MCP `ue-editor` 连接和操作编辑器。
2. 操作前先确认编辑器在线（`get_editor_state`）。
3. 资产路径使用 `/Game/...` 或 `/Game/....AssetName` 格式；Bridge 会做常见补全。
4. 除 `.bplisp` 文件本身外，其余蓝图读写均通过 Python Bridge 完成，不要直接读蓝图节点来理解逻辑。
5. 导入/更新前建议先备份蓝图资产。
6. 默认导入模式优先使用 `ReplaceGraph`；`MergeAppend` 只在明确要保留原节点并追加时使用。

---

## 能力边界与推荐口径

- 默认导入模式优先使用 `ReplaceGraph`，这是当前最稳的全量替换语义。
- `MergeAppend` 只在明确希望保留现有节点并追加新内容时使用；重复执行可能累积节点或事件入口。
- `UpdateSemantic` 用于增量更新场景，依赖稳定的 `:event-id` / `:id`。
- 当前已支持顶层 `(func Name)` 创建新的 FunctionGraph，再用 `(function Name ...)` 导入函数体。
- `MacroGraph` 目前更适合“导入到已有宏图”而不是自动新建宏图。
- 对“异构多输出纯宏 -> FunctionGraph 后续参数消费”这类场景仍应谨慎，未验证前不要假定其已完全稳定。

---

## 核心工作流

### Step 1：确认编辑器在线

```python
get_editor_state()  # is_connected == true 才继续
```

---

### Step 2：读 — 导出 Blueprint 图到 DSL

```python
import unreal

ASSET_PATH = "/Game/Props/BP_Door.BP_Door"

result = unreal.BlueprintLispPythonBridge.export_graph_to_text(
    ASSET_PATH,
    "EventGraph",
    False,   # bIncludePositions
    True     # bStableIds
)
if result.b_success:
    print(result.dsl_text)
else:
    print(result.message)
```

导出到指定文件：

```python
result = unreal.BlueprintLispPythonBridge.export_graph_to_file(
    ASSET_PATH,
    "<PROJECT_ROOT>/Saved/BP2DSL/BlueprintLisp/Props/BP_Door/EventGraph.bplisp",
    "EventGraph",
    False,
    True
)
```

按默认约定路径导出：

```python
result = unreal.BlueprintLispPythonBridge.export_graph_to_default_path(
    ASSET_PATH,
    "EventGraph",
    False,
    True
)
# -> Saved/BP2DSL/BlueprintLisp/Props/BP_Door/EventGraph.bplisp
```

---

### Step 3：写 — 导入 DSL 到蓝图图表

```python
import unreal


def resolve_import_mode(preferred=("REPLACE_GRAPH", "ReplaceGraph")):
    for enum_name in ("BlueprintLispPythonImportMode", "BlueprintLispImportMode"):
        enum_type = getattr(unreal, enum_name, None)
        if enum_type is None:
            continue
        for value_name in preferred:
            value = getattr(enum_type, value_name, None)
            if value is not None:
                return value
    raise RuntimeError("未找到 BlueprintLisp 导入模式枚举")


replace_graph = resolve_import_mode(("REPLACE_GRAPH", "ReplaceGraph"))

result = unreal.BlueprintLispPythonBridge.import_graph_from_text(
    ASSET_PATH,
    "EventGraph",
    dsl_text,
    replace_graph,
    True,
    True
)
print("success:", result.b_success)
print("message:", result.message)
for w in result.warnings:
    print("warning:", w)
```

从文件导入：

```python
merge_append = resolve_import_mode(("MERGE_APPEND", "MergeAppend"))

result = unreal.BlueprintLispPythonBridge.import_graph_from_file(
    ASSET_PATH,
    "EventGraph",
    "<PROJECT_ROOT>/Saved/BP2DSL/BlueprintLisp/Props/BP_Door/EventGraph.bplisp",
    merge_append,
    True,
    True
)
```

### ImportMode 说明

- `ReplaceGraph`：默认推荐，先按图级替换语义导入，最适合回灌完整 DSL。
- `MergeAppend`：保留现有节点并追加新内容，适合少量补充，但重复执行可能堆积节点。
- `UpdateSemantic`：面向语义增量更新；如果任务本身就是 diff/apply，优先直接用 `update_graph_from_text/file()`。

---

### Step 4：增量更新（AI 迭代修改推荐）

```python
result = unreal.BlueprintLispPythonBridge.update_graph_from_text(
    ASSET_PATH,
    "EventGraph",
    new_dsl_text,
    True,
    True
)
print(result.b_success)
```

Update 内部流程：

1. Export 当前图 -> old AST
2. Parse 新 DSL -> new AST
3. 基于 `:event-id` / `:id` 做 semantic diff
4. 只应用新增 / 删除 / 修改，不动其他节点

---

### Step 5：查询与验证

列出蓝图中的所有 Graph：

```python
result = unreal.BlueprintLispPythonBridge.list_graphs(ASSET_PATH)
if result.b_success:
    print(result.dsl_text)
```

只验证 DSL 语法（不操作资产）：

```python
result = unreal.BlueprintLispPythonBridge.validate_dsl(dsl_text)
print(result.b_success)
for err in result.warnings:
    print(err)
```

导出节点类型签名 stub：

```python
result = unreal.BlueprintLispPythonBridge.export_stub()
print(result.file_path)
```

---

## FBlueprintLispPythonResult 字段

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `b_success` | bool | 是否成功 |
| `message` | str | 结果描述 |
| `asset_path` | str | 被操作的蓝图资产路径 |
| `file_path` | str | 写入/读取的文件路径 |
| `dsl_text` | str | DSL 文本（Export）或 Graph 列表（ListGraphs） |
| `b_saved_package` | bool | 是否已保存到磁盘 |
| `warnings` | list[str] | 警告/错误信息列表 |

---

## 导出路径约定

所有 BlueprintLisp 导出文件统一存放于：

```text
{Project}/Saved/BP2DSL/BlueprintLisp/{MountPoint相对路径}/{GraphName}.bplisp
```

示例：

- `/Game/Props/BP_Door` + `EventGraph` -> `Saved/BP2DSL/BlueprintLisp/Props/BP_Door/EventGraph.bplisp`
- `/Game/Props/BP_Door` + `OpenDoor` -> `Saved/BP2DSL/BlueprintLisp/Props/BP_Door/OpenDoor.bplisp`
- `/MyPlugin/Characters/BP_Hero` + `EventGraph` -> `Saved/BP2DSL/BlueprintLisp/Characters/BP_Hero/EventGraph.bplisp`

支持动态 mount point 检测，并跳过 `/Engine/`、`/Script/`、`/Temp/`、`/Transient/` 等系统路径。

---

## BlueprintLisp DSL 速览

```scheme
(event BeginPlay
  (PrintString :instring "Hello"))

(func OpenDoor)
(function OpenDoor
  (branch (CanOpen)
    (then (PlayOpenAnimation))
    (else (PlayLockedSound))))

(macro CheckKey
  :exit
    (输出 (ReturnValue bool))
  (branch (equal KeyCount 0)
    (then (exit :ReturnValue false))
    (else (exit :ReturnValue true))))
```

**关键语法**：

- `(event Name body...)` — EventGraph 事件节点
- `(func Name)` — 创建新的 FunctionGraph（通常与后续 `(function Name ...)` 配合）
- `(function Name body...)` — 向指定函数图导入函数体
- `(macro Name body...)` — 向已有宏图导入宏体
- `:event-id` / `:id` — 稳定 ID，用于增量更新
- `:"key with spaces"` — 含空格或 Unicode 的 keyword 需加引号

---

## 与其他 Bridge 的分工

| Bridge | 适用范围 |
| --- | --- |
| `unreal.AnimBP2FPPythonBridge` | AnimBlueprint 的 **AnimGraph** 与部分 EventGraph 工作流 |
| **`unreal.BlueprintLispPythonBridge`** | **任意 Blueprint 的 EventGraph / FunctionGraph / MacroGraph** |
| `unreal.MatBP2FPPythonBridge` | UMaterial 材质表达式图 |

---

## 源码位置

| 内容 | 路径 |
| --- | --- |
| Python Bridge 头文件 | `Plugins/BlueprintLisp/Source/BlueprintLisp/Public/BlueprintLispPythonBridge.h` |
| Converter 头文件 | `Plugins/BlueprintLisp/Source/BlueprintLisp/Public/BlueprintLispConverter.h` |

---

## 常见问题

### Import 失败（图不存在 / 图未创建）

先通过 `list_graphs` 确认目标图名称是否存在。

- 新 **FunctionGraph**：可先导入顶层 `(func FunctionName)` 创建函数图，再导入 `(function FunctionName ...)` 函数体。
- 新 **MacroGraph**：当前更稳妥的做法仍是先在编辑器中准备已有宏图，再导入 `(macro MacroName ...)` 内容。
- 若 `import_graph_from_text/file()` 返回失败，先看 `result.message`，再看 `result.warnings`，不要只看是否落了一部分节点。

### Import 后节点重复

- 先检查是否误用了 `MergeAppend`
- 若目标是用完整 DSL 回灌同一张图，优先使用 `ReplaceGraph`
- 若目标是语义增量修改，优先改用 `update_graph_from_text/file()`

### Update 效果不符合预期

- 确保导出时使用了 `bStableIds=True`，这样 DSL 中的 `:event-id` / `:id` 标签才能匹配现有节点实现增量更新。
- 缺少 ID 标签时会退化为较弱的匹配策略，稳定性会下降。

### 路径报错 `invalid or non-exportable package`

- 检查 Blueprint 路径是否以 `/Engine/`、`/Script/`、`/Temp/` 等系统路径开头，这些路径不可导出。

### 编译后蓝图有错误

- 优先检查 `result.message`
- 再看 `result.warnings` 里的编译或连接错误
- 对未充分验证的新节点家族或复杂纯表达式链路，不要直接假定已经稳定互转

