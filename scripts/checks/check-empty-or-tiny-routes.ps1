param(
    [switch]$Changed,
    [switch]$IncludeNonMaps,
    [ValidateRange(1, 50)]
    [int]$TinyThreshold = 2,
    [switch]$FailOnTiny
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

$errorCount = 0
$emptyCount = 0
$tinyCount = 0

foreach ($file in $files) {
    $relativePath = Get-RepoRelativePath -Path $file
    $json = $null

    try {
        $json = Get-Content -Path $file -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Host "[ERROR] $relativePath : invalid JSON syntax. $($_.Exception.Message)"
        $errorCount++
        continue
    }

    if ($json -isnot [pscustomobject]) {
        Write-Host "[ERROR] $relativePath : root must be a JSON object."
        $errorCount++
        continue
    }

    if (-not ($json.PSObject.Properties.Name -contains "Coordinates") -or $null -eq $json.Coordinates) {
        Write-Host "[ERROR] $relativePath : missing 'Coordinates' (must be an array)."
        $errorCount++
        continue
    }

    if ($json.Coordinates -is [string] -or $json.Coordinates -isnot [System.Collections.IEnumerable]) {
        Write-Host "[ERROR] $relativePath : 'Coordinates' must be an array."
        $errorCount++
        continue
    }

    $coordinates = @($json.Coordinates)
    $count = $coordinates.Count

    if ($count -eq 0) {
        Write-Host "[EMPTY] $relativePath : Coordinates count is 0."
        $emptyCount++
        continue
    }

    if ($count -le $TinyThreshold) {
        Write-Host "[TINY] $relativePath : Coordinates count is $count (threshold=$TinyThreshold)."
        $tinyCount++
    }
}

Write-Host ""
Write-Host "Scanned files: $($files.Count)"
Write-Host "Empty routes: $emptyCount"
Write-Host "Tiny routes: $tinyCount (threshold=$TinyThreshold)"
Write-Host "Errors: $errorCount"

if ($errorCount -gt 0 -or $emptyCount -gt 0) {
    exit 1
}

if ($FailOnTiny -and $tinyCount -gt 0) {
    exit 1
}

exit 0
