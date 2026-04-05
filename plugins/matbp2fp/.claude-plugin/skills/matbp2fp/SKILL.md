---
name: matbp2fp
description: This skill should be used when working in AdvancedLocomotionSystemV and the task involves converting UE5 materials to/from MatLang DSL — including exporting materials to `.matlang` files, importing DSL back into materials, updating existing materials from DSL, or running round-trip validation. MatBP2FP supports both in-process Python Bridge (via ue-editor-alsv) and commandlet subprocess operations.
---

# MatBP2FP — Material <-> MatLang DSL 互转

## 定位

**MatBP2FP** 是项目中负责 **UE5 材质 <-> MatLang DSL** 双向转换的插件。

- **MatLang** 是一种基于 S-expression 的 DSL，能稳定地描述材质表达式图的结构、属性和连接关系
- 设计目标：让 AI 可以读取/修改/生成 UE5 材质，实现批量回归、版本对比、AI 驱动材质编辑

有两条调用链路：
1. **进程内直调**（推荐单资产）：`ue-editor-alsv → execute_command → unreal.MatBP2FPPythonBridge`
2. **commandlet 子进程**（批量任务）：`UnrealEditor-Cmd.exe -run=MatBP2FPExport/Import/RoundTrip`

Python 类名：`unreal.MatBP2FPPythonBridge`

---

## 强制约束

1. 使用 `ue-editor-alsv` MCP 连接编辑器（不用 `unreal-mcp`）。
2. 操作前先确认编辑器在线（`get_editor_state`）。
3. 所有 UE 资产路径使用 `/Game/...` 格式，文件系统路径使用正斜杠。
4. 批量操作优先走 commandlet，单资产操作优先走 Python Bridge。

---

## Python Bridge 快速参考

### Export（导出材质到 DSL）

```python
import unreal

# 导出到文本
result = unreal.MatBP2FPPythonBridge.export_material_to_text(
    "/Game/Materials/M_Example.M_Example"
)
if result.b_success:
    print(result.dsl_text)

# 导出到文件
result = unreal.MatBP2FPPythonBridge.export_material_to_file(
    "/Game/Materials/M_Example.M_Example",
    "<PROJECT_ROOT>/MatLang/Exported/M_Example.matlang"
)
```

### Import（从 DSL 新建材质）

```python
# 从 DSL 文本新建材质
result = unreal.MatBP2FPPythonBridge.import_material_from_text(
    dsl_text,                          # MatLang DSL 字符串
    "/Game/Materials/Imported",        # 目标包路径
    True                               # save_package
)
print(result.b_success, result.asset_path)
print(result.num_expressions_created, result.num_connections_made)

# 从文件新建材质
result = unreal.MatBP2FPPythonBridge.import_material_from_file(
    "<PROJECT_ROOT>/MatLang/Exported/M_Example.matlang",
    "/Game/Materials/Imported",
    True
)
```

### Update（更新现有材质，双策略）

```python
result = unreal.MatBP2FPPythonBridge.update_material_from_text(
    "/Game/Materials/M_Example.M_Example",   # 现有材质路径
    new_dsl_text,                             # 新 DSL 内容
    True                                      # save_package
)
print(result.b_used_incremental_patch)        # True=增量patch / False=全量重建
print(result.num_changes, result.num_structural_changes)

result = unreal.MatBP2FPPythonBridge.update_material_from_file(
    "/Game/Materials/M_Example.M_Example",
    "<PROJECT_ROOT>/MatLang/Exported/M_Example.matlang",
    True
)
```

### Round-trip 验证（单材质）

```python
result = unreal.MatBP2FPPythonBridge.validate_material_round_trip(
    "/Game/Materials/M_Example.M_Example"
)
print(result.message)       # "RoundTrip PASS: 100.0% fidelity ..."
for diff in result.warnings:
    print(diff)             # diff 行（FAIL 时才有内容）
```

---

## FMatBP2FPPythonResult 字段

| 字段 | 类型 | 说明 |
|-----|------|------|
| `b_success` | bool | 是否成功 |
| `message` | str | 结果描述 |
| `asset_path` | str | 被操作的材质资产路径 |
| `file_path` | str | 写入/读取的文件路径 |
| `dsl_text` | str | MatLang DSL 文本（Export 操作） |
| `b_used_incremental_patch` | bool | Update 是否走增量 patch |
| `b_saved_package` | bool | 是否已保存到磁盘 |
| `num_changes` | int | Update 总 diff 数 |
| `num_structural_changes` | int | 结构性 diff 数 |
| `num_expressions_created` | int | Import 创建的表达式数 |
| `num_connections_made` | int | Import 连线数 |
| `warnings` | list[str] | 警告/错误/diff 行 |

---

## Commandlet 详细参数

### 1. Export — 导出材质到 MatLang

```bash
# 导出单个材质
UnrealEditor-Cmd.exe Project.uproject -run=MatBP2FPExport -material=M_Example -stdout -unattended -nopause

# 导出所有 /Game/ 下的材质
UnrealEditor-Cmd.exe Project.uproject -run=MatBP2FPExport -all -stdout -unattended -nopause
```

**参数**：
- `-material=<name>` — 按材质名/包路径片段过滤（Contains 匹配）
- `-all` — 导出所有 `/Game/` 下的 UMaterial

---

### 2. RoundTrip — 解析稳定性校验

```bash
UnrealEditor-Cmd.exe Project.uproject -run=MatBP2FPRoundTrip -stdout -unattended -nopause
```

---

### 3. Import — 从 DSL 导入/更新材质

```bash
# 导入测试（不写磁盘）
UnrealEditor-Cmd.exe Project.uproject -run=MatBP2FPImport -test -stdout -unattended -nopause

# 导入单个文件
UnrealEditor-Cmd.exe Project.uproject -run=MatBP2FPImport -file="<PROJECT_ROOT>/MatLang/Exported/M_Example.matlang" -stdout -unattended -nopause

# 更新现有同名材质
UnrealEditor-Cmd.exe Project.uproject -run=MatBP2FPImport -file=<path> -update -stdout -unattended -nopause
```

---

## 通过 ue-editor-alsv 触发 commandlet（编辑器已开启时）

```python
import subprocess

UE_CMD = r"<ENGINE_ROOT>/Engine/Binaries/Win64/UnrealEditor-Cmd.exe"
PROJECT = r"<PROJECT_FILE>"

cmd = [UE_CMD, PROJECT, "-run=MatBP2FPExport", "-all",
       "-stdout", "-unattended", "-nopause", "-nullrhi"]
result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
print("Exit code:", result.returncode)
print(result.stdout[-3000:])
```

---

## MatLang DSL 格式速览

```scheme
(material "M_Example"
  :domain surface
  :blend-mode opaque
  :shading-model default-lit
  (expressions
    (texture-sample $tex1
      :texture (asset "/Game/Textures/T_Albedo.T_Albedo")
      :coordinates (connect $uv2))
    (texture-coordinate $uv2
      :coordinate-index 0
      :u-tiling 2.0
      :v-tiling 2.0)
    (scalar-parameter $sparam3
      :name "Roughness"
      :default 0.5
      :group "Surface")
  )
  (outputs
    :base-color (connect $tex1)
    :roughness  (connect $sparam3))
)
```

**关键语法**：
- `$id` — 每个表达式节点的唯一 ID
- `(connect $id)` — 引用另一节点输出
- `(asset "path")` — UE 资产引用
- `:"key with spaces"` — 含空格或 Unicode 的 keyword 加引号

---

## C++ API（代码内直接调用）

```cpp
#include "MatBPExporter.h"
#include "MatBPImporter.h"

FString DSL = FMatBPExporter::ExportToString(MyMaterial);

FMatBPImporter::FImportResult ImportResult =
    FMatBPImporter::ImportFromString(DSL, TEXT("/Game/Materials/Imported/"));

FMatBPImporter::FUpdateResult UpdateResult =
    FMatBPImporter::UpdateMaterialDetailed(ExistingMaterial, NewDSL);
```

---

## 项目路径速查

| 内容 | 路径 |
|-----|------|
| 插件根目录 | `Plugins/MatBP2FP/` |
| Python Bridge 头文件 | `Plugins/MatBP2FP/Source/MatBP2FPEditor/Public/MatBP2FPPythonBridge.h` |
| Exporter 头文件 | `Plugins/MatBP2FP/Source/MatBP2FP/Public/MatBPExporter.h` |
| Importer 头文件 | `Plugins/MatBP2FP/Source/MatBP2FP/Public/MatBPImporter.h` |

---

## 常见问题排查

### RoundTrip FAIL（`<missing>` 行）

重跑 `MatBP2FPExport -all` 更新 matlang 文件后再测试（旧文件可能来自修复前的 Exporter）。

### Import -test fidelity 低（如 `m_SimpleVolumetricCloud` 2.6%）

Importer 覆盖面限制，已知问题，不影响 Import `succeeded` 计数。

### `ConflictingInstance` / UBT mutex 冲突

用 `UnrealEditor-Cmd.exe` 而非 `Build.bat`，或等待 dotnet 进程退出。

---

## 已知限制

| 限制 | 说明 |
|-----|------|
| Importer 覆盖面 | `m_SimpleVolumetricCloud` 等复杂材质 import fidelity 较低 |
| `SetMaterialAttributes` | 导入时跳过 `inputs`/`attribute-set-types` 反射恢复，连线仍可恢复 |
| `LandscapeGrassType` | 复杂 UStruct 属性 round-trip 稳定，import 侧不保证 100% 恢复 |
