# AnimBP2FP Python Bridge — 完整 API 参考

## 位置

- C++ 头文件: `Plugins/AnimBP2FP/Source/AnimBP2FPEditor/Public/AnimBP2FPPythonBridge.h`
- C++ 实现: `Plugins/AnimBP2FP/Source/AnimBP2FPEditor/Private/AnimBP2FPPythonBridge.cpp`
- Python 类: `unreal.AnimBP2FPPythonBridge`（`UBlueprintFunctionLibrary` 子类）
- 返回结构: `unreal.AnimBP2FPPythonResult`（`UStruct`）

---

## 返回结构：FAnimBP2FPPythonResult

```cpp
USTRUCT(BlueprintType)
struct FAnimBP2FPPythonResult
{
    UPROPERTY() bool   bSuccess;
    UPROPERTY() FString Message;
    UPROPERTY() FString AssetPath;
    UPROPERTY() FString FilePath;
    UPROPERTY() FString DSLText;
    UPROPERTY() bool   bUsedIncrementalPatch;
    UPROPERTY() bool   bSavedPackage;
    UPROPERTY() int32  NumChanges;
    UPROPERTY() int32  NumPropertyChanges;
    UPROPERTY() int32  NumStructuralChanges;
    UPROPERTY() TArray<FString> AppliedOps;
    UPROPERTY() TArray<FString> Warnings;
};
```

Python 访问：

```python
result.b_success              # bool
result.message                # str
result.asset_path             # str  — 被操作 / 新建的资产对象路径
result.file_path              # str  — 写入的文件路径
result.dsl_text               # str  — DSL 文本（export 类操作返回）
result.b_used_incremental_patch  # bool — update 是否走增量 patch
result.b_saved_package        # bool — 是否已写磁盘
result.num_changes            # int
result.num_property_changes   # int
result.num_structural_changes # int
result.applied_ops            # list[str]
result.warnings               # list[str]
```

---

## 导出类 API

### export_anim_blueprint_to_text

```
static FAnimBP2FPPythonResult ExportAnimBlueprintToText(
    const FString& AssetObjectPath
)
```

Python:
```python
result = unreal.AnimBP2FPPythonBridge.export_anim_blueprint_to_text(asset_object_path)
```

- `asset_object_path`: UE 资产对象路径，格式 `/Game/Path/BP.BP`
- 返回：`dsl_text` 包含完整 AnimLang DSL

---

### export_anim_blueprint_to_file

```
static FAnimBP2FPPythonResult ExportAnimBlueprintToFile(
    const FString& AssetObjectPath,
    const FString& OutputFilePath
)
```

Python:
```python
result = unreal.AnimBP2FPPythonBridge.export_anim_blueprint_to_file(
    asset_object_path,
    "<PROJECT_ROOT>/AnimLang/Exported/MyBP.animlang"
)
```

- `OutputFilePath`: 绝对文件系统路径（正斜杠），父目录须存在
- 返回：`file_path` 确认写入路径

---

### export_event_graph_to_text

```
static FAnimBP2FPPythonResult ExportEventGraphToText(
    const FString& AssetObjectPath,
    const FString& GraphName,
    bool bPrettyPrint,
    bool bIncludeComments
)
```

Python:
```python
result = unreal.AnimBP2FPPythonBridge.export_event_graph_to_text(
    asset_object_path,
    "EventGraph",   # 图名，通常是 "EventGraph"
    False,          # pretty_print：缩进格式
    True,           # include_comments：写 ;; 注释
)
```

- 返回：`dsl_text` 包含 BlueprintLisp S-expression

---

### export_event_graph_to_file

```
static FAnimBP2FPPythonResult ExportEventGraphToFile(
    const FString& AssetObjectPath,
    const FString& OutputFilePath,
    const FString& GraphName,
    bool bPrettyPrint,
    bool bIncludeComments
)
```

Python:
```python
result = unreal.AnimBP2FPPythonBridge.export_event_graph_to_file(
    asset_object_path,
    "<PROJECT_ROOT>/AnimLang/EventGraph/MyBP_EG.bplisp",
    "EventGraph",
    False,
    True,
)
```

---

## 导入类 API（新建蓝图）

### import_anim_blueprint_from_text

```
static FAnimBP2FPPythonResult ImportAnimBlueprintFromText(
    const FString& DSLText,
    const FString& DestPackagePath,
    bool bSavePackage
)
```

Python:
```python
result = unreal.AnimBP2FPPythonBridge.import_anim_blueprint_from_text(
    dsl_text,
    "/Game/AnimBP2FP/Imported",   # 目标包路径（不含资产名）
    True,                          # save_package
)
```

- `DestPackagePath`: 不含资产名，只到目录层级
- 资产名从 DSL 的 `(anim-blueprint :name "...")` 自动推断
- 返回：`asset_path` 为新建资产对象路径

---

### import_anim_blueprint_from_file

```
static FAnimBP2FPPythonResult ImportAnimBlueprintFromFile(
    const FString& InputFilePath,
    const FString& DestPackagePath,
    bool bSavePackage
)
```

Python:
```python
result = unreal.AnimBP2FPPythonBridge.import_anim_blueprint_from_file(
    "<PROJECT_ROOT>/AnimLang/Exported/ALS_AnimBP.animlang",
    "/Game/AnimBP2FP/Imported",
    True,
)
```

---

## 更新类 API（写回现有蓝图）

### update_anim_blueprint_from_text

```
static FAnimBP2FPPythonResult UpdateAnimBlueprintFromText(
    const FString& AssetObjectPath,
    const FString& DSLText,
    bool bSavePackage
)
```

Python:
```python
result = unreal.AnimBP2FPPythonBridge.update_anim_blueprint_from_text(
    asset_object_path,
    dsl_text,
    True,   # save_package
)
```

- 内部先尝试增量 patch，失败则 fallback 到 full rebuild
- `b_used_incremental_patch` 反映实际路径

---

### update_anim_blueprint_from_file

```
static FAnimBP2FPPythonResult UpdateAnimBlueprintFromFile(
    const FString& AssetObjectPath,
    const FString& InputFilePath,
    bool bSavePackage
)
```

Python:
```python
result = unreal.AnimBP2FPPythonBridge.update_anim_blueprint_from_file(
    asset_object_path,
    "<PROJECT_ROOT>/AnimLang/Exported/ALS_AnimBP.animlang",
    True,
)
```

---

## 资产路径格式说明

| 格式 | 示例 | 用途 |
|------|------|------|
| 对象路径 | `/Game/Path/BP.BP` | 所有 bridge API 的 AssetObjectPath 参数 |
| 包路径 | `/Game/Path/BP` | import 的 DestPackagePath |
| 文件系统路径 | `X:/...` 或 `/home/.../` | OutputFilePath / InputFilePath |

对象路径 = 包路径 + `.` + 资产名（通常相同）。

---

## 安全属性访问

UE Python 反射层有时返回代理对象，属性访问可能抛异常。推荐用以下 helper：

```python
def prop(obj, name, default=None):
    try:
        return obj.get_editor_property(name)
    except Exception:
        try:
            return getattr(obj, name)
        except Exception:
            return default

# 使用示例
success = bool(prop(result, "bSuccess", False))
text    = prop(result, "DSLText", "") or ""
```
