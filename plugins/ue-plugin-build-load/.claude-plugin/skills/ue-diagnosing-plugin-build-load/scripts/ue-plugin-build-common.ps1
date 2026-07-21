function ConvertFrom-UeJson([string]$Text) {
    $WithoutComments = New-Object System.Text.StringBuilder
    $InString = $false
    $Escaped = $false
    for ($Index = 0; $Index -lt $Text.Length; $Index++) {
        $Character = $Text[$Index]
        if ($InString) {
            [void]$WithoutComments.Append($Character)
            if ($Escaped) { $Escaped = $false }
            elseif ($Character -eq [char]92) { $Escaped = $true }
            elseif ($Character -eq [char]34) { $InString = $false }
            continue
        }
        if ($Character -eq [char]34) {
            $InString = $true
            [void]$WithoutComments.Append($Character)
            continue
        }
        if ($Character -eq '/' -and $Index + 1 -lt $Text.Length) {
            $Next = $Text[$Index + 1]
            if ($Next -eq '/') {
                $Index += 2
                while ($Index -lt $Text.Length -and
                    $Text[$Index] -ne "`r" -and $Text[$Index] -ne "`n") { $Index++ }
                if ($Index -lt $Text.Length) { [void]$WithoutComments.Append($Text[$Index]) }
                continue
            }
            if ($Next -eq '*') {
                [void]$WithoutComments.Append(' ')
                $Index += 2
                while ($Index + 1 -lt $Text.Length -and
                    -not ($Text[$Index] -eq '*' -and $Text[$Index + 1] -eq '/')) {
                    if ($Text[$Index] -eq "`r" -or $Text[$Index] -eq "`n") {
                        [void]$WithoutComments.Append($Text[$Index])
                    }
                    $Index++
                }
                if ($Index + 1 -ge $Text.Length) { throw 'Unterminated block comment in UE JSON' }
                $Index++
                continue
            }
        }
        [void]$WithoutComments.Append($Character)
    }
    if ($InString) { throw 'Unterminated string in UE JSON' }

    $CommentFree = $WithoutComments.ToString()
    $Normalized = New-Object System.Text.StringBuilder
    $InString = $false
    $Escaped = $false
    for ($Index = 0; $Index -lt $CommentFree.Length; $Index++) {
        $Character = $CommentFree[$Index]
        if ($InString) {
            [void]$Normalized.Append($Character)
            if ($Escaped) { $Escaped = $false }
            elseif ($Character -eq [char]92) { $Escaped = $true }
            elseif ($Character -eq [char]34) { $InString = $false }
            continue
        }
        if ($Character -eq [char]34) {
            $InString = $true
            [void]$Normalized.Append($Character)
            continue
        }
        if ($Character -eq ',') {
            $LookAhead = $Index + 1
            while ($LookAhead -lt $CommentFree.Length -and
                [char]::IsWhiteSpace($CommentFree[$LookAhead])) { $LookAhead++ }
            if ($LookAhead -lt $CommentFree.Length -and
                ($CommentFree[$LookAhead] -eq ']' -or $CommentFree[$LookAhead] -eq '}')) {
                continue
            }
        }
        [void]$Normalized.Append($Character)
    }
    return ConvertFrom-Json -InputObject $Normalized.ToString()
}
function Read-UeJsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing file: $Path"
    }
    return ConvertFrom-UeJson (Get-Content -LiteralPath $Path -Raw)
}

function Test-UeListContains([object[]]$Values, [string]$Expected) {
    foreach ($Value in @($Values)) {
        if ("$Value".Equals($Expected, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-UeDescriptorProperty(
    [object]$Entry,
    [string]$CanonicalName,
    [string]$LegacyName
) {
    if ($null -eq $Entry) { return $null }
    $Property = $Entry.PSObject.Properties[$CanonicalName]
    if ($null -eq $Property -and -not [string]::IsNullOrWhiteSpace($LegacyName)) {
        $Property = $Entry.PSObject.Properties[$LegacyName]
    }
    return $Property
}

function Test-UeSelectionDimension(
    [object]$Entry,
    [string]$AllowProperty,
    [string]$LegacyAllowProperty,
    [string]$DenyProperty,
    [string]$LegacyDenyProperty,
    [string]$Value
) {
    if ($null -eq $Entry) { return $false }
    $Allow = Get-UeDescriptorProperty $Entry $AllowProperty $LegacyAllowProperty
    $AllowValues = $(if ($null -ne $Allow) { @($Allow.Value) } else { @() })
    if ($AllowValues.Count -gt 0 -and -not (Test-UeListContains $AllowValues $Value)) {
        return $false
    }

    $Deny = Get-UeDescriptorProperty $Entry $DenyProperty $LegacyDenyProperty
    $DenyValues = $(if ($null -ne $Deny) { @($Deny.Value) } else { @() })
    if (Test-UeListContains $DenyValues $Value) { return $false }
    return $true
}

function Test-UePluginReferenceApplicable(
    [object]$Entry,
    [string]$Platform = 'Win64',
    [string]$Target = 'Editor',
    [string]$Configuration = 'Development'
) {
    if ($null -eq $Entry) { return $false }
    $PlatformAllow = Get-UeDescriptorProperty $Entry 'PlatformAllowList' 'WhitelistPlatforms'
    $PlatformDeny = Get-UeDescriptorProperty $Entry 'PlatformDenyList' 'BlacklistPlatforms'
    $IsExplicit = ($Entry.HasExplicitPlatforms -eq $true)
    if ($IsExplicit) {
        if ($null -eq $PlatformAllow -or
            -not (Test-UeListContains @($PlatformAllow.Value) $Platform)) { return $false }
    }
    elseif ($null -ne $PlatformAllow -and @($PlatformAllow.Value).Count -gt 0 -and
        -not (Test-UeListContains @($PlatformAllow.Value) $Platform)) { return $false }
    if ($null -ne $PlatformDeny -and
        (Test-UeListContains @($PlatformDeny.Value) $Platform)) { return $false }

    $Supported = $Entry.PSObject.Properties['SupportedTargetPlatforms']
    if ($IsExplicit) {
        if ($null -eq $Supported -or
            -not (Test-UeListContains @($Supported.Value) $Platform)) { return $false }
    }
    elseif ($null -ne $Supported -and @($Supported.Value).Count -gt 0 -and
        -not (Test-UeListContains @($Supported.Value) $Platform)) { return $false }

    if (-not (Test-UeSelectionDimension $Entry `
        'TargetAllowList' 'WhitelistTargets' 'TargetDenyList' 'BlacklistTargets' `
        $Target)) { return $false }
    if (-not (Test-UeSelectionDimension $Entry `
        'TargetConfigurationAllowList' 'WhitelistTargetConfigurations' `
        'TargetConfigurationDenyList' 'BlacklistTargetConfigurations' `
        $Configuration)) { return $false }
    return $true
}

function Test-UePluginDescriptorApplicable([object]$Descriptor, [string]$Platform = 'Win64') {
    if ($null -eq $Descriptor) { return $false }
    $Supported = $Descriptor.PSObject.Properties['SupportedTargetPlatforms']
    if ($Descriptor.HasExplicitPlatforms -eq $true) {
        return ($null -ne $Supported -and
            (Test-UeListContains @($Supported.Value) $Platform))
    }
    return ($null -eq $Supported -or @($Supported.Value).Count -eq 0 -or
        (Test-UeListContains @($Supported.Value) $Platform))
}

function Test-UeModuleApplicable(
    [object]$Module,
    [string]$Platform = 'Win64',
    [string]$Target = 'Editor',
    [string]$Configuration = 'Development'
) {
    if ($null -eq $Module) { return $false }
    $PlatformAllow = Get-UeDescriptorProperty $Module 'PlatformAllowList' 'WhitelistPlatforms'
    if ($null -ne $PlatformAllow -and
        -not (Test-UeListContains @($PlatformAllow.Value) $Platform)) { return $false }
    if ($Module.HasExplicitPlatforms -eq $true -and
        ($null -eq $PlatformAllow -or
        -not (Test-UeListContains @($PlatformAllow.Value) $Platform))) { return $false }
    $PlatformDeny = Get-UeDescriptorProperty $Module 'PlatformDenyList' 'BlacklistPlatforms'
    if ($null -ne $PlatformDeny -and
        (Test-UeListContains @($PlatformDeny.Value) $Platform)) { return $false }
    if (-not (Test-UeSelectionDimension $Module `
        'TargetAllowList' 'WhitelistTargets' 'TargetDenyList' 'BlacklistTargets' `
        $Target)) { return $false }
    if (-not (Test-UeSelectionDimension $Module `
        'TargetConfigurationAllowList' 'WhitelistTargetConfigurations' `
        'TargetConfigurationDenyList' 'BlacklistTargetConfigurations' `
        $Configuration)) { return $false }

    $ModuleType = "$($Module.Type)"
    foreach ($AllowedType in @(
        'Runtime', 'RuntimeNoCommandlet', 'RuntimeAndProgram', 'UncookedOnly',
        'Developer', 'DeveloperTool', 'Editor', 'EditorNoCommandlet',
        'EditorAndProgram', 'ServerOnly', 'ClientOnly', 'ClientOnlyNoCommandlet'
    )) {
        if ($ModuleType.Equals($AllowedType, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-UeSafeManifestArtifacts(
    [string]$ManifestPath,
    [string]$ModuleName,
    [object]$ManifestValue
) {
    $DllName = "$ManifestValue"
    $BinariesRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $ManifestPath)).TrimEnd('\', '/')
    $LeafName = [System.IO.Path]::GetFileName($DllName)
    if ([string]::IsNullOrWhiteSpace($DllName) -or
        [System.IO.Path]::IsPathRooted($DllName) -or
        $DllName.Contains('\') -or $DllName.Contains('/') -or
        $DllName.Contains('..') -or $DllName -ne $LeafName -or
        [System.IO.Path]::GetExtension($DllName) -ine '.dll') {
        throw "UE_CONTRACT|UNSAFE_MANIFEST_ARTIFACT|module $ModuleName maps to unsafe artifact '$DllName' in $ManifestPath"
    }

    $DllPath = [System.IO.Path]::GetFullPath((Join-Path $BinariesRoot $DllName))
    $PdbPath = [System.IO.Path]::GetFullPath((Join-Path $BinariesRoot `
        ([System.IO.Path]::GetFileNameWithoutExtension($DllName) + '.pdb')))
    foreach ($ArtifactPath in @($DllPath, $PdbPath)) {
        if ((Split-Path -Parent $ArtifactPath).TrimEnd('\', '/') -ine $BinariesRoot) {
            throw "UE_CONTRACT|UNSAFE_MANIFEST_ARTIFACT|module $ModuleName escapes plugin Binaries/Win64 in $ManifestPath"
        }
    }
    [pscustomobject]@{ DllPath = $DllPath; PdbPath = $PdbPath }
}

function Get-UeProjectMutexName([string]$ProjectPath) {
    $Normalized = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd('\', '/').ToLowerInvariant()
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Normalized)
    $Hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Hash = ([System.BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '')
        return "Local\UEPluginBuild_$Hash"
    }
    finally {
        $Hasher.Dispose()
    }
}
