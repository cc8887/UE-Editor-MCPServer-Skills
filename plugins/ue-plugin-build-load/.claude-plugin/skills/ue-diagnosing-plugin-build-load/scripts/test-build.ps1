param()

$ErrorActionPreference = 'Stop'
$BuildScript = Join-Path $PSScriptRoot 'build-ue-editor-with-plugins.ps1'
$AuditScript = Join-Path $PSScriptRoot 'audit-ue-plugin-build.ps1'
$Root = Join-Path ([System.IO.Path]::GetTempPath()) ('ue plugin build tests ' + [guid]::NewGuid())
$FakeUbtTemplate = Join-Path $Root 'host template/UnrealBuildTool.exe'
$WindowsPowerShell = Join-Path $PSHOME 'powershell.exe'
$OriginalFixtureEnvironment = @{}
foreach ($Entry in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'UE_FIXTURE_*' })) {
    $OriginalFixtureEnvironment[$Entry.Name] = [pscustomobject]@{
        Exists = $true
        Value = $Entry.Value
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT_FAIL $Message" }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) {
        throw "ASSERT_FAIL $Message`nExpected pattern: $Pattern`nActual:`n$Actual"
    }
}

function Assert-PropertySet {
    param([object]$Value, [string[]]$Expected, [string]$Message)
    $Actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $Wanted = @($Expected | Sort-Object)
    if (($Actual -join '|') -ne ($Wanted -join '|')) {
        throw "ASSERT_FAIL $Message`nExpected: $($Wanted -join ', ')`nActual: $($Actual -join ', ')"
    }
}

function Test-InvokeLoggedToolOwnsStartedProcessLifetime {
    $Source = Get-Content -LiteralPath $BuildScript -Raw
    Assert-Match $Source '(?s)function Stop-ToolProcessTree\b.*?taskkill\.exe.*?/T.*?/F' `
        'the wrapper must provide bounded process-tree termination for exceptional tool exits'
    Assert-Match $Source '(?s)finally\s*\{.*?if\s*\(\$ProcessStarted\s*-and\s*-not\s*\$Process\.HasExited\).*?Stop-ToolProcessTree' `
        'Invoke-LoggedTool must not release the project lock while a started UBT process can remain alive'
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    $Parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-TextFile {
    param([string]$Path, [string]$Value)
    $Parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    Set-Content -LiteralPath $Path -Value $Value -Encoding UTF8
}

function Write-AsciiFile {
    param([string]$Path, [string]$Value)
    $Parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    Set-Content -LiteralPath $Path -Value $Value -Encoding ASCII
}

function New-Fixture {
    param(
        [string]$Name,
        [switch]$WithoutHostTarget,
        [switch]$SharedPlugin,
        [switch]$InternalPluginJunction,
        [switch]$PluginSourceJunction,
        [switch]$WithDependencyPlugin,
        [switch]$WithoutProjectPlugin,
        [switch]$SuppressDependencyOutput,
        [switch]$EmitServerOnlyModule
    )

    $FixtureRoot = Join-Path $Root $Name
    $EngineRoot = Join-Path $FixtureRoot 'Engine Root'
    $ProjectRoot = Join-Path $FixtureRoot 'Project Root'
    $Project = Join-Path $ProjectRoot 'Game.uproject'
    $CallLog = Join-Path $FixtureRoot 'tool arguments.jsonl'

    Write-JsonFile (Join-Path $EngineRoot 'Engine/Build/Build.version') @{
        MajorVersion = 5
        MinorVersion = 8
        PatchVersion = 0
    }
    Write-JsonFile $Project @{
        FileVersion = 3
        EngineAssociation = '5.8'
        Modules = @(@{ Name = 'Game'; Type = 'Runtime'; LoadingPhase = 'Default' })
        Plugins = @(@{ Name = 'MyPlugin'; Enabled = $true; TargetAllowList = @('Editor') })
    }

    if (-not $WithoutHostTarget) {
        Write-TextFile (Join-Path $ProjectRoot 'Source/GameEditor.Target.cs') @'
public class GameEditorTarget : TargetRules
{
    public GameEditorTarget(TargetInfo Target) : base(Target) {}
}
'@
    }

    $PluginRoot = Join-Path $ProjectRoot 'Plugins/MyPlugin'
    if ($SharedPlugin) {
        $PluginRoot = Join-Path $FixtureRoot 'External Plugin/MyPlugin'
        New-Item -ItemType Directory -Force -Path $PluginRoot | Out-Null
        $ProjectPlugins = Join-Path $ProjectRoot 'Plugins'
        New-Item -ItemType Directory -Force -Path $ProjectPlugins | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $ProjectPlugins 'MyPlugin') `
            -Target $PluginRoot | Out-Null
    }
    elseif ($InternalPluginJunction) {
        $PluginRoot = Join-Path $ProjectRoot 'Alternate Plugin/MyPlugin'
        New-Item -ItemType Directory -Force -Path $PluginRoot | Out-Null
        $ProjectPlugins = Join-Path $ProjectRoot 'Plugins'
        New-Item -ItemType Directory -Force -Path $ProjectPlugins | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $ProjectPlugins 'MyPlugin') `
            -Target $PluginRoot | Out-Null
    }
    if (-not $WithoutProjectPlugin) {
        $PluginDescriptor = @{
            FileVersion = 3
            Modules = @(@{ Name = 'MyPluginEditor'; Type = 'Editor'; LoadingPhase = 'Default' })
        }
        if ($WithDependencyPlugin) {
            $PluginDescriptor.Plugins = @(@{ Name = 'DependencyPlugin'; Enabled = $true })
        }
        Write-JsonFile (Join-Path $PluginRoot 'MyPlugin.uplugin') $PluginDescriptor
        if ($EmitServerOnlyModule) {
            $PluginDescriptor.Modules += @{
                Name = 'ServerHostEditor'; Type = 'ServerOnly'; LoadingPhase = 'Default'
            }
            Write-JsonFile (Join-Path $PluginRoot 'MyPlugin.uplugin') $PluginDescriptor
        }
    }
    if ($PluginSourceJunction -and -not $WithoutProjectPlugin) {
        $SourceTargetA = Join-Path $FixtureRoot 'Alternate Inputs/Input A'
        $SourceTargetB = Join-Path $FixtureRoot 'Alternate Inputs/Input B'
        foreach ($SourceTarget in @($SourceTargetA, $SourceTargetB)) {
            Write-TextFile (Join-Path $SourceTarget 'MyPluginEditor/MyPluginEditor.Build.cs') `
                'public class MyPluginEditor : ModuleRules {}'
            Write-TextFile (Join-Path $SourceTarget 'MyPluginEditor/MyPluginEditor.h') `
                '#pragma once'
            Write-TextFile (Join-Path $SourceTarget 'MyPluginEditor/MyPluginEditor.cpp') `
                '#include "MyPluginEditor.h"'
        }
        New-Item -ItemType Junction -Path (Join-Path $PluginRoot 'Source') `
            -Target $SourceTargetA | Out-Null
    }
    elseif (-not $WithoutProjectPlugin) {
        Write-TextFile (Join-Path $PluginRoot 'Source/MyPluginEditor/MyPluginEditor.Build.cs') `
            'public class MyPluginEditor : ModuleRules {}'
        Write-TextFile (Join-Path $PluginRoot 'Source/MyPluginEditor/MyPluginEditor.h') '#pragma once'
        Write-TextFile (Join-Path $PluginRoot 'Source/MyPluginEditor/MyPluginEditor.cpp') `
            '#include "MyPluginEditor.h"'
    }
    $DependencyPluginRoot = $null
    if ($WithDependencyPlugin) {
        $DependencyPluginRoot = Join-Path $ProjectRoot 'Plugins/DependencyPlugin'
        Write-JsonFile (Join-Path $DependencyPluginRoot 'DependencyPlugin.uplugin') @{
            FileVersion = 3
            Modules = @(@{ Name = 'DependencyPluginEditor'; Type = 'Editor'; LoadingPhase = 'Default' })
        }
        Write-TextFile (Join-Path $DependencyPluginRoot 'Source/DependencyPluginEditor/DependencyPluginEditor.Build.cs') `
            'public class DependencyPluginEditor : ModuleRules {}'
        Write-TextFile (Join-Path $DependencyPluginRoot 'Source/DependencyPluginEditor/DependencyPluginEditor.cpp') `
            '// dependency source'
    }
    Write-TextFile (Join-Path $ProjectRoot 'Content/keep.uasset') 'content marker'
    Write-TextFile (Join-Path $ProjectRoot 'Config/DefaultGame.ini') 'config marker'

    $FakeBuild = Join-Path $FixtureRoot 'fake ubt.ps1'
    Write-TextFile $FakeBuild @'
param(
    [Parameter(Position = 0)][string]$Tool,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$BuildArguments
)
$ErrorActionPreference = 'Stop'

$HostLoggedArguments = -not [string]::IsNullOrWhiteSpace($env:UE_FIXTURE_ARGS_BASE64)
if ($HostLoggedArguments) {
    $Tool = $env:UE_FIXTURE_TOOL
    $BuildArguments = @(
        $env:UE_FIXTURE_ARGS_BASE64 -split ';' | ForEach-Object {
            [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_))
        }
    )
}

function Write-JsonFile([string]$Path, [object]$Value) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

if (-not $HostLoggedArguments) {
    for ($Index = 0; $Index -lt $BuildArguments.Count; $Index++) {
        [pscustomobject]@{
            tool = $Tool
            index = $Index
            value = $BuildArguments[$Index]
            pid = $PID
        } | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:UE_FIXTURE_CALL_LOG -Encoding UTF8
    }
}

if ($Tool -eq 'GenerateProjectFiles') { exit 0 }
if ($env:UE_FIXTURE_MODE -eq 'record-only') { exit 7 }
if ($env:UE_FIXTURE_MODE -eq 'ubt-failure') {
    Write-Output 'fixture UBT failure'
    exit 23
}
if ($env:UE_FIXTURE_MODE -eq 'stream-block') {
    Write-Output 'UE_FIXTURE_STREAM_MARKER_7F39'
}
if ($env:UE_FIXTURE_MODE -eq 'lock-block' -or $env:UE_FIXTURE_MODE -eq 'stream-block') {
    Add-Content -LiteralPath $env:UE_FIXTURE_BLOCK_ENTERED -Value "$PID" -Encoding ASCII
    while (-not (Test-Path -LiteralPath $env:UE_FIXTURE_BLOCK_RELEASE -PathType Leaf)) {
        Start-Sleep -Milliseconds 100
    }
}

$Target = $BuildArguments[0]
$ProjectRoot = $env:UE_FIXTURE_PROJECT_ROOT
$PluginRoot = $env:UE_FIXTURE_PLUGIN_ROOT
$Project = Join-Path $ProjectRoot 'Game.uproject'
$BuildId = 'fresh-fixture-build-id'
$EngineVersion = Get-Content -LiteralPath `
    (Join-Path $env:UE_FIXTURE_ENGINE_ROOT 'Engine/Build/Build.version') -Raw | ConvertFrom-Json
$Dll = Join-Path $PluginRoot 'Binaries/Win64/UnrealEditor-MyPluginEditor.dll'
$Pdb = Join-Path $PluginRoot 'Binaries/Win64/UnrealEditor-MyPluginEditor.pdb'
$RelativeDll = '$(ProjectDir)/Plugins/MyPlugin/Binaries/Win64/UnrealEditor-MyPluginEditor.dll'
$BuildProducts = @(@{ Path = $RelativeDll; Type = 'DynamicLibrary' })
$ManifestModules = @{ MyPluginEditor = 'UnrealEditor-MyPluginEditor.dll' }
if ($env:UE_FIXTURE_EMIT_SERVER_ONLY -eq 'true') {
    $BuildProducts += @{
        Path = '$(ProjectDir)/Plugins/MyPlugin/Binaries/Win64/UnrealEditor-ServerHostEditor.dll'
        Type = 'DynamicLibrary'
    }
    $ManifestModules.ServerHostEditor = 'UnrealEditor-ServerHostEditor.dll'
}
$DependencyPluginRoot = $env:UE_FIXTURE_DEPENDENCY_PLUGIN_ROOT
if (-not [string]::IsNullOrWhiteSpace($DependencyPluginRoot) -and
    $env:UE_FIXTURE_SUPPRESS_DEPENDENCY_OUTPUT -ne 'true') {
    $BuildProducts += @{
        Path = '$(ProjectDir)/Plugins/DependencyPlugin/Binaries/Win64/UnrealEditor-DependencyPluginEditor.dll'
        Type = 'DynamicLibrary'
    }
}

Write-JsonFile (Join-Path $ProjectRoot "Binaries/Win64/$Target.target") @{
    TargetName = $Target
    Version = @{
        BuildId = $BuildId
        MajorVersion = $EngineVersion.MajorVersion
        MinorVersion = $EngineVersion.MinorVersion
        PatchVersion = $EngineVersion.PatchVersion
    }
    BuildProducts = $BuildProducts
}
Write-JsonFile (Join-Path $PluginRoot 'Binaries/Win64/UnrealEditor.modules') @{
    BuildId = $(if ($env:UE_FIXTURE_MODE -eq 'audit-failure') { 'mismatched-audit-build-id' } else { $BuildId })
    Modules = $ManifestModules
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dll) | Out-Null
if ($env:UE_FIXTURE_MODE -ne 'audit-failure') {
    Set-Content -LiteralPath $Dll -Value 'fresh dll marker' -Encoding UTF8
}
Set-Content -LiteralPath $Pdb -Value 'fresh pdb marker' -Encoding UTF8
if ($env:UE_FIXTURE_EMIT_SERVER_ONLY -eq 'true') {
    Set-Content -LiteralPath (Join-Path $PluginRoot `
        'Binaries/Win64/UnrealEditor-ServerHostEditor.dll') `
        -Value 'server-only dll marker' -Encoding UTF8
}

if (-not [string]::IsNullOrWhiteSpace($DependencyPluginRoot) -and
    $env:UE_FIXTURE_SUPPRESS_DEPENDENCY_OUTPUT -ne 'true') {
    $DependencyDll = Join-Path $DependencyPluginRoot `
        'Binaries/Win64/UnrealEditor-DependencyPluginEditor.dll'
    Write-JsonFile (Join-Path $DependencyPluginRoot 'Binaries/Win64/UnrealEditor.modules') @{
        BuildId = $BuildId
        Modules = @{ DependencyPluginEditor = 'UnrealEditor-DependencyPluginEditor.dll' }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DependencyDll) | Out-Null
    Set-Content -LiteralPath $DependencyDll -Value 'dependency dll marker' -Encoding UTF8
}

if ($env:UE_FIXTURE_MODE -eq 'dependency-warning') {
    Write-Output "WARNING: Plugin 'MyPlugin' does not list plugin 'DependencyPlugin' as a dependency, but module 'MyPluginEditor' depends on module 'DependencyModule'."
}
exit 0
'@

    $FakeUbt = Join-Path $EngineRoot 'Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.exe'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $FakeUbt) | Out-Null
    $FakeHostSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public static class FakeUnrealBuildTool
{
    public static int Main(string[] args)
    {
        string tool = args.Length > 0 && args[0] == "-ProjectFiles"
            ? "GenerateProjectFiles" : "Build";
        string log = Environment.GetEnvironmentVariable("UE_FIXTURE_CALL_LOG");
        using (StreamWriter writer = new StreamWriter(log, true, new UTF8Encoding(false)))
        {
            for (int index = 0; index < args.Length; index++)
            {
                string encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(args[index]));
                writer.WriteLine("{\"tool\":\"" + tool + "\",\"index\":" + index +
                    ",\"value_base64\":\"" + encoded + "\",\"pid\":" +
                    Process.GetCurrentProcess().Id + "}");
            }
        }

        string[] encodedArgs = new string[args.Length];
        for (int index = 0; index < args.Length; index++)
        {
            encodedArgs[index] = Convert.ToBase64String(Encoding.UTF8.GetBytes(args[index]));
        }
        Environment.SetEnvironmentVariable("UE_FIXTURE_TOOL", tool);
        Environment.SetEnvironmentVariable("UE_FIXTURE_ARGS_BASE64", String.Join(";", encodedArgs));

        ProcessStartInfo start = new ProcessStartInfo();
        start.FileName = Environment.GetEnvironmentVariable("UE_FIXTURE_POWERSHELL");
        start.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" +
            Environment.GetEnvironmentVariable("UE_FIXTURE_FAKE_BUILD") + "\"";
        start.UseShellExecute = false;
        start.RedirectStandardOutput = false;
        start.RedirectStandardError = false;
        Process child = Process.Start(start);
        child.WaitForExit();
        return child.ExitCode;
    }
}
'@
    if (-not (Test-Path -LiteralPath $FakeUbtTemplate -PathType Leaf)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $FakeUbtTemplate) | Out-Null
        Add-Type -TypeDefinition $FakeHostSource -Language CSharp `
            -OutputAssembly $FakeUbtTemplate -OutputType ConsoleApplication
    }
    Copy-Item -LiteralPath $FakeUbtTemplate -Destination $FakeUbt

    [pscustomobject]@{
        Root = $FixtureRoot
        EngineRoot = $EngineRoot
        ProjectRoot = $ProjectRoot
        Project = $Project
        PluginRoot = $PluginRoot
        CallLog = $CallLog
        FakeBuild = $FakeBuild
        FakeUbt = $FakeUbt
        DependencyPluginRoot = $DependencyPluginRoot
        SuppressDependencyOutput = [bool]$SuppressDependencyOutput
        EmitServerOnlyModule = [bool]$EmitServerOnlyModule
        SourceTargetA = $SourceTargetA
        SourceTargetB = $SourceTargetB
    }
}

function Add-StaleArtifacts {
    param([object]$Fixture)
    $Receipt = Join-Path $Fixture.ProjectRoot 'Binaries/Win64/GameEditor.target'
    $Manifest = Join-Path $Fixture.PluginRoot 'Binaries/Win64/UnrealEditor.modules'
    $Dll = Join-Path $Fixture.PluginRoot 'Binaries/Win64/UnrealEditor-MyPluginEditor.dll'
    $Pdb = Join-Path $Fixture.PluginRoot 'Binaries/Win64/UnrealEditor-MyPluginEditor.pdb'

    Write-JsonFile $Receipt @{
        FixtureMarker = 'stale receipt marker'
        TargetName = 'GameEditor'
        Version = @{
            BuildId = 'stale-build-id'
            MajorVersion = 5
            MinorVersion = 8
            PatchVersion = 0
        }
        BuildProducts = @(@{
            Path = '$(ProjectDir)/Plugins/MyPlugin/Binaries/Win64/UnrealEditor-MyPluginEditor.dll'
            Type = 'DynamicLibrary'
        })
    }
    Write-JsonFile $Manifest @{
        FixtureMarker = 'stale manifest marker'
        BuildId = 'different-stale-build-id'
        Modules = @{ MyPluginEditor = 'UnrealEditor-MyPluginEditor.dll' }
    }
    Write-TextFile $Dll 'stale dll marker'
    Write-TextFile $Pdb 'stale pdb marker'
    Write-TextFile (Join-Path $Fixture.PluginRoot 'Binaries/Win64/Unlisted.dll') 'unlisted marker'
    Write-TextFile (Join-Path $Fixture.PluginRoot 'Intermediate/Build/DoNotMove.obj') 'intermediate marker'
}

function Add-UnsafeManifestArtifacts {
    param([object]$Fixture)
    $Victim = Join-Path $Fixture.PluginRoot 'Source/Victim.cpp'
    Write-TextFile $Victim 'victim source marker'
    Write-JsonFile (Join-Path $Fixture.ProjectRoot 'Binaries/Win64/GameEditor.target') @{
        TargetName = 'GameEditor'
        Version = @{
            BuildId = 'unsafe-target-build-id'
            MajorVersion = 5; MinorVersion = 8; PatchVersion = 0
        }
        BuildProducts = @()
    }
    Write-JsonFile (Join-Path $Fixture.PluginRoot 'Binaries/Win64/UnrealEditor.modules') @{
        BuildId = 'unsafe-manifest-build-id'
        Modules = @{ MyPluginEditor = '..\..\Source\Victim.cpp' }
    }
    $Victim
}

function Add-PreviousEngineArtifacts {
    param([object]$Fixture)
    Write-JsonFile (Join-Path $Fixture.EngineRoot 'Engine/Build/Build.version') @{
        MajorVersion = 5; MinorVersion = 9; PatchVersion = 0
    }
    $ProjectJson = Get-Content -LiteralPath $Fixture.Project -Raw | ConvertFrom-Json
    $ProjectJson.EngineAssociation = '5.9'
    Write-JsonFile $Fixture.Project $ProjectJson
    $BuildId = 'previous-engine-build-id'
    Write-JsonFile (Join-Path $Fixture.ProjectRoot 'Binaries/Win64/GameEditor.target') @{
        TargetName = 'GameEditor'
        Version = @{
            BuildId = $BuildId
            MajorVersion = 5; MinorVersion = 8; PatchVersion = 7
        }
        BuildProducts = @(@{
            Path = '$(ProjectDir)/Plugins/MyPlugin/Binaries/Win64/UnrealEditor-MyPluginEditor.dll'
            Type = 'DynamicLibrary'
        })
    }
    Write-JsonFile (Join-Path $Fixture.PluginRoot 'Binaries/Win64/UnrealEditor.modules') @{
        BuildId = $BuildId
        Modules = @{ MyPluginEditor = 'UnrealEditor-MyPluginEditor.dll' }
    }
    Write-TextFile (Join-Path $Fixture.PluginRoot `
        'Binaries/Win64/UnrealEditor-MyPluginEditor.dll') 'previous engine dll marker'
}

function Invoke-BuildFixture {
    param(
        [object]$Fixture,
        [string]$Mode = 'success',
        [string]$EngineArgument = 'Engine Root',
        [string[]]$ExtraArguments = @(),
        [AllowNull()][string[]]$AdditionalBuildArguments = $null
    )

    $env:UE_FIXTURE_MODE = $Mode
    $env:UE_FIXTURE_POWERSHELL = $WindowsPowerShell
    $env:UE_FIXTURE_CALL_LOG = $Fixture.CallLog
    $env:UE_FIXTURE_FAKE_BUILD = $Fixture.FakeBuild
    $env:UE_FIXTURE_PROJECT_ROOT = $Fixture.ProjectRoot
    $env:UE_FIXTURE_PLUGIN_ROOT = $Fixture.PluginRoot
    $env:UE_FIXTURE_DEPENDENCY_PLUGIN_ROOT = "$($Fixture.DependencyPluginRoot)"
    $env:UE_FIXTURE_SUPPRESS_DEPENDENCY_OUTPUT = "$($Fixture.SuppressDependencyOutput)".ToLowerInvariant()
    $env:UE_FIXTURE_EMIT_SERVER_ONLY = "$($Fixture.EmitServerOnlyModule)".ToLowerInvariant()
    $env:UE_FIXTURE_ENGINE_ROOT = Join-Path $Fixture.Root $EngineArgument

    Push-Location $Fixture.Root
    try {
        if ($null -ne $AdditionalBuildArguments) {
            $env:UE_FIXTURE_ADDITIONAL_ARGS_JSON = `
                ConvertTo-Json @($AdditionalBuildArguments) -Compress
            $Runner = Join-Path $Fixture.Root 'additional arguments runner.ps1'
            Write-TextFile $Runner @"
[string[]]`$Additional = (`$env:UE_FIXTURE_ADDITIONAL_ARGS_JSON | ConvertFrom-Json)
& '$BuildScript' -Project 'Project Root/Game.uproject' -EngineRoot '$EngineArgument' -AdditionalBuildArgs `$Additional
exit `$LASTEXITCODE
"@
            $Arguments = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Runner
            )
        }
        else {
            $Arguments = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $BuildScript,
                '-Project', 'Project Root/Game.uproject',
                '-EngineRoot', $EngineArgument
            ) + $ExtraArguments
        }
        $Output = & $WindowsPowerShell @Arguments 2>&1 | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Output = $Output }
    }
    finally {
        Pop-Location
    }
}

function Get-CallLog([object]$Fixture) {
    if (-not (Test-Path -LiteralPath $Fixture.CallLog)) { return '' }
    Get-Content -LiteralPath $Fixture.CallLog -Raw
}

function Get-ToolArguments {
    param([object]$Fixture, [string]$Tool)
    if (-not (Test-Path -LiteralPath $Fixture.CallLog)) { return @() }
    @(
        Get-Content -LiteralPath $Fixture.CallLog |
            ForEach-Object {
                $Record = $_ | ConvertFrom-Json
                if ($Record.PSObject.Properties.Name -contains 'value_base64') {
                    $Record | Add-Member -NotePropertyName value -NotePropertyValue `
                        ([System.Text.Encoding]::UTF8.GetString(
                            [Convert]::FromBase64String("$($Record.value_base64)")))
                }
                $Record
            } |
            Where-Object { $_.tool -eq $Tool } |
            Sort-Object index
    )
}

function Assert-SingleArgument {
    param([object[]]$Records, [string]$Expected, [string]$Message)
    $Matching = @($Records | Where-Object { $_.value -eq $Expected })
    Assert-True ($Matching.Count -eq 1) $Message
}

function Assert-ArgumentVector {
    param([object[]]$Records, [string[]]$Expected, [string]$Message)
    $ExpectedDisplay = @(
        for ($Index = 0; $Index -lt $Expected.Count; $Index++) {
            "expected[$Index]='$($Expected[$Index])'"
        }
    ) -join "`n"
    $ActualDisplay = @(
        foreach ($Record in $Records) {
            "actual[$($Record.index)]='$($Record.value)'"
        }
    ) -join "`n"
    Assert-True ($Records.Count -eq $Expected.Count) `
        ("$Message (argument count: expected $($Expected.Count), actual $($Records.Count))`n" +
            "$ExpectedDisplay`n$ActualDisplay")
    for ($Index = 0; $Index -lt $Expected.Count; $Index++) {
        Assert-True ($Records[$Index].index -eq $Index) "$Message (recorded index $Index)"
        Assert-True ($Records[$Index].value -ceq $Expected[$Index]) `
            "$Message (index $Index expected '$($Expected[$Index])', actual '$($Records[$Index].value)')"
    }
}

function Find-MarkerFiles {
    param([object]$Fixture, [string]$Marker)
    @(
        Get-ChildItem -LiteralPath $Fixture.Root -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match [regex]::Escape($Marker) }
    )
}

function Test-MissingHostTargetStopsBeforeUbt {
    $Fixture = New-Fixture '01 host case' -WithoutHostTarget
    $Result = Invoke-BuildFixture $Fixture
    Assert-True ($Result.Code -eq 1) 'missing host target must exit 1'
    Assert-Match $Result.Output '(?m)^FAIL NO_EDITOR_HOST_TARGET\b' `
        'missing host target must report the explicit contract error code'
    Assert-True ([string]::IsNullOrWhiteSpace((Get-CallLog $Fixture))) `
        'missing host target must fail before any UnrealBuildTool invocation'
}

function Test-StaleBuildIdFailsWithoutMovingAnything {
    $Fixture = New-Fixture '02 identity case'
    Add-StaleArtifacts $Fixture
    $Result = Invoke-BuildFixture $Fixture
    Assert-True ($Result.Code -eq 1) 'stale BuildId must exit 1 by default'
    Assert-Match $Result.Output '(?m)^FAIL STALE_BUILD_ID\b' `
        'identity mismatch must report the explicit contract error code'
    Assert-True ([string]::IsNullOrWhiteSpace((Get-CallLog $Fixture))) `
        'stale identity must fail before invoking UBT'
    foreach ($Marker in @('stale receipt marker', 'stale manifest marker', 'stale dll marker', 'stale pdb marker')) {
        $Matches = @(Find-MarkerFiles $Fixture $Marker)
        Assert-True ($Matches.Count -eq 1) "default fail-fast must neither move nor copy $Marker"
    }
    Assert-True ((Get-Content -LiteralPath (Join-Path $Fixture.PluginRoot 'Binaries/Win64/Unlisted.dll') -Raw) -match 'unlisted marker') `
        'unlisted output must remain untouched'
}

function Test-ExplicitQuarantineMovesOnlyRecognizedGeneratedFiles {
    $Fixture = New-Fixture '03 explicit quarantine'
    Add-StaleArtifacts $Fixture
    $Result = Invoke-BuildFixture $Fixture -ExtraArguments @('-QuarantineStaleArtifacts')
    Assert-True ($Result.Code -eq 0) "explicit quarantine build must succeed: $($Result.Output)"
    Assert-Match $Result.Output 'QUARANTINE ' 'moved stale artifacts must be reported'
    Assert-Match $Result.Output 'BUILD ' 'UBT invocation must be reported'
    Assert-Match $Result.Output 'STATE ' 'successful state write must be reported'
    $BuildArguments = @(Get-ToolArguments $Fixture 'Build')
    Assert-ArgumentVector $BuildArguments @(
        'GameEditor',
        'Win64',
        'Development',
        "-Project=$($Fixture.Project)",
        '-WaitMutex',
        '-NoHotReloadFromIDE'
    ) 'UBT must receive the exact full Editor target argument vector'

    $BackupRoot = Join-Path $Fixture.ProjectRoot 'Saved/BuildReceiptBackup'
    $BackupTimestamps = @()
    foreach ($Marker in @('stale receipt marker', 'stale manifest marker', 'stale dll marker', 'stale pdb marker')) {
        $Matches = @(Find-MarkerFiles $Fixture $Marker)
        Assert-True ($Matches.Count -eq 1) "quarantine must preserve exactly one copy of $Marker"
        $BackupPrefix = $BackupRoot.TrimEnd('\') + '\'
        Assert-True ($Matches[0].FullName.StartsWith($BackupPrefix, [System.StringComparison]::OrdinalIgnoreCase)) `
            "quarantine must place $Marker below Saved/BuildReceiptBackup/<timestamp>"
        $RelativeBackupPath = $Matches[0].FullName.Substring($BackupPrefix.Length)
        $Segments = @($RelativeBackupPath -split '[\\/]')
        Assert-True ($Segments.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($Segments[0])) `
            "quarantine path must contain a timestamp directory for $Marker"
        Assert-True ($Segments[0] -match '^\d{8}T\d{9}Z$') `
            "quarantine timestamp must use UTC yyyyMMddTHHmmssfffZ format for $Marker"
        $BackupTimestamps += $Segments[0]
    }
    Assert-True (@($BackupTimestamps | Select-Object -Unique).Count -eq 1) `
        'all stale artifacts from one invocation must use one backup timestamp directory'
    foreach ($Pair in @(
        @('Binaries/Win64/Unlisted.dll', 'unlisted marker'),
        @('Intermediate/Build/DoNotMove.obj', 'intermediate marker'),
        @('Source/MyPluginEditor/MyPluginEditor.Build.cs', 'ModuleRules')
    )) {
        $Path = Join-Path $Fixture.PluginRoot $Pair[0]
        Assert-True ((Test-Path -LiteralPath $Path -PathType Leaf) -and
            ((Get-Content -LiteralPath $Path -Raw) -match $Pair[1])) `
            "quarantine must not move unrecognized or source file $($Pair[0])"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $Fixture.PluginRoot 'MyPlugin.uplugin')) `
        'quarantine must not move the plugin descriptor'
    Assert-True (Test-Path -LiteralPath (Join-Path $Fixture.ProjectRoot 'Content/keep.uasset')) `
        'quarantine must not move Content'
    Assert-True (Test-Path -LiteralPath (Join-Path $Fixture.ProjectRoot 'Config/DefaultGame.ini')) `
        'quarantine must not move Config'
}

function Test-DependencyWarningFailsWithoutState {
    $Fixture = New-Fixture '04 compiler message case'
    $Result = Invoke-BuildFixture $Fixture -Mode 'dependency-warning'
    Assert-True ($Result.Code -eq 1) 'plugin dependency warning must fail the build contract'
    Assert-Match $Result.Output '(?m)^FAIL UBT_PLUGIN_DEPENDENCY_WARNING\b' `
        'dependency warning must report the explicit contract error code'
    $State = Join-Path $Fixture.ProjectRoot 'Saved/PluginBuildState/GameEditor.json'
    Assert-True (-not (Test-Path -LiteralPath $State)) 'warning-gated build must not write state'
}

function Test-UbtFailureDoesNotWriteState {
    $Fixture = New-Fixture '05 compiler exit case'
    $Result = Invoke-BuildFixture $Fixture -Mode 'ubt-failure'
    Assert-True ($Result.Code -eq 1) 'nonzero UBT exit must become contract exit 1'
    Assert-Match $Result.Output '(?m)^FAIL UBT_EXIT_NONZERO\b' `
        'UBT failure must report the explicit contract error code'
    Assert-Match $Result.Output '(?m)^fixture UBT failure\r?$' 'UBT failure output must be preserved'
    Assert-True (@(Get-ToolArguments $Fixture 'Build').Count -gt 0) 'UBT failure fixture must invoke Build.bat'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $Fixture.ProjectRoot 'Saved/PluginBuildState/GameEditor.json'))) `
        'nonzero UBT exit must not write state'
}

function Test-AuditFailureDoesNotWriteState {
    $Fixture = New-Fixture '06 audit failure'
    $Result = Invoke-BuildFixture $Fixture -Mode 'audit-failure'
    Assert-True ($Result.Code -eq 1) 'audit failure must become contract exit 1'
    Assert-Match $Result.Output 'AUDIT ' 'orchestrator must report invoking its colocated audit script'
    Assert-Match $Result.Output 'FAIL .*BuildId mismatch' 'real audit must reject the mismatched manifest BuildId'
    Assert-Match $Result.Output 'FAIL .*Missing DLL' 'real audit must reject the deliberately missing DLL'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $Fixture.ProjectRoot 'Saved/PluginBuildState/GameEditor.json'))) `
        'audit failure must not write state'
}

function Test-AdditionalBuildArgumentsPreserveNativeArgv {
    $Fixture = New-Fixture '06 argument integrity case'
    $AdditionalArguments = @(
        '-Define=Value With Space',
        '-Percent=100%',
        '-Meta=a&b',
        '-Quote=a"b',
        '-Caret=a^b',
        '-Pipe=a|b'
    )
    $Result = Invoke-BuildFixture $Fixture `
        -AdditionalBuildArguments $AdditionalArguments
    Assert-True ($Result.Code -eq 0) `
        "dangerous-but-valid additional build arguments must not alter command execution: $($Result.Output)"
    $Expected = @(
        'GameEditor', 'Win64', 'Development', "-Project=$($Fixture.Project)",
        '-WaitMutex', '-NoHotReloadFromIDE'
    ) + $AdditionalArguments
    Assert-ArgumentVector @(Get-ToolArguments $Fixture 'Build') $Expected `
        'AdditionalBuildArgs must reach UnrealBuildTool as exact, ordered, unsplit argv elements'
}

function Test-SuccessAuditsAndWritesState {
    $Fixture = New-Fixture '07 relative success'
    $Result = Invoke-BuildFixture $Fixture -ExtraArguments @('-GenerateProjectFiles')
    Assert-True ($Result.Code -eq 0) "healthy build must succeed: $($Result.Output)"
    Assert-Match $Result.Output 'AUDIT ' 'successful orchestrator build must report its audit invocation'
    Assert-ArgumentVector @(Get-ToolArguments $Fixture 'GenerateProjectFiles') @(
        '-ProjectFiles', "-Project=$($Fixture.Project)", '-Game', '-Engine'
    ) 'GenerateProjectFiles must receive the spaced project path as one exact argument'
    Assert-ArgumentVector @(Get-ToolArguments $Fixture 'Build') @(
        'GameEditor', 'Win64', 'Development', "-Project=$($Fixture.Project)",
        '-WaitMutex', '-NoHotReloadFromIDE'
    ) 'healthy build must receive the spaced project path as one exact argument'

    $AuditOutput = & $WindowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $AuditScript `
        -Project $Fixture.Project -EngineRoot $Fixture.EngineRoot 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) "post-build audit must pass: $AuditOutput"
    Assert-Match $AuditOutput 'AUDIT_PASS' 'post-build audit must report success'

    $StatePath = Join-Path $Fixture.ProjectRoot 'Saved/PluginBuildState/GameEditor.json'
    Assert-True (Test-Path -LiteralPath $StatePath -PathType Leaf) 'successful build must write target state'
    $State = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    Assert-PropertySet $State @(
        'schema_version', 'project_file', 'editor_target', 'platform', 'configuration',
        'engine', 'target_build_id', 'built_at_utc', 'input_fingerprint', 'plugins'
    ) 'state top-level schema must remain stable'
    Assert-PropertySet $State.engine @('root', 'version') 'state engine schema must remain stable'
    Assert-True ($State.schema_version -eq 1) 'state schema_version must be 1'
    Assert-True (-not [string]::IsNullOrWhiteSpace("$($State.project_file)")) `
        'state must identify the project file'
    Assert-True ($State.editor_target -eq 'GameEditor') 'state must identify the Editor target'
    Assert-True ($State.platform -eq 'Win64' -and $State.configuration -eq 'Development') `
        'state must identify platform and configuration'
    Assert-True ($State.target_build_id -eq 'fresh-fixture-build-id') 'state must record audited BuildId'
    Assert-True ($State.engine.root -eq $Fixture.EngineRoot -and
        -not [string]::IsNullOrWhiteSpace("$($State.engine.version)")) `
        'state must record the resolved engine root and version'
    Assert-True (-not [string]::IsNullOrWhiteSpace("$($State.built_at_utc)")) 'state must record build time'
    Assert-True (-not [string]::IsNullOrWhiteSpace("$($State.input_fingerprint)")) 'state must record input fingerprint'
    Assert-True (@($State.plugins).Count -eq 1 -and $State.plugins[0].name -eq 'MyPlugin') `
        'state must record the audited project plugin'
    Assert-PropertySet $State.plugins[0] @('name', 'descriptor', 'build_id', 'modules') `
        'state plugin schema must remain stable'
    Assert-True (-not [string]::IsNullOrWhiteSpace("$($State.plugins[0].descriptor)") -and
        $State.plugins[0].build_id -eq 'fresh-fixture-build-id' -and
        @($State.plugins[0].modules) -contains 'MyPluginEditor') `
        'plugin state must record descriptor, BuildId, and module names'

    $PreviousFingerprint = "$($State.input_fingerprint)"
    $NoInputChange = Invoke-BuildFixture $Fixture
    Assert-True ($NoInputChange.Code -eq 0) `
        "second build without input changes must succeed: $($NoInputChange.Output)"
    $StableFingerprint = "$((Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).input_fingerprint)"
    Assert-True ($StableFingerprint -eq $PreviousFingerprint) `
        'input_fingerprint must stay stable when only fake UBT receipts and DLL outputs are rewritten'

    $TimestampOnlyPath = Join-Path $Fixture.PluginRoot 'Source/MyPluginEditor/MyPluginEditor.h'
    $TimestampContentHash = (Get-FileHash -LiteralPath $TimestampOnlyPath -Algorithm SHA256).Hash
    $TimestampFile = Get-Item -LiteralPath $TimestampOnlyPath
    $TimestampFile.LastWriteTimeUtc = $TimestampFile.LastWriteTimeUtc.AddMinutes(-7)
    Assert-True ((Get-FileHash -LiteralPath $TimestampOnlyPath -Algorithm SHA256).Hash -eq $TimestampContentHash) `
        'timestamp-only fixture mutation must not change source file contents'
    $TimestampOnlyChange = Invoke-BuildFixture $Fixture
    Assert-True ($TimestampOnlyChange.Code -eq 0) `
        "build after timestamp-only mutation must succeed: $($TimestampOnlyChange.Output)"
    $TimestampFingerprint = "$((Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).input_fingerprint)"
    Assert-True ($TimestampFingerprint -ne $StableFingerprint) `
        'input_fingerprint must change when only ordinary source LastWriteTimeUtc changes'
    $PreviousFingerprint = $TimestampFingerprint

    $Mutations = @(
        @{
            Name = 'Build.cs'
            Apply = {
                Add-Content -LiteralPath (Join-Path $Fixture.PluginRoot 'Source/MyPluginEditor/MyPluginEditor.Build.cs') `
                    -Value '// Build.cs fingerprint mutation' -Encoding UTF8
            }
        },
        @{
            Name = '.uplugin'
            Apply = {
                $DescriptorPath = Join-Path $Fixture.PluginRoot 'MyPlugin.uplugin'
                $Descriptor = Get-Content -LiteralPath $DescriptorPath -Raw | ConvertFrom-Json
                $Descriptor | Add-Member -NotePropertyName Description -NotePropertyValue 'fingerprint mutation'
                Write-JsonFile $DescriptorPath $Descriptor
            }
        },
        @{
            Name = 'ordinary .h'
            Apply = {
                Add-Content -LiteralPath (Join-Path $Fixture.PluginRoot 'Source/MyPluginEditor/MyPluginEditor.h') `
                    -Value '// header fingerprint mutation' -Encoding UTF8
            }
        },
        @{
            Name = 'ordinary .cpp'
            Apply = {
                Add-Content -LiteralPath (Join-Path $Fixture.PluginRoot 'Source/MyPluginEditor/MyPluginEditor.cpp') `
                    -Value '// cpp fingerprint mutation' -Encoding UTF8
            }
        }
    )
    foreach ($Mutation in $Mutations) {
        & $Mutation.Apply
        $Changed = Invoke-BuildFixture $Fixture
        Assert-True ($Changed.Code -eq 0) `
            "build after $($Mutation.Name) mutation must succeed: $($Changed.Output)"
        $ChangedFingerprint = "$((Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).input_fingerprint)"
        Assert-True ($ChangedFingerprint -ne $PreviousFingerprint) `
            "input_fingerprint must change after $($Mutation.Name) changes"
        $PreviousFingerprint = $ChangedFingerprint
    }

    $BuildCallsBeforeVersionChange = @(Get-ToolArguments $Fixture 'Build').Count
    Write-JsonFile (Join-Path $Fixture.EngineRoot 'Engine/Build/Build.version') @{
        MajorVersion = 5; MinorVersion = 8; PatchVersion = 1
    }
    $VersionMismatch = Invoke-BuildFixture $Fixture
    Assert-True ($VersionMismatch.Code -eq 1) `
        'Build.version mutation must reject the receipt from the previous engine patch before build'
    Assert-Match $VersionMismatch.Output '(?m)^FAIL RECEIPT_ENGINE_MISMATCH\b' `
        'Build.version mutation must report the explicit receipt engine mismatch code'
    Assert-True (@(Get-ToolArguments $Fixture 'Build').Count -eq $BuildCallsBeforeVersionChange) `
        'receipt engine mismatch must not invoke UBT'

    $VersionRebuild = Invoke-BuildFixture $Fixture `
        -ExtraArguments @('-QuarantineStaleArtifacts')
    Assert-True ($VersionRebuild.Code -eq 0) `
        "explicit quarantine rebuild after Build.version mutation must succeed: $($VersionRebuild.Output)"
    $VersionFingerprint = "$((Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).input_fingerprint)"
    Assert-True ($VersionFingerprint -ne $PreviousFingerprint) `
        'input_fingerprint must change after Build.version changes and a clean rebuild'
    $PreviousFingerprint = $VersionFingerprint

    Remove-Item -LiteralPath (Join-Path $Fixture.ProjectRoot 'Source/GameEditor.Target.cs')
    Write-TextFile (Join-Path $Fixture.ProjectRoot 'Source/RenamedEditor.Target.cs') @'
public class RenamedEditorTarget : TargetRules
{
    public RenamedEditorTarget(TargetInfo Target) : base(Target) {}
}
'@
    $TargetChange = Invoke-BuildFixture $Fixture
    Assert-True ($TargetChange.Code -eq 0) `
        "build after Target.cs/name mutation must succeed: $($TargetChange.Output)"
    $RenamedStatePath = Join-Path $Fixture.ProjectRoot 'Saved/PluginBuildState/RenamedEditor.json'
    Assert-True (Test-Path -LiteralPath $RenamedStatePath -PathType Leaf) `
        'target rename must write state under the resolved target name'
    $RenamedState = Get-Content -LiteralPath $RenamedStatePath -Raw | ConvertFrom-Json
    Assert-True ($RenamedState.editor_target -eq 'RenamedEditor') `
        'state must record the renamed target parsed from Target.cs'
    Assert-True ("$($RenamedState.input_fingerprint)" -ne $PreviousFingerprint) `
        'input_fingerprint must change after Target.cs path, content, and target name change'

    $TargetFingerprint = "$($RenamedState.input_fingerprint)"
    $SecondEngineRoot = Join-Path $Fixture.Root 'Second Engine Root'
    New-Item -ItemType Directory -Force -Path $SecondEngineRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $Fixture.EngineRoot 'Engine') `
        -Destination $SecondEngineRoot -Recurse
    $FirstBuildVersion = Join-Path $Fixture.EngineRoot 'Engine/Build/Build.version'
    $SecondBuildVersion = Join-Path $SecondEngineRoot 'Engine/Build/Build.version'
    (Get-Item -LiteralPath $SecondBuildVersion).LastWriteTimeUtc = `
        (Get-Item -LiteralPath $FirstBuildVersion).LastWriteTimeUtc
    Assert-True ((Get-FileHash -LiteralPath $SecondBuildVersion -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $FirstBuildVersion -Algorithm SHA256).Hash) `
        'second EngineRoot must contain an identical Build.version'
    $EngineIdentityChange = Invoke-BuildFixture $Fixture -EngineArgument 'Second Engine Root'
    Assert-True ($EngineIdentityChange.Code -eq 0) `
        "build with second relative EngineRoot must succeed: $($EngineIdentityChange.Output)"
    $SecondEngineState = Get-Content -LiteralPath $RenamedStatePath -Raw | ConvertFrom-Json
    Assert-True ($SecondEngineState.engine.root -eq $SecondEngineRoot) `
        'state must record the newly resolved EngineRoot identity'
    Assert-True ("$($SecondEngineState.input_fingerprint)" -ne $TargetFingerprint) `
        'input_fingerprint must change when only resolved EngineRoot identity changes'
}

function Test-SourceJunctionTargetChangesFingerprint {
    $Fixture = New-Fixture '08 input identity case' -PluginSourceJunction
    $SourceAFile = Join-Path $Fixture.SourceTargetA 'MyPluginEditor/MyPluginEditor.cpp'
    $SourceBFile = Join-Path $Fixture.SourceTargetB 'MyPluginEditor/MyPluginEditor.cpp'
    Assert-True ((Get-FileHash -LiteralPath $SourceAFile -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $SourceBFile -Algorithm SHA256).Hash) `
        'source junction targets must have identical contents so the resolved target path is tested'

    $First = Invoke-BuildFixture $Fixture
    Assert-True ($First.Code -eq 0) "build through Source junction A must succeed: $($First.Output)"
    $StatePath = Join-Path $Fixture.ProjectRoot 'Saved/PluginBuildState/GameEditor.json'
    $FingerprintA = "$((Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).input_fingerprint)"

    $SourceLink = Join-Path $Fixture.PluginRoot 'Source'
    [System.IO.Directory]::Delete($SourceLink)
    New-Item -ItemType Junction -Path $SourceLink -Target $Fixture.SourceTargetB | Out-Null
    $Second = Invoke-BuildFixture $Fixture
    Assert-True ($Second.Code -eq 0) "build through Source junction B must succeed: $($Second.Output)"
    $FingerprintB = "$((Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).input_fingerprint)"
    Assert-True ($FingerprintB -ne $FingerprintA) `
        'input_fingerprint must include resolved Source junction target path as well as content hashes'
}

function Test-SharedPluginJunctionRequiresOverride {
    $Fixture = New-Fixture '09 ownership outside case' -SharedPlugin
    $Result = Invoke-BuildFixture $Fixture
    Assert-True ($Result.Code -eq 1) 'whole-plugin junction must be blocked by default'
    Assert-Match $Result.Output '(?m)^FAIL WHOLE_PLUGIN_REPARSE_POINT\b' `
        'external whole-plugin reparse point must report the explicit contract error code'
    Assert-True ([string]::IsNullOrWhiteSpace((Get-CallLog $Fixture))) `
        'blocked whole-plugin junction must not invoke UBT'
}

function Test-InternalPluginJunctionIsBlocked {
    $Fixture = New-Fixture '10 ownership inside case' -InternalPluginJunction
    $Result = Invoke-BuildFixture $Fixture
    Assert-True ($Result.Code -eq 1) 'whole-plugin junction within ProjectRoot must also be blocked by default'
    Assert-Match $Result.Output '(?m)^FAIL WHOLE_PLUGIN_REPARSE_POINT\b' `
        'internal whole-plugin reparse point must report the explicit contract error code'
    Assert-True ([string]::IsNullOrWhiteSpace((Get-CallLog $Fixture))) `
        'blocked internal whole-plugin junction must not invoke UBT'
}

function Test-SharedPluginOverrideDoesNotQuarantineExternalOutputs {
    $Fixture = New-Fixture '11 ownership override case' -SharedPlugin
    Add-StaleArtifacts $Fixture
    $Result = Invoke-BuildFixture $Fixture -Mode 'record-only' `
        -ExtraArguments @('-AllowSharedPluginOutputs', '-QuarantineStaleArtifacts')
    $BuildArguments = @(Get-ToolArguments $Fixture 'Build')
    Assert-True ($BuildArguments.Count -gt 0 -and $BuildArguments[0].value -eq 'GameEditor') `
        'explicit shared-output override must continue to UBT'
    Assert-True ($Result.Code -eq 1) 'fixture UBT failure must propagate as exit 1'
    $ReceiptMatches = @(Find-MarkerFiles $Fixture 'stale receipt marker')
    $BackupPrefix = (Join-Path $Fixture.ProjectRoot 'Saved/BuildReceiptBackup').TrimEnd('\') + '\'
    Assert-True ($ReceiptMatches.Count -eq 1 -and
        $ReceiptMatches[0].FullName.StartsWith($BackupPrefix, [System.StringComparison]::OrdinalIgnoreCase)) `
        'shared-output override must quarantine the project-local Editor receipt'
    foreach ($Pair in @(
        @('Binaries/Win64/UnrealEditor.modules', 'stale manifest marker'),
        @('Binaries/Win64/UnrealEditor-MyPluginEditor.dll', 'stale dll marker'),
        @('Binaries/Win64/UnrealEditor-MyPluginEditor.pdb', 'stale pdb marker')
    )) {
        $LivePath = Join-Path $Fixture.PluginRoot $Pair[0]
        Assert-True ((Test-Path -LiteralPath $LivePath -PathType Leaf) -and
            ((Get-Content -LiteralPath $LivePath -Raw) -match $Pair[1])) `
            "quarantine must not move shared output outside ProjectRoot: $($Pair[0])"
    }
}

function Test-UnsafeManifestArtifactIsRejectedWithoutMovingSource {
    $Fixture = New-Fixture '12 artifact boundary case'
    $Victim = Add-UnsafeManifestArtifacts $Fixture
    $Result = Invoke-BuildFixture $Fixture -ExtraArguments @('-QuarantineStaleArtifacts')
    Assert-True ($Result.Code -eq 1) 'unsafe manifest artifact must exit 1'
    Assert-Match $Result.Output '(?m)^FAIL UNSAFE_MANIFEST_ARTIFACT\b' `
        'manifest traversal must report the explicit safety error code'
    Assert-True ([string]::IsNullOrWhiteSpace((Get-CallLog $Fixture))) `
        'unsafe manifest artifact must fail before UBT'
    Assert-True ((Test-Path -LiteralPath $Victim -PathType Leaf) -and
        ((Get-Content -LiteralPath $Victim -Raw) -match 'victim source marker')) `
        'quarantine must leave the source victim at its original path'
    Assert-True (@(Find-MarkerFiles $Fixture 'victim source marker').Count -eq 1) `
        'quarantine must neither move nor copy a manifest path outside plugin Binaries/Win64'
}

function Test-ReceiptFromPreviousEngineIsRejectedBeforeBuild {
    $Fixture = New-Fixture '13 engine identity case'
    Add-PreviousEngineArtifacts $Fixture
    $Result = Invoke-BuildFixture $Fixture
    Assert-True ($Result.Code -eq 1) 'receipt from another engine version must exit 1'
    Assert-Match $Result.Output '(?m)^FAIL RECEIPT_ENGINE_MISMATCH\b' `
        'old receipt engine identity must report the explicit error code'
    Assert-True ([string]::IsNullOrWhiteSpace((Get-CallLog $Fixture))) `
        'receipt engine mismatch must fail before UBT even when all BuildIds agree'
}

function Test-DescriptorDependencyClosureIsBuiltAndFingerprinted {
    $Fixture = New-Fixture '14 dependency closure case' -WithDependencyPlugin
    $Result = Invoke-BuildFixture $Fixture
    Assert-True ($Result.Code -eq 0) `
        "descriptor dependency closure build must succeed: $($Result.Output)"
    $StatePath = Join-Path $Fixture.ProjectRoot 'Saved/PluginBuildState/GameEditor.json'
    $State = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $PluginNames = @($State.plugins | ForEach-Object { $_.name } | Sort-Object)
    Assert-True (($PluginNames -join '|') -eq 'DependencyPlugin|MyPlugin') `
        'state.plugins must include direct and descriptor-transitive project source plugins'
    $Before = "$($State.input_fingerprint)"
    Add-Content -LiteralPath (Join-Path $Fixture.DependencyPluginRoot `
        'Source/DependencyPluginEditor/DependencyPluginEditor.Build.cs') `
        -Value '// dependency fingerprint mutation' -Encoding UTF8
    $Changed = Invoke-BuildFixture $Fixture
    Assert-True ($Changed.Code -eq 0) `
        "dependency source mutation rebuild must succeed: $($Changed.Output)"
    $After = "$((Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).input_fingerprint)"
    Assert-True ($After -ne $Before) `
        'input_fingerprint must include transitive project plugin source inputs'
}

function Test-EnabledPluginWithoutAnyDescriptorIsRejected {
    $Fixture = New-Fixture '15 unresolved enablement case' -WithoutProjectPlugin
    $Result = Invoke-BuildFixture $Fixture
    Assert-True ($Result.Code -eq 1) 'enabled plugin with no descriptor anywhere must exit 1'
    Assert-Match $Result.Output '(?m)^FAIL ENABLED_PLUGIN_NOT_FOUND\b' `
        'unresolved enabled plugin must report the explicit error code'
    Assert-True ([string]::IsNullOrWhiteSpace((Get-CallLog $Fixture))) `
        'unresolved enabled plugin must fail before UBT'
}

function Test-EnginePluginDescriptorSatisfiesDirectEnablement {
    $Fixture = New-Fixture '16 engine ownership case' -WithoutProjectPlugin
    Write-JsonFile (Join-Path $Fixture.EngineRoot 'Engine/Plugins/Runtime/MyPlugin/MyPlugin.uplugin') @{
        FileVersion = 3
        Modules = @(@{ Name = 'MyPluginEditor'; Type = 'Editor'; LoadingPhase = 'Default' })
    }
    $Result = Invoke-BuildFixture $Fixture
    Assert-True ($Result.Output -notmatch '(?m)^FAIL ENABLED_PLUGIN_NOT_FOUND\b') `
        'matching EngineRoot descriptor must satisfy direct enablement lookup'
    Assert-True ($Result.Code -eq 0) `
        "engine plugin ownership fixture must succeed: $($Result.Output)"
}

function Test-InapplicableDirectEnablementDoesNotRequireDescriptor {
    $Fixture = New-Fixture '17 platform selection case'
    $ProjectJson = Get-Content -LiteralPath $Fixture.Project -Raw | ConvertFrom-Json
    $ProjectJson.Plugins = @($ProjectJson.Plugins) + @([pscustomobject]@{
        Name = 'LinuxOnlyMissing'
        Enabled = $true
        PlatformAllowList = @('Linux')
    })
    Write-JsonFile $Fixture.Project $ProjectJson
    $Result = Invoke-BuildFixture $Fixture
    Assert-True ($Result.Output -notmatch '(?m)^FAIL ENABLED_PLUGIN_NOT_FOUND\b') `
        'Win64 must ignore an enabled direct entry allowed only on Linux before descriptor lookup'
    Assert-True ($Result.Code -eq 0) `
        "platform-inapplicable direct entry must not block the Editor build: $($Result.Output)"
}

function Test-MissingOptionalDescriptorDependencyIsSkipped {
    $Fixture = New-Fixture '18 optional selection case'
    $DescriptorPath = Join-Path $Fixture.PluginRoot 'MyPlugin.uplugin'
    $Descriptor = Get-Content -LiteralPath $DescriptorPath -Raw | ConvertFrom-Json
    $Descriptor | Add-Member -NotePropertyName Plugins -NotePropertyValue @(@{
        Name = 'OptionalMissing'; Enabled = $true; Optional = $true
    })
    Write-JsonFile $DescriptorPath $Descriptor
    $Result = Invoke-BuildFixture $Fixture
    Assert-True ($Result.Output -notmatch '(?m)^FAIL ENABLED_PLUGIN_NOT_FOUND\b') `
        'missing Optional descriptor dependency must not be reported as required'
    Assert-True ($Result.Code -eq 0) `
        "missing optional dependency must not block the Editor build: $($Result.Output)"
}

function Test-TargetInapplicableDescriptorDependencyIsSkipped {
    $Fixture = New-Fixture '19 target selection case'
    $DescriptorPath = Join-Path $Fixture.PluginRoot 'MyPlugin.uplugin'
    $Descriptor = Get-Content -LiteralPath $DescriptorPath -Raw | ConvertFrom-Json
    $Descriptor | Add-Member -NotePropertyName Plugins -NotePropertyValue @(@{
        Name = 'ServerOnlyMissing'; Enabled = $true; TargetAllowList = @('Server')
    })
    Write-JsonFile $DescriptorPath $Descriptor
    $Result = Invoke-BuildFixture $Fixture
    Assert-True ($Result.Output -notmatch '(?m)^FAIL ENABLED_PLUGIN_NOT_FOUND\b') `
        'Editor must ignore a descriptor dependency allowed only for Server before lookup'
    Assert-True ($Result.Code -eq 0) `
        "target-inapplicable dependency must not block the Editor build: $($Result.Output)"
}

function Test-FilteredDependencyModulesDoNotRequireBuildProducts {
    foreach ($Filter in @(
        @{ Name = 'platform'; Property = 'PlatformAllowList'; Value = @('Linux') },
        @{ Name = 'target'; Property = 'TargetDenyList'; Value = @('Editor') }
    )) {
        $Fixture = New-Fixture ("20 module selection " + $Filter.Name) `
            -WithDependencyPlugin -SuppressDependencyOutput
        $DescriptorPath = Join-Path $Fixture.DependencyPluginRoot 'DependencyPlugin.uplugin'
        $Descriptor = Get-Content -LiteralPath $DescriptorPath -Raw | ConvertFrom-Json
        $Descriptor.Modules[0] | Add-Member -NotePropertyName $Filter.Property `
            -NotePropertyValue $Filter.Value
        Write-JsonFile $DescriptorPath $Descriptor
        $Result = Invoke-BuildFixture $Fixture
        Assert-True ($Result.Code -eq 0) `
            "$($Filter.Name)-filtered dependency module must not require manifest or DLL: $($Result.Output)"
        $StatePath = Join-Path $Fixture.ProjectRoot 'Saved/PluginBuildState/GameEditor.json'
        $State = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        $DependencyState = @($State.plugins | Where-Object { $_.name -eq 'DependencyPlugin' })
        Assert-True ($DependencyState.Count -le 1) 'dependency state entry must not be duplicated'
        if ($DependencyState.Count -eq 1) {
            Assert-True (@($DependencyState[0].modules) -notcontains 'DependencyPluginEditor') `
                'state must not require a target-filtered dependency module'
        }
    }
}

function Test-Ubt59ExactPlatformSemantics {
    $ServerFixture = New-Fixture '21 server host type case' -EmitServerOnlyModule
    $ServerResult = Invoke-BuildFixture $ServerFixture
    Assert-True ($ServerResult.Code -eq 0) `
        "ServerOnly module must remain applicable to an Editor target: $($ServerResult.Output)"
    $ServerState = Get-Content -LiteralPath (Join-Path $ServerFixture.ProjectRoot `
        'Saved/PluginBuildState/GameEditor.json') -Raw | ConvertFrom-Json
    $MyPluginState = @($ServerState.plugins | Where-Object { $_.name -eq 'MyPlugin' })[0]
    Assert-True (@($MyPluginState.modules) -contains 'ServerHostEditor') `
        'state must include an applicable ServerOnly module and its built manifest DLL'

    foreach ($Case in @(
        @{ Name = 'empty allow'; Fields = @{ PlatformAllowList = @() } },
        @{ Name = 'explicit module'; Fields = @{ HasExplicitPlatforms = $true } }
    )) {
        $Fixture = New-Fixture ("22 module " + $Case.Name + ' case')
        $DescriptorPath = Join-Path $Fixture.PluginRoot 'MyPlugin.uplugin'
        $Descriptor = Get-Content -LiteralPath $DescriptorPath -Raw | ConvertFrom-Json
        $Module = [ordered]@{ Name = 'ExcludedEditor'; Type = 'Editor'; LoadingPhase = 'Default' }
        foreach ($Field in $Case.Fields.Keys) { $Module[$Field] = $Case.Fields[$Field] }
        $Descriptor.Modules = @($Descriptor.Modules) + @($Module)
        Write-JsonFile $DescriptorPath $Descriptor
        $Result = Invoke-BuildFixture $Fixture
        Assert-True ($Result.Code -eq 0) `
            "$($Case.Name) module must be inapplicable without manifest or DLL: $($Result.Output)"
        $State = Get-Content -LiteralPath (Join-Path $Fixture.ProjectRoot `
            'Saved/PluginBuildState/GameEditor.json') -Raw | ConvertFrom-Json
        Assert-True (@($State.plugins[0].modules) -notcontains 'ExcludedEditor') `
            "$($Case.Name) module must not enter state"
    }
}

function Test-Ubt59ExactPluginPlatformSemantics {
    foreach ($Case in @(
        @{ Name = 'explicit reference'; Fields = @{ HasExplicitPlatforms = $true } },
        @{ Name = 'supported reference'; Fields = @{ SupportedTargetPlatforms = @('Linux') } }
    )) {
        $Fixture = New-Fixture ("23 " + $Case.Name + ' case')
        $ProjectJson = Get-Content -LiteralPath $Fixture.Project -Raw | ConvertFrom-Json
        $Reference = [ordered]@{ Name = 'MissingByPlatform'; Enabled = $true }
        foreach ($Field in $Case.Fields.Keys) { $Reference[$Field] = $Case.Fields[$Field] }
        $ProjectJson.Plugins = @($ProjectJson.Plugins) + @($Reference)
        Write-JsonFile $Fixture.Project $ProjectJson
        $Result = Invoke-BuildFixture $Fixture
        Assert-True ($Result.Output -notmatch '(?m)^FAIL ENABLED_PLUGIN_NOT_FOUND\b') `
            "$($Case.Name) must be filtered before missing descriptor lookup"
        Assert-True ($Result.Code -eq 0) `
            "$($Case.Name) must not block Win64 Editor: $($Result.Output)"
    }

    foreach ($Case in @(
        @{ Name = 'explicit descriptor'; Fields = @{ HasExplicitPlatforms = $true } },
        @{ Name = 'supported descriptor'; Fields = @{ SupportedTargetPlatforms = @('Linux') } }
    )) {
        $Fixture = New-Fixture ("24 " + $Case.Name + ' case') `
            -WithDependencyPlugin -SuppressDependencyOutput
        $DescriptorPath = Join-Path $Fixture.DependencyPluginRoot 'DependencyPlugin.uplugin'
        $Descriptor = Get-Content -LiteralPath $DescriptorPath -Raw | ConvertFrom-Json
        foreach ($Field in $Case.Fields.Keys) {
            $Descriptor | Add-Member -NotePropertyName $Field -NotePropertyValue $Case.Fields[$Field]
        }
        Write-JsonFile $DescriptorPath $Descriptor
        $Result = Invoke-BuildFixture $Fixture
        Assert-True ($Result.Code -eq 0) `
            "$($Case.Name) must stay outside the Win64 project plugin closure: $($Result.Output)"
        $State = Get-Content -LiteralPath (Join-Path $Fixture.ProjectRoot `
            'Saved/PluginBuildState/GameEditor.json') -Raw | ConvertFrom-Json
        Assert-True (@($State.plugins | Where-Object { $_.name -eq 'DependencyPlugin' }).Count -eq 0) `
            "$($Case.Name) must not enter state.plugins"
    }
}

function Wait-FixtureCondition {
    param([scriptblock]$Condition, [string]$Message, [int]$TimeoutMilliseconds = 10000)
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "ASSERT_FAIL timeout: $Message"
}

function Start-BlockedFixtureBuild {
    param(
        [object]$Fixture,
        [string]$Mode,
        [string]$Label,
        [switch]$Quarantine
    )
    $Entered = Join-Path $Fixture.Root 'block entered.txt'
    $Release = Join-Path $Fixture.Root 'block release.txt'
    $env:UE_FIXTURE_MODE = $Mode
    $env:UE_FIXTURE_POWERSHELL = $WindowsPowerShell
    $env:UE_FIXTURE_CALL_LOG = $Fixture.CallLog
    $env:UE_FIXTURE_FAKE_BUILD = $Fixture.FakeBuild
    $env:UE_FIXTURE_PROJECT_ROOT = $Fixture.ProjectRoot
    $env:UE_FIXTURE_PLUGIN_ROOT = $Fixture.PluginRoot
    $env:UE_FIXTURE_DEPENDENCY_PLUGIN_ROOT = ''
    $env:UE_FIXTURE_SUPPRESS_DEPENDENCY_OUTPUT = 'false'
    $env:UE_FIXTURE_EMIT_SERVER_ONLY = 'false'
    $env:UE_FIXTURE_ENGINE_ROOT = $Fixture.EngineRoot
    $env:UE_FIXTURE_BLOCK_ENTERED = $Entered
    $env:UE_FIXTURE_BLOCK_RELEASE = $Release

    $Runner = Join-Path $Fixture.Root ("runner $Label.ps1")
    $QuarantineArgument = $(if ($Quarantine) { ' -QuarantineStaleArtifacts' } else { '' })
    Write-TextFile $Runner @"
`$ErrorActionPreference = 'Stop'
& '$BuildScript' -Project 'Project Root/Game.uproject' -EngineRoot 'Engine Root'$QuarantineArgument
exit `$LASTEXITCODE
"@
    $StdOut = Join-Path $Fixture.Root ("process $Label stdout.txt")
    $StdErr = Join-Path $Fixture.Root ("process $Label stderr.txt")
    $Process = Start-Process -FilePath $WindowsPowerShell -ArgumentList `
        "-NoProfile -ExecutionPolicy Bypass -File `"$Runner`"" `
        -WorkingDirectory $Fixture.Root -RedirectStandardOutput $StdOut `
        -RedirectStandardError $StdErr -PassThru -WindowStyle Hidden
    [pscustomobject]@{
        Process = $Process; StdOut = $StdOut; StdErr = $StdErr
        Entered = $Entered; Release = $Release
    }
}

function Stop-FixtureProcesses {
    param([object[]]$Runs)
    foreach ($Run in @($Runs)) {
        if ($null -eq $Run) { continue }
        New-Item -ItemType File -Force -Path $Run.Release | Out-Null
    }
    foreach ($Run in @($Runs)) {
        if ($null -eq $Run -or $null -eq $Run.Process) { continue }
        $Run.Process.Refresh()
        if (-not $Run.Process.HasExited) {
            $Run.Process.Kill()
            $Run.Process.WaitForExit()
        }
    }
}

function Test-ProjectLockSerializesTheWholeBuildFlow {
    $Fixture = New-Fixture '25 process ownership case'
    Add-StaleArtifacts $Fixture
    $RunA = $null
    $RunB = $null
    try {
        $RunA = Start-BlockedFixtureBuild $Fixture 'lock-block' 'A' -Quarantine
        Wait-FixtureCondition { Test-Path -LiteralPath $RunA.Entered } 'first build entering fake UBT'
        $RunB = Start-BlockedFixtureBuild $Fixture 'lock-block' 'B' -Quarantine
        Start-Sleep -Milliseconds 750
        $RunB.Process.Refresh()
        Assert-True (-not $RunB.Process.HasExited) 'second build must wait for the project lock'
        Assert-True (@(Get-ToolArguments $Fixture 'Build' |
            Where-Object { $_.index -eq 0 }).Count -eq 1) `
            'second process must not enter UBT before the first process releases the project lock'
        [string]$BOutput = $(if (Test-Path -LiteralPath $RunB.StdOut) {
            Get-Content -LiteralPath $RunB.StdOut -Raw | Out-String
        } else { [string]::Empty })
        Assert-True ($BOutput -notmatch '(?m)^(QUARANTINE|AUDIT|STATE) ') `
            'waiting process must not enter quarantine, audit, or state phases'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $Fixture.ProjectRoot `
            'Saved/PluginBuildState/GameEditor.json'))) 'blocked first build must not have written state'

        New-Item -ItemType File -Force -Path $RunA.Release | Out-Null
        Assert-True ($RunA.Process.WaitForExit(30000)) 'first serialized build must finish after release'
        Assert-True ($RunB.Process.WaitForExit(30000)) 'second serialized build must finish after first'
        $RunA.Process.Refresh()
        $RunB.Process.Refresh()
        $AStdOut = Get-Content -LiteralPath $RunA.StdOut -Raw -ErrorAction SilentlyContinue | Out-String
        $AStdErr = Get-Content -LiteralPath $RunA.StdErr -Raw -ErrorAction SilentlyContinue | Out-String
        $BStdOut = Get-Content -LiteralPath $RunB.StdOut -Raw -ErrorAction SilentlyContinue | Out-String
        $BStdErr = Get-Content -LiteralPath $RunB.StdErr -Raw -ErrorAction SilentlyContinue | Out-String
        $ExitMessage = ("both serialized builds must complete successfully`n" +
            "A ExitCode=$($RunA.Process.ExitCode)`nA stdout:`n$AStdOut`nA stderr:`n$AStdErr`n" +
            "B ExitCode=$($RunB.Process.ExitCode)`nB stdout:`n$BStdOut`nB stderr:`n$BStdErr")
        $ObservableSuccess = (
            $AStdOut -match '(?m)^STATE ' -and $AStdOut -notmatch '(?m)^FAIL ' -and
            $BStdOut -match '(?m)^STATE ' -and $BStdOut -notmatch '(?m)^FAIL ' -and
            [string]::IsNullOrWhiteSpace($AStdErr) -and
            [string]::IsNullOrWhiteSpace($BStdErr)
        )
        Assert-True $ObservableSuccess `
            $ExitMessage
        Assert-True (@(Get-ToolArguments $Fixture 'Build' |
            Where-Object { $_.index -eq 0 }).Count -eq 2) `
            'both builds must eventually invoke UBT exactly once'
    }
    finally {
        Stop-FixtureProcesses @($RunA, $RunB)
    }
}

function Test-UbtOutputStreamsToTheOperationLog {
    $Fixture = New-Fixture '26 output visibility case'
    $Run = $null
    try {
        $Run = Start-BlockedFixtureBuild $Fixture 'stream-block' 'stream'
        Wait-FixtureCondition { Test-Path -LiteralPath $Run.Entered } 'stream fixture entering fake UBT'
        $LogRoot = Join-Path $Fixture.ProjectRoot 'Saved/Logs/PluginBuild'
        Wait-FixtureCondition {
            $Logs = @(Get-ChildItem -LiteralPath $LogRoot -Filter '*-ubt.log' -File -ErrorAction SilentlyContinue)
            $Logs.Count -eq 1 -and
                (Get-Content -LiteralPath $Logs[0].FullName -Raw) -match 'UE_FIXTURE_STREAM_MARKER_7F39'
        } 'stream marker becoming visible before UBT exits'
        $Run.Process.Refresh()
        Assert-True (-not $Run.Process.HasExited) `
            'build process must still be running when streamed UBT output is observed'
        New-Item -ItemType File -Force -Path $Run.Release | Out-Null
        Assert-True ($Run.Process.WaitForExit(30000)) 'stream fixture build must finish after release'
        $Run.Process.Refresh()
        $StreamStdOut = Get-Content -LiteralPath $Run.StdOut -Raw -ErrorAction SilentlyContinue | Out-String
        $StreamStdErr = Get-Content -LiteralPath $Run.StdErr -Raw -ErrorAction SilentlyContinue | Out-String
        $StreamSuccess = (
            $StreamStdOut -match '(?m)^STATE ' -and
            $StreamStdOut -notmatch '(?m)^FAIL ' -and
            [string]::IsNullOrWhiteSpace($StreamStdErr)
        )
        $StreamDiagnostic = ("stream fixture build must finish successfully`n" +
            "ExitCode=$($Run.Process.ExitCode)`nstdout:`n$StreamStdOut`nstderr:`n$StreamStdErr")
        Assert-True $StreamSuccess $StreamDiagnostic
    }
    finally {
        Stop-FixtureProcesses @($Run)
    }
}

try {
    if (-not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) {
        throw "TEST_RED production script does not exist: $BuildScript"
    }

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Test-InvokeLoggedToolOwnsStartedProcessLifetime
    Test-MissingHostTargetStopsBeforeUbt
    Test-StaleBuildIdFailsWithoutMovingAnything
    Test-ExplicitQuarantineMovesOnlyRecognizedGeneratedFiles
    Test-DependencyWarningFailsWithoutState
    Test-UbtFailureDoesNotWriteState
    Test-AuditFailureDoesNotWriteState
    Test-AdditionalBuildArgumentsPreserveNativeArgv
    Test-SuccessAuditsAndWritesState
    Test-SourceJunctionTargetChangesFingerprint
    Test-SharedPluginJunctionRequiresOverride
    Test-InternalPluginJunctionIsBlocked
    Test-SharedPluginOverrideDoesNotQuarantineExternalOutputs
    Test-UnsafeManifestArtifactIsRejectedWithoutMovingSource
    Test-ReceiptFromPreviousEngineIsRejectedBeforeBuild
    Test-DescriptorDependencyClosureIsBuiltAndFingerprinted
    Test-EnabledPluginWithoutAnyDescriptorIsRejected
    Test-EnginePluginDescriptorSatisfiesDirectEnablement
    Test-InapplicableDirectEnablementDoesNotRequireDescriptor
    Test-MissingOptionalDescriptorDependencyIsSkipped
    Test-TargetInapplicableDescriptorDependencyIsSkipped
    Test-FilteredDependencyModulesDoNotRequireBuildProducts
    Test-Ubt59ExactPlatformSemantics
    Test-Ubt59ExactPluginPlatformSemantics
    Test-ProjectLockSerializesTheWholeBuildFlow
    Test-UbtOutputStreamsToTheOperationLog
    Write-Output 'TEST_PASS build contract, argv, quarantine, failure gates, audit, fingerprint, state, and junction cases'
}
finally {
    try {
        if (Test-Path -LiteralPath $Root) {
            Remove-Item -LiteralPath $Root -Recurse -Force
        }
    }
    finally {
        foreach ($Entry in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'UE_FIXTURE_*' })) {
            Remove-Item -LiteralPath ("Env:" + $Entry.Name)
        }
        foreach ($Name in $OriginalFixtureEnvironment.Keys) {
            Set-Item -LiteralPath ("Env:" + $Name) `
                -Value $OriginalFixtureEnvironment[$Name].Value
        }
    }
}

$global:LASTEXITCODE = 0
