---
name: ue-diagnosing-plugin-build-load
description: Prevent and diagnose mixed, stale, partial, or incompatible Unreal Engine plugin builds. Use when creating or opening a UE project with native plugins, modifying plugin source or descriptors, changing engine versions, onboarding shared plugins, generating project files, or investigating enabled-but-not-compiled, module startup, commandlet, NullRHI, /Script package, or EditorMCP loading failures.
---

# Prevent UE Plugin Build And Load Failures

## Build contract

Treat plugin availability as one project Editor-target transaction. Build the complete project Editor target, audit every applicable project-plugin module and dependency against the same engine identity, and write build state only after the audit passes.

Do not use a leaf-plugin build, copied DLL, edited `BuildId`, Live Coding result, or `Enabled=true` as proof. Do not launch the Editor, NullRHI commandlet, export commandlet, or EditorMCP workflow until this contract passes.

Use `superpowers:systematic-debugging` when the contract fails and `superpowers:verification-before-completion` before reporting success.

## Standard entry point

Set paths from the active workspace and environment. Never reproduce the machine-specific skill location from a loading instruction in user commands, and never embed a workstation path in project scripts.

```powershell
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$SkillRoot = Join-Path $CodexHome 'skills\ue-diagnosing-plugin-build-load'
$Project = (Resolve-Path '.\Game.uproject').Path
$EngineRoot = (Resolve-Path $env:UE_ENGINE_ROOT).Path
$BuildScript = Join-Path $SkillRoot 'scripts\build-ue-editor-with-plugins.ps1'

& $BuildScript -Project $Project -EngineRoot $EngineRoot
if ($LASTEXITCODE -ne 0) { throw "Plugin build contract failed: $LASTEXITCODE" }
```

The wrapper resolves `UnrealBuildTool.exe` directly and preserves each argument as one Windows process argument. It does not pass UBT through `cmd.exe` or a batch-file reparse. It serializes work per project, streams unique logs under `Saved/Logs/PluginBuild/`, audits receipts/manifests/DLLs, and atomically writes `Saved/PluginBuildState/<EditorTarget>.json` only on success.

Pass extra UBT arguments as an array:

```powershell
$Extra = @('-SomeFlag', '-Setting=Value With Space')
& $BuildScript -Project $Project -EngineRoot $EngineRoot -AdditionalBuildArgs $Extra
```

## Workflow by situation

### New or content-only project

1. Read `EngineAssociation` and the selected engine `Engine/Build/Build.version`; reject an unintended engine before building.
2. If native project plugins exist but `Source/*Editor.Target.cs` does not, invoke the `bpproject2cpp` skill and follow its UnrealBuildTool-based conversion workflow to create the minimal C++ host module and project Editor target. Do not synthesize `Target.cs`, `Build.cs`, module source, or `.uproject` JSON in an inline PowerShell script; those templates and project-file updates vary by engine version. A native plugin needs a host target even when gameplay remains Blueprint-only.
3. Generate project files and build through the same wrapper:

   ```powershell
   & $BuildScript -Project $Project -EngineRoot $EngineRoot -GenerateProjectFiles
   ```

4. Require the audit and state-file gates before the first Editor launch.

### Plugin source, descriptor, or dependency change

1. Close the Editor for this project or disable Live Coding.
2. Update both dependency layers when required: `.uplugin` `Plugins` references express plugin ownership; `.Build.cs` dependencies express module linkage.
3. Run the standard wrapper. It computes the transitive applicable project-plugin closure for `Win64`, `Editor`, `Development` and builds the whole project Editor target.
4. Treat UBT's missing plugin-dependency warning as a failed contract even when compilation exits zero.

### Engine switch or project reassociation

1. Select the intended engine explicitly; do not rely on whichever editor last opened the project.
2. Run the wrapper without quarantine first. Engine receipt/version or `BuildId` mismatches fail fast and list blockers.
3. Inspect the listed files. If they are confirmed generated, project-local outputs, rerun explicitly:

   ```powershell
   & $BuildScript -Project $Project -EngineRoot $EngineRoot -QuarantineStaleArtifacts
   ```

The switch moves only recognized project-local receipt, manifest, mapped DLL, and mapped PDB files into `Saved/BuildReceiptBackup/<UTC timestamp>/`. It does not delete source, config, content, `Intermediate`, or outputs reached through a shared-plugin reparse point.

### Binary-only plugin

Require a binary distribution built for the selected engine identity, platform, target, and configuration. If its receipt/manifest is incompatible and source is unavailable, obtain a matching binary package or the source; rebuilding the host cannot make an incompatible binary compatible. Never copy a DLL from another engine tree or rewrite its `BuildId`.

## Shared plugin layout

Block a junction or symlink at `Plugins/<Plugin>` by default. A whole-plugin link shares `Binaries` and `Intermediate` across projects and engine installs, so one successful build can silently poison another.

Prefer a project-local plugin shell:

```text
Plugins/<Plugin>/
  <Plugin>.uplugin        project-local
  Binaries/              project-local generated output
  Intermediate/          project-local generated output
  Source/                may link to shared source
  Content/               may link when sharing content is intended
```

Migrate by recreating the plugin directory locally, retaining a local descriptor, and linking only the necessary `Source` or `Content` subtree. Use `-AllowSharedPluginOutputs` only as an explicit temporary exception after accepting cross-project output ownership; the wrapper still refuses to quarantine external/shared outputs.

## Failure triage

Preserve the first failing log and classify that error before later `/Script/...` fallout.

| Symptom | Likely failed boundary |
|---|---|
| `NO_EDITOR_HOST_TARGET` | Native plugins have no complete project Editor target |
| `WHOLE_PLUGIN_REPARSE_POINT` | Plugin output directories are shared through a whole-plugin link |
| `RECEIPT_ENGINE_MISMATCH` or `STALE_BUILD_ID` | Generated outputs belong to another engine/build transaction |
| module could not be found | Target omitted it, manifest/DLL is missing, or filters exclude it |
| incompatible/different engine version | Engine identity or binary distribution mismatch |
| module could not initialize | Native dependency or `StartupModule` failure |
| failed to load `/Script/X` | Native module `X` did not create its reflected package |
| commandlet missing after module load | Registration, loading phase, module type, or `-run` name |

Use the bundled audit alone for a read-only inspection:

```powershell
$AuditScript = Join-Path $SkillRoot 'scripts\audit-ue-plugin-build.ps1'
& $AuditScript -Project $Project -EngineRoot $EngineRoot
```

For cold-load diagnosis, start a fresh `UnrealEditor-Cmd.exe` with a unique log, `-stdout -FullStdOutLogOutput -unattended -nosplash`, and the required NullRHI or commandlet arguments. Verify exit code, the expected module-load lines, commandlet execution, output count, parseability, schema, expected asset set, and determinism where relevant.

## EditorMCP boundary

Use EditorMCP after the native editor module and forwarder have loaded. It can call this external wrapper, run post-start Python, inspect assets, and validate interactive state. It cannot be the sole bootstrap authority because the plugin needed to expose MCP may itself be the module that failed to build or load.

Do not accept an EditorMCP `READY` result as proof that all project plugins are current. Keep UBT invocation, cross-plugin fingerprints, receipt/manifest auditing, pre-MCP startup failures, short-lived NullRHI commandlets, and post-exit artifact assertions in the external bootstrap flow.

## Completion gate

Require all applicable evidence: complete Editor-target build exits zero; dependency warnings are absent; receipts, manifests, engine identity, module mappings, and DLLs agree; the build-state file exists for the exact inputs; cold startup loads expected modules without related errors; the commandlet/export exits zero and its artifact passes semantic checks; normal Editor restart succeeds. For plugin, configuration, or loading changes, also perform project data validation and the repository-required packaged build.
