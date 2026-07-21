param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    [Parameter(Mandatory = $true)]
    [string]$EngineRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ue-plugin-build-common.ps1')
$script:Failures = 0

function Write-Failure([string]$Message) {
    $script:Failures++
    Write-Output "FAIL $Message"
}
function Read-Json([string]$Path) {
    return Read-UeJsonFile $Path
}

try {
    $ProjectPath = (Resolve-Path -LiteralPath $Project).Path
    $EnginePath = (Resolve-Path -LiteralPath $EngineRoot).Path
    $ProjectRoot = Split-Path -Parent $ProjectPath
    $ProjectName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
    $ProjectJson = Read-Json $ProjectPath
    $BuildVersionPath = Join-Path $EnginePath 'Engine\Build\Build.version'
    $BuildVersion = Read-Json $BuildVersionPath
    $EngineVersion = "$($BuildVersion.MajorVersion).$($BuildVersion.MinorVersion)"

    Write-Output "INFO project=$ProjectPath"
    Write-Output "INFO engine=$EnginePath version=$EngineVersion association=$($ProjectJson.EngineAssociation)"

    if ("$($ProjectJson.EngineAssociation)" -match '^\d+\.\d+$' -and
        "$($ProjectJson.EngineAssociation)" -ne $EngineVersion) {
        Write-Failure "EngineAssociation $($ProjectJson.EngineAssociation) does not match engine $EngineVersion"
    }

    $EditorTarget = "$($ProjectName)Editor"
    $TargetFiles = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'Source') `
        -Filter '*Editor.Target.cs' -File -ErrorAction SilentlyContinue)
    if ($TargetFiles.Count -gt 0) {
        $TargetText = Get-Content -LiteralPath $TargetFiles[0].FullName -Raw
        if ($TargetText -match 'class\s+(\w+)Target\s*:') {
            $EditorTarget = $Matches[1]
        }
        else {
            $EditorTarget = $TargetFiles[0].Name -replace '\.Target\.cs$', ''
        }
    }

    if ($TargetFiles.Count -eq 0) {
        $ExistingReceipts = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'Binaries\Win64') `
            -Filter '*Editor.target' -File -ErrorAction SilentlyContinue)
        if ($ExistingReceipts.Count -eq 1) {
            $EditorTarget = $ExistingReceipts[0].BaseName
        }
        elseif ($ExistingReceipts.Count -eq 0) {
            Write-Failure 'No project Editor host target or receipt; create a minimal C++ Editor host target before building native project plugins'
            exit 1
        }
        else {
            Write-Failure 'Multiple Editor receipts found but no Editor Target.cs; select the intended project Editor target explicitly'
            exit 1
        }
    }

    $ReceiptPath = Join-Path $ProjectRoot "Binaries\Win64\$EditorTarget.target"
    if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
        Write-Failure "Missing Editor target receipt: $ReceiptPath"
        Write-Output "REBUILD $EnginePath\Engine\Build\BatchFiles\Build.bat $EditorTarget Win64 Development -Project=$ProjectPath -WaitMutex -NoHotReloadFromIDE"
        exit 1
    }

    $Receipt = Read-Json $ReceiptPath
    $TargetBuildId = "$($Receipt.Version.BuildId)"
    if ([string]::IsNullOrWhiteSpace($TargetBuildId)) {
        Write-Failure "Editor target receipt has no Version.BuildId: $ReceiptPath"
    }
    else {
        Write-Output "INFO target=$EditorTarget BuildId=$TargetBuildId"
    }

    $BuildProducts = @($Receipt.BuildProducts | ForEach-Object { "$($_.Path)" -replace '\\', '/' })
    # Recurse from each child so project plugin junctions are entered on Windows.
    $DescriptorFiles = @(
        foreach ($PluginDirectory in @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'Plugins') `
            -Directory -ErrorAction SilentlyContinue)) {
            Get-ChildItem -LiteralPath $PluginDirectory.FullName -Filter '*.uplugin' `
                -File -Recurse -ErrorAction SilentlyContinue
        }
    )
    $ProjectDescriptors = @{}
    foreach ($Descriptor in $DescriptorFiles) {
        $Key = $Descriptor.BaseName.ToLowerInvariant()
        if (-not $ProjectDescriptors.ContainsKey($Key)) {
            $ProjectDescriptors[$Key] = $Descriptor
        }
    }
    $EngineDescriptors = @{}
    $EnginePluginsRoot = Join-Path $EnginePath 'Engine\Plugins'
    if (Test-Path -LiteralPath $EnginePluginsRoot -PathType Container) {
        foreach ($Descriptor in @(Get-ChildItem -LiteralPath $EnginePluginsRoot -Filter '*.uplugin' `
            -File -Recurse -ErrorAction SilentlyContinue)) {
            $Key = $Descriptor.BaseName.ToLowerInvariant()
            if (-not $EngineDescriptors.ContainsKey($Key)) {
                $EngineDescriptors[$Key] = $Descriptor
            }
        }
    }

    $Queue = @($ProjectJson.Plugins | Where-Object { $_.Enabled -eq $true })
    $Visited = @{}
    $ResolvedPlugins = @()
    for ($Index = 0; $Index -lt $Queue.Count; $Index++) {
        $Reference = $Queue[$Index]
        if (-not (Test-UePluginReferenceApplicable $Reference 'Win64' 'Editor' 'Development')) {
            continue
        }
        $PluginName = "$($Reference.Name)"
        if ([string]::IsNullOrWhiteSpace($PluginName)) { continue }
        $Key = $PluginName.ToLowerInvariant()
        if ($Visited.ContainsKey($Key)) { continue }
        $Visited[$Key] = $true

        if ($ProjectDescriptors.ContainsKey($Key)) {
            $Descriptor = $ProjectDescriptors[$Key]
            $DescriptorJson = Read-Json $Descriptor.FullName
            if (-not (Test-UePluginDescriptorApplicable $DescriptorJson 'Win64')) { continue }
            $ResolvedPlugins += [pscustomobject]@{
                Name = $PluginName
                Descriptor = $Descriptor
            }
            foreach ($Dependency in @($DescriptorJson.Plugins)) {
                if ($Dependency.Enabled -eq $false) { continue }
                $Queue += $Dependency
            }
            continue
        }
        if ($EngineDescriptors.ContainsKey($Key)) {
            $EngineDescriptorJson = Read-Json $EngineDescriptors[$Key].FullName
            if (-not (Test-UePluginDescriptorApplicable $EngineDescriptorJson 'Win64')) { continue }
            Write-Output "SKIP $PluginName is owned by the selected engine"
            continue
        }
        if ($Reference.Optional -eq $true) {
            Write-Output "INFO optional plugin $PluginName has no descriptor; skipped"
            continue
        }
        Write-Failure "$PluginName enabled descriptor was not found in project or selected engine plugins"
    }

    foreach ($PluginEntry in @($ResolvedPlugins | Sort-Object Name)) {
        $PluginName = "$($PluginEntry.Name)"
        $Descriptor = $PluginEntry.Descriptor

        $PluginFailedAtStart = $script:Failures
        $PluginJson = Read-Json $Descriptor.FullName
        $PluginRoot = $Descriptor.Directory.FullName
        $ApplicableModules = @(
            $PluginJson.Modules |
                Where-Object { Test-UeModuleApplicable $_ 'Win64' 'Editor' 'Development' }
        )
        if ($ApplicableModules.Count -eq 0) {
            Write-Output "PASS $PluginName has no applicable Win64 Editor Development modules"
            continue
        }
        $ManifestPath = Join-Path $PluginRoot 'Binaries\Win64\UnrealEditor.modules'
        if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
            Write-Failure "$PluginName missing manifest: $ManifestPath"
            continue
        }

        $Manifest = Read-Json $ManifestPath
        if ("$($Manifest.BuildId)" -ne $TargetBuildId) {
            Write-Failure "$PluginName BuildId mismatch: manifest=$($Manifest.BuildId) target=$TargetBuildId"
        }

        $ManifestModules = @($Manifest.Modules.PSObject.Properties.Name)
        foreach ($Module in $ApplicableModules) {
            $ModuleName = "$($Module.Name)"
            if ([string]::IsNullOrWhiteSpace($ModuleName)) { continue }

            if ($ManifestModules -notcontains $ModuleName) {
                Write-Failure "$PluginName module $ModuleName absent from UnrealEditor.modules"
                continue
            }

            $DllName = "$($Manifest.Modules.$ModuleName)"
            $MappedArtifacts = Get-UeSafeManifestArtifacts $ManifestPath `
                $ModuleName $DllName
            $DllPath = $MappedArtifacts.DllPath
            if (-not (Test-Path -LiteralPath $DllPath -PathType Leaf)) {
                Write-Failure "$PluginName Missing DLL for ${ModuleName}: $DllPath"
                continue
            }

            $RelativePluginRoot = $PluginRoot.Substring($ProjectRoot.Length).TrimStart('\', '/') -replace '\\', '/'
            $ExpectedSuffix = "$RelativePluginRoot/Binaries/Win64/$DllName"
            if (-not ($BuildProducts | Where-Object { $_.EndsWith($ExpectedSuffix, [System.StringComparison]::OrdinalIgnoreCase) })) {
                Write-Failure "$PluginName DLL is absent from $EditorTarget.target BuildProducts: $DllName"
            }
        }

        if ($script:Failures -eq $PluginFailedAtStart) {
            Write-Output "PASS $PluginName"
        }
    }

    if ($script:Failures -gt 0) {
        Write-Output "REBUILD $EnginePath\Engine\Build\BatchFiles\Build.bat $EditorTarget Win64 Development -Project=$ProjectPath -WaitMutex -NoHotReloadFromIDE"
        exit 1
    }

    Write-Output 'AUDIT_PASS project plugin manifests, DLLs, BuildIds, and receipt products agree'
    exit 0
}
catch {
    $FailureMessage = $_.Exception.Message
    if ($FailureMessage -match '^UE_CONTRACT\|([^|]+)\|(.*)$') {
        Write-Output "FAIL $($Matches[1]) $($Matches[2])"
        exit 1
    }
    Write-Output "FAIL audit error: $FailureMessage at line $($_.InvocationInfo.ScriptLineNumber)"
    exit 2
}
