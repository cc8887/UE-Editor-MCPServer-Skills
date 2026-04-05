#!/usr/bin/env python3
"""构造 AnimBP2FP / BlueprintLisp commandlet 命令行。

用途：
- 避免每次手写 UnrealEditor-Cmd.exe 参数
- 给 skill 使用者一个稳定的命令生成器

示例：
    python build_command.py export
    python build_command.py roundtrip
    python build_command.py import --file <PROJECT_ROOT>/AnimLang/Exported/ALS_AnimBP.animlang
    python build_command.py update --file <PROJECT_ROOT>/AnimLang/Exported/ALS_AnimBP.animlang
    python build_command.py eventgraph --bp /Game/AdvancedLocomotionV4/Blueprints/CharacterLogic/ALS_AnimBP.ALS_AnimBP --roundtrip
"""

from __future__ import annotations

import argparse
import shlex
from typing import List

# 请根据实际环境修改以下路径
ENGINE_CMD = r"<ENGINE_ROOT>/Engine/Binaries/Win64/UnrealEditor-Cmd.exe"
PROJECT = r"<PROJECT_FILE>"
DEFAULT_IMPORT_OUTDIR = "/Game/AnimBP2FP/Imported"


def quote_args(parts: List[str]) -> str:
    return " ".join(shlex.quote(p) for p in parts)


def build_command(args: argparse.Namespace) -> List[str]:
    cmd = [ENGINE_CMD, PROJECT]

    if args.mode == "export":
        cmd.append("-run=AnimBP2FPExport")
    elif args.mode == "roundtrip":
        cmd.append("-run=AnimBP2FPRoundTrip")
    elif args.mode in {"import", "import-test", "update"}:
        cmd.append("-run=AnimBP2FPImport")
        if args.file:
            cmd.append(f"-file={args.file}")
        if args.outdir:
            cmd.append(f"-outdir={args.outdir}")
        elif args.mode != "export":
            cmd.append(f"-outdir={DEFAULT_IMPORT_OUTDIR}")
        if args.mode == "import-test":
            cmd.append("-test")
        if args.mode == "update":
            cmd.append("-update")
    elif args.mode == "eventgraph":
        cmd.append("-run=AnimBP2FPBlueprintLisp")
        if args.bp:
            cmd.append(f"-bp={args.bp}")
        if args.graph:
            cmd.append(f"-graph={args.graph}")
        if args.roundtrip:
            cmd.append("-roundtrip")
        if args.nowrite:
            cmd.append("-nowrite")
    else:
        raise ValueError(f"Unsupported mode: {args.mode}")

    cmd.extend(["-stdout", "-unattended", "-nullrhi"])
    return cmd


def main() -> None:
    parser = argparse.ArgumentParser(description="Build AnimBP2FP commandlet command line")
    parser.add_argument("mode", choices=["export", "roundtrip", "import", "import-test", "update", "eventgraph"])
    parser.add_argument("--file", help="Absolute .animlang file path for import/update/test")
    parser.add_argument("--outdir", help="Output package path, e.g. /Game/AnimBP2FP/Imported")
    parser.add_argument("--bp", help="Blueprint object path for eventgraph export")
    parser.add_argument("--graph", default="EventGraph", help="Graph name for eventgraph export")
    parser.add_argument("--roundtrip", action="store_true", help="Enable roundtrip for eventgraph export")
    parser.add_argument("--nowrite", action="store_true", help="Do not write files for eventgraph export")
    ns = parser.parse_args()

    cmd = build_command(ns)
    print(quote_args(cmd))


if __name__ == "__main__":
    main()
