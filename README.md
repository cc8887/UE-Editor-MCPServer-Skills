# UE-Editor-MCPServer Skills Marketplace

Skills marketplace for [UE-Editor-MCPServer](https://github.com/cc8887/UE-Editor-MCPServer) - enabling AI agents to automate Unreal Engine development through MCP.

## Plugins

| Plugin | Description |
|--------|-------------|
| **alsv-blueprint-rw** | Read/write AnimBlueprint assets via in-process Python Bridge |
| **animbp2fp-mcp** | AnimBP2FP conversion through MCP (export, import, round-trip) |
| **blueprint-lisp** | BlueprintLisp DSL for any Blueprint graph |
| **matbp2fp** | Material to MatLang DSL conversion |

## Prerequisites

- [UE-Editor-MCPServer](https://github.com/cc8887/UE-Editor-MCPServer) plugin installed and running
- UE5.5 editor with PythonScriptPlugin enabled
- AnimBP2FP, MatBP2FP, BlueprintLisp plugins compiled for your project

## Usage

Add this marketplace to your Claude Code / WorkBuddy configuration:

```json
{
  "mcpServers": {
    "ue-editor": {
      "url": "http://127.0.0.1:8099/SSE"
    }
  }
}
```

> **Important**: The SSE endpoint path must be uppercase `/SSE` (not `/sse`).

## Requirements

These skills are designed for projects using:
- AnimBP2FP plugin (AnimBlueprint <-> AnimLang DSL)
- MatBP2FP plugin (Material <-> MatLang DSL)
- BlueprintLisp plugin (Blueprint Graph <-> BlueprintLisp DSL)

## License

MIT
