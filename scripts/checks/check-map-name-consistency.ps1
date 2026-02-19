param(
    [switch]$Changed,
    [switch]$IncludeNonMaps,
    [switch]$WarnOnMapNameInFileMismatch,
    [string[]]$TopLevelScopes = @(
        "01 Core Tyria",
        "02 Heart of Thorns",
        "03 Path of Fire",
        "04 End of Dragons",
        "05 Secrets of the Obscure",
        "06 Janthir Wilds",
        "07 Visions of Eternity",
        "10 Living World"
    )
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

function Get-ClosestNames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputName,
        [Parameter(Mandatory = $true)]
        [string[]]$Candidates
    )

    $needle = $InputName.ToLowerInvariant()
    $matches = @($Candidates | Where-Object {
        $c = $_.ToLowerInvariant()
        $c.Contains($needle) -or $needle.Contains($c)
    } | Select-Object -Unique)

    if ($matches.Count -gt 0) {
        return $matches | Select-Object -First 3
    }

    $tokens = @($needle -split '\s+' | Where-Object { $_ })
    if ($tokens.Count -eq 0) {
        return @()
    }

    $scored = foreach ($candidate in $Candidates) {
        $cl = $candidate.ToLowerInvariant()
        $score = 0
        foreach ($token in $tokens) {
            if ($cl.Contains($token)) {
                $score++
            }
        }

        if ($score -gt 0) {
            [pscustomobject]@{
                Name  = $candidate
                Score = $score
            }
        }
    }

    return @($scored | Sort-Object -Property @{Expression = "Score"; Descending = $true }, @{Expression = "Name"; Descending = $false } | Select-Object -ExpandProperty Name -First 3)
}

function Normalize-MapFolderName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return (($Name -replace '^\d+\s+', '').Trim())
}

function Resolve-MapFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Parts
    )

    if ($Parts.Count -lt 3 -or $Parts[0] -ne "Maps") {
        return $null
    }

    $scope = $Parts[1]

    if ($scope -eq "10 Living World") {
        if ($Parts.Count -lt 4) {
            return $null
        }

        $wrapper = $Parts[2]
        if ($wrapper -eq "_Story Missions") {
            return $null
        }

        return Normalize-MapFolderName -Name $Parts[3]
    }

    if ($scope -eq "06 Janthir Wilds") {
        if ($Parts.Count -lt 3) {
            return $null
        }

        $candidate = Normalize-MapFolderName -Name $Parts[2]
        if ($candidate -eq "Janthir Wilds Story") {
            return $null
        }

        return $candidate
    }

    if ($scope -eq "07 Visions of Eternity") {
        if ($Parts.Count -lt 3) {
            return $null
        }

        $candidate = Normalize-MapFolderName -Name $Parts[2]
        if ($candidate -eq "Story") {
            return $null
        }

        return $candidate
    }

    if ($Parts.Count -lt 3) {
        return $null
    }

    $candidateDefault = Normalize-MapFolderName -Name $Parts[2]
    $ignored = @(
        "Over All Maps",
        "Achievements Across Cantha",
        "Collections",
        "SotO Story"
    )

    if ($ignored -contains $candidateDefault) {
        return $null
    }

    return $candidateDefault
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

$canonicalMapNames = @(
    $rawMapNames |
    ForEach-Object { [string]$_.name } |
    Where-Object { $_ } |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ } |
    Sort-Object -Unique
)

$canonicalLookup = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($name in $canonicalMapNames) {
    [void]$canonicalLookup.Add($name)
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

$scopes = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($scope in $TopLevelScopes) {
    if ($scope) {
        [void]$scopes.Add($scope.Trim())
    }
}

$checkedMapFolders = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$unknownMapFolders = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$mapNameMismatchWarnings = 0

foreach ($file in $files) {
    $relativePath = Get-RepoRelativePath -Path $file
    $parts = @($relativePath -split '[\\/]')
    if ($parts.Count -lt 3) {
        continue
    }

    if ($parts[0] -ne "Maps") {
        continue
    }

    $scope = $parts[1]
    if (-not $scopes.Contains($scope)) {
        continue
    }

    $mapFolder = Resolve-MapFolder -Parts $parts
    if (-not $mapFolder) {
        continue
    }

    [void]$checkedMapFolders.Add("$scope/$mapFolder")
    if (-not $canonicalLookup.Contains($mapFolder)) {
        [void]$unknownMapFolders.Add("$scope/$mapFolder")
    }
}

if ($WarnOnMapNameInFileMismatch) {
    $knownMapFolders = @($checkedMapFolders | ForEach-Object { ($_ -split '/', 2)[1] } | Sort-Object -Unique)
    $knownByLength = @($knownMapFolders | Sort-Object { $_.Length } -Descending)

    foreach ($file in $files) {
        $relativePath = Get-RepoRelativePath -Path $file
        $parts = @($relativePath -split '[\\/]')
        if ($parts.Count -lt 3 -or $parts[0] -ne "Maps") {
            continue
        }

        $scope = $parts[1]
        if (-not $scopes.Contains($scope)) {
            continue
        }

        $mapFolder = Resolve-MapFolder -Parts $parts
        if (-not $mapFolder) {
            continue
        }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($parts[$parts.Count - 1])
        if ($baseName -match '(?i)^Transit to ') {
            continue
        }

        $mentioned = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        $apostropheTypoHints = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)

        foreach ($candidate in $knownByLength) {
            if ($candidate -eq $mapFolder) {
                continue
            }

            $escaped = [System.Text.RegularExpressions.Regex]::Escape($candidate)
            $pattern = "(?i)(?<!\w)$escaped(?!\w)"
            if ($baseName -match $pattern) {
                [void]$mentioned.Add($candidate)
            }
        }

        # Detect common apostrophe typos such as "Lions Arch" instead of "Lion's Arch".
        foreach ($canonical in $knownByLength) {
            if ($canonical -notmatch "[']") {
                continue
            }

            $apostropheLess = ($canonical -replace "[']", "")
            if ([string]::IsNullOrWhiteSpace($apostropheLess) -or $apostropheLess -eq $canonical) {
                continue
            }

            $canonicalEscaped = [System.Text.RegularExpressions.Regex]::Escape($canonical)
            $apostropheLessEscaped = [System.Text.RegularExpressions.Regex]::Escape($apostropheLess)
            $canonicalPattern = "(?i)(?<!\w)$canonicalEscaped(?!\w)"
            $apostropheLessPattern = "(?i)(?<!\w)$apostropheLessEscaped(?!\w)"

            if ($baseName -match $apostropheLessPattern -and $baseName -notmatch $canonicalPattern) {
                [void]$apostropheTypoHints.Add("$apostropheLess -> $canonical")
            }
        }

        if ($mentioned.Count -gt 0 -or $apostropheTypoHints.Count -gt 0) {
            $mapNameMismatchWarnings++
            if ($mentioned.Count -gt 0) {
                Write-Host "[MAP-NAME][WARN] $relativePath : file name mentions another map name(s): $($mentioned -join ', ')"
            }
            if ($apostropheTypoHints.Count -gt 0) {
                Write-Host "[MAP-NAME][WARN] $relativePath : possible apostrophe typo(s): $($apostropheTypoHints -join '; ')"
            }
        }
    }
}

foreach ($entry in ($unknownMapFolders | Sort-Object)) {
    $split = $entry -split '/', 2
    $scope = $split[0]
    $mapFolder = $split[1]
    $suggestions = @(Get-ClosestNames -InputName $mapFolder -Candidates $canonicalMapNames)
    if ($suggestions.Count -gt 0) {
        Write-Host "[MAP-NAME][WARN] $scope/$mapFolder : not found in Data/map_names.json. Suggestions: $($suggestions -join ', ')"
    }
    else {
        Write-Host "[MAP-NAME][WARN] $scope/$mapFolder : not found in Data/map_names.json."
    }
}

Write-Host ""
Write-Host "Checked scope folders: $($scopes.Count)"
Write-Host "Checked map folders: $($checkedMapFolders.Count)"
Write-Host "Unknown map folders: $($unknownMapFolders.Count)"
Write-Host "File-name map mismatch warnings: $mapNameMismatchWarnings"

if ($unknownMapFolders.Count -gt 0) {
    exit 1
}

exit 0
