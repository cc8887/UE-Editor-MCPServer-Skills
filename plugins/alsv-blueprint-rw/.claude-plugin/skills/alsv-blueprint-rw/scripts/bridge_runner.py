"""bridge_runner.py — AnimBP2FP Python bridge 调用脚本

用途：
    在 ue-editor-alsv 的 execute_command 中粘贴或引用本脚本，
    完成对单个 AnimBlueprint 资产的读写操作。

用法（在编辑器 Python 中）：
    将下方代码段粘贴到 execute_command 的 code 参数中，
    按需修改 CONFIG 节区的变量。

支持的操作 (ACTION):
    export_text   — 把蓝图导出成 DSL 文本并打印
    export_file   — 把蓝图导出成 DSL 文件
    update_text   — 把 DSL_TEXT 变量里的文本写回蓝图
    update_file   — 读 DSL_FILE 文件写回蓝图
    import_file   — 从 DSL_FILE 新建蓝图资产
    eventgraph    — 导出 EventGraph 的 BlueprintLisp 文本
"""

# ============================================================
# CONFIG — 按需修改
# ============================================================
ACTION      = "export_text"   # 见上方支持的操作列表

ASSET_PATH  = "/Game/AdvancedLocomotionV4/CharacterAssets/MannequinSkeleton/ALS_AnimBP.ALS_AnimBP"

DSL_FILE    = "<PROJECT_ROOT>/AnimLang/Exported/ALS_AnimBP.animlang"
OUTPUT_DIR  = "<PROJECT_ROOT>/AnimLang/Exported"
IMPORT_DEST = "/Game/AnimBP2FP/Imported"
GRAPH_NAME  = "EventGraph"
SAVE        = True

DSL_TEXT    = ""   # 仅 update_text 时需要填入 DSL 内容
# ============================================================

import json
import os
import traceback
import unreal  # type: ignore  # noqa: F401  # 编辑器环境变量


def safe_prop(obj, name, default=None):
    """兼容 UE Python 代理对象的属性读取。"""
    try:
        return obj.get_editor_property(name)
    except Exception:
        try:
            return getattr(obj, name)
        except Exception:
            return default


def serialize(result):
    """把 FAnimBP2FPPythonResult 序列化为可打印的字典。"""
    text = safe_prop(result, "DSLText", "") or ""
    return {
        "success":              bool(safe_prop(result, "bSuccess", False)),
        "message":              safe_prop(result, "Message", "") or "",
        "asset_path":           safe_prop(result, "AssetPath", "") or "",
        "file_path":            safe_prop(result, "FilePath", "") or "",
        "dsl_text_length":      len(text),
        "dsl_text_preview":     text[:200],
        "dsl_text_full":        text,
        "used_incremental":     bool(safe_prop(result, "bUsedIncrementalPatch", False)),
        "saved_package":        bool(safe_prop(result, "bSavedPackage", False)),
        "num_changes":          int(safe_prop(result, "NumChanges", 0) or 0),
        "num_property_changes": int(safe_prop(result, "NumPropertyChanges", 0) or 0),
        "num_structural_changes": int(safe_prop(result, "NumStructuralChanges", 0) or 0),
        "applied_ops":          list(safe_prop(result, "AppliedOps", []) or []),
        "warnings":             list(safe_prop(result, "Warnings", []) or []),
    }


def run():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    B = unreal.AnimBP2FPPythonBridge  # 简写

    if ACTION == "export_text":
        result = B.export_anim_blueprint_to_text(ASSET_PATH)

    elif ACTION == "export_file":
        out_file = os.path.join(OUTPUT_DIR, os.path.basename(DSL_FILE))
        result = B.export_anim_blueprint_to_file(ASSET_PATH, out_file)

    elif ACTION == "update_text":
        if not DSL_TEXT:
            raise ValueError("DSL_TEXT is empty. Fill it before running update_text.")
        result = B.update_anim_blueprint_from_text(ASSET_PATH, DSL_TEXT, SAVE)

    elif ACTION == "update_file":
        result = B.update_anim_blueprint_from_file(ASSET_PATH, DSL_FILE, SAVE)

    elif ACTION == "import_file":
        result = B.import_anim_blueprint_from_file(DSL_FILE, IMPORT_DEST, SAVE)

    elif ACTION == "eventgraph":
        result = B.export_event_graph_to_text(ASSET_PATH, GRAPH_NAME, False, True)

    else:
        raise ValueError(f"Unknown ACTION: {ACTION!r}")

    data = serialize(result)
    print(json.dumps(data, ensure_ascii=False, indent=2))


try:
    run()
except Exception as exc:
    print(json.dumps({
        "success": False,
        "exception": str(exc),
        "traceback": traceback.format_exc(),
    }, ensure_ascii=False, indent=2))
