param()

$ErrorActionPreference = 'Stop'
$Audit = Join-Path $PSScriptRoot 'audit-ue-plugin-build.ps1'
$Common = Join-Path $PSScriptRoot 'ue-plugin-build-common.ps1'
$Root = Join-Path ([System.IO.Path]::GetTempPath()) ('ue-plugin-audit-' + [guid]::NewGuid())
. $Common

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    $Parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Audit {
    param([string]$Project, [string]$EngineRoot)
    $Output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Audit `
        -Project $Project -EngineRoot $EngineRoot 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = $Output }
}

try {
    $EngineRoot = Join-Path $Root 'UE'
    $ProjectRoot = Join-Path $Root 'Game'
    $Project = Join-Path $ProjectRoot 'Game.uproject'
    $BuildId = 'fixture-build-id'

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $RelaxedJsonPath = Join-Path $Root 'relaxed descriptor.uplugin'
    @'
{
    // Unreal descriptors permit comments and trailing commas.
    "Text": "keep , } and // inside strings",
    "Modules": [
        { "Name": "Relaxed", },
    ],
}
'@ | Set-Content -LiteralPath $RelaxedJsonPath -Encoding UTF8
    $RelaxedJson = Read-UeJsonFile $RelaxedJsonPath
    if ($RelaxedJson.Text -ne 'keep , } and // inside strings' -or
        @($RelaxedJson.Modules).Count -ne 1) {
        throw 'UE descriptor parser must accept comments/trailing commas without changing strings'
    }
    $JoinedTokenPath = Join-Path $Root 'joined tokens.uplugin'
    '{ "Version": 1/*separator*/2 }' |
        Set-Content -LiteralPath $JoinedTokenPath -Encoding UTF8
    $RejectedJoinedTokens = $false
    try { [void](Read-UeJsonFile $JoinedTokenPath) }
    catch { $RejectedJoinedTokens = $true }
    if (-not $RejectedJoinedTokens) {
        throw 'block-comment removal must not silently concatenate adjacent JSON tokens'
    }

    Write-JsonFile (Join-Path $EngineRoot 'Engine/Build/Build.version') @{
        MajorVersion = 5; MinorVersion = 9; PatchVersion = 0
    }
    Write-JsonFile $Project @{
        FileVersion = 3
        EngineAssociation = '5.9'
        Modules = @(@{ Name = 'Game'; Type = 'Runtime'; LoadingPhase = 'Default' })
        Plugins = @(@{ Name = 'MyPlugin'; Enabled = $true; TargetAllowList = @('Editor') })
    }
    Write-JsonFile (Join-Path $ProjectRoot 'Plugins/MyPlugin/MyPlugin.uplugin') @{
        FileVersion = 3
        Modules = @(
            @{ Name = 'MyPluginEditor'; Type = 'Editor'; LoadingPhase = 'Default' }
            @{ Name = 'ServerHostEditor'; Type = 'ServerOnly'; LoadingPhase = 'Default' }
            @{ Name = 'ExplicitEmptyAllow'; Type = 'Editor'; PlatformAllowList = @() }
            @{ Name = 'ExplicitPlatformModule'; Type = 'Editor'; HasExplicitPlatforms = $true }
            @{ Name = 'LinuxOnly'; Type = 'Editor'; PlatformAllowList = @('Linux') }
            @{ Name = 'Win64Denied'; Type = 'Editor'; PlatformDenyList = @('Win64') }
            @{ Name = 'ServerOnly'; Type = 'Editor'; TargetAllowList = @('Server') }
            @{ Name = 'EditorDenied'; Type = 'Editor'; TargetDenyList = @('Editor') }
            @{ Name = 'ShippingOnly'; Type = 'Editor'; TargetConfigurationAllowList = @('Shipping') }
            @{ Name = 'DevelopmentDenied'; Type = 'Editor'; TargetConfigurationDenyList = @('Development') }
            @{ Name = 'LegacyLinuxOnly'; Type = 'Editor'; WhitelistPlatforms = @('Linux') }
            @{ Name = 'LegacyWin64Denied'; Type = 'Editor'; BlacklistPlatforms = @('Win64') }
            @{ Name = 'LegacyServerOnly'; Type = 'Editor'; WhitelistTargets = @('Server') }
            @{ Name = 'LegacyEditorDenied'; Type = 'Editor'; BlacklistTargets = @('Editor') }
            @{ Name = 'LegacyShippingOnly'; Type = 'Editor'; WhitelistTargetConfigurations = @('Shipping') }
            @{ Name = 'LegacyDevelopmentDenied'; Type = 'Editor'; BlacklistTargetConfigurations = @('Development') }
        )
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $ProjectRoot 'Source') | Out-Null
    'public class GameEditorTarget {}' | Set-Content `
        -LiteralPath (Join-Path $ProjectRoot 'Source/GameEditor.Target.cs') -Encoding UTF8
    Write-JsonFile (Join-Path $ProjectRoot 'Binaries/Win64/GameEditor.target') @{
        TargetName = 'GameEditor'
        Version = @{ BuildId = $BuildId; MajorVersion = 5; MinorVersion = 9; PatchVersion = 0 }
        BuildProducts = @(
            @{ Path = '$(ProjectDir)/Plugins/MyPlugin/Binaries/Win64/UnrealEditor-MyPluginEditor.dll'; Type = 'DynamicLibrary' }
            @{ Path = '$(ProjectDir)/Plugins/MyPlugin/Binaries/Win64/UnrealEditor-ServerHostEditor.dll'; Type = 'DynamicLibrary' }
        )
    }
    Write-JsonFile (Join-Path $ProjectRoot 'Plugins/MyPlugin/Binaries/Win64/UnrealEditor.modules') @{
        BuildId = $BuildId
        Modules = @{
            MyPluginEditor = 'UnrealEditor-MyPluginEditor.dll'
            ServerHostEditor = 'UnrealEditor-ServerHostEditor.dll'
        }
    }
    New-Item -ItemType File -Force -Path `
        (Join-Path $ProjectRoot 'Plugins/MyPlugin/Binaries/Win64/UnrealEditor-MyPluginEditor.dll') | Out-Null
    New-Item -ItemType File -Force -Path `
        (Join-Path $ProjectRoot 'Plugins/MyPlugin/Binaries/Win64/UnrealEditor-ServerHostEditor.dll') | Out-Null

    $Healthy = Invoke-Audit $Project $EngineRoot
    if ($Healthy.Code -ne 0 -or $Healthy.Output -notmatch 'PASS MyPlugin') {
        throw "Healthy fixture failed:`n$($Healthy.Output)"
    }

    $OutsideDll = Join-Path $ProjectRoot 'Plugins/MyPlugin/Source/Victim.dll'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutsideDll) | Out-Null
    New-Item -ItemType File -Force -Path $OutsideDll | Out-Null
    foreach ($Case in @(
        @{ Name = 'absolute'; Value = $OutsideDll },
        @{ Name = 'parent traversal'; Value = '..\..\Source\Victim.dll' },
        @{ Name = 'child directory'; Value = 'Nested\Victim.dll' },
        @{ Name = 'non library'; Value = 'Victim.txt' }
    )) {
        Write-JsonFile (Join-Path $ProjectRoot 'Plugins/MyPlugin/Binaries/Win64/UnrealEditor.modules') @{
            BuildId = $BuildId
            Modules = @{
                MyPluginEditor = $Case.Value
                ServerHostEditor = 'UnrealEditor-ServerHostEditor.dll'
            }
        }
        $Unsafe = Invoke-Audit $Project $EngineRoot
        if ($Unsafe.Code -ne 1 -or $Unsafe.Output -notmatch '(?m)^FAIL UNSAFE_MANIFEST_ARTIFACT\b') {
            throw "Unsafe $($Case.Name) manifest value was not rejected at the trust boundary:`n$($Unsafe.Output)"
        }
    }

    Write-JsonFile (Join-Path $ProjectRoot 'Plugins/MyPlugin/Binaries/Win64/UnrealEditor.modules') @{
        BuildId = $BuildId
        Modules = @{
            MyPluginEditor = 'UnrealEditor-MyPluginEditor.dll'
            ServerHostEditor = 'UnrealEditor-ServerHostEditor.dll'
        }
    }

    Write-JsonFile (Join-Path $ProjectRoot 'Plugins/MyPlugin/Binaries/Win64/UnrealEditor.modules') @{
        BuildId = 'stale-build-id'
        Modules = @{
            MyPluginEditor = 'UnrealEditor-MyPluginEditor.dll'
            ServerHostEditor = 'UnrealEditor-ServerHostEditor.dll'
        }
    }
    $Stale = Invoke-Audit $Project $EngineRoot
    if ($Stale.Code -ne 1 -or $Stale.Output -notmatch 'BuildId mismatch') {
        throw "Stale BuildId was not rejected:`n$($Stale.Output)"
    }

    Write-JsonFile (Join-Path $ProjectRoot 'Plugins/MyPlugin/Binaries/Win64/UnrealEditor.modules') @{
        BuildId = $BuildId
        Modules = @{
            MyPluginEditor = 'UnrealEditor-MyPluginEditor.dll'
            ServerHostEditor = 'UnrealEditor-ServerHostEditor.dll'
        }
    }
    Remove-Item -LiteralPath `
        (Join-Path $ProjectRoot 'Plugins/MyPlugin/Binaries/Win64/UnrealEditor-MyPluginEditor.dll')
    $Missing = Invoke-Audit $Project $EngineRoot
    if ($Missing.Code -ne 1 -or $Missing.Output -notmatch 'Missing DLL') {
        throw "Missing DLL was not rejected:`n$($Missing.Output)"
    }

    Remove-Item -LiteralPath (Join-Path $ProjectRoot 'Source/GameEditor.Target.cs')
    Remove-Item -LiteralPath (Join-Path $ProjectRoot 'Binaries/Win64/GameEditor.target')
    $NoHostTarget = Invoke-Audit $Project $EngineRoot
    if ($NoHostTarget.Code -ne 1 -or $NoHostTarget.Output -notmatch 'No project Editor host target') {
        throw "Missing content-only host target was not explained:`n$($NoHostTarget.Output)"
    }

    Write-Output 'TEST_PASS compatibility filters, stale BuildId, missing DLL, and missing host target cases'
}
finally {
    if (Test-Path -LiteralPath $Root) {
        Remove-Item -LiteralPath $Root -Recurse -Force
    }
}

$global:LASTEXITCODE = 0
