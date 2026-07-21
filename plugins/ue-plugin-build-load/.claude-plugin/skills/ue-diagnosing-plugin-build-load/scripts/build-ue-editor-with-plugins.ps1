param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    [Parameter(Mandatory = $true)]
    [string]$EngineRoot,

    [switch]$GenerateProjectFiles,
    [switch]$QuarantineStaleArtifacts,
    [switch]$AllowSharedPluginOutputs,
    [string[]]$AdditionalBuildArgs = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ue-plugin-build-common.ps1')

function Read-Json([string]$Path) {
    Read-UeJsonFile $Path
}
function Stop-Contract([string]$Code, [string]$Message) {
    throw "UE_CONTRACT|$Code|$Message"
}

function Test-IsUnderRoot([string]$Path, [string]$Root) {
    $FullPath = [System.IO.Path]::GetFullPath($Path)
    $FullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $Prefix = $FullRoot + [System.IO.Path]::DirectorySeparatorChar
    return $FullPath.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-HasReparseAncestor([string]$Path, [string]$Root) {
    $Current = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    $RootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    while (-not [string]::IsNullOrWhiteSpace($Current) -and
        $Current.Length -gt $RootPath.Length) {
        if (Test-Path -LiteralPath $Current) {
            $Item = Get-Item -LiteralPath $Current -Force
            if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $true
            }
        }
        $Parent = Split-Path -Parent $Current
        if ($Parent -eq $Current) { break }
        $Current = $Parent
    }
    return $false
}

function Get-ReparseTarget([System.IO.FileSystemInfo]$Item) {
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        return $null
    }
    $Target = @($Item.Target) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace("$Target")) {
        return '<unresolved>'
    }
    if (-not [System.IO.Path]::IsPathRooted("$Target")) {
        $Target = Join-Path $Item.Parent.FullName "$Target"
    }
    return [System.IO.Path]::GetFullPath("$Target")
}

function Get-EditorTarget([string]$ProjectRoot, [string]$ProjectName) {
    $SourceRoot = Join-Path $ProjectRoot 'Source'
    $TargetFiles = @()
    if (Test-Path -LiteralPath $SourceRoot -PathType Container) {
        $TargetFiles = @(Get-ChildItem -LiteralPath $SourceRoot -Filter '*Editor.Target.cs' `
            -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)
    }
    if ($TargetFiles.Count -gt 0) {
        if ($TargetFiles.Count -gt 1) {
            Stop-Contract 'MULTIPLE_EDITOR_HOST_TARGETS' `
                "Multiple Editor Target.cs files found: $($TargetFiles.FullName -join '; ')"
        }
        $Text = Get-Content -LiteralPath $TargetFiles[0].FullName -Raw
        $Name = $TargetFiles[0].Name -replace '\.Target\.cs$', ''
        if ($Text -match 'class\s+(\w+)Target\s*:') {
            $Name = $Matches[1]
        }
        return [pscustomobject]@{ Name = $Name; File = $TargetFiles[0].FullName }
    }

    $ReceiptRoot = Join-Path $ProjectRoot 'Binaries\Win64'
    $Receipts = @()
    if (Test-Path -LiteralPath $ReceiptRoot -PathType Container) {
        $Receipts = @(Get-ChildItem -LiteralPath $ReceiptRoot -Filter '*Editor.target' `
            -File -ErrorAction SilentlyContinue | Sort-Object FullName)
    }
    if ($Receipts.Count -eq 1) {
        return [pscustomobject]@{ Name = $Receipts[0].BaseName; File = $null }
    }
    if ($Receipts.Count -gt 1) {
        Stop-Contract 'MULTIPLE_EDITOR_HOST_TARGETS' `
            "Multiple Editor receipts found without a Target.cs: $($Receipts.FullName -join '; ')"
    }
    Stop-Contract 'NO_EDITOR_HOST_TARGET' `
        "No project Editor host target or receipt exists for $ProjectName; create a minimal C++ Editor host target"
}

function Get-ResolvedProjectPlugins(
    [string]$ProjectRoot,
    [string]$EnginePath,
    [object]$ProjectJson
) {
    $PluginsRoot = Join-Path $ProjectRoot 'Plugins'
    $ProjectDescriptors = @{}
    if (Test-Path -LiteralPath $PluginsRoot -PathType Container) {
        foreach ($PluginDirectory in @(Get-ChildItem -LiteralPath $PluginsRoot -Directory `
            -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            $WholeReparse = (($PluginDirectory.Attributes -band `
                [System.IO.FileAttributes]::ReparsePoint) -ne 0)
            foreach ($Descriptor in @(Get-ChildItem -LiteralPath $PluginDirectory.FullName `
                -Filter '*.uplugin' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)) {
                $Key = $Descriptor.BaseName.ToLowerInvariant()
                if (-not $ProjectDescriptors.ContainsKey($Key)) {
                    $ProjectDescriptors[$Key] = [pscustomobject]@{
                        Name = $Descriptor.BaseName
                        Descriptor = $Descriptor.FullName
                        Root = $Descriptor.Directory.FullName
                        WholePluginReparse = $WholeReparse
                        ReparseTarget = $(if ($WholeReparse) {
                            Get-ReparseTarget $PluginDirectory
                        } else { $null })
                    }
                }
            }
        }
    }

    $EngineDescriptors = @{}
    $EnginePluginsRoot = Join-Path $EnginePath 'Engine\Plugins'
    if (Test-Path -LiteralPath $EnginePluginsRoot -PathType Container) {
        foreach ($Descriptor in @(Get-ChildItem -LiteralPath $EnginePluginsRoot -Filter '*.uplugin' `
            -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            $Key = $Descriptor.BaseName.ToLowerInvariant()
            if (-not $EngineDescriptors.ContainsKey($Key)) {
                $EngineDescriptors[$Key] = $Descriptor.FullName
            }
        }
    }

    $Queue = @($ProjectJson.Plugins | Where-Object { $_.Enabled -eq $true })
    $Visited = @{}
    $Result = @()
    for ($Index = 0; $Index -lt $Queue.Count; $Index++) {
        $Reference = $Queue[$Index]
        if (-not (Test-UePluginReferenceApplicable $Reference 'Win64' 'Editor' 'Development')) {
            continue
        }
        $Name = "$($Reference.Name)"
        if ([string]::IsNullOrWhiteSpace($Name)) { continue }
        $Key = $Name.ToLowerInvariant()
        if ($Visited.ContainsKey($Key)) { continue }
        $Visited[$Key] = $true

        if ($ProjectDescriptors.ContainsKey($Key)) {
            $Plugin = $ProjectDescriptors[$Key]
            $DescriptorJson = Read-Json $Plugin.Descriptor
            if (-not (Test-UePluginDescriptorApplicable $DescriptorJson 'Win64')) { continue }
            $ApplicableModules = @(
                $DescriptorJson.Modules |
                    Where-Object { Test-UeModuleApplicable $_ 'Win64' 'Editor' 'Development' }
            )
            $Plugin | Add-Member -NotePropertyName ApplicableModules `
                -NotePropertyValue $ApplicableModules -Force
            $Result += $Plugin
            foreach ($Dependency in @($DescriptorJson.Plugins)) {
                if ($Dependency.Enabled -eq $false) { continue }
                $Queue += $Dependency
            }
            continue
        }
        if ($EngineDescriptors.ContainsKey($Key)) {
            $EngineDescriptorJson = Read-Json $EngineDescriptors[$Key]
            if (-not (Test-UePluginDescriptorApplicable $EngineDescriptorJson 'Win64')) { continue }
            continue
        }
        if ($Reference.Optional -eq $true) {
            $script:ResolutionInfo += "INFO optional plugin $Name has no descriptor; skipped"
            continue
        }
        Stop-Contract 'ENABLED_PLUGIN_NOT_FOUND' `
            "No project or selected-engine descriptor was found for enabled plugin $Name"
    }
    return @($Result | Sort-Object Name, Descriptor)
}

function Get-ReceiptEngineMismatch(
    [string]$ReceiptPath,
    [object]$Receipt,
    [object]$BuildVersion,
    [string]$EnginePath
) {
    $Fields = @('MajorVersion', 'MinorVersion', 'PatchVersion')
    foreach ($Field in $Fields) {
        $ReceiptValue = $Receipt.Version.$Field
        $EngineValue = $BuildVersion.$Field
        if ($null -ne $ReceiptValue -and $null -ne $EngineValue -and
            "$ReceiptValue" -ne "$EngineValue") {
            return "$ReceiptPath has $Field=$ReceiptValue but selected engine has $Field=$EngineValue"
        }
    }

    $EngineManifestPath = Join-Path $EnginePath 'Engine\Binaries\Win64\UnrealEditor.modules'
    if (Test-Path -LiteralPath $EngineManifestPath -PathType Leaf) {
        $EngineManifest = Read-Json $EngineManifestPath
        $ReceiptBuildId = "$($Receipt.Version.BuildId)"
        $EngineBuildId = "$($EngineManifest.BuildId)"
        if (-not [string]::IsNullOrWhiteSpace($ReceiptBuildId) -and
            -not [string]::IsNullOrWhiteSpace($EngineBuildId) -and
            $ReceiptBuildId -ne $EngineBuildId) {
            return "$ReceiptPath BuildId=$ReceiptBuildId but selected engine manifest BuildId=$EngineBuildId"
        }
    }
    return $null
}

function Get-StaleArtifacts(
    [string]$ProjectRoot,
    [string]$EditorTarget,
    [object[]]$Plugins,
    [bool]$ForceAll
) {
    $ReceiptPath = Join-Path $ProjectRoot "Binaries\Win64\$EditorTarget.target"
    if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { return @() }

    $Receipt = Read-Json $ReceiptPath
    $ReceiptBuildId = "$($Receipt.Version.BuildId)"
    if ([string]::IsNullOrWhiteSpace($ReceiptBuildId) -and -not $ForceAll) { return @() }

    $Artifacts = @()
    if ($ForceAll) {
        $Artifacts += [pscustomobject]@{ Path = $ReceiptPath; Kind = 'receipt'; Shared = $false }
    }
    foreach ($Plugin in $Plugins) {
        if (@($Plugin.ApplicableModules).Count -eq 0) { continue }
        $ManifestPath = Join-Path $Plugin.Root 'Binaries\Win64\UnrealEditor.modules'
        if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { continue }
        $Manifest = Read-Json $ManifestPath
        $MappedDlls = @()
        foreach ($Property in @($Manifest.Modules.PSObject.Properties)) {
            $MappedArtifacts = Get-UeSafeManifestArtifacts $ManifestPath `
                $Property.Name $Property.Value
            $MappedDlls += [pscustomobject]@{
                Name = $Property.Name
                DllPath = $MappedArtifacts.DllPath
                PdbPath = $MappedArtifacts.PdbPath
            }
        }
        $ManifestBuildId = "$($Manifest.BuildId)"
        if (-not $ForceAll -and ([string]::IsNullOrWhiteSpace($ManifestBuildId) -or
            $ManifestBuildId -eq $ReceiptBuildId)) { continue }

        if (-not ($Artifacts | Where-Object { $_.Path -eq $ReceiptPath })) {
            $Artifacts += [pscustomobject]@{ Path = $ReceiptPath; Kind = 'receipt'; Shared = $false }
        }
        $Artifacts += [pscustomobject]@{
            Path = $ManifestPath
            Kind = 'manifest'
            Shared = [bool]$Plugin.WholePluginReparse
        }
        foreach ($MappedDll in $MappedDlls) {
            $DllPath = $MappedDll.DllPath
            if (Test-Path -LiteralPath $DllPath -PathType Leaf) {
                $Artifacts += [pscustomobject]@{
                    Path = $DllPath
                    Kind = 'mapped DLL'
                    Shared = [bool]$Plugin.WholePluginReparse
                }
            }
            $PdbPath = $MappedDll.PdbPath
            if (Test-Path -LiteralPath $PdbPath -PathType Leaf) {
                $Artifacts += [pscustomobject]@{
                    Path = $PdbPath
                    Kind = 'mapped PDB'
                    Shared = [bool]$Plugin.WholePluginReparse
                }
            }
        }
    }
    return @($Artifacts | Sort-Object Path -Unique)
}

function Move-StaleArtifacts([object[]]$Artifacts, [string]$ProjectRoot) {
    $Timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $BackupRoot = Join-Path $ProjectRoot "Saved\BuildReceiptBackup\$Timestamp"
    foreach ($Artifact in $Artifacts) {
        if ($Artifact.Shared) {
            Write-Output "QUARANTINE_SKIP shared plugin output: $($Artifact.Path)"
            continue
        }
        if (-not (Test-IsUnderRoot $Artifact.Path $ProjectRoot)) {
            Write-Output "QUARANTINE_SKIP outside project root: $($Artifact.Path)"
            continue
        }
        if (Test-HasReparseAncestor $Artifact.Path $ProjectRoot) {
            Write-Output "QUARANTINE_SKIP output traverses a reparse point: $($Artifact.Path)"
            continue
        }
        if (-not (Test-Path -LiteralPath $Artifact.Path -PathType Leaf)) { continue }
        $Relative = $Artifact.Path.Substring($ProjectRoot.TrimEnd('\', '/').Length).TrimStart('\', '/')
        $Destination = Join-Path $BackupRoot $Relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
        Move-Item -LiteralPath $Artifact.Path -Destination $Destination
        Write-Output "QUARANTINE $($Artifact.Kind): $($Artifact.Path) -> $Destination"
    }
}

function ConvertTo-WindowsProcessArgument([string]$Value) {
    if ($null -eq $Value) { $Value = '' }
    $NeedsQuotes = ($Value.Length -eq 0 -or $Value.Contains('"'))
    if (-not $NeedsQuotes) {
        foreach ($Character in $Value.ToCharArray()) {
            if ([char]::IsWhiteSpace($Character)) { $NeedsQuotes = $true; break }
        }
    }
    if (-not $NeedsQuotes) { return $Value }

    $Builder = New-Object System.Text.StringBuilder
    [void]$Builder.Append('"')
    $Backslashes = 0
    foreach ($Character in $Value.ToCharArray()) {
        if ($Character -eq '\') {
            $Backslashes++
            continue
        }
        if ($Character -eq '"') {
            [void]$Builder.Append(('\' * (($Backslashes * 2) + 1)))
            [void]$Builder.Append('"')
            $Backslashes = 0
            continue
        }
        if ($Backslashes -gt 0) {
            [void]$Builder.Append(('\' * $Backslashes))
            $Backslashes = 0
        }
        [void]$Builder.Append($Character)
    }
    if ($Backslashes -gt 0) { [void]$Builder.Append(('\' * ($Backslashes * 2))) }
    [void]$Builder.Append('"')
    return $Builder.ToString()
}

function Stop-ToolProcessTree([System.Diagnostics.Process]$Process) {
    try {
        if ($Process.HasExited) { return }
    }
    catch { return }

    $TaskKill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    if (Test-Path -LiteralPath $TaskKill -PathType Leaf) {
        $Killer = New-Object System.Diagnostics.Process
        try {
            $Killer.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $Killer.StartInfo.FileName = $TaskKill
            $Killer.StartInfo.Arguments = "/PID $($Process.Id) /T /F"
            $Killer.StartInfo.UseShellExecute = $false
            $Killer.StartInfo.CreateNoWindow = $true
            if ($Killer.Start()) { [void]$Killer.WaitForExit(15000) }
        }
        catch { }
        finally { $Killer.Dispose() }
    }

    try {
        if (-not $Process.HasExited) { $Process.Kill() }
        [void]$Process.WaitForExit(15000)
    }
    catch { }
}

function Invoke-LoggedTool([string]$Tool, [string[]]$Arguments, [string]$LogPath) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
    $Writer = New-Object System.IO.StreamWriter($LogPath, $false, `
        (New-Object System.Text.UTF8Encoding($false)))
    $Writer.AutoFlush = $true
    $WarningState = [pscustomobject]@{ Found = $false }
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $Process.StartInfo.FileName = $Tool
    $Process.StartInfo.Arguments = (@($Arguments | ForEach-Object {
        ConvertTo-WindowsProcessArgument "$_"
    }) -join ' ')
    $Process.StartInfo.UseShellExecute = $false
    $Process.StartInfo.CreateNoWindow = $true
    $Process.StartInfo.RedirectStandardOutput = $true
    $Process.StartInfo.RedirectStandardError = $true
    $ProcessStarted = $false
    try {
        if (-not $Process.Start()) { throw "Failed to start tool: $Tool" }
        $ProcessStarted = $true
        $OutputDone = $false
        $ErrorDone = $false
        $OutputTask = $Process.StandardOutput.ReadLineAsync()
        $ErrorTask = $Process.StandardError.ReadLineAsync()
        while (-not $OutputDone -or -not $ErrorDone) {
            $HandledLine = $false
            $Line = $null
            if (-not $OutputDone -and $OutputTask.IsCompleted) {
                $Line = $OutputTask.Result
                if ($null -eq $Line) { $OutputDone = $true }
                else { $OutputTask = $Process.StandardOutput.ReadLineAsync() }
                $HandledLine = $true
            }
            elseif (-not $ErrorDone -and $ErrorTask.IsCompleted) {
                $Line = $ErrorTask.Result
                if ($null -eq $Line) { $ErrorDone = $true }
                else { $ErrorTask = $Process.StandardError.ReadLineAsync() }
                $HandledLine = $true
            }
            if ($null -ne $Line) {
                $Writer.WriteLine($Line)
                [Console]::Out.WriteLine($Line)
                if ($Line -match "(?i)^\s*(?:warning\s*:\s*)?Plugin\s+'[^']+'\s+does not list plugin\s+'[^']+'\s+as a dependency") {
                    $WarningState.Found = $true
                }
            }
            if (-not $HandledLine) { Start-Sleep -Milliseconds 10 }
        }
        $Process.WaitForExit()
        $ExitCode = $Process.ExitCode
        [pscustomobject]@{
            ExitCode = $ExitCode
            DependencyWarning = $WarningState.Found
            Log = $LogPath
        }
    }
    finally {
        if ($ProcessStarted -and -not $Process.HasExited) {
            Stop-ToolProcessTree $Process
        }
        $Writer.Dispose()
        $Process.Dispose()
    }
}

function Get-FileIdentity([string]$Path, [string]$Label) {
    $Item = Get-Item -LiteralPath $Path -Force
    $Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    "$Label|$($Item.FullName)|$($Item.Length)|$($Item.LastWriteTimeUtc.Ticks)|$Hash"
}

function Get-InputFingerprint(
    [string]$ProjectPath,
    [string]$ProjectRoot,
    [string]$EnginePath,
    [string]$BuildVersionPath,
    [object]$Target,
    [object[]]$Plugins
) {
    $Records = @("engine-root|$EnginePath")
    $Records += Get-FileIdentity $ProjectPath 'project'
    $Records += Get-FileIdentity $BuildVersionPath 'engine-version'
    if ($Target.File) { $Records += Get-FileIdentity $Target.File 'editor-target' }

    foreach ($Plugin in @($Plugins | Sort-Object Name, Descriptor)) {
        $Records += Get-FileIdentity $Plugin.Descriptor "plugin-descriptor:$($Plugin.Name)"
        $SourceRoot = Join-Path $Plugin.Root 'Source'
        if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) { continue }
        $SourceItem = Get-Item -LiteralPath $SourceRoot -Force
        $SourceTarget = Get-ReparseTarget $SourceItem
        if ($SourceTarget) {
            $Records += "source-reparse|$($SourceItem.FullName)|$SourceTarget"
        }
        foreach ($File in @(Get-ChildItem -LiteralPath $SourceRoot -File -Recurse `
            -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            $Records += Get-FileIdentity $File.FullName "native-source:$($Plugin.Name)"
        }
    }

    $Payload = (@($Records | Sort-Object) -join "`n")
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
    $Hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        ([System.BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $Hasher.Dispose()
    }
}

function Write-StateAtomically([string]$Path, [object]$State) {
    $Directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $Temporary = Join-Path $Directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' +
        [guid]::NewGuid().ToString('N') + '.tmp')
    $Backup = Join-Path $Directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' +
        [guid]::NewGuid().ToString('N') + '.bak')
    try {
        $State | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Temporary -Encoding UTF8
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($Temporary, $Path, $Backup, $true)
            Remove-Item -LiteralPath $Backup -Force
        }
        else {
            Move-Item -LiteralPath $Temporary -Destination $Path
        }
    }
    finally {
        if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
        if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Force }
    }
}

$ProjectMutex = $null
$ProjectMutexAcquired = $false
try {
    $script:ResolutionInfo = @()
    $ProjectPath = (Resolve-Path -LiteralPath $Project).Path
    $MutexName = Get-UeProjectMutexName $ProjectPath
    $ProjectMutex = [System.Threading.Mutex]::new($false, $MutexName)
    try {
        $ProjectMutexAcquired = $ProjectMutex.WaitOne()
    }
    catch [System.Threading.AbandonedMutexException] {
        $ProjectMutexAcquired = $true
    }
    $EnginePath = (Resolve-Path -LiteralPath $EngineRoot).Path
    $ProjectRoot = Split-Path -Parent $ProjectPath
    $ProjectName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
    $ProjectJson = Read-Json $ProjectPath
    $BuildVersionPath = Join-Path $EnginePath 'Engine\Build\Build.version'
    $BuildVersion = Read-Json $BuildVersionPath
    $EngineVersion = "$($BuildVersion.MajorVersion).$($BuildVersion.MinorVersion).$($BuildVersion.PatchVersion)"
    $EngineMajorMinor = "$($BuildVersion.MajorVersion).$($BuildVersion.MinorVersion)"

    if ("$($ProjectJson.EngineAssociation)" -match '^\d+\.\d+$' -and
        "$($ProjectJson.EngineAssociation)" -ne $EngineMajorMinor) {
        Stop-Contract 'ENGINE_ASSOCIATION_MISMATCH' `
            "project association $($ProjectJson.EngineAssociation) does not match engine $EngineMajorMinor"
    }

    $Target = Get-EditorTarget $ProjectRoot $ProjectName
    $Plugins = @(Get-ResolvedProjectPlugins $ProjectRoot $EnginePath $ProjectJson)
    $script:ResolutionInfo | ForEach-Object { Write-Output $_ }
    foreach ($Plugin in $Plugins) {
        if ($Plugin.WholePluginReparse -and -not $AllowSharedPluginOutputs) {
            Stop-Contract 'WHOLE_PLUGIN_REPARSE_POINT' `
                "$($Plugin.Name) uses a whole-plugin reparse point ($($Plugin.ReparseTarget)); use a project-local plugin shell and link only Source or Content, or explicitly pass -AllowSharedPluginOutputs"
        }
    }

    $ReceiptPath = Join-Path $ProjectRoot "Binaries\Win64\$($Target.Name).target"
    $ForceQuarantine = $false
    if (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) {
        $PreBuildReceipt = Read-Json $ReceiptPath
        $EngineMismatch = Get-ReceiptEngineMismatch $ReceiptPath $PreBuildReceipt `
            $BuildVersion $EnginePath
        if (-not [string]::IsNullOrWhiteSpace("$EngineMismatch")) {
            if (-not $QuarantineStaleArtifacts) {
                Stop-Contract 'RECEIPT_ENGINE_MISMATCH' $EngineMismatch
            }
            $ForceQuarantine = $true
        }
    }

    $StaleArtifacts = @(Get-StaleArtifacts -ProjectRoot $ProjectRoot `
        -EditorTarget $Target.Name -Plugins $Plugins -ForceAll $ForceQuarantine)
    if ($StaleArtifacts.Count -gt 0) {
        if (-not $QuarantineStaleArtifacts) {
            Write-Output "FAIL STALE_BUILD_ID receipt and plugin manifest BuildIds disagree"
            foreach ($Artifact in $StaleArtifacts) { Write-Output "BLOCKER $($Artifact.Path)" }
            exit 1
        }
        Move-StaleArtifacts $StaleArtifacts $ProjectRoot
    }

    $BuildTool = Join-Path $EnginePath `
        'Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.exe'
    if (-not (Test-Path -LiteralPath $BuildTool -PathType Leaf)) {
        Stop-Contract 'MISSING_BUILD_TOOL' "Missing UnrealBuildTool executable: $BuildTool"
    }

    $LogRoot = Join-Path $ProjectRoot 'Saved\Logs\PluginBuild'
    $InvocationId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' +
        [guid]::NewGuid().ToString('N')
    if ($GenerateProjectFiles) {
        $GpfArguments = @('-ProjectFiles', "-Project=$ProjectPath", '-Game', '-Engine')
        $GpfLog = Join-Path $LogRoot "$InvocationId-gpf.log"
        Write-Output "GPF $BuildTool $($GpfArguments -join ' ') log=$GpfLog"
        $GpfResult = Invoke-LoggedTool $BuildTool $GpfArguments $GpfLog
        if ($GpfResult.ExitCode -ne 0) {
            Stop-Contract 'GPF_EXIT_NONZERO' "exit_code=$($GpfResult.ExitCode) log=$GpfLog"
        }
    }

    $BuildArguments = @(
        $Target.Name,
        'Win64',
        'Development',
        "-Project=$ProjectPath",
        '-WaitMutex',
        '-NoHotReloadFromIDE'
    ) + @($AdditionalBuildArgs)
    $BuildLog = Join-Path $LogRoot "$InvocationId-ubt.log"
    Write-Output "BUILD $BuildTool $($BuildArguments -join ' ') log=$BuildLog"
    $BuildResult = Invoke-LoggedTool $BuildTool $BuildArguments $BuildLog
    if ($BuildResult.ExitCode -ne 0) {
        Stop-Contract 'UBT_EXIT_NONZERO' "exit_code=$($BuildResult.ExitCode) log=$BuildLog"
    }
    if ($BuildResult.DependencyWarning) {
        Stop-Contract 'UBT_PLUGIN_DEPENDENCY_WARNING' "dependency declaration warning found in $BuildLog"
    }

    $AuditScript = Join-Path $PSScriptRoot 'audit-ue-plugin-build.ps1'
    if (-not (Test-Path -LiteralPath $AuditScript -PathType Leaf)) {
        Stop-Contract 'MISSING_AUDIT_SCRIPT' "Missing colocated audit: $AuditScript"
    }
    $PowerShellExecutable = (Get-Process -Id $PID).Path
    $AuditArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $AuditScript,
        '-Project', $ProjectPath, '-EngineRoot', $EnginePath
    )
    $AuditLog = Join-Path $LogRoot "$InvocationId-audit.log"
    Write-Output "AUDIT $AuditScript log=$AuditLog"
    $AuditResult = Invoke-LoggedTool $PowerShellExecutable $AuditArguments $AuditLog
    $AuditResult.Output | ForEach-Object { Write-Output $_ }
    if ($AuditResult.ExitCode -ne 0) {
        Stop-Contract 'AUDIT_EXIT_NONZERO' "exit_code=$($AuditResult.ExitCode) log=$AuditLog"
    }

    $ReceiptPath = Join-Path $ProjectRoot "Binaries\Win64\$($Target.Name).target"
    $Receipt = Read-Json $ReceiptPath
    $Fingerprint = Get-InputFingerprint $ProjectPath $ProjectRoot $EnginePath `
        $BuildVersionPath $Target $Plugins
    $PluginStates = @()
    foreach ($Plugin in $Plugins) {
        $ApplicableModuleNames = @($Plugin.ApplicableModules | ForEach-Object { "$($_.Name)" })
        $ManifestPath = Join-Path $Plugin.Root 'Binaries\Win64\UnrealEditor.modules'
        $Manifest = $null
        if ($ApplicableModuleNames.Count -gt 0) { $Manifest = Read-Json $ManifestPath }
        $PluginStates += [pscustomobject]@{
            name = $Plugin.Name
            descriptor = $Plugin.Descriptor
            build_id = $(if ($null -ne $Manifest) { "$($Manifest.BuildId)" } else { '' })
            modules = @($ApplicableModuleNames | Sort-Object)
        }
    }
    $State = [ordered]@{
        schema_version = 1
        project_file = $ProjectPath
        editor_target = $Target.Name
        platform = 'Win64'
        configuration = 'Development'
        engine = [ordered]@{ root = $EnginePath; version = $EngineVersion }
        target_build_id = "$($Receipt.Version.BuildId)"
        built_at_utc = [DateTime]::UtcNow.ToString('o')
        input_fingerprint = $Fingerprint
        plugins = @($PluginStates)
    }
    $StatePath = Join-Path $ProjectRoot "Saved\PluginBuildState\$($Target.Name).json"
    Write-StateAtomically $StatePath $State
    Write-Output "STATE $StatePath fingerprint=$Fingerprint"
    exit 0
}
catch {
    $FailureMessage = $_.Exception.Message
    if ($FailureMessage -match '^UE_CONTRACT\|([^|]+)\|(.*)$') {
        Write-Output "FAIL $($Matches[1]) $($Matches[2])"
        exit 1
    }
    Write-Output "FAIL ORCHESTRATOR_ERROR $FailureMessage"
    exit 2
}
finally {
    if ($ProjectMutexAcquired -and $null -ne $ProjectMutex) {
        try { $ProjectMutex.ReleaseMutex() } catch { }
    }
    if ($null -ne $ProjectMutex) { $ProjectMutex.Dispose() }
}
