# AnimBP2FP MCP Reference

## 路径说明

以下路径需要根据你的实际环境替换：

- `<ENGINE_ROOT>`: UE 引擎根目录
- `<PROJECT_FILE>`: 项目的 `.uproject` 文件完整路径
- `<PROJECT_ROOT>`: 项目根目录

## MCP 侧事实

`ue-editor-alsv` 当前暴露的 MCP 工具只有：

- `execute_command`：在 UE 编辑器主线程执行 Python 代码
- `excute_file`：在 UE 编辑器主线程执行 Python 文件
- `get_editor_state`：查看 UE 编辑器连接状态

这意味着：

- 可以执行任意编辑器 Python
- 可以在 Python 中使用 `subprocess.run(...)`
- 可以通过 `unreal.AnimBP2FPPythonBridge` 调用已暴露的 `UFUNCTION`
- 仍然不能直接调用没有 Python 暴露层的 C++ 静态类


## AnimBP2FP 入口矩阵

| 目标 | 入口 | 说明 |
|---|---|---|
| 批量导出 AnimGraph DSL | `-run=AnimBP2FPExport` | 导出所有 AnimBlueprint |
| Round-trip 校验 | `-run=AnimBP2FPRoundTrip` | 校验 `AnimLang/Exported/` |
| 导入 `.animlang` | `-run=AnimBP2FPImport -file=<abs-path>` | 导入单文件 |
| 导入 round-trip 测试 | `-run=AnimBP2FPImport -file=<abs-path> -test` | 导入后再导出比较 |
| Update 测试 | `-run=AnimBP2FPImport -file=<abs-path> -update` | 跑 UpdateBlueprintDetailed 流程 |
| EventGraph BlueprintLisp 导出 | `-run=AnimBP2FPBlueprintLisp [-bp=...] [-graph=...] [-roundtrip]` | 导出 EventGraph |

## 推荐命令模板

### 1. 批量导出 AnimLang

```python
import subprocess

cmd = [
    r"<ENGINE_ROOT>/Engine/Binaries/Win64/UnrealEditor-Cmd.exe",
    r"<PROJECT_FILE>",
    "-run=AnimBP2FPExport",
    "-stdout",
    "-unattended",
    "-nullrhi",
]

result = subprocess.run(cmd, capture_output=True, text=True)
print("exit:", result.returncode)
print(result.stdout)
print(result.stderr)
```

### 2. Round-trip 校验

```python
import subprocess

cmd = [
    r"<ENGINE_ROOT>/Engine/Binaries/Win64/UnrealEditor-Cmd.exe",
    r"<PROJECT_FILE>",
    "-run=AnimBP2FPRoundTrip",
    "-stdout",
    "-unattended",
    "-nullrhi",
]

result = subprocess.run(cmd, capture_output=True, text=True)
print(result.returncode)
print(result.stdout)
print(result.stderr)
```

### 3. 导入单个 `.animlang`

```python
import subprocess

input_file = "<PROJECT_ROOT>/AnimLang/Exported/ALS_AnimBP.animlang"
outdir = "/Game/AnimBP2FP/Imported"

cmd = [
    r"<ENGINE_ROOT>/Engine/Binaries/Win64/UnrealEditor-Cmd.exe",
    r"<PROJECT_FILE>",
    "-run=AnimBP2FPImport",
    f"-file={input_file}",
    f"-outdir={outdir}",
    "-stdout",
    "-unattended",
    "-nullrhi",
]

result = subprocess.run(cmd, capture_output=True, text=True)
print(result.returncode)
print(result.stdout)
print(result.stderr)
```

### 4. Update 测试

```python
import subprocess

input_file = "<PROJECT_ROOT>/AnimLang/Exported/ALS_AnimBP.animlang"

cmd = [
    r"<ENGINE_ROOT>/Engine/Binaries/Win64/UnrealEditor-Cmd.exe",
    r"<PROJECT_FILE>",
    "-run=AnimBP2FPImport",
    f"-file={input_file}",
    "-update",
    "-stdout",
    "-unattended",
    "-nullrhi",
]

result = subprocess.run(cmd, capture_output=True, text=True)
print(result.returncode)
print(result.stdout)
print(result.stderr)
```

### 5. EventGraph -> BlueprintLisp

```python
import subprocess

bp = "/Game/AdvancedLocomotionV4/Blueprints/CharacterLogic/ALS_AnimBP.ALS_AnimBP"

cmd = [
    r"<ENGINE_ROOT>/Engine/Binaries/Win64/UnrealEditor-Cmd.exe",
    r"<PROJECT_FILE>",
    "-run=AnimBP2FPBlueprintLisp",
    f"-bp={bp}",
    "-graph=EventGraph",
    "-roundtrip",
    "-stdout",
    "-unattended",
    "-nullrhi",
]

result = subprocess.run(cmd, capture_output=True, text=True)
print(result.returncode)
print(result.stdout)
print(result.stderr)
```

## Python bridge 直调模板

### 1. 导出现有 AnimBlueprint -> DSL 文本

```python
import unreal

result = unreal.AnimBP2FPPythonBridge.export_anim_blueprint_to_text(
    "/Game/AdvancedLocomotionV4/Blueprints/CharacterLogic/ALS_AnimBP.ALS_AnimBP"
)
print(result.b_success)
print(result.message)
print(result.dsl_text)
```

### 2. 从 DSL 文本更新现有 AnimBlueprint

```python
import unreal

asset_path = "/Game/AdvancedLocomotionV4/Blueprints/CharacterLogic/ALS_AnimBP.ALS_AnimBP"
dsl_text = """(anim-blueprint ... )"""

result = unreal.AnimBP2FPPythonBridge.update_anim_blueprint_from_text(
    asset_path,
    dsl_text,
    True,
)
print(result.b_success)
print(result.message)
print(result.b_used_incremental_patch)
print(result.num_changes)
print(result.warnings)
```

### 3. 从文件更新现有 AnimBlueprint

```python
import unreal

result = unreal.AnimBP2FPPythonBridge.update_anim_blueprint_from_file(
    "/Game/AdvancedLocomotionV4/Blueprints/CharacterLogic/ALS_AnimBP.ALS_AnimBP",
    "<PROJECT_ROOT>/AnimLang/Exported/ALS_AnimBP.animlang",
    True,
)
print(result.b_success)
print(result.message)
```

### 4. 从 DSL 创建新 AnimBlueprint

```python
import unreal

result = unreal.AnimBP2FPPythonBridge.import_anim_blueprint_from_file(
    "<PROJECT_ROOT>/AnimLang/Exported/ALS_AnimBP.animlang",
    "/Game/AnimBP2FP/Imported",
    True,
)
print(result.b_success)
print(result.asset_path)
```

### 5. 导出 EventGraph -> BlueprintLisp 文本

```python
import unreal

result = unreal.AnimBP2FPPythonBridge.export_event_graph_to_text(
    "/Game/AdvancedLocomotionV4/Blueprints/CharacterLogic/ALS_AnimBP.ALS_AnimBP",
    "EventGraph",
    False,
    True,
)
print(result.b_success)
print(result.dsl_text)
```

## 为什么不能直接 Python 调底层静态类

底层核心入口仍然是：

- `FAnimBPExporter::Export(...)`
- `FAnimBPExporter::ExportEventGraph(...)`
- `FAnimBPImporter::Import(...)`
- `FAnimBPImporter::UpdateBlueprint(...)`

这些本身依旧不是 `UFUNCTION`，不会自动进入 UE Python 反射层。

现在的做法是：

- 在 `AnimBP2FPEditor` 新增 `UAnimBP2FPPythonBridge`
- 用 `UFUNCTION(BlueprintCallable)` 包一层
- 再让编辑器 Python 通过 `unreal.AnimBP2FPPythonBridge` 调用

## 何时仍然优先用 commandlet

以下场景继续优先使用 commandlet：

- 批量导出整个项目
- 批量 round-trip / 回归验证
- 不依赖打开的编辑器实例，只需要离线跑转换
- 需要固定、可复现的批处理流水线输出
