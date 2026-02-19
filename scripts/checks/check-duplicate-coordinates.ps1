param(
    [switch]$Changed,
    [switch]$IncludeNonMaps,
    [ValidateRange(0, 8)]
    [int]$Precision = 3
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

function Normalize-CoordinateValue {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Value,
        [Parameter(Mandatory = $true)]
        [int]$Digits
    )

    $rounded = [Math]::Round($Value, $Digits, [MidpointRounding]::AwayFromZero)
    return $rounded.ToString("F$Digits", [System.Globalization.CultureInfo]::InvariantCulture)
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
$signatureGroups = @{}

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

    $normalizedPoints = New-Object System.Collections.Generic.List[string]
    $index = 0

    foreach ($coordinate in $json.Coordinates) {
        if ($coordinate -isnot [pscustomobject]) {
            Write-Host "[ERROR] $relativePath : Coordinates[$index] must be an object."
            $errorCount++
            $index++
            continue
        }

        foreach ($axis in @("X", "Y", "Z")) {
            if (-not ($coordinate.PSObject.Properties.Name -contains $axis) -or -not (Test-NumericValue -Value $coordinate.$axis)) {
                Write-Host "[ERROR] $relativePath : Coordinates[$index].$axis must be numeric."
                $errorCount++
            }
        }

        if (
            (Test-NumericValue -Value $coordinate.X) -and
            (Test-NumericValue -Value $coordinate.Y) -and
            (Test-NumericValue -Value $coordinate.Z)
        ) {
            $x = Normalize-CoordinateValue -Value ([double]$coordinate.X) -Digits $Precision
            $y = Normalize-CoordinateValue -Value ([double]$coordinate.Y) -Digits $Precision
            $z = Normalize-CoordinateValue -Value ([double]$coordinate.Z) -Digits $Precision
            $normalizedPoints.Add("$x|$y|$z")
        }

        $index++
    }

    if ($normalizedPoints.Count -eq 0) {
        continue
    }

    $signatureText = ($normalizedPoints | Sort-Object -Unique) -join ";"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($signatureText)
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $hash = ([System.BitConverter]::ToString($hashBytes)).Replace("-", "")

    if (-not $signatureGroups.ContainsKey($hash)) {
        $signatureGroups[$hash] = New-Object System.Collections.Generic.List[string]
    }

    $signatureGroups[$hash].Add($relativePath)
}

$duplicateGroups = @($signatureGroups.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
$duplicateFileCount = 0

foreach ($group in $duplicateGroups) {
    $paths = @($group.Value | Sort-Object)
    $duplicateFileCount += $paths.Count
    Write-Host "[DUPLICATE] Signature=$($group.Key) Count=$($paths.Count)"
    foreach ($path in $paths) {
        $folder = Split-Path -Path $path -Parent
        Write-Host "  - $path"
        Write-Host "    Folder: $folder"
    }
}

Write-Host ""
Write-Host "Scanned files: $($files.Count)"
Write-Host "Duplicate groups: $($duplicateGroups.Count)"
Write-Host "Files in duplicate groups: $duplicateFileCount"
Write-Host "Errors: $errorCount"

if ($duplicateGroups.Count -gt 0 -or $errorCount -gt 0) {
    exit 1
}

exit 0
