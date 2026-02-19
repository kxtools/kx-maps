param(
    [switch]$Changed,
    [switch]$IncludeNonMaps,
    [switch]$WarnOnMapNameInFileMismatch,
    [switch]$WarnOnNearMapTypos
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

function Remove-TrailingS {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    if ($Token.Length -gt 1 -and $Token.EndsWith("s")) {
        return $Token.Substring(0, $Token.Length - 1)
    }

    return $Token
}

function Test-NearPluralTypo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceText,
        [Parameter(Mandatory = $true)]
        [string]$CanonicalText
    )

    $source = Normalize-MapNameForMatch -Text $SourceText
    $canonical = Normalize-MapNameForMatch -Text $CanonicalText

    if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($canonical)) {
        return $false
    }

    if ($source -eq $canonical) {
        return $false
    }

    $sourceTokens = @($source -split ' ' | Where-Object { $_ })
    $canonicalTokens = @($canonical -split ' ' | Where-Object { $_ })
    if ($sourceTokens.Count -ne $canonicalTokens.Count) {
        return $false
    }

    $changes = 0
    for ($i = 0; $i -lt $sourceTokens.Count; $i++) {
        $s = $sourceTokens[$i]
        $c = $canonicalTokens[$i]
        if ($s -eq $c) {
            continue
        }

        if ((Remove-TrailingS -Token $s) -eq (Remove-TrailingS -Token $c)) {
            $changes++
            continue
        }

        return $false
    }

    return ($changes -gt 0)
}

function Get-NearPluralKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $normalized = Normalize-MapNameForMatch -Text $Text
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    $tokens = @($normalized -split ' ' | Where-Object { $_ })
    if ($tokens.Count -eq 0) {
        return $null
    }

    $trimmed = @($tokens | ForEach-Object { Remove-TrailingS -Token $_ })
    return ($trimmed -join ' ')
}

function Get-ClosestNames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputName,
        [Parameter(Mandatory = $true)]
        [string[]]$Candidates
    )

    $needle = Normalize-MapNameForMatch -Text $InputName
    if ([string]::IsNullOrWhiteSpace($needle)) {
        return @()
    }

    $matches = @($Candidates | Where-Object {
        $c = Normalize-MapNameForMatch -Text $_
        $c.Contains($needle) -or $needle.Contains($c)
    } | Select-Object -Unique)
    if ($matches.Count -gt 0) {
        return @($matches | Select-Object -First 3)
    }

    $tokens = @($needle -split '\s+' | Where-Object { $_ })
    if ($tokens.Count -eq 0) {
        return @()
    }

    $scored = foreach ($candidate in $Candidates) {
        $normalized = Normalize-MapNameForMatch -Text $candidate
        $score = 0
        foreach ($token in $tokens) {
            if ($normalized.Contains($token)) {
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

    return @(
        $scored |
        Sort-Object -Property @{Expression = "Score"; Descending = $true }, @{Expression = "Name"; Descending = $false } |
        Select-Object -ExpandProperty Name -First 3
    )
}

function Get-MapMentions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseName,
        [Parameter(Mandatory = $true)]
        [string[]]$KnownMapNames
    )

    $mentions = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($candidate in ($KnownMapNames | Sort-Object { $_.Length } -Descending)) {
        $escaped = [System.Text.RegularExpressions.Regex]::Escape($candidate)
        $pattern = "(?i)(?<!\w)$escaped(?!\w)"
        if ($BaseName -match $pattern) {
            [void]$mentions.Add($candidate)
            continue
        }

        if ($candidate -match "'") {
            $apostropheLess = ($candidate -replace "'", "")
            $apostropheLessEscaped = [System.Text.RegularExpressions.Regex]::Escape($apostropheLess)
            $apostropheLessPattern = "(?i)(?<!\w)$apostropheLessEscaped(?!\w)"
            if ($BaseName -match $apostropheLessPattern) {
                [void]$mentions.Add($candidate)
            }
        }
    }

    return @($mentions | Sort-Object)
}

function Get-ApostropheTypoHints {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseName,
        [Parameter(Mandatory = $true)]
        [string[]]$KnownMapNames
    )

    $hints = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($canonical in $KnownMapNames) {
        if ($canonical -notmatch "'") {
            continue
        }

        $variants = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        $apostropheLess = ($canonical -replace "'", "")
        if (-not [string]::IsNullOrWhiteSpace($apostropheLess) -and $apostropheLess -ne $canonical) {
            [void]$variants.Add($apostropheLess)
        }
        $possessiveLess = ($canonical -replace "(?i)'s\b", "")
        if (-not [string]::IsNullOrWhiteSpace($possessiveLess) -and $possessiveLess -ne $canonical) {
            [void]$variants.Add($possessiveLess)
        }

        $canonicalEscaped = [System.Text.RegularExpressions.Regex]::Escape($canonical)
        $canonicalPattern = "(?i)(?<!\w)$canonicalEscaped(?!\w)"

        foreach ($variant in $variants) {
            $variantEscaped = [System.Text.RegularExpressions.Regex]::Escape($variant)
            $variantPattern = "(?i)(?<!\w)$variantEscaped(?!\w)"
            if ($BaseName -match $variantPattern -and $BaseName -notmatch $canonicalPattern) {
                [void]$hints.Add("$variant -> $canonical")
            }
        }
    }

    return @($hints | Sort-Object)
}

function Test-ApostropheVariant {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceText,
        [Parameter(Mandatory = $true)]
        [string]$CanonicalText
    )

    if ($CanonicalText -notmatch "'") {
        return $false
    }

    $source = $SourceText.Trim()
    $canonical = $CanonicalText.Trim()
    if ($source -ceq $canonical) {
        return $false
    }

    if ($source -match "'") {
        return $false
    }

    $normalizedSource = Normalize-MapNameForMatch -Text $source
    $normalizedCanonical = Normalize-MapNameForMatch -Text $canonical
    if ($normalizedSource -eq $normalizedCanonical) {
        return $true
    }

    $canonicalPossessiveLess = ($canonical -replace "(?i)'s\b", "")
    $normalizedPossessiveLess = Normalize-MapNameForMatch -Text $canonicalPossessiveLess
    if (-not [string]::IsNullOrWhiteSpace($normalizedPossessiveLess) -and $normalizedSource -eq $normalizedPossessiveLess) {
        return $true
    }

    return $false
}

function Resolve-FileMapContext {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Parts,
        [Parameter(Mandatory = $true)]
        [string[]]$CanonicalMapNames,
        [Parameter(Mandatory = $true)]
        [hashtable]$CanonicalByNormalized,
        [Parameter(Mandatory = $true)]
        [hashtable]$CanonicalByNearPluralKey,
        [Parameter(Mandatory = $true)]
        [hashtable]$CanonicalByApostropheVariant
    )

    if ($Parts.Count -lt 3 -or $Parts[0] -ne "Maps") {
        return $null
    }

    $best = $null
    for ($i = 1; $i -lt ($Parts.Count - 1); $i++) {
        $segment = $Parts[$i].Trim()
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        $normalized = Normalize-MapNameForMatch -Text $segment
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }

        if ($CanonicalByNormalized.ContainsKey($normalized)) {
            $candidate = [pscustomobject]@{
                Segment      = $segment
                SegmentIndex = $i
                Canonical    = $CanonicalByNormalized[$normalized]
                MatchKind    = "exact"
                Score        = 100
            }
            if ($null -eq $best -or $candidate.Score -gt $best.Score -or ($candidate.Score -eq $best.Score -and $candidate.SegmentIndex -gt $best.SegmentIndex)) {
                $best = $candidate
            }
            continue
        }

        if ($CanonicalByApostropheVariant.ContainsKey($normalized)) {
            foreach ($canonical in $CanonicalByApostropheVariant[$normalized]) {
                if (-not (Test-ApostropheVariant -SourceText $segment -CanonicalText $canonical)) {
                    continue
                }

                $candidate = [pscustomobject]@{
                    Segment      = $segment
                    SegmentIndex = $i
                    Canonical    = $canonical
                    MatchKind    = "near"
                    Score        = 80
                }
                if ($null -eq $best -or $candidate.Score -gt $best.Score -or ($candidate.Score -eq $best.Score -and $candidate.SegmentIndex -gt $best.SegmentIndex)) {
                    $best = $candidate
                }
            }
        }

        $nearKey = Get-NearPluralKey -Text $segment
        if ([string]::IsNullOrWhiteSpace($nearKey) -or -not $CanonicalByNearPluralKey.ContainsKey($nearKey)) {
            continue
        }

        foreach ($canonical in $CanonicalByNearPluralKey[$nearKey]) {
            if (Test-NearPluralTypo -SourceText $segment -CanonicalText $canonical) {
                $candidate = [pscustomobject]@{
                    Segment      = $segment
                    SegmentIndex = $i
                    Canonical    = $canonical
                    MatchKind    = "near"
                    Score        = 70
                }
                if ($null -eq $best -or $candidate.Score -gt $best.Score -or ($candidate.Score -eq $best.Score -and $candidate.SegmentIndex -gt $best.SegmentIndex)) {
                    $best = $candidate
                }
            } 
        }
    }

    return $best
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

$canonicalByNormalized = @{}
foreach ($name in $canonicalMapNames) {
    $normalized = Normalize-MapNameForMatch -Text $name
    if (-not $canonicalByNormalized.ContainsKey($normalized)) {
        $canonicalByNormalized[$normalized] = $name
    }
}

$canonicalListByNormalized = @{}
foreach ($name in $canonicalMapNames) {
    $normalized = Normalize-MapNameForMatch -Text $name
    if (-not $canonicalListByNormalized.ContainsKey($normalized)) {
        $canonicalListByNormalized[$normalized] = New-Object System.Collections.Generic.List[string]
    }

    if (-not $canonicalListByNormalized[$normalized].Contains($name)) {
        [void]$canonicalListByNormalized[$normalized].Add($name)
    }
}

$canonicalByNearPluralKey = @{}
foreach ($name in $canonicalMapNames) {
    $key = Get-NearPluralKey -Text $name
    if ([string]::IsNullOrWhiteSpace($key)) {
        continue
    }

    if (-not $canonicalByNearPluralKey.ContainsKey($key)) {
        $canonicalByNearPluralKey[$key] = New-Object System.Collections.Generic.List[string]
    }

    if (-not $canonicalByNearPluralKey[$key].Contains($name)) {
        [void]$canonicalByNearPluralKey[$key].Add($name)
    }
}

$canonicalByApostropheVariant = @{}
foreach ($name in $canonicalMapNames) {
    if ($name -notmatch "'") {
        continue
    }

    $variants = @(
        (Normalize-MapNameForMatch -Text ($name -replace "'", "")),
        (Normalize-MapNameForMatch -Text ($name -replace "(?i)'s\b", ""))
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($variant in $variants) {
        if (-not $canonicalByApostropheVariant.ContainsKey($variant)) {
            $canonicalByApostropheVariant[$variant] = New-Object System.Collections.Generic.List[string]
        }
        if (-not $canonicalByApostropheVariant[$variant].Contains($name)) {
            [void]$canonicalByApostropheVariant[$variant].Add($name)
        }
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

$checkedScopeFolders = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$checkedMapFolders = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$unknownMapFolders = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$apostropheMapFolders = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$mapNameMismatchWarnings = 0
$nearTypoWarnings = 0
$inferenceByFile = @{}
$nearFolderSuggestions = @{}
$apostropheFolderSuggestions = @{}
$repoExactCanonicalNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)

foreach ($file in $files) {
    $relativePath = Get-RepoRelativePath -Path $file
    $parts = @($relativePath -split '[\\/]')
    if ($parts.Count -lt 2 -or $parts[0] -ne "Maps") {
        continue
    }

    if ($parts.Count -ge 2) {
        [void]$checkedScopeFolders.Add($parts[1])
    }

    $inferred = Resolve-FileMapContext -Parts $parts -CanonicalMapNames $canonicalMapNames -CanonicalByNormalized $canonicalByNormalized -CanonicalByNearPluralKey $canonicalByNearPluralKey -CanonicalByApostropheVariant $canonicalByApostropheVariant
    if ($null -eq $inferred) {
        continue
    }

    $folderKey = (($parts[1..$inferred.SegmentIndex]) -join '/')
    if ($inferred.MatchKind -eq "exact") {
        [void]$checkedMapFolders.Add($folderKey)
        [void]$repoExactCanonicalNames.Add($inferred.Canonical)

        if (Test-ApostropheVariant -SourceText $inferred.Segment -CanonicalText $inferred.Canonical) {
            [void]$apostropheMapFolders.Add($folderKey)
            $apostropheFolderSuggestions[$folderKey] = "$($inferred.Segment) -> $($inferred.Canonical)"
        }
    }
    else {
        [void]$unknownMapFolders.Add($folderKey)
        $nearFolderSuggestions[$folderKey] = $inferred.Canonical
    }

    $inferenceByFile[$relativePath] = $inferred
}

if ($WarnOnMapNameInFileMismatch) {
    $knownMapNames = @($repoExactCanonicalNames | Sort-Object)

    foreach ($file in $files) {
        $relativePath = Get-RepoRelativePath -Path $file
        if (-not $inferenceByFile.ContainsKey($relativePath)) {
            continue
        }

        $inferred = $inferenceByFile[$relativePath]
        if ($inferred.MatchKind -ne "exact") {
            continue
        }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($relativePath)
        if ($baseName -match '(?i)^Transit to ') {
            continue
        }

        $mentioned = @(Get-MapMentions -BaseName $baseName -KnownMapNames $knownMapNames | Where-Object { $_ -ne $inferred.Canonical })
        $apostropheHints = @(Get-ApostropheTypoHints -BaseName $baseName -KnownMapNames $knownMapNames)

        if ($mentioned.Count -gt 0 -or $apostropheHints.Count -gt 0) {
            $mapNameMismatchWarnings++
            if ($mentioned.Count -gt 0) {
                Write-Host "[MAP-NAME][WARN] $relativePath : file name mentions another map name(s): $($mentioned -join ', ')"
            }
            if ($apostropheHints.Count -gt 0) {
                Write-Host "[MAP-NAME][WARN] $relativePath : possible apostrophe typo(s): $($apostropheHints -join '; ')"
            }
        }
    }
}

if ($WarnOnNearMapTypos) {
    $knownMapNames = @($repoExactCanonicalNames | Sort-Object)

    foreach ($file in $files) {
        $relativePath = Get-RepoRelativePath -Path $file
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($relativePath)
        if ($baseName -match '(?i)^Transit to ') {
            continue
        }

        $baseNormalized = Normalize-MapNameForMatch -Text $baseName
        if ($canonicalListByNormalized.ContainsKey($baseNormalized)) {
            $apostropheHints = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            foreach ($candidate in $canonicalListByNormalized[$baseNormalized]) {
                if ($knownMapNames -notcontains $candidate) {
                    continue
                }

                if ($candidate -match "'" -and $baseName -notmatch "'" -and $baseName -cne $candidate) {
                    [void]$apostropheHints.Add("$baseName -> $candidate")
                }
            }

            if ($apostropheHints.Count -gt 0) {
                $nearTypoWarnings++
                Write-Host "[MAP-NAME][WARN] $relativePath : possible apostrophe typo(s): $($apostropheHints -join '; ')"
            }

            continue
        }

        $hints = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        $key = Get-NearPluralKey -Text $baseName
        if (-not [string]::IsNullOrWhiteSpace($key) -and $canonicalByNearPluralKey.ContainsKey($key)) {
            foreach ($candidate in $canonicalByNearPluralKey[$key]) {
                if ($knownMapNames -notcontains $candidate) {
                    continue
                }

                if (Test-NearPluralTypo -SourceText $baseName -CanonicalText $candidate) {
                    [void]$hints.Add("$baseName -> $candidate")
                }
            }
        }
        else {
            foreach ($candidate in $knownMapNames) {
                if (Test-NearPluralTypo -SourceText $baseName -CanonicalText $candidate) {
                    [void]$hints.Add("$baseName -> $candidate")
                }
            }
        }

        if ($hints.Count -gt 0) {
            $nearTypoWarnings++
            Write-Host "[MAP-NAME][WARN] $relativePath : possible near typo(s): $($hints -join '; ')"
        }
    }
}

foreach ($entry in ($unknownMapFolders | Sort-Object)) {
    if ($nearFolderSuggestions.ContainsKey($entry)) {
        Write-Host "[MAP-NAME][WARN] $entry : not found in Data/map_names.json. Suggestion: $($nearFolderSuggestions[$entry])"
    }
    else {
        $mapFolder = ($entry -split '/')[-1]
        $suggestions = @(Get-ClosestNames -InputName $mapFolder -Candidates $canonicalMapNames)
        if ($suggestions.Count -gt 0) {
            Write-Host "[MAP-NAME][WARN] $entry : not found in Data/map_names.json. Suggestions: $($suggestions -join ', ')"
        }
        else {
            Write-Host "[MAP-NAME][WARN] $entry : not found in Data/map_names.json."
        }
    }
}

foreach ($entry in ($apostropheMapFolders | Sort-Object)) {
    Write-Host "[MAP-NAME][WARN] $entry : possible apostrophe typo: $($apostropheFolderSuggestions[$entry])"
}

Write-Host ""
Write-Host "Checked scope folders: $($checkedScopeFolders.Count)"
Write-Host "Checked map folders: $($checkedMapFolders.Count)"
Write-Host "Unknown map folders: $($unknownMapFolders.Count)"
Write-Host "Apostrophe map folder warnings: $($apostropheMapFolders.Count)"
if ($WarnOnMapNameInFileMismatch) {
    Write-Host "File-name map mismatch warnings: $mapNameMismatchWarnings"
}
if ($WarnOnNearMapTypos) {
    Write-Host "Near map typo warnings: $nearTypoWarnings"
}

if ($unknownMapFolders.Count -gt 0 -or $apostropheMapFolders.Count -gt 0) {
    exit 1
}

exit 0
