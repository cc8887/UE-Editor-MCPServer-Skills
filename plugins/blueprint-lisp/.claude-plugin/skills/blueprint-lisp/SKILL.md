---
name: blueprint-lisp
description: This skill should be used when working in AdvancedLocomotionSystemV and the task involves reading or writing ANY Blueprint's EventGraph (or other named graph) via BlueprintLisp DSL. this skill covers all Blueprint types and uses the in-process Python Bridge unreal.BlueprintLispPythonBridge. Supports Export, Import, Incremental Update, and DSL validation.
---

# BlueprintLisp — 通用 Blueprint Graph <-> BlueprintLisp DSL

## 定位

**BlueprintLisp** 是项目中负责将任意 Blueprint 图（EventGraph、FunctionGraph 等）与 S-expression DSL 互转的插件。

- 适用于**任何 Blueprint 类型**（AnimBlueprint、Actor BP、Widget BP 等）
- AnimBlueprint 的 AnimGraph 仍走 AnimBP2FP；EventGraph 可用本 Bridge 也可用 `unreal.AnimBP2FPPythonBridge.export_event_graph_to_text`

Python 类名：`unreal.BlueprintLispPythonBridge`

操作通道：`ue-editor→ execute_command → unreal.BlueprintLispPythonBridge`

---

## 强制约束

1. 只使用MCP `ue-editor` 连接和操作编辑器。
2. 操作前先确认编辑器在线（`get_editor_state`）。
3. 资产路径格式：`/Game/Foo/BP_Bar` 或 `/Game/Foo/BP_Bar.BP_Bar`（两段都可以，Bridge 内部自动补全）。
4. `bClearExisting=True` 会清除图中已有节点，请谨慎；`bClearExisting=False`（默认）在已有节点基础上追加。
5. **Update 是增量操作**（语义 diff + apply），不清除节点；建议在 AI 迭代修改时使用。

---

## 核心工作流

### Step 1：确认编辑器在线

```
get_editor_state()  # 返回 is_connected: true 才继续
```

---

### Step 2：读 — 导出 Blueprint 图到 DSL 文本

```python
import unreal

ASSET_PATH = "/Game/Foo/BP_Character.BP_Character"

result = unreal.BlueprintLispPythonBridge.export_graph_to_text(
    ASSET_PATH,
    "EventGraph",    # 图名
    False,           # bIncludePositions
    True             # bStableIds（保留 :id 标签，用于增量更新）
)

if result.b_success:
    print(result.dsl_text)
else:
    print("FAIL:", result.message)
```

写入文件：

```python
result = unreal.BlueprintLispPythonBridge.export_graph_to_file(
    ASSET_PATH,
    "<PROJECT_ROOT>/AnimLang/EventGraph/BP_Character_EventGraph.bplisp",
    "EventGraph"
)
```

---

### Step 3：写 — 从 DSL 导入节点到图

```python
result = unreal.BlueprintLispPythonBridge.import_graph_from_text(
    ASSET_PATH,
    "EventGraph",
    dsl_text,
    False,   # bClearExisting — False: 追加节点；True: 先清除
    True,    # bCompile
    True     # bSavePackage
)
print("success:", result.b_success)
print("message:", result.message)
for w in result.warnings:
    print("warning:", w)
```

从文件导入：

```python
result = unreal.BlueprintLispPythonBridge.import_graph_from_file(
    ASSET_PATH,
    "EventGraph",
    "<PROJECT_ROOT>/.../BP_Character_EventGraph.bplisp",
    False, True, True
)
```

---

### Step 4：增量更新（AI 迭代修改推荐）

```python
result = unreal.BlueprintLispPythonBridge.update_graph_from_text(
    ASSET_PATH,
    "EventGraph",
    new_dsl_text,    # 新的完整 DSL
    True,            # bCompile
    True             # bSavePackage
)
print("success:", result.b_success)
```

Update 流程（内部）：

1. Export 当前图 → old AST
2. Parse new DSL → new AST
3. Semantic diff（通过 `:id`/`:event-id` 标签匹配）
4. 只应用新增/删除/修改，不动其他节点

---

### Step 5：只验证 DSL 语法（不操作资产）

```python
result = unreal.BlueprintLispPythonBridge.validate_dsl(dsl_text)
print(result.b_success)   # True = 语法合法
for err in result.warnings:
    print(err)
```

---

## FBlueprintLispPythonResult 字段

| 字段                | 类型        | 说明                |
| ----------------- | --------- | ----------------- |
| `b_success`       | bool      | 是否成功              |
| `message`         | str       | 结果描述              |
| `asset_path`      | str       | 被操作的 Blueprint 路径 |
| `file_path`       | str       | 写入/读取的文件路径        |
| `dsl_text`        | str       | DSL 文本（Export 操作） |
| `b_saved_package` | bool      | 是否已保存到磁盘          |
| `warnings`        | list[str] | 警告/错误列表           |

---

## BlueprintLisp DSL 格式速览

```scheme
(module "EventGraph"
  (event :name "EventBeginPlay" :id "evt_001"
    (call "PrintString"
      :in-string (str "Hello World")
      :duration 5.0))

  (event :name "EventTick" :id "evt_002"
    :args [delta-seconds]
    (branch :condition (> (self.Health) 0.0)
      :true  (call "RegenerateHealth")
      :false (call "Die")))
)
```

**关键结构**：

- `(event :name "EventName" :id "stable-id" ...)` — 每个事件函数
- `(call "FunctionName" ...)` — 蓝图函数调用
- `(branch :condition expr :true ... :false ...)` — 分支节点
- `(set :var "VarName" :value expr)` — 变量赋值
- `(let [var val] body)` — 局部变量绑定
- `(seq stmt1 stmt2 ...)` — 执行序列

---

## 与其他 Bridge 的分工

| Bridge                                 | 适用范围                                                                   |
| -------------------------------------- | ---------------------------------------------------------------------- |
| `unreal.AnimBP2FPPythonBridge`         | AnimBlueprint 的 **AnimGraph**（状态机/CachedPose/LinkedLayer等）+ EventGraph |
| **`unreal.BlueprintLispPythonBridge`** | **任意 Blueprint 的任意 Graph**（EventGraph/FunctionGraph等），无动画图专属特性         |
| `unreal.MatBP2FPPythonBridge`          | UMaterial 材质表达式图                                                       |

---

## 源码位置

| 内容                | 路径                                                                              |
| ----------------- | ------------------------------------------------------------------------------- |
| Python Bridge 头文件 | `Plugins/BlueprintLisp/Source/BlueprintLisp/Public/BlueprintLispPythonBridge.h` |
| Converter 头文件     | `Plugins/BlueprintLisp/Source/BlueprintLisp/Public/BlueprintLispConverter.h`    |

---

## 常见问题

### `b_success=False` + "Failed to load Blueprint"

- 确认路径格式 `/Game/Foo/BP_Bar` 或 `/Game/Foo/BP_Bar.BP_Bar`
- 用 AssetRegistry 查询确认路径：
  
  ```python
  reg = unreal.AssetRegistryHelpers.get_asset_registry()
  for a in reg.get_all_assets():
      if "BP_Character" in str(a.asset_name):
          print(a.package_name)
  ```

### Import 后节点重复

- 使用 `bClearExisting=True` 清除已有节点，或改用 `update_graph_from_text`（增量，不重复）

### Update 效果不符合预期

- 检查 Export 时是否用了 `bStableIds=True`（默认 True），确保 `:id` 标签存在以供 diff 使用
- 增量 diff 基于 `:event-id` / `:id` 匹配；没有 ID 时回退到位置匹配

### 编译后蓝图有错误

- 检查 `result.warnings` 里的编译错误信息
- 部分 K2Node 类型 Import 后需要编辑器交互式操作才能固化 pin 类型（已知限制）
