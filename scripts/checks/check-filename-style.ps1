param(
    [switch]$Changed,
    [switch]$IncludeNonMaps,
    [switch]$WarnOnSquashed,
    [switch]$WarnOnUnderscore,
    [string]$DisallowedPunctuation = "´"
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

function Add-Count {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Map,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not $Map.ContainsKey($Key)) {
        $Map[$Key] = 0
    }

    $Map[$Key] = [int]$Map[$Key] + 1
}

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

$strictErrors = 0
$warningCount = 0
$ruleCounts = @{}

foreach ($file in $files) {
    $relativePath = Get-RepoRelativePath -Path $file
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file)

    if ($relativePath -match '[^\x00-\x7F]') {
        Write-Host "[STYLE][ERROR] $relativePath : non-ASCII character in path."
        Add-Count -Map $ruleCounts -Key "non_ascii_path"
        $strictErrors++
    }

    if ($baseName -ne $baseName.Trim()) {
        Write-Host "[STYLE][ERROR] $relativePath : leading or trailing spaces in file name."
        Add-Count -Map $ruleCounts -Key "leading_or_trailing_spaces"
        $strictErrors++
    }

    if ($baseName -match '  +') {
        Write-Host "[STYLE][ERROR] $relativePath : double spaces in file name."
        Add-Count -Map $ruleCounts -Key "double_spaces"
        $strictErrors++
    }

    if ($DisallowedPunctuation.Length -gt 0) {
        foreach ($char in $DisallowedPunctuation.ToCharArray()) {
            if ($relativePath.Contains([string]$char)) {
                Write-Host "[STYLE][ERROR] $relativePath : disallowed punctuation '$char'."
                Add-Count -Map $ruleCounts -Key "disallowed_punctuation"
                $strictErrors++
                break
            }
        }
    }

    if ($WarnOnUnderscore -and $baseName.Contains("_")) {
        Write-Host "[STYLE][WARN] $relativePath : underscore in file name."
        Add-Count -Map $ruleCounts -Key "underscore_warning"
        $warningCount++
    }

    if ($WarnOnSquashed -and $baseName -notmatch '[ _-]' -and $baseName -match '[a-z][A-Z]') {
        Write-Host "[STYLE][WARN] $relativePath : possible squashed camel-like token."
        Add-Count -Map $ruleCounts -Key "squashed_warning"
        $warningCount++
    }
}

Write-Host ""
Write-Host "Scanned files: $($files.Count)"
Write-Host "Strict style errors: $strictErrors"
Write-Host "Warnings: $warningCount"

if ($ruleCounts.Count -gt 0) {
    Write-Host "Rule summary:"
    foreach ($entry in ($ruleCounts.GetEnumerator() | Sort-Object Name)) {
        Write-Host "  - $($entry.Name): $($entry.Value)"
    }
}

if ($strictErrors -gt 0) {
    exit 1
}

exit 0
