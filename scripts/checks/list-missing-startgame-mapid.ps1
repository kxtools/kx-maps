param(
    [switch]$Changed,
    [switch]$IncludeNonMaps,
    [string]$OutFile = "scripts/fixes/missing-startgame-mapid-files.txt"
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

$missing = New-Object System.Collections.Generic.List[string]
$errorCount = 0

foreach ($file in $files) {
    $relativePath = Get-RepoRelativePath -Path $file
    try {
        $json = Get-Content -Path $file -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Host "[ERROR] $relativePath : invalid JSON syntax. $($_.Exception.Message)"
        $errorCount++
        continue
    }

    if ($json -isnot [pscustomobject]) {
        continue
    }

    if (-not ($json.PSObject.Properties.Name -contains "StartGameMapId")) {
        [void]$missing.Add($relativePath)
    }
}

$outputPath = Join-Path $repoRoot $OutFile
$outputDir = Split-Path -Parent $outputPath
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$missing | Sort-Object | Set-Content -Path $outputPath -Encoding utf8

Write-Host "Scanned files: $($files.Count)"
Write-Host "Missing StartGameMapId: $($missing.Count)"
Write-Host "Report: $(Get-RepoRelativePath -Path $outputPath)"
Write-Host "Errors: $errorCount"

if ($errorCount -gt 0) {
    exit 1
}

exit 0
