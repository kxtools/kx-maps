param(
    [switch]$Changed,
    [switch]$IgnoreCase,
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

$errorCount = 0

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

    if (-not ($json.PSObject.Properties.Name -contains "Name") -or $json.Name -isnot [string]) {
        Write-Host "[ERROR] $relativePath : missing or invalid 'Name' (must be a string)."
        $errorCount++
        continue
    }

    $expected = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $actual = $json.Name

    $isMatch = $false
    if ($IgnoreCase) {
        $isMatch = [string]::Equals($actual, $expected, [System.StringComparison]::OrdinalIgnoreCase)
    }
    else {
        $isMatch = [string]::Equals($actual, $expected, [System.StringComparison]::Ordinal)
    }

    if (-not $isMatch) {
        Write-Host "[MISMATCH] $relativePath"
        Write-Host "  File name : $expected"
        Write-Host "  JSON Name : $actual"
        $errorCount++
    }
}

if ($errorCount -gt 0) {
    Write-Host "Name alignment check failed with $errorCount issue(s)."
    exit 1
}

Write-Host "Name alignment check passed for $($files.Count) JSON file(s)."
exit 0
