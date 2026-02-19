param(
    [switch]$Changed,
    [switch]$Apply,
    [switch]$IncludeNonMaps
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..")).Path

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

$mismatchCount = 0
$updatedCount = 0
$errorCount = 0

foreach ($file in $files) {
    $relativePath = Get-RepoRelativePath -Path $file
    $expected = [System.IO.Path]::GetFileNameWithoutExtension($file)

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
        Write-Host "[ERROR] $relativePath : root must be a JSON object."
        $errorCount++
        continue
    }

    if (-not ($json.PSObject.Properties.Name -contains "Name") -or $json.Name -isnot [string]) {
        Write-Host "[ERROR] $relativePath : missing or invalid 'Name' (must be a string)."
        $errorCount++
        continue
    }

    $actual = $json.Name
    if ([string]::Equals($actual, $expected, [System.StringComparison]::Ordinal)) {
        continue
    }

    $mismatchCount++
    Write-Host "[MISMATCH] $relativePath"
    Write-Host "  File name : $expected"
    Write-Host "  JSON Name : $actual"

    if (-not $Apply) {
        continue
    }

    $escapedExpected = ($expected | ConvertTo-Json -Compress)
    $namePattern = '("Name"\s*:\s*)"((?:\\.|[^"\\])*)"'
    $regex = [System.Text.RegularExpressions.Regex]::new($namePattern)
    $updatedRaw = $regex.Replace($raw, ('$1' + $escapedExpected), 1)

    if ([string]::Equals($updatedRaw, $raw, [System.StringComparison]::Ordinal)) {
        Write-Host "[ERROR] $relativePath : unable to update Name field in raw text."
        $errorCount++
        continue
    }

    Set-Content -Path $file -Value $updatedRaw -Encoding utf8
    $updatedCount++
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "Dry run complete. Mismatches found: $mismatchCount. Use -Apply to update files."
    if ($errorCount -gt 0) {
        Write-Host "Errors: $errorCount"
        exit 1
    }
    exit 0
}

Write-Host ""
Write-Host "Apply complete. Mismatches found: $mismatchCount. Files updated: $updatedCount. Errors: $errorCount."
if ($errorCount -gt 0) {
    exit 1
}
exit 0
