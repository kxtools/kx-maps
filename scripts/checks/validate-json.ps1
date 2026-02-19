param(
    [switch]$Changed
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

function Test-NumericValue {
    param(
        [Parameter(Mandatory = $false)]
        $Value
    )

    if ($null -eq $Value) {
        return $false
    }

    if (
        $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [int32] -or
        $Value -is [int64] -or
        $Value -is [uint16] -or
        $Value -is [uint32] -or
        $Value -is [uint64] -or
        $Value -is [single] -or
        $Value -is [double] -or
        $Value -is [decimal]
    ) {
        return $true
    }

    $parsed = 0.0
    return [double]::TryParse(
        [string]$Value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
    )
}

function Get-JsonFiles {
    param(
        [switch]$OnlyChanged
    )

    Push-Location $repoRoot
    try {
        if (-not $OnlyChanged) {
            return Get-ChildItem -Path . -Recurse -File |
                Where-Object { $_.Extension -match '^\.(?i:json)$' } |
                Select-Object -ExpandProperty FullName
        }

        $changed = @()

        $diffOutput = git diff --name-only --diff-filter=ACMR HEAD -- '*.json' 2>$null
        if ($LASTEXITCODE -eq 0 -and $diffOutput) {
            $changed += $diffOutput
        }

        $untrackedOutput = git ls-files --others --exclude-standard -- '*.json' 2>$null
        if ($LASTEXITCODE -eq 0 -and $untrackedOutput) {
            $changed += $untrackedOutput
        }

        return $changed |
            Where-Object { $_ -and (Test-Path $_) } |
            Sort-Object -Unique |
            ForEach-Object { (Resolve-Path $_).Path }
    }
    finally {
        Pop-Location
    }
}

$files = Get-JsonFiles -OnlyChanged:$Changed

if (-not $files -or $files.Count -eq 0) {
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
    $isRouteJson = $relativePath -like "Maps\*" -or $relativePath -like "Maps/*"
    $raw = ""
    $json = $null

    try {
        $raw = Get-Content -Path $file -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json
    }
    catch {
        Write-Error "$relativePath : invalid JSON syntax. $($_.Exception.Message)"
        $errorCount++
        continue
    }

    if (-not $isRouteJson) {
        continue
    }

    if ($json -isnot [pscustomobject]) {
        Write-Error "$relativePath : root must be a JSON object."
        $errorCount++
        continue
    }

    if (-not ($json.PSObject.Properties.Name -contains "Name") -or $json.Name -isnot [string]) {
        Write-Error "$relativePath : missing or invalid 'Name' (must be a string)."
        $errorCount++
    }

    if (-not ($json.PSObject.Properties.Name -contains "Coordinates") -or $null -eq $json.Coordinates) {
        Write-Error "$relativePath : missing 'Coordinates' (must be an array)."
        $errorCount++
        continue
    }

    if ($json.Coordinates -is [string] -or $json.Coordinates -isnot [System.Collections.IEnumerable]) {
        Write-Error "$relativePath : 'Coordinates' must be an array."
        $errorCount++
        continue
    }

    $index = 0
    foreach ($coordinate in $json.Coordinates) {
        if ($coordinate -isnot [pscustomobject]) {
            Write-Error "$relativePath : Coordinates[$index] must be an object."
            $errorCount++
            $index++
            continue
        }

        foreach ($axis in @("X", "Y", "Z")) {
            if (-not ($coordinate.PSObject.Properties.Name -contains $axis) -or -not (Test-NumericValue -Value $coordinate.$axis)) {
                Write-Error "$relativePath : Coordinates[$index].$axis must be numeric."
                $errorCount++
            }
        }

        $index++
    }
}

if ($errorCount -gt 0) {
    Write-Host "Validation failed with $errorCount error(s)."
    exit 1
}

Write-Host "Validation passed for $($files.Count) JSON file(s)."
exit 0
