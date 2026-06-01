---
name: matbp2fp
description: Primary use: Parsing and understanding Unreal Engine (UE) Material Blueprints, extracting key attributes of blueprint nodes. Converts Material Blueprints to a domain-specific language (*.matlang) to accelerate AI comprehension.
---

**MatBP2FP** 是项目中负责 **UE 材质 <-> MatLang DSL** 双向转换的插件。

- **MatLang** 是一种基于 S-expression 的 DSL，能稳定地描述材质表达式图的结构、属性和连接关系
- 设计目标：让 AI 可以读取/修改/生成 UE5 材质，实现批量回归、版本对比、AI 驱动材质编辑

## 使用思路

每当尝试读取材质蓝图时：尝试搜索蓝图对应的.matlang文件，通过直接解析.matlang实现对材质的理解。

调用链路：
使用能连接 UE 编辑器的 MCP，调用其执行 Python 代码的工具 → `unreal.MatBP2FPPythonBridge`

Python 类名：`unreal.MatBP2FPPythonBridge`

操作通道：使用能连接 UE 编辑器的 MCP，调用其执行 Python 代码的工具 → `unreal.MatBP2FPPythonBridge`

---

## 强制约束

1. 使用能连接 UE 编辑器的 MCP，调用其执行 Python 代码的工具来操作编辑器。
2. 操作前先确认编辑器在线（调用编辑器状态查询工具）。
3. 所有 UE 资产路径使用 `/...` 格式，文件系统路径使用正斜杠。
4. 除了读写.matlang文件，其余操作均通过Python Bridge，利用python完成所有的操作
5. 不要尝试通过直接读取材质蓝图的节点来理解蓝图

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

# 导出到文件（路径约定: Saved/BP2DSL/MatBP/{/Game/相对路径}.matlang）
result = unreal.MatBP2FPPythonBridge.export_material_to_file(
    "/Game/Materials/M_Example.M_Example",
    "<PROJECT_ROOT>/Saved/BP2DSL/MatBP/Materials/M_Example.matlang"
)

# 导出材质及其所有依赖的 MaterialFunction（递归）
# 每个资产独立导出为 .matlang，路径: {OutputDir}/{/Game/相对路径}.matlang
result = unreal.MatBP2FPPythonBridge.export_material_with_dependencies_to_file(
    "/Game/Materials/M_Example.M_Example",
    "<PROJECT_ROOT>/Saved/BP2DSL/MatBP"
)
print(result.message)  # 列出所有导出的文件（材质 + 函数）
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
    "<PROJECT_ROOT>/Saved/BP2DSL/MatBP/Materials/M_Example.matlang",
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
    "<PROJECT_ROOT>/Saved/BP2DSL/MatBP/Materials/M_Example.matlang",
    True
)
```

> **重要：增量 patch 只在 Export-Edit-Import 回路中触发**
>
> Differ 用 `$id` 字符串作为"同一节点"的匹配 key。但 Exporter 每次都按 `$<typeprefix><counter>` 重新生成 ID，**不读取任何持久化字段**——所以你 DSL 里写的 `$base_color` / `$rim_fresnel` 这种语义 ID **在第一次 import 之后会丢失**，下次 Differ 把所有节点判成 Removed+Added，永远走 full rebuild。
>
> 详见 `Plugins/MatBP2FP/README.md` 的 "增量更新与 `$id` 稳定性" 一节。
>
> **正确 / 错误工作流对照：**
>
> ```python
> # ❌ 错误：直接持有 DSL 编辑后推送 → 总是 full rebuild
> my_dsl = '(material "M_X" ... (constant3-vector $color :value (1 0 0)) ...)'
> unreal.MatBP2FPPythonBridge.update_material_from_text(path, my_dsl, True)
>
> # ✅ 正确：先 export，在导出文本上就地修改，再 import → 增量 patch
> exp = unreal.MatBP2FPPythonBridge.export_material_to_text(path)
> new_dsl = exp.dsl_text.replace(":default 0.5", ":default 0.85")
> unreal.MatBP2FPPythonBridge.update_material_from_text(path, new_dsl, True)
> ```
>
> **判断你走了哪条路径：** 检查返回结果里 `b_used_incremental_patch` 字段。
>
> **何时这个区分重要：**
> - 大材质（≥ 几十节点）需要快速响应小改动 → 必须走 Export-Edit-Import；
> - 下游观察生命周期事件（BlueprintAutoLayout / DrivenHighlight 等）希望看到精准的 Modified 事件而非全量 Added → 必须走 Export-Edit-Import；
> - 你只关心材质最终内容、不在意节点 GUID 是否保留 → 任意路径都可以。

### 对照表查询（Mapping Registry）

```python
import json
import unreal

# 获取完整对照表（JSON 数组）
result = unreal.MatBP2FPPythonBridge.get_mapping_table()
if result.b_success:
    entries = json.loads(result.dsl_text)  # JSON array
    # 每项: material_path, dsl_file_path, state, has_material, has_dsl

# 查询单个 Material 的映射
result = unreal.MatBP2FPPythonBridge.find_mapping_by_material("/Game/Materials/M_Example.M_Example")
print(result.file_path)    # DSL 文件绝对路径
print(result.message)      # State + 存在状态

# 纯路径转换（无需注册表初始化）
result = unreal.MatBP2FPPythonBridge.material_path_to_dsl_path("/Game/Props/M_Wood")
print(result.file_path)    # -> {Project}/Saved/BP2DSL/MatBP/Props/M_Wood.matlang
```

---

## FMatBP2FPPythonResult 字段

| 字段                         | 类型        | 说明                                                  |
| -------------------------- | --------- | --------------------------------------------------- |
| `b_success`                | bool      | 是否成功                                                |
| `message`                  | str       | 结果描述                                                |
| `asset_path`               | str       | 被操作的材质资产路径                                          |
| `file_path`                | str       | 写入/读取的文件路径                                          |
| `dsl_text`                 | str       | MatLang DSL 文本（Export）；或 JSON 数组（get_mapping_table） |
| `b_used_incremental_patch` | bool      | Update 是否走增量 patch                                  |
| `b_saved_package`          | bool      | 是否已保存到磁盘                                            |
| `num_changes`              | int       | Update 总 diff 数                                     |
| `num_structural_changes`   | int       | 结构性 diff 数                                          |
| `num_expressions_created`  | int       | Import 创建的表达式数                                      |
| `num_connections_made`     | int       | Import 连线数                                          |
| `warnings`                 | list[str] | 警告/错误/diff 行                                        |

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

## 导出路径约定

所有 MatLang 导出文件统一存放于：

```
{Project}/Saved/BP2DSL/MatBP/{/Game/ 相对路径}.matlang
```

示例：

- 材质：`/Game/Props/M_Wood` → `{Project}/Saved/BP2DSL/MatBP/Props/M_Wood.matlang`
- 材质函数：`/Game/Functions/MF_Roughness` → `{Project}/Saved/BP2DSL/MatBP/Functions/MF_Roughness.matlang`

CompilerHook（Mat2FP 模式）编译时自动导出材质到此路径。
使用 `export_material_with_dependencies_to_file` 可同时导出材质及其引用的所有 MaterialFunction。

## 常见问题排查

### RoundTrip FAIL（`<missing>` 行）

重跑 `MatBP2FPExport -all` 更新 matlang 文件后再测试（旧文件可能来自修复前的 Exporter）。
