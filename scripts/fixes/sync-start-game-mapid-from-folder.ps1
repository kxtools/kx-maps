param(
    [switch]$Changed,
    [switch]$Apply,
    [switch]$IncludeNonMaps,
    [switch]$UseModeDefaults
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\..")).Path

function Get-RepoRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = (Resolve-Path $Path).Path
    if ($fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($repoRoot.Length).TrimStart('\', '/')
    }

    return $fullPath
}

function Get-JsonFiles {
    param(
        [switch]$OnlyChanged
    )

    Push-Location $repoRoot
    try {
        if (-not $OnlyChanged) {
            return @(Get-ChildItem -Path . -Recurse -File |
                Where-Object { $_.Extension -match '^\.(?i:json)$' } |
                Select-Object -ExpandProperty FullName)
        }

        $changed = @()
        $diffOutput = @(git diff --name-only --diff-filter=ACMR HEAD -- '*.json' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $diffOutput) {
            $changed += $diffOutput
        }

        $untrackedOutput = @(git ls-files --others --exclude-standard -- '*.json' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $untrackedOutput) {
            $changed += $untrackedOutput
        }

        return @($changed |
            Where-Object { $_ -and (Test-Path $_) } |
            Sort-Object -Unique |
            ForEach-Object { (Resolve-Path $_).Path })
    }
    finally {
        Pop-Location
    }
}

function Normalize-MapNameForMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $value = $Text.ToLowerInvariant()
    $value = $value -replace "[']", ""
    $value = $value -replace "[^a-z0-9 ]", " "
    $value = $value -replace "\s+", " "
    return $value.Trim()
}

function Normalize-PathSegmentForMapLookup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Segment
    )

    # Support numbered folders like "01 Lowland Shore".
    return (($Segment -replace '^\d+\s+', '').Trim())
}

function Resolve-CanonicalMapNameFromPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,
        [Parameter(Mandatory = $true)]
        [hashtable]$CanonicalByNormalized
    )

    $parts = @($RelativePath -split '[\\/]')
    if ($parts.Count -lt 3 -or $parts[0] -ne "Maps") {
        return $null
    }

    $resolved = $null
    for ($i = 1; $i -lt ($parts.Count - 1); $i++) {
        $segment = Normalize-PathSegmentForMapLookup -Segment $parts[$i]
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        $normalized = Normalize-MapNameForMatch -Text $segment
        if ($CanonicalByNormalized.ContainsKey($normalized)) {
            # Use deepest matching segment (actual map folder tends to be deepest).
            $resolved = $CanonicalByNormalized[$normalized]
        }
    }

    return $resolved
}

function Get-CanonicalMapNameFromFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [hashtable]$CanonicalByNormalized
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        return $null
    }

    $normalized = Normalize-MapNameForMatch -Text $baseName
    if ($CanonicalByNormalized.ContainsKey($normalized)) {
        return $CanonicalByNormalized[$normalized]
    }

    return $null
}

function Get-CanonicalMapNameFromFileNameContains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$CanonicalNamesForScan
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        return $null
    }

    foreach ($canonical in $CanonicalNamesForScan) {
        $escaped = [System.Text.RegularExpressions.Regex]::Escape($canonical)
        $pattern = "(?i)(?<!\w)$escaped(?!\w)"
        if ($baseName -match $pattern) {
            return $canonical
        }

        if ($canonical -match "'") {
            $apostropheLess = ($canonical -replace "'", "")
            $apostropheLessEscaped = [System.Text.RegularExpressions.Regex]::Escape($apostropheLess)
            $apostropheLessPattern = "(?i)(?<!\w)$apostropheLessEscaped(?!\w)"
            if ($baseName -match $apostropheLessPattern) {
                return $canonical
            }
        }
    }

    return $null
}

function Resolve-ModeDefaultMapId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    # Optional convenience defaults for broad content groups.
    $rules = @(
        @{ Pattern = '(?i)^Maps[\\/].*Super Adventure Box'; Id = 895 },
        @{ Pattern = '(?i)^Maps[\\/]60 Story Journal[\\/]02 Heart of Thorns Story'; Id = 1042 },
        @{ Pattern = '(?i)^Maps[\\/]60 Story Journal[\\/]03 Path of Fire Story'; Id = 1210 },
        @{ Pattern = '(?i)^Maps[\\/]60 Story Journal[\\/]04 End of Dragons Story'; Id = 1442 },
        @{ Pattern = '(?i)^Maps[\\/]06 Janthir Wilds[\\/]00 Janthir Wilds Story'; Id = 1550 }
    )

    foreach ($rule in $rules) {
        if ($RelativePath -match $rule.Pattern) {
            return [int]$rule.Id
        }
    }

    return $null
}

function Insert-StartGameMapId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Raw,
        [Parameter(Mandatory = $true)]
        [int]$MapId
    )

    $newline = "`n"
    if ($Raw.Contains("`r`n")) {
        $newline = "`r`n"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Raw -split '\r?\n', -1)) {
        [void]$lines.Add($line)
    }

    $anchorRegexes = @(
        '^\s*"LastUpdated"\s*:',
        '^\s*"Author"\s*:',
        '^\s*"CreatedWithTool"\s*:',
        '^\s*"FormatVersion"\s*:',
        '^\s*"Name"\s*:'
    )

    $insertAfterIndex = -1
    foreach ($anchorRegex in $anchorRegexes) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $anchorRegex) {
                $insertAfterIndex = $i
                break
            }
        }
        if ($insertAfterIndex -ge 0) {
            break
        }
    }

    if ($insertAfterIndex -lt 0) {
        return $null
    }

    if ($lines[$insertAfterIndex] -notmatch ',\s*$') {
        $lines[$insertAfterIndex] = $lines[$insertAfterIndex].TrimEnd() + ","
    }

    $indent = "  "
    if ($lines[$insertAfterIndex] -match '^(\s*)"') {
        $indent = $Matches[1]
    }
    $insertLine = "$indent`"StartGameMapId`": $MapId,"

    $lines.Insert($insertAfterIndex + 1, $insertLine)
    return ($lines -join $newline)
}

$mapNamesPath = Join-Path $repoRoot "Data\map_names.json"
if (-not (Test-Path $mapNamesPath)) {
    Write-Host "[ERROR] Data/map_names.json not found."
    exit 1
}

$rawMapNames = Get-Content -Path $mapNamesPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($rawMapNames -isnot [System.Collections.IEnumerable]) {
    Write-Host "[ERROR] Data/map_names.json must contain an array."
    exit 1
}

$idsByCanonicalName = @{}
$canonicalByNormalized = @{}
$canonicalNamesForScan = @()
foreach ($entry in $rawMapNames) {
    $name = [string]$entry.name
    $idValue = [string]$entry.id
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($idValue)) {
        continue
    }

    $name = $name.Trim()
    $id = 0
    if (-not [int]::TryParse($idValue.Trim(), [ref]$id)) {
        continue
    }

    if (-not $idsByCanonicalName.ContainsKey($name)) {
        $idsByCanonicalName[$name] = New-Object System.Collections.Generic.HashSet[int]
    }
    [void]$idsByCanonicalName[$name].Add($id)

    $normalized = Normalize-MapNameForMatch -Text $name
    if (-not $canonicalByNormalized.ContainsKey($normalized)) {
        $canonicalByNormalized[$normalized] = $name
    }
}
$canonicalNamesForScan = @($idsByCanonicalName.Keys | Sort-Object { $_.Length } -Descending)

$files = @(Get-JsonFiles -OnlyChanged:$Changed)
if (-not $IncludeNonMaps) {
    $files = @($files | Where-Object {
        $rel = Get-RepoRelativePath -Path $_
        $rel -like "Maps\*" -or $rel -like "Maps/*"
    })
}

if ($files.Count -eq 0) {
    if ($Changed) {
        Write-Host "No changed JSON files found."
    }
    else {
        Write-Host "No JSON files found."
    }
    exit 0
}

$missingCount = 0
$updatedCount = 0
$skippedNoMapCount = 0
$skippedAmbiguousCount = 0
$errorCount = 0
$resolvedByFileNameCount = 0
$resolvedByFileNameContainsCount = 0
$resolvedAmbiguousBySiblingCount = 0
$resolvedAmbiguousByLowestIdCount = 0
$resolvedByModeDefaultsCount = 0
$autoFixableCount = 0

$folderKnownIds = @{}
foreach ($file in $files) {
    $relativePath = Get-RepoRelativePath -Path $file
    $dir = Split-Path -Parent $relativePath
    if ([string]::IsNullOrWhiteSpace($dir)) {
        continue
    }

    try {
        $raw = Get-Content -Path $file -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json
    }
    catch {
        continue
    }

    if ($json -isnot [pscustomobject]) {
        continue
    }

    if (-not ($json.PSObject.Properties.Name -contains "StartGameMapId")) {
        continue
    }

    $id = 0
    if (-not [int]::TryParse([string]$json.StartGameMapId, [ref]$id)) {
        continue
    }

    if (-not $folderKnownIds.ContainsKey($dir)) {
        $folderKnownIds[$dir] = New-Object System.Collections.Generic.HashSet[int]
    }
    [void]$folderKnownIds[$dir].Add($id)
}

foreach ($file in $files) {
    $relativePath = Get-RepoRelativePath -Path $file
    $directoryPath = Split-Path -Parent $relativePath

    $raw = $null
    $json = $null
    try {
        $raw = Get-Content -Path $file -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json
    }
    catch {
        Write-Host "[ERROR] $relativePath : invalid JSON syntax. $($_.Exception.Message)"
        $errorCount++
        continue
    }

    if ($json -isnot [pscustomobject]) {
        continue
    }

    if ($json.PSObject.Properties.Name -contains "StartGameMapId") {
        continue
    }

    $missingCount++

    $canonical = Resolve-CanonicalMapNameFromPath -RelativePath $relativePath -CanonicalByNormalized $canonicalByNormalized
    if ([string]::IsNullOrWhiteSpace($canonical)) {
        $canonical = Get-CanonicalMapNameFromFileName -FilePath $file -CanonicalByNormalized $canonicalByNormalized
        if (-not [string]::IsNullOrWhiteSpace($canonical)) {
            $resolvedByFileNameCount++
        }
    }

    if ([string]::IsNullOrWhiteSpace($canonical)) {
        $canonical = Get-CanonicalMapNameFromFileNameContains -FilePath $file -CanonicalNamesForScan $canonicalNamesForScan
        if (-not [string]::IsNullOrWhiteSpace($canonical)) {
            $resolvedByFileNameContainsCount++
        }
    }

    $modeDefaultId = $null
    if ([string]::IsNullOrWhiteSpace($canonical)) {
        if ($UseModeDefaults) {
            $modeDefaultId = Resolve-ModeDefaultMapId -RelativePath $relativePath
        }

        if ($null -eq $modeDefaultId) {
            Write-Host "[SKIP] $relativePath : could not infer map name from folder path."
            $skippedNoMapCount++
            continue
        }
    }

    if ($null -eq $modeDefaultId -and -not $idsByCanonicalName.ContainsKey($canonical)) {
        Write-Host "[SKIP] $relativePath : canonical map '$canonical' has no ID entry."
        $skippedNoMapCount++
        continue
    }

    $targetId = $null
    if ($null -ne $modeDefaultId) {
        $targetId = [int]$modeDefaultId
        $resolvedByModeDefaultsCount++
    }
    else {
        $ids = @($idsByCanonicalName[$canonical] | Sort-Object)
        if ($ids.Count -ne 1) {
            if ($folderKnownIds.ContainsKey($directoryPath)) {
                $known = @($folderKnownIds[$directoryPath] | Sort-Object)
                $overlap = @($ids | Where-Object { $known -contains $_ } | Sort-Object -Unique)
                if ($overlap.Count -eq 1) {
                    $ids = @([int]$overlap[0])
                    $resolvedAmbiguousBySiblingCount++
                }
            }
        }

        if ($ids.Count -ne 1) {
            $ids = @([int]($ids | Sort-Object | Select-Object -First 1))
            $resolvedAmbiguousByLowestIdCount++
        }

        $targetId = [int]$ids[0]
    }

    $autoFixableCount++
    if ($null -ne $modeDefaultId) {
        Write-Host "[MISSING] $relativePath -> StartGameMapId $targetId (mode default)"
    }
    else {
        Write-Host "[MISSING] $relativePath -> StartGameMapId $targetId ($canonical)"
    }

    if (-not $Apply) {
        continue
    }

    $updatedRaw = Insert-StartGameMapId -Raw $raw -MapId $targetId
    if ([string]::IsNullOrWhiteSpace($updatedRaw)) {
        Write-Host "[ERROR] $relativePath : failed to locate insertion point for StartGameMapId."
        $errorCount++
        continue
    }

    try {
        $updatedObj = $updatedRaw | ConvertFrom-Json
        if ($updatedObj -isnot [pscustomobject] -or -not ($updatedObj.PSObject.Properties.Name -contains "StartGameMapId")) {
            Write-Host "[ERROR] $relativePath : verification failed after update."
            $errorCount++
            continue
        }
    }
    catch {
        Write-Host "[ERROR] $relativePath : update produced invalid JSON. $($_.Exception.Message)"
        $errorCount++
        continue
    }

    Set-Content -Path $file -Value $updatedRaw -Encoding utf8
    $updatedCount++
}

Write-Host ""
if (-not $Apply) {
    Write-Host "Dry run complete."
}
else {
    Write-Host "Apply complete."
}
Write-Host "Files scanned: $($files.Count)"
Write-Host "Files missing StartGameMapId: $missingCount"
Write-Host "Auto-fixable (current run): $autoFixableCount"
Write-Host "Files updated: $updatedCount"
Write-Host "Skipped (no inferred map/ID): $skippedNoMapCount"
Write-Host "Skipped (ambiguous map IDs): $skippedAmbiguousCount"
Write-Host "Resolved by filename fallback: $resolvedByFileNameCount"
Write-Host "Resolved by filename contains fallback: $resolvedByFileNameContainsCount"
Write-Host "Resolved ambiguous by sibling IDs: $resolvedAmbiguousBySiblingCount"
Write-Host "Resolved ambiguous by lowest ID: $resolvedAmbiguousByLowestIdCount"
Write-Host "Resolved by mode defaults: $resolvedByModeDefaultsCount"
Write-Host "Errors: $errorCount"

if ($errorCount -gt 0) {
    exit 1
}

exit 0
