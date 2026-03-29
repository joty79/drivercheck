[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BasePath,

    [Parameter(Mandatory = $true)]
    [string]$ComparePath,

    [string]$OutputRoot = (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'compare-output') 'structured-text'),

    [ValidateSet('DriverCheck', 'Generic')]
    [string]$Profile = 'DriverCheck'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-InputFilePath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Empty file path is not allowed."
    }

    if (Test-Path -LiteralPath $Path) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $candidate = Join-Path (Split-Path $PSScriptRoot -Parent) $Path
    if (Test-Path -LiteralPath $candidate) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    throw "File not found: $Path"
}

function Convert-ToSafeName {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'unnamed'
    }

    $sanitized = $Value.Trim()
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars() + [char[]]':\/'
    foreach ($invalidChar in $invalidChars) {
        $sanitized = $sanitized.Replace([string]$invalidChar, '_')
    }

    $sanitized = ($sanitized -replace '\s+', ' ').Trim()
    if ($sanitized.Length -gt 90) {
        $sanitized = $sanitized.Substring(0, 90).TrimEnd()
    }

    return $sanitized
}

function Get-ProfileSettings {
    param(
        [string]$Name
    )

    switch ($Name) {
        'DriverCheck' {
            return [pscustomobject]@{
                IgnoreSections     = @('Driver Snapshot Compare', 'Compare Reports')
                IgnoreLinePatterns = @(
                    '^\s*Before\s*:',
                    '^\s*After\s*:',
                    '^\s*Before mode\s*:',
                    '^\s*After mode\s*:',
                    '^\s*Folder\s*:',
                    '^\s*Full report\s*:',
                    '^\s*Differences only\s*:',
                    '^\s*Similarities only\s*:'
                )
            }
        }
        default {
            return [pscustomobject]@{
                IgnoreSections     = @()
                IgnoreLinePatterns = @()
            }
        }
    }
}

function Test-IsSectionUnderline {
    param(
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }

    return $Line.Trim() -match '^[=\-~_]{3,}$'
}

function New-SectionObject {
    param(
        [string]$Name,
        [string]$Underline
    )

    return [pscustomobject]@{
        Name      = $Name
        Underline = $Underline
        Lines     = [System.Collections.Generic.List[string]]::new()
    }
}

function Parse-StructuredReport {
    param(
        [string]$Path,
        [string[]]$IgnoreSections
    )

    $lines = [string[]](Get-Content -LiteralPath $Path)
    $sections = [System.Collections.Generic.List[object]]::new()
    $currentSection = $null
    $index = 0

    while ($index -lt $lines.Count) {
        $line = [string]$lines[$index]
        $nextLine = if (($index + 1) -lt $lines.Count) { [string]$lines[$index + 1] } else { '' }

        if (-not [string]::IsNullOrWhiteSpace($line) -and
            -not ($line -match '^\s') -and
            (Test-IsSectionUnderline -Line $nextLine)) {

            if ($null -ne $currentSection) {
                [void]$sections.Add($currentSection)
            }

            $sectionName = $line.Trim()
            $currentSection = New-SectionObject -Name $sectionName -Underline $nextLine.Trim()
            $index += 2
            continue
        }

        if ($null -eq $currentSection) {
            $currentSection = New-SectionObject -Name 'Preamble' -Underline ''
        }

        [void]$currentSection.Lines.Add($line)
        $index++
    }

    if ($null -ne $currentSection) {
        [void]$sections.Add($currentSection)
    }

    if ($IgnoreSections.Count -eq 0) {
        return @($sections.ToArray())
    }

    return @(
        $sections.ToArray() |
            Where-Object { $IgnoreSections -notcontains $_.Name }
    )
}

function Test-MatchesAnyPattern {
    param(
        [AllowEmptyString()]
        [string]$Value,
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        if ($Value -match $pattern) {
            return $true
        }
    }

    return $false
}

function Convert-SectionToBlocks {
    param(
        [object]$Section,
        [string[]]$IgnoreLinePatterns
    )

    $blocks = [System.Collections.Generic.List[object]]::new()
    $currentBlockLines = [System.Collections.Generic.List[string]]::new()

    foreach ($rawLine in @($Section.Lines)) {
        $line = [string]$rawLine
        $trimmedEndLine = $line.TrimEnd()

        if ([string]::IsNullOrWhiteSpace($trimmedEndLine)) {
            continue
        }

        $startsNewBlock = -not ($trimmedEndLine -match '^\s')
        if ($startsNewBlock -and $currentBlockLines.Count -gt 0) {
            $blockText = ($currentBlockLines.ToArray() -join [Environment]::NewLine).TrimEnd()
            if (-not [string]::IsNullOrWhiteSpace($blockText)) {
                [void]$blocks.Add([pscustomobject]@{
                    Header = [string]$currentBlockLines[0]
                    Text   = $blockText
                })
            }

            $currentBlockLines = [System.Collections.Generic.List[string]]::new()
        }

        [void]$currentBlockLines.Add($trimmedEndLine)
    }

    if ($currentBlockLines.Count -gt 0) {
        $blockText = ($currentBlockLines.ToArray() -join [Environment]::NewLine).TrimEnd()
        if (-not [string]::IsNullOrWhiteSpace($blockText)) {
            [void]$blocks.Add([pscustomobject]@{
                Header = [string]$currentBlockLines[0]
                Text   = $blockText
            })
        }
    }

    if ($IgnoreLinePatterns.Count -eq 0) {
        return @($blocks.ToArray())
    }

    return @(
        $blocks.ToArray() |
            Where-Object { -not (Test-MatchesAnyPattern -Value $_.Header -Patterns $IgnoreLinePatterns) }
    )
}

function New-SectionMap {
    param(
        [object[]]$Sections,
        [string[]]$IgnoreLinePatterns
    )

    $map = @{}
    foreach ($section in $Sections) {
        $blocks = @(Convert-SectionToBlocks -Section $section -IgnoreLinePatterns $IgnoreLinePatterns)
        $map[$section.Name] = [pscustomobject]@{
            Name      = $section.Name
            Underline = $section.Underline
            Blocks    = $blocks
        }
    }

    return $map
}

function Get-OrderedSectionNames {
    param(
        [object[]]$BaseSections,
        [object[]]$CompareSections
    )

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($section in @($BaseSections) + @($CompareSections)) {
        if ($null -eq $section) {
            continue
        }

        if (-not $names.Contains($section.Name)) {
            [void]$names.Add($section.Name)
        }
    }

    return @($names.ToArray())
}

function Get-BlockTexts {
    param(
        [object]$SectionInfo
    )

    if ($null -eq $SectionInfo) {
        return @()
    }

    return @($SectionInfo.Blocks | ForEach-Object { $_.Text })
}

function Write-StructuredCompareReport {
    param(
        [string]$Path,
        [string]$Title,
        [string]$Description,
        [string]$BaseFilePath,
        [string]$CompareFilePath,
        [string[]]$OrderedSectionNames,
        [hashtable]$BaseMap,
        [hashtable]$CompareMap,
        [ValidateSet('MissingVsBase', 'ExtraVsBase')]
        [string]$Mode
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add($Title)
    [void]$lines.Add((''.PadLeft($Title.Length, '-')))
    [void]$lines.Add("Base    : $BaseFilePath")
    [void]$lines.Add("Compare : $CompareFilePath")
    [void]$lines.Add("Meaning : $Description")
    [void]$lines.Add('')

    $sectionCount = 0
    foreach ($sectionName in $OrderedSectionNames) {
        $baseSection = if ($BaseMap.ContainsKey($sectionName)) { $BaseMap[$sectionName] } else { $null }
        $compareSection = if ($CompareMap.ContainsKey($sectionName)) { $CompareMap[$sectionName] } else { $null }

        $baseBlocks = @(Get-BlockTexts -SectionInfo $baseSection)
        $compareBlocks = @(Get-BlockTexts -SectionInfo $compareSection)

        $selectedBlocks = @(
            switch ($Mode) {
                'MissingVsBase' { $baseBlocks | Where-Object { $compareBlocks -notcontains $_ } }
                'ExtraVsBase'   { $compareBlocks | Where-Object { $baseBlocks -notcontains $_ } }
            }
        )

        if ($selectedBlocks.Count -eq 0) {
            continue
        }

        $underline = if ($null -ne $baseSection -and -not [string]::IsNullOrWhiteSpace($baseSection.Underline)) {
            $baseSection.Underline
        }
        elseif ($null -ne $compareSection -and -not [string]::IsNullOrWhiteSpace($compareSection.Underline)) {
            $compareSection.Underline
        }
        else {
            ''.PadLeft($sectionName.Length, '-')
        }

        if ($sectionCount -gt 0) {
            [void]$lines.Add('')
        }

        [void]$lines.Add($sectionName)
        [void]$lines.Add($underline)
        foreach ($block in $selectedBlocks) {
            foreach ($blockLine in ($block -split "`r?`n")) {
                [void]$lines.Add($blockLine)
            }
        }

        $sectionCount++
    }

    if ($sectionCount -eq 0) {
        [void]$lines.Add('No section differences matched this report.')
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

$baseFilePath = Resolve-InputFilePath -Path $BasePath
$compareFilePath = Resolve-InputFilePath -Path $ComparePath
$profileSettings = Get-ProfileSettings -Name $Profile

$baseSections = @(Parse-StructuredReport -Path $baseFilePath -IgnoreSections $profileSettings.IgnoreSections)
$compareSections = @(Parse-StructuredReport -Path $compareFilePath -IgnoreSections $profileSettings.IgnoreSections)
$baseMap = New-SectionMap -Sections $baseSections -IgnoreLinePatterns $profileSettings.IgnoreLinePatterns
$compareMap = New-SectionMap -Sections $compareSections -IgnoreLinePatterns $profileSettings.IgnoreLinePatterns
$orderedSectionNames = Get-OrderedSectionNames -BaseSections $baseSections -CompareSections $compareSections

$baseLeaf = [System.IO.Path]::GetFileNameWithoutExtension($baseFilePath)
$compareLeaf = [System.IO.Path]::GetFileNameWithoutExtension($compareFilePath)

$baseDisplayName = if ($baseLeaf -ieq $compareLeaf) {
    Convert-ToSafeName -Value ("base__{0}" -f $baseLeaf)
}
else {
    Convert-ToSafeName -Value $baseLeaf
}

$compareDisplayName = if ($baseLeaf -ieq $compareLeaf) {
    Convert-ToSafeName -Value ("compare__{0}" -f $compareLeaf)
}
else {
    Convert-ToSafeName -Value $compareLeaf
}

$timestamp = Get-Date -Format 'MM-dd-yyyy - HH.mm.ss'
$outputFolderName = "{0}__vs__{1} {2}" -f $baseDisplayName, $compareDisplayName, $timestamp
$outputPath = Join-Path $OutputRoot $outputFolderName
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

$missingReportPath = Join-Path $outputPath 'missing-vs-base.txt'
$extraReportPath = Join-Path $outputPath 'extra-vs-base.txt'

Write-StructuredCompareReport `
    -Path $missingReportPath `
    -Title 'Missing Vs Base' `
    -Description 'Blocks present in BASE but missing from COMPARE.' `
    -BaseFilePath $baseFilePath `
    -CompareFilePath $compareFilePath `
    -OrderedSectionNames $orderedSectionNames `
    -BaseMap $baseMap `
    -CompareMap $compareMap `
    -Mode 'MissingVsBase'

Write-StructuredCompareReport `
    -Path $extraReportPath `
    -Title 'Extra Vs Base' `
    -Description 'Blocks present in COMPARE but extra versus BASE.' `
    -BaseFilePath $baseFilePath `
    -CompareFilePath $compareFilePath `
    -OrderedSectionNames $orderedSectionNames `
    -BaseMap $baseMap `
    -CompareMap $compareMap `
    -Mode 'ExtraVsBase'

Write-Host ''
Write-Host 'Structured Text Compare' -ForegroundColor Cyan
Write-Host '-----------------------' -ForegroundColor Cyan
Write-Host "Base file         : $baseFilePath"
Write-Host "Compare file      : $compareFilePath"
Write-Host "Profile           : $Profile"
Write-Host "Output folder     : $outputPath"
Write-Host "Missing vs base   : $missingReportPath"
Write-Host "Extra vs base     : $extraReportPath"

[pscustomobject]@{
    BasePath          = $baseFilePath
    ComparePath       = $compareFilePath
    Profile           = $Profile
    OutputFolder      = $outputPath
    MissingReportPath = $missingReportPath
    ExtraReportPath   = $extraReportPath
}
