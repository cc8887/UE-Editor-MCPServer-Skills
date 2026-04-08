---
name: alsv-blueprint-rw
description: This skill should be used when working in AdvancedLocomotionSystemV and the task involves reading or writing AnimBlueprint assets through the `ue-editor-alsv` MCP connection — such as exporting a blueprint to DSL text, modifying DSL and writing it back, creating a new blueprint from DSL, or exporting the EventGraph as BlueprintLisp. This skill covers the complete read-write workflow using the in-process Python bridge (`unreal.AnimBP2FPPythonBridge`).
---

# ALSV Blueprint Read/Write via ue-editor-alsv

## 定位

本 skill 专门处理 **AI 在打开的 ALSV 编辑器中，直接读写 AnimBlueprint** 的场景：

- 把蓝图导出成 DSL 文本供 AI 阅读/修改
- 把 AI 修改后的 DSL 文本写回蓝图
- 从 DSL 新建蓝图资产
- 导出 EventGraph 的 BlueprintLisp 表示

操作通道：`ue-editor-alsv` → `execute_command` → 编辑器主线程 Python → `unreal.AnimBP2FPPythonBridge`

> **注意**：本 skill 面向单资产交互式读写，批量任务请改用 `animbp2fp-mcp` skill 的 commandlet 链路。

---

## 强制约束

1. 只使用 `ue-editor-alsv` MCP server 连接 ALSV 编辑器，不使用 `unreal-mcp`。
2. 操作前先调用 `get_editor_state` 确认编辑器在线。
3. 不要直接调用 `FAnimBPExporter` / `FAnimBPImporter` C++ 静态类，只走 `unreal.AnimBP2FPPythonBridge`。
4. 所有 UE 资产路径使用 `/Game/...` 格式，文件系统路径使用正斜杠。
5. 如需保存蓝图到磁盘，在调用 import/update 时传 `save_package=True`。

---

## 核心工作流

### Step 1：确认编辑器在线

```
get_editor_state()
```

返回 `is_connected: true` 才继续。如果未连接，先启动 ALSV 编辑器并等待加载完成（约 90 秒）。

---

### Step 2：查找资产路径

如果不确定资产的完整对象路径，在编辑器内查询：

```python
import unreal

registry = unreal.AssetRegistryHelpers.get_asset_registry()
all_assets = registry.get_all_assets()
for a in all_assets:
    name = str(a.asset_name)
    pkg  = str(a.package_name)
    cls  = str(a.asset_class_path.asset_name)
    if "目标蓝图名" in name:
        print(name, "->", pkg, "class=", cls)
```

AnimBlueprint 的对象路径格式为：`{PackageName}.{AssetName}`，例如：

```
/Game/AdvancedLocomotionV4/CharacterAssets/MannequinSkeleton/ALS_AnimBP.ALS_AnimBP
```

---

### Step 3：读 — 导出蓝图到 DSL 文本

```python
import unreal

ASSET_PATH = "/Game/AdvancedLocomotionV4/CharacterAssets/MannequinSkeleton/ALS_AnimBP.ALS_AnimBP"

result = unreal.AnimBP2FPPythonBridge.export_anim_blueprint_to_text(ASSET_PATH)

if result.b_success:
    print(result.dsl_text)   # AnimLang DSL，可供 AI 阅读/修改
else:
    print("FAIL:", result.message)
```

如需同时写入文件：

```python
OUTPUT_FILE = "<PROJECT_ROOT>/AnimLang/Exported/ALS_AnimBP.animlang"
result = unreal.AnimBP2FPPythonBridge.export_anim_blueprint_to_file(ASSET_PATH, OUTPUT_FILE)
```

---

### Step 4：写 — 把修改后的 DSL 更新回蓝图

AI 修改 DSL 后，用 `update_anim_blueprint_from_text` 写回现有蓝图：

```python
import unreal

ASSET_PATH = "/Game/AdvancedLocomotionV4/CharacterAssets/MannequinSkeleton/ALS_AnimBP.ALS_AnimBP"
dsl_text = """(anim-blueprint ...)"""   # AI 修改后的 DSL

result = unreal.AnimBP2FPPythonBridge.update_anim_blueprint_from_text(
    ASSET_PATH,
    dsl_text,
    True,   # save_package
)

print("success:", result.b_success)
print("message:", result.message)
print("incremental:", result.b_used_incremental_patch)
print("changes:", result.num_changes)
print("warnings:", result.warnings)
```

从文件更新：

```python
result = unreal.AnimBP2FPPythonBridge.update_anim_blueprint_from_file(
    ASSET_PATH,
    "<PROJECT_ROOT>/AnimLang/Exported/ALS_AnimBP.animlang",
    True,
)
```

---

### Step 5：写 — 从 DSL 新建蓝图资产

```python
import unreal

result = unreal.AnimBP2FPPythonBridge.import_anim_blueprint_from_file(
    "<PROJECT_ROOT>/AnimLang/Exported/ALS_AnimBP.animlang",
    "/Game/AnimBP2FP/Imported",   # 目标包路径
    True,                          # save_package
)

print("success:", result.b_success)
print("created asset:", result.asset_path)
```

---

### Step 6：读 EventGraph — 导出 BlueprintLisp

```python
import unreal

result = unreal.AnimBP2FPPythonBridge.export_event_graph_to_text(
    ASSET_PATH,
    "EventGraph",   # 图名
    False,          # pretty_print
    True,           # include_comments
)

print("success:", result.b_success)
print(result.dsl_text)   # BlueprintLisp S-expression
```

写入文件：

```python
OUTPUT_FILE = "<PROJECT_ROOT>/AnimLang/EventGraph/ALS_AnimBP_EventGraph.bplisp"
result = unreal.AnimBP2FPPythonBridge.export_event_graph_to_file(
    ASSET_PATH, OUTPUT_FILE, "EventGraph", False, True
)
```

---

### Step 7：读写 EventGraph — 通过 BlueprintLispPythonBridge

EventGraph 的 **Export** 可走 AnimBP2FP bridge（Step 6）。若需要 **Import / Update** EventGraph 节点，改用 `unreal.BlueprintLispPythonBridge`：

```python
import unreal

ASSET_PATH = "/Game/AdvancedLocomotionV4/CharacterAssets/MannequinSkeleton/ALS_AnimBP.ALS_AnimBP"

# 导出 EventGraph
result = unreal.BlueprintLispPythonBridge.export_graph_to_text(
    ASSET_PATH,
    "EventGraph",
    False,   # bIncludePositions
    True     # bStableIds（保留 :id 标签供增量更新用）
)
print(result.dsl_text)

# 增量更新 EventGraph（AI 修改 DSL 后写回）
result = unreal.BlueprintLispPythonBridge.update_graph_from_text(
    ASSET_PATH,
    "EventGraph",
    modified_dsl,
    True,   # bCompile
    True    # bSavePackage
)
print(result.b_success, result.message)
```

> **分工说明**：
> 
> - AnimGraph（状态机/CachedPose/LinkedLayer）→ 只走 `AnimBP2FPPythonBridge`
> - EventGraph Import/Update → 优先走 `BlueprintLispPythonBridge`
> - EventGraph Export → 两者均可，`AnimBP2FPPythonBridge.export_event_graph_to_text` 也可

---

## 解读返回值

所有操作都返回 `unreal.AnimBP2FPPythonResult`。如果 Python 属性访问不稳定（UE Python 反射有时返回代理对象），使用安全读取模式：

```python
def prop(obj, name, default=None):
    try:
        return obj.get_editor_property(name)
    except Exception:
        try:
            return getattr(obj, name)
        except Exception:
            return default
```

关键字段：

| 字段                         | 类型        | 说明                 |
| -------------------------- | --------- | ------------------ |
| `b_success`                | bool      | 是否成功               |
| `message`                  | str       | 成功/失败原因            |
| `dsl_text`                 | str       | DSL 文本（export 类操作） |
| `asset_path`               | str       | 被操作或新建的资产路径        |
| `file_path`                | str       | 写入的文件路径            |
| `b_used_incremental_patch` | bool      | update 是否走增量 patch |
| `b_saved_package`          | bool      | 是否已写磁盘             |
| `num_changes`              | int       | 总变更数               |
| `num_property_changes`     | int       | 属性变更数              |
| `num_structural_changes`   | int       | 结构变更数              |
| `applied_ops`              | list[str] | 实际应用的 diff 操作列表    |
| `warnings`                 | list[str] | 警告列表（含编译错误）        |

---

## 常见问题排查

### `unreal.AnimBP2FPPythonBridge` 不存在

- 确认 `AnimBP2FPEditor` 插件已加载（检查 `.uproject` 中 `AnimBP2FP` 插件已启用）
- 确认用的是最新编译的 `UnrealEditor-AnimBP2FPEditor.dll`
- 重启编辑器后再试

### `b_success=True` 但 `warnings` 里有编译错误

- 这是正常现象：importer 调用链成功，但生成的蓝图有编译错误
- 说明 importer fidelity 问题，不是 bridge 问题
- 检查 warnings 里的具体内容，确认哪个节点/连接恢复失败

### 资产路径找不到（LoadObject 失败）

- 确认使用了 `PackageName.AssetName` 格式（两段，中间有点）
- 用 Step 2 的资产查询脚本确认路径

---

## 资源

- 完整 API 签名与参数说明：`references/python_bridge_api.md`
- 开箱即用的 bridge 调用脚本：`scripts/bridge_runner.py`
