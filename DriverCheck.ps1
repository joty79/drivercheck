[CmdletBinding()]
param(
    [string]$SnapshotsRoot = (Join-Path $PSScriptRoot 'snapshots'),
    [string]$CompareOutputRoot = (Join-Path $PSScriptRoot 'compare-output')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:InternalToolsRoot = Join-Path $PSScriptRoot 'internal'
$script:LiveReportsRoot = Join-Path $PSScriptRoot 'live'

function Test-CurrentSessionElevated {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SelfElevationArgumentList {
    $argumentList = @('-NoLogo', '-NoProfile', '-File', $PSCommandPath)

    if (-not [string]::IsNullOrWhiteSpace($SnapshotsRoot)) {
        $argumentList += @('-SnapshotsRoot', $SnapshotsRoot)
    }

    if (-not [string]::IsNullOrWhiteSpace($CompareOutputRoot)) {
        $argumentList += @('-CompareOutputRoot', $CompareOutputRoot)
    }

    return $argumentList
}

function Start-SelfElevatedInstance {
    $pwshPath = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
        $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    }

    $argumentList = Get-SelfElevationArgumentList
    $process = Start-Process -FilePath $pwshPath -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
    if ($null -ne $process) {
        exit $process.ExitCode
    }

    exit 0
}

function Read-HostTrimmed {
    param(
        [string]$Prompt
    )

    try {
        if (-not [Console]::IsInputRedirected) {
            $displayPrompt = if ([string]::IsNullOrWhiteSpace($Prompt)) { '' } else { "${Prompt}: " }
            Write-Host -NoNewline $displayPrompt

            $buffer = [System.Text.StringBuilder]::new()
            while ($true) {
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    'Enter' {
                        Write-Host ''
                        return $buffer.ToString().Trim()
                    }
                    'Escape' {
                        Write-Host ''
                        return ([string][char]27)
                    }
                    'Backspace' {
                        if ($buffer.Length -gt 0) {
                            [void]$buffer.Remove($buffer.Length - 1, 1)
                            Write-Host -NoNewline "`b `b"
                        }
                    }
                    default {
                        if (-not [char]::IsControl($key.KeyChar)) {
                            [void]$buffer.Append($key.KeyChar)
                            Write-Host -NoNewline $key.KeyChar
                        }
                    }
                }
            }
        }

        $value = Read-Host $Prompt
    }
    catch {
        return ''
    }

    if ($null -eq $value) {
        return ''
    }

    return ([string]$value).Trim()
}

function Test-IsEscapeInput {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return $false
    }

    $raw = [string]$Value
    if ($raw.Length -eq 1 -and [int][char]$raw[0] -eq 27) {
        return $true
    }

    return $raw.Trim() -match '^(?i:esc|escape)$'
}

function Clear-HostSafe {
    try {
        Clear-Host
    }
    catch {
        # Redirected/non-interactive hosts can fail here.
    }
}

function Get-ConsoleSafeText {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    $value = $Text ?? ''
    try {
        $windowWidth = [Console]::WindowWidth
    }
    catch {
        return $value
    }

    if ($windowWidth -le 0) {
        return $value
    }

    $maxLength = [Math]::Max(8, $windowWidth - 2)
    if ($value.Length -le $maxLength) {
        return $value
    }

    if ($maxLength -le 3) {
        return $value.Substring(0, $maxLength)
    }

    return ($value.Substring(0, $maxLength - 3) + '...')
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

function Get-InternalToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName
    )

    return (Join-Path $script:InternalToolsRoot $ScriptName)
}

function Pause-Launcher {
    Write-Host ''
    $null = Read-HostTrimmed -Prompt 'Πατήστε ENTER για επιστροφή στο menu ή γράψε ESC για ακύρωση'
}

function Get-LauncherMenuItems {
    return @(
        [pscustomobject]@{ Key = '1'; Label = 'Save Snapshot'; Color = 'Yellow' },
        [pscustomobject]@{ Key = '2'; Label = 'Compare Snapshots'; Color = 'Cyan' },
        [pscustomobject]@{ Key = '3'; Label = 'Compare Structured Reports'; Color = 'DarkCyan' },
        [pscustomobject]@{ Key = '4'; Label = 'Audit Cleanup From Snapshots'; Color = 'DarkYellow' },
        [pscustomobject]@{ Key = '5'; Label = 'Run Cleanup From Snapshots'; Color = 'Red' },
        [pscustomobject]@{ Key = '6'; Label = 'Live Driver Check'; Color = 'Green' },
        [pscustomobject]@{ Key = '7'; Label = 'Live Driver Clean Reports'; Color = 'Green' },
        [pscustomobject]@{ Key = '8'; Label = 'Delete Snapshot'; Color = 'Magenta' },
        [pscustomobject]@{ Key = '0'; Label = 'Exit'; Color = 'Gray' }
    )
}

function Read-LauncherMenuChoice {
    param(
        [object[]]$MenuItems,
        [object[]]$Snapshots
    )

    if ([Console]::IsInputRedirected) {
        Write-Host ''
        foreach ($item in $MenuItems) {
            $line = "[{0}] {1}" -f $item.Key, $item.Label
            Write-Host $line -ForegroundColor $item.Color
        }
        Write-Host '[ESC] Exit current menu' -ForegroundColor DarkGray
        Write-Host ''

        $choice = Read-HostTrimmed -Prompt 'Choose an option'
        if (Test-IsEscapeInput -Value $choice) {
            return '0'
        }

        return $choice
    }

    $selectedIndex = 0
    $eraseLine = '{0}[K' -f [char]27

    function Write-LauncherMenuFrame {
        [Console]::SetCursorPosition(0, $menuTop)

        for ($i = 0; $i -lt $MenuItems.Count; $i++) {
            $item = $MenuItems[$i]
            $isSelected = $i -eq $selectedIndex
            $prefix = if ($isSelected) { '❯' } else { ' ' }
            $line = "{0} [{1}] {2}" -f $prefix, $item.Key, $item.Label
            $color = if ($isSelected) { 'White' } else { $item.Color }
            Write-Host "$line$eraseLine" -ForegroundColor $color
        }
    }

    [Console]::CursorVisible = $false
    try {
        Clear-HostSafe
        Show-LauncherHeader -Snapshots $Snapshots
        Write-Host ''
        Write-Host 'Use Up/Down, Enter, number shortcuts, or ESC.' -ForegroundColor DarkGray
        Write-Host ''
        $menuTop = [Console]::CursorTop

        while ($true) {
            Write-LauncherMenuFrame

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' {
                    if ($selectedIndex -gt 0) {
                        $selectedIndex--
                    }
                }
                'DownArrow' {
                    if ($selectedIndex -lt ($MenuItems.Count - 1)) {
                        $selectedIndex++
                    }
                }
                'Enter' {
                    return $MenuItems[$selectedIndex].Key
                }
                'Escape' {
                    return '0'
                }
                default {
                    $typedKey = [string]$key.KeyChar
                    if (-not [string]::IsNullOrWhiteSpace($typedKey)) {
                        $matchedIndex = -1
                        for ($i = 0; $i -lt $MenuItems.Count; $i++) {
                            if ($MenuItems[$i].Key -eq $typedKey) {
                                $matchedIndex = $i
                                break
                            }
                        }

                        if ($matchedIndex -ge 0) {
                            $selectedIndex = $matchedIndex
                            Write-LauncherMenuFrame
                            Start-Sleep -Milliseconds 90
                            return $MenuItems[$selectedIndex].Key
                        }
                    }
                }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

function Get-UiIcons {
    if ($env:WT_SESSION) {
        return @{
            Title = '🛠️'
            Case = '🧪'
            Snapshot = '📸'
            Compare = '🔍'
            Audit = '🧭'
            Cleanup = '🧹'
            Live = '⚙️'
            Report = '🧾'
            Exit = '🚪'
            Tip = '💡'
            Warn = '⚠️'
        }
    }

    return @{
        Title = '[DC]'
        Case = '[C]'
        Snapshot = '[S]'
        Compare = '[?]'
        Audit = '[A]'
        Cleanup = '[X]'
        Live = '[L]'
        Report = '[R]'
        Exit = '[E]'
        Tip = '[i]'
        Warn = '[!]'
    }
}

function Get-OptionalObjectProperty {
    param(
        [object]$InputObject,
        [string]$PropertyName,
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Get-SnapshotFolders {
    param(
        [string]$RootPath,
        [string]$PreferredCaseName,
        [switch]$Chronological
    )

    if (-not (Test-Path -LiteralPath $RootPath)) {
        return @()
    }

    $items = foreach ($dir in Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue) {
        $metadataPath = Join-Path $dir.FullName 'metadata.json'
        $metadata = $null
        if (Test-Path -LiteralPath $metadataPath) {
            try {
                $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
            }
            catch {
                $metadata = $null
            }
        }

        $snapshotCase = [string](Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'CaseName' -DefaultValue '')
        $snapshotStage = [string](Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'Stage' -DefaultValue '')
        $snapshotName = [string](Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'SnapshotName' -DefaultValue $dir.Name)
        $timestampValue = Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'Timestamp' -DefaultValue $null
        $timestamp = if ($null -ne $timestampValue -and -not [string]::IsNullOrWhiteSpace([string]$timestampValue)) { [datetime]$timestampValue } else { $dir.LastWriteTime }
        $focusTermValue = Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'FocusTerm' -DefaultValue @()
        $focusTerms = if ($null -ne $focusTermValue) { @($focusTermValue) -join ', ' } else { '' }
        $casePriority = if (-not [string]::IsNullOrWhiteSpace($PreferredCaseName) -and $snapshotCase -eq $PreferredCaseName) { 0 } else { 1 }
        $stageOrder = Get-StageSortOrder -Stage $snapshotStage

        [pscustomobject]@{
            Name = $dir.Name
            FullName = $dir.FullName
            SnapshotName = $snapshotName
            CaseName = $snapshotCase
            Stage = $snapshotStage
            Timestamp = $timestamp
            FocusTerms = $focusTerms
            CasePriority = $casePriority
            StageOrder = $stageOrder
        }
    }

    if ($Chronological) {
        return @(
            $items |
            Sort-Object @{ Expression = 'CasePriority'; Ascending = $true }, @{ Expression = 'Timestamp'; Ascending = $true }, @{ Expression = 'StageOrder'; Ascending = $true }, Name
        )
    }

    return @(
        $items |
        Sort-Object @{ Expression = 'CasePriority'; Ascending = $true }, @{ Expression = 'Timestamp'; Descending = $true }, @{ Expression = 'StageOrder'; Ascending = $true }, Name
    )
}

function Get-StageSortOrder {
    param(
        [string]$Stage
    )

    switch -Regex (($Stage ?? '').Trim()) {
        '^BeforeInstall$' { return 10 }
        '^AfterInstall$' { return 20 }
        '^AfterRemove$' { return 30 }
        '^AfterCleanup$' { return 40 }
        '^AfterCertCleanup$' { return 50 }
        default { return 100 }
    }
}

function Get-SnapshotDisplayLabel {
    param(
        [object]$Snapshot
    )

    $caseText = [string]$Snapshot.CaseName
    $stageText = [string]$Snapshot.Stage
    $snapshotName = [string]$Snapshot.SnapshotName

    if (-not [string]::IsNullOrWhiteSpace($caseText) -and -not [string]::IsNullOrWhiteSpace($stageText)) {
        return "$caseText / $stageText"
    }

    if (-not [string]::IsNullOrWhiteSpace($stageText)) {
        return $stageText
    }

    if (-not [string]::IsNullOrWhiteSpace($caseText) -and -not [string]::IsNullOrWhiteSpace($snapshotName) -and $snapshotName -ne 'Snapshot') {
        return "$caseText / $snapshotName"
    }

    if (-not [string]::IsNullOrWhiteSpace($snapshotName) -and $snapshotName -ne 'Snapshot') {
        return $snapshotName
    }

    return $Snapshot.Name
}

function Get-SnapshotMetaLine {
    param(
        [object]$Snapshot
    )

    $parts = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace([string]$Snapshot.CaseName) -and [string]::IsNullOrWhiteSpace([string]$Snapshot.Stage)) {
        $parts.Add('unlabeled')
    }

    $parts.Add(([datetime]$Snapshot.Timestamp).ToString('yyyy-MM-dd HH:mm'))

    return ($parts -join '  |  ')
}

function Show-SnapshotCompactList {
    param(
        [object[]]$Snapshots,
        [string]$BaseFullName,
        [string]$CompareFullName
    )

    if ($Snapshots.Count -eq 0) {
        Write-Host 'Δεν βρέθηκαν snapshot folders ακόμα.' -ForegroundColor Yellow
        return
    }

    for ($i = 0; $i -lt $Snapshots.Count; $i++) {
        $snapshot = $Snapshots[$i]
        $title = Get-SnapshotDisplayLabel -Snapshot $snapshot
        $meta = Get-SnapshotMetaLine -Snapshot $snapshot
        $suffix = ''
        $titleColor = 'Cyan'
        if (-not [string]::IsNullOrWhiteSpace($BaseFullName) -and $snapshot.FullName -eq $BaseFullName) {
            $suffix = '  <----- Base (Before)'
            $titleColor = 'Red'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($CompareFullName) -and $snapshot.FullName -eq $CompareFullName) {
            $suffix = '  <----- Compare (After)'
            $titleColor = 'Green'
        }

        Write-Host ("[{0:00}] {1}{2}" -f ($i + 1), $title, $suffix) -ForegroundColor $titleColor
        Write-Host "      $meta" -ForegroundColor DarkGray
    }
}

function Show-SelectionPreview {
    param(
        [object]$BeforeSnapshot,
        [object]$AfterSnapshot
    )

    if ($null -eq $BeforeSnapshot -and $null -eq $AfterSnapshot) {
        return
    }

    Write-Host ''
    Write-Host 'Current Compare Selection' -ForegroundColor Cyan
    Write-Host '-------------------------' -ForegroundColor Cyan

    if ($null -ne $BeforeSnapshot) {
        Write-Host ("Base (Before)   : {0}" -f (Get-SnapshotDisplayLabel -Snapshot $BeforeSnapshot)) -ForegroundColor Red
        Write-Host ("                  {0}" -f (Get-SnapshotMetaLine -Snapshot $BeforeSnapshot)) -ForegroundColor DarkGray
    }

    if ($null -ne $AfterSnapshot) {
        Write-Host ("Compare (After) : {0}" -f (Get-SnapshotDisplayLabel -Snapshot $AfterSnapshot)) -ForegroundColor Green
        Write-Host ("                  {0}" -f (Get-SnapshotMetaLine -Snapshot $AfterSnapshot)) -ForegroundColor DarkGray
    }
}

function Format-FileSize {
    param(
        [long]$Bytes
    )

    if ($Bytes -lt 1KB) {
        return ('{0} B' -f $Bytes)
    }

    if ($Bytes -lt 1MB) {
        return ('{0:N1} KB' -f ($Bytes / 1KB))
    }

    if ($Bytes -lt 1GB) {
        return ('{0:N1} MB' -f ($Bytes / 1MB))
    }

    return ('{0:N1} GB' -f ($Bytes / 1GB))
}

function Get-SnapshotDescriptorFromFolderPath {
    param(
        [string]$FolderPath
    )

    if ([string]::IsNullOrWhiteSpace($FolderPath) -or -not (Test-Path -LiteralPath $FolderPath)) {
        return $null
    }

    $metadataPath = Join-Path $FolderPath 'metadata.json'
    if (-not (Test-Path -LiteralPath $metadataPath)) {
        return [pscustomobject]@{
            DisplayLabel = [IO.Path]::GetFileName($FolderPath)
            Mode = ''
        }
    }

    try {
        $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            DisplayLabel = [IO.Path]::GetFileName($FolderPath)
            Mode = ''
        }
    }

    $caseName = [string](Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'CaseName' -DefaultValue '')
    $stage = [string](Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'Stage' -DefaultValue '')
    $snapshotName = [string](Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'SnapshotName' -DefaultValue '')
    $mode = [string](Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'SnapshotMode' -DefaultValue '')

    $displayLabel = switch ($true) {
        { -not [string]::IsNullOrWhiteSpace($caseName) -and -not [string]::IsNullOrWhiteSpace($stage) } { "$caseName / $stage"; break }
        { -not [string]::IsNullOrWhiteSpace($stage) } { $stage; break }
        { -not [string]::IsNullOrWhiteSpace($caseName) -and -not [string]::IsNullOrWhiteSpace($snapshotName) -and $snapshotName -ne 'Snapshot' } { "$caseName / $snapshotName"; break }
        { -not [string]::IsNullOrWhiteSpace($snapshotName) } { $snapshotName; break }
        default { [IO.Path]::GetFileName($FolderPath) }
    }

    return [pscustomobject]@{
        DisplayLabel = $displayLabel
        Mode = $mode
    }
}

function Get-StructuredCompareReportContext {
    param(
        [string]$FolderPath
    )

    if ([string]::IsNullOrWhiteSpace($FolderPath) -or -not (Test-Path -LiteralPath $FolderPath)) {
        return $null
    }

    $differenceFilePath = Join-Path $FolderPath 'differences-only.txt'
    if (-not (Test-Path -LiteralPath $differenceFilePath)) {
        return $null
    }

    $fullReportPath = Join-Path $FolderPath 'full-report.txt'
    $beforePath = ''
    $afterPath = ''

    if (Test-Path -LiteralPath $fullReportPath) {
        foreach ($line in @(Get-Content -LiteralPath $fullReportPath -TotalCount 12 -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($beforePath) -and $line -match '^\s*Before\s*:\s*(.+?)\s*$') {
                $beforePath = $matches[1]
                continue
            }

            if ([string]::IsNullOrWhiteSpace($afterPath) -and $line -match '^\s*After\s*:\s*(.+?)\s*$') {
                $afterPath = $matches[1]
            }
        }
    }

    $beforeDescriptor = Get-SnapshotDescriptorFromFolderPath -FolderPath $beforePath
    $afterDescriptor = Get-SnapshotDescriptorFromFolderPath -FolderPath $afterPath

    $displayLabel = switch ($true) {
        { $null -ne $beforeDescriptor -and $null -ne $afterDescriptor } { '{0} with {1}' -f $beforeDescriptor.DisplayLabel, $afterDescriptor.DisplayLabel; break }
        { $null -ne $beforeDescriptor } { '{0} with compare report' -f $beforeDescriptor.DisplayLabel; break }
        default { [IO.Path]::GetFileName($FolderPath) }
    }

    $modeText = ''
    if ($null -ne $beforeDescriptor -or $null -ne $afterDescriptor) {
        $modeParts = New-Object System.Collections.Generic.List[string]
        if ($null -ne $beforeDescriptor -and -not [string]::IsNullOrWhiteSpace($beforeDescriptor.Mode)) {
            $modeParts.Add("base:$($beforeDescriptor.Mode)")
        }
        if ($null -ne $afterDescriptor -and -not [string]::IsNullOrWhiteSpace($afterDescriptor.Mode)) {
            $modeParts.Add("compare:$($afterDescriptor.Mode)")
        }
        if ($modeParts.Count -gt 0) {
            $modeText = $modeParts -join '  '
        }
    }

    return [pscustomobject]@{
        DisplayLabel         = $displayLabel
        DifferenceFilePath   = $differenceFilePath
        FullReportPath       = $fullReportPath
        BeforePath           = $beforePath
        AfterPath            = $afterPath
        BeforeLabel          = if ($null -ne $beforeDescriptor) { [string]$beforeDescriptor.DisplayLabel } else { '' }
        AfterLabel           = if ($null -ne $afterDescriptor) { [string]$afterDescriptor.DisplayLabel } else { '' }
        ModeText             = $modeText
        CompareIdentity      = ('{0}||{1}||{2}' -f $beforePath, $afterPath, $modeText)
        SemanticIdentity     = ('{0}||{1}||{2}' -f $displayLabel, $modeText, 'differences-only.txt')
    }
}

function Get-LiveCleanupReportFiles {
    param(
        [string]$RootPath
    )

    if ([string]::IsNullOrWhiteSpace($RootPath) -or -not (Test-Path -LiteralPath $RootPath)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $RootPath -File -Filter '*.md' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name
                    FullName = $_.FullName
                    BaseName = $_.BaseName
                    Length = $_.Length
                    LastWriteTime = $_.LastWriteTime
                }
            }
    )
}

function Get-LiveCleanupReportDisplayLabel {
    param(
        [object]$Report
    )

    if ($null -eq $Report) {
        return ''
    }

    return [string]$Report.BaseName
}

function Get-LiveCleanupReportMetaLine {
    param(
        [object]$Report
    )

    if ($null -eq $Report) {
        return ''
    }

    return ('{0:yyyy-MM-dd HH:mm}  |  {1}' -f [datetime]$Report.LastWriteTime, (Format-FileSize -Bytes ([long]$Report.Length)))
}

function Show-LiveCleanupReportSelectionPreview {
    param(
        [object]$SelectedReport
    )

    if ($null -eq $SelectedReport) {
        return
    }

    Write-Host ''
    Write-Host 'Current Live Cleanup Report' -ForegroundColor Green
    Write-Host '---------------------------' -ForegroundColor Green
    Write-Host ("Report : {0}" -f (Get-LiveCleanupReportDisplayLabel -Report $SelectedReport)) -ForegroundColor Green
    Write-Host ("Meta   : {0}" -f (Get-LiveCleanupReportMetaLine -Report $SelectedReport)) -ForegroundColor DarkGray
}

function Confirm-LiveCleanupReportDeletion {
    param(
        [object]$Report
    )

    if ($null -eq $Report) {
        return $false
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $script:LiveReportsRoot -ErrorAction Stop).ProviderPath.TrimEnd('\')
    $resolvedTarget = (Resolve-Path -LiteralPath $Report.FullName -ErrorAction Stop).ProviderPath.TrimEnd('\')
    $rootPrefix = $resolvedRoot + '\'

    if (
        $resolvedTarget -eq $resolvedRoot -or
        (-not $resolvedTarget.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase))
    ) {
        Write-Host 'Ακύρωση: το target live report path βγήκε εκτός του configured live root.' -ForegroundColor Red
        Start-Sleep -Milliseconds 1200
        return $false
    }

    Clear-HostSafe
    Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
    Write-Host ''
    Write-Host 'Delete Live Cleanup Report' -ForegroundColor Magenta
    Write-Host '--------------------------' -ForegroundColor Magenta
    Write-Host ("Report : {0}" -f (Get-LiveCleanupReportDisplayLabel -Report $Report)) -ForegroundColor Yellow
    Write-Host ("Meta   : {0}" -f (Get-LiveCleanupReportMetaLine -Report $Report)) -ForegroundColor DarkGray
    Write-Host ("Path   : {0}" -f $resolvedTarget) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '⚠️ IMPORTANT' -ForegroundColor Red
    Write-Host 'Αυτό θα διαγράψει το selected live cleanup report από το live root.' -ForegroundColor Yellow
    Write-Host '[ENTER] Delete live report' -ForegroundColor DarkYellow
    Write-Host '[ESC] Cancel' -ForegroundColor DarkGray

    if ([Console]::IsInputRedirected) {
        $confirmation = Read-HostTrimmed -Prompt 'Πάτα ENTER για διαγραφή ή γράψε ESC για ακύρωση'
        if (Test-IsEscapeInput -Value $confirmation) {
            return $false
        }

        return [string]::IsNullOrWhiteSpace($confirmation)
    }

    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'Enter' { return $true }
                'Escape' { return $false }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

function Select-LiveCleanupReportItem {
    param(
        [object[]]$Items
    )

    if ($Items.Count -eq 0) {
        return $null
    }

    $workingItems = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Items)) {
        [void]$workingItems.Add($item)
    }

    $selectedReport = $null
    while ($true) {
        if ($workingItems.Count -eq 0) {
            return $null
        }

        Clear-HostSafe
        Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
        Show-LiveCleanupReportSelectionPreview -SelectedReport $selectedReport
        Write-Host ''
        Write-Host 'Live Driver Clean Reports' -ForegroundColor Green
        Write-Host '-------------------------' -ForegroundColor Green

        if ([Console]::IsInputRedirected) {
            for ($i = 0; $i -lt $workingItems.Count; $i++) {
                $item = $workingItems[$i]
                Write-Host (Get-ConsoleSafeText -Text ("[{0:00}] {1}" -f ($i + 1), (Get-LiveCleanupReportDisplayLabel -Report $item))) -ForegroundColor Green
                Write-Host (Get-ConsoleSafeText -Text ("      {0}" -f (Get-LiveCleanupReportMetaLine -Report $item))) -ForegroundColor DarkGray
            }

            Write-Host ''
            Write-Host '[ESC] Cancel selection' -ForegroundColor DarkGray
            $selection = Read-HostTrimmed -Prompt 'Διάλεξε αριθμό live report'
            if (Test-IsEscapeInput -Value $selection) {
                return $null
            }

            $index = $selection -as [int]
            if ($null -eq $index -or $index -lt 1 -or $index -gt $workingItems.Count) {
                Write-Host 'Μη έγκυρη επιλογή live report.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 900
                continue
            }

            return $workingItems[$index - 1]
        }

        $selectedIndex = 0
        $eraseLine = '{0}[K' -f [char]27
        $restartPicker = $false

        function Write-LiveReportPickerFrame {
            [Console]::SetCursorPosition(0, $menuTop)
            for ($i = 0; $i -lt $workingItems.Count; $i++) {
                $item = $workingItems[$i]
                $isSelected = $i -eq $selectedIndex
                $prefix = if ($isSelected) { '❯' } else { ' ' }
                $line = Get-ConsoleSafeText -Text ("{0}[{1:00}] {2}" -f $prefix, ($i + 1), (Get-LiveCleanupReportDisplayLabel -Report $item))
                $color = if ($isSelected) { 'White' } else { 'Green' }
                Write-Host "$line$eraseLine" -ForegroundColor $color
                Write-Host ((Get-ConsoleSafeText -Text ("      {0}" -f (Get-LiveCleanupReportMetaLine -Report $item))) + $eraseLine) -ForegroundColor DarkGray
            }

            Write-Host ((Get-ConsoleSafeText -Text '[UP/DOWN] Move  [ENTER] View  [1-9] Shortcut  [D/DEL] Delete  [ESC] Back') + $eraseLine) -ForegroundColor DarkGray
        }

        [Console]::CursorVisible = $false
        try {
            Write-Host ''
            $menuTop = [Console]::CursorTop
            $frameHeight = ($workingItems.Count * 2) + 1
            for ($lineIndex = 0; $lineIndex -lt $frameHeight; $lineIndex++) {
                Write-Host ''
            }
            [Console]::SetCursorPosition(0, $menuTop)

            while ($true) {
                Write-LiveReportPickerFrame
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    'UpArrow' {
                        if ($selectedIndex -gt 0) {
                            $selectedIndex--
                        }
                    }
                    'DownArrow' {
                        if ($selectedIndex -lt ($workingItems.Count - 1)) {
                            $selectedIndex++
                        }
                    }
                    'Enter' {
                        return $workingItems[$selectedIndex]
                    }
                    'Escape' {
                        return $null
                    }
                    'Delete' {
                        $targetItem = $workingItems[$selectedIndex]
                        if (Confirm-LiveCleanupReportDeletion -Report $targetItem) {
                            Remove-Item -LiteralPath $targetItem.FullName -Force -ErrorAction Stop
                            [void]$workingItems.RemoveAt($selectedIndex)
                            if ($selectedIndex -ge $workingItems.Count -and $selectedIndex -gt 0) {
                                $selectedIndex--
                            }
                            $selectedReport = if ($workingItems.Count -gt 0) { $workingItems[$selectedIndex] } else { $null }
                            if ($workingItems.Count -eq 0) {
                                return $null
                            }
                            $restartPicker = $true
                        }
                        break
                    }
                    default {
                        $typedKey = [string]$key.KeyChar
                        if ($typedKey -match '^[dD]$') {
                            $targetItem = $workingItems[$selectedIndex]
                            if (Confirm-LiveCleanupReportDeletion -Report $targetItem) {
                                Remove-Item -LiteralPath $targetItem.FullName -Force -ErrorAction Stop
                                [void]$workingItems.RemoveAt($selectedIndex)
                                if ($selectedIndex -ge $workingItems.Count -and $selectedIndex -gt 0) {
                                    $selectedIndex--
                                }
                                $selectedReport = if ($workingItems.Count -gt 0) { $workingItems[$selectedIndex] } else { $null }
                                if ($workingItems.Count -eq 0) {
                                    return $null
                                }
                                $restartPicker = $true
                            }
                            break
                        }

                        if ($typedKey -match '^[1-9]$') {
                            $typedIndex = ([int]$typedKey) - 1
                            if ($typedIndex -lt $workingItems.Count) {
                                $selectedIndex = $typedIndex
                                $selectedReport = $workingItems[$selectedIndex]
                                Write-LiveReportPickerFrame
                                Start-Sleep -Milliseconds 90
                                return $workingItems[$selectedIndex]
                            }
                        }
                    }
                }

                if ($restartPicker) {
                    $restartPicker = $false
                    break
                }

                $selectedReport = $workingItems[$selectedIndex]
            }
        }
        finally {
            [Console]::CursorVisible = $true
        }
    }
}

function Get-LiveCleanupReportDisplayLines {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $allLines = [string[]](Get-Content -LiteralPath $Path -ErrorAction Stop)
    $filteredLines = foreach ($line in $allLines) {
        if (
            $line -match '^\*{6,}$' -or
            $line -match '^PowerShell transcript (start|end)$' -or
            $line -match '^Start time:\s*' -or
            $line -match '^End time:\s*'
        ) {
            continue
        }

        [string]$line
    }

    $startIndex = 0
    while ($startIndex -lt $filteredLines.Count -and [string]::IsNullOrWhiteSpace([string]$filteredLines[$startIndex])) {
        $startIndex++
    }

    $endIndex = $filteredLines.Count - 1
    while ($endIndex -ge $startIndex -and [string]::IsNullOrWhiteSpace([string]$filteredLines[$endIndex])) {
        $endIndex--
    }

    if ($endIndex -lt $startIndex) {
        return @()
    }

    return @($filteredLines[$startIndex..$endIndex])
}

function Show-LiveCleanupReportFile {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        Write-Host ("Το live cleanup report δεν βρέθηκε: {0}" -f $Path) -ForegroundColor Yellow
        return
    }

    $lines = @(Get-LiveCleanupReportDisplayLines -Path $Path)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        $nextLine = if (($index + 1) -lt $lines.Count) { [string]$lines[$index + 1] } else { '' }

        if ([string]::IsNullOrWhiteSpace($line)) {
            Write-Host ''
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($line) -and -not ($line -match '^\s') -and (Test-IsSectionUnderline -Line $nextLine)) {
            Write-Host $line -ForegroundColor Cyan
            continue
        }

        if (Test-IsSectionUnderline -Line $line) {
            Write-Host $line -ForegroundColor Cyan
            continue
        }

        switch -Regex ($line) {
            '^PS>TerminatingError' {
                Write-Host $line -ForegroundColor DarkYellow
                continue
            }
            '^(✅|\[V\])' {
                Write-Host $line -ForegroundColor Green
                continue
            }
            '^(⚠️|\[!\])' {
                Write-Host $line -ForegroundColor Yellow
                continue
            }
            '^(🔵|🧩|📦|📁|\[~\]|\[DEV\]|\[PKG\]|\[P\])' {
                Write-Host $line -ForegroundColor Cyan
                continue
            }
            '^(🔸| ->)' {
                Write-Host $line -ForegroundColor DarkYellow
                continue
            }
            default {
                Write-Host $line
            }
        }
    }
}

function Read-LiveCleanupReportViewerAction {
    if ([Console]::IsInputRedirected) {
        $choice = Read-HostTrimmed -Prompt 'Πατήστε ENTER για επιστροφή ή γράψε D για διαγραφή'
        if ([string]$choice -match '^(?i:d|del|delete)$') {
            return 'Delete'
        }

        return 'Back'
    }

    Write-Host ''
    Write-Host '[ENTER] Back to live reports' -ForegroundColor DarkGray
    Write-Host '[D/DEL] Delete this live report' -ForegroundColor DarkYellow
    Write-Host '[ESC] Back to live reports' -ForegroundColor DarkGray

    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'Enter' { return 'Back' }
                'Escape' { return 'Back' }
                'Delete' { return 'Delete' }
                default {
                    if ([string]$key.KeyChar -match '^[dD]$') {
                        return 'Delete'
                    }
                }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

function Invoke-LiveCleanupReportViewer {
    param(
        [object]$Report
    )

    if ($null -eq $Report) {
        return 'Back'
    }

    while ($true) {
        Clear-HostSafe
        Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
        Write-Host ''
        Write-Host 'Live Driver Clean Reports' -ForegroundColor Green
        Write-Host '-------------------------' -ForegroundColor Green
        Write-Host ("Report : {0}" -f (Get-LiveCleanupReportDisplayLabel -Report $Report)) -ForegroundColor Green
        Write-Host ("Meta   : {0}" -f (Get-LiveCleanupReportMetaLine -Report $Report)) -ForegroundColor DarkGray
        Write-Host ("Path   : {0}" -f $Report.FullName) -ForegroundColor DarkGray
        Write-Host ''

        Show-LiveCleanupReportFile -Path $Report.FullName
        $action = Read-LiveCleanupReportViewerAction
        if ($action -eq 'Delete') {
            if (Confirm-LiveCleanupReportDeletion -Report $Report) {
                Remove-Item -LiteralPath $Report.FullName -Force -ErrorAction Stop
                return 'Deleted'
            }

            continue
        }

        return 'Back'
    }
}

function Get-StructuredReportFolders {
    param(
        [string]$RootPath
    )

    if (-not (Test-Path -LiteralPath $RootPath)) {
        return @()
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $RootPath -ErrorAction Stop).ProviderPath.TrimEnd('\')

    $structuredTextRoot = Join-Path $resolvedRoot 'structured-text'
    $structuredTextPrefix = $structuredTextRoot.TrimEnd('\') + '\'

    $folderItems = @(
        Get-ChildItem -LiteralPath $resolvedRoot -Directory -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object {
                $candidatePath = $_.FullName.TrimEnd('\')
                if (
                    $candidatePath.Equals($structuredTextRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $candidatePath.StartsWith($structuredTextPrefix, [System.StringComparison]::OrdinalIgnoreCase)
                ) {
                    return
                }

                $textFiles = @(Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.txt' -ErrorAction SilentlyContinue)
                if ($textFiles.Count -eq 0) {
                    return
                }

                $reportContext = Get-StructuredCompareReportContext -FolderPath $_.FullName
                if ($null -eq $reportContext) {
                    return
                }

                $relativePath = $_.FullName.Substring($resolvedRoot.Length).TrimStart('\')
                $differenceFile = Get-Item -LiteralPath $reportContext.DifferenceFilePath -ErrorAction Stop
                $lastWriteTime = $differenceFile.LastWriteTime

                [pscustomobject]@{
                    Name                = $_.Name
                    FullName            = $_.FullName
                    RelativePath        = $relativePath
                    TextFileCount       = $textFiles.Count
                    LastWriteTime       = $lastWriteTime
                    DisplayLabel        = $reportContext.DisplayLabel
                    DifferenceFilePath  = $reportContext.DifferenceFilePath
                    BeforeLabel         = $reportContext.BeforeLabel
                    AfterLabel          = $reportContext.AfterLabel
                    ModeText            = $reportContext.ModeText
                    CompareIdentity     = $reportContext.CompareIdentity
                    SemanticIdentity    = $reportContext.SemanticIdentity
                }
            } |
            Sort-Object @{ Expression = 'LastWriteTime'; Descending = $true }, RelativePath
    )

    $seenIdentities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $dedupedItems = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $folderItems) {
        $identity = [string]$item.CompareIdentity
        if ([string]::IsNullOrWhiteSpace($identity)) {
            $identity = [string]$item.SemanticIdentity
        }

        if ([string]::IsNullOrWhiteSpace($identity)) {
            $identity = [string]$item.DisplayLabel
        }

        if ([string]::IsNullOrWhiteSpace($identity)) {
            $identity = [string]$item.RelativePath
        }

        if ($seenIdentities.Add($identity)) {
            [void]$dedupedItems.Add($item)
        }
    }

    return @($dedupedItems.ToArray())
}

function Get-StructuredReportFolderDisplayLabel {
    param(
        [object]$Folder
    )

    $displayLabel = [string]$Folder.DisplayLabel
    if ([string]::IsNullOrWhiteSpace($displayLabel)) {
        $displayLabel = [string]$Folder.RelativePath
    }

    if ($displayLabel.Length -le 80) {
        return $displayLabel
    }

    return ('{0} ... {1}' -f $displayLabel.Substring(0, 34).TrimEnd(), $displayLabel.Substring($displayLabel.Length - 30))
}

function Get-StructuredReportFolderMetaLine {
    param(
        [object]$Folder
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('differences-only.txt')
    if (-not [string]::IsNullOrWhiteSpace([string]$Folder.ModeText)) {
        $parts.Add([string]$Folder.ModeText)
    }
    $parts.Add(([datetime]$Folder.LastWriteTime).ToString('yyyy-MM-dd HH:mm'))
    return ($parts -join '  |  ')
}

function Get-TextReportFiles {
    param(
        [string]$FolderPath
    )

    if (-not (Test-Path -LiteralPath $FolderPath)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $FolderPath -File -Filter '*.txt' -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object {
                [pscustomobject]@{
                    Name         = $_.Name
                    FullName     = $_.FullName
                    Length       = $_.Length
                    LastWriteTime = $_.LastWriteTime
                }
            }
    )
}

function Get-StructuredReportFileDisplayLabel {
    param(
        [object]$File
    )

    return [string]$File.Name
}

function Get-StructuredReportFileMetaLine {
    param(
        [object]$File
    )

    return ('{0}  |  {1}' -f (Format-FileSize -Bytes ([long]$File.Length)), ([datetime]$File.LastWriteTime).ToString('yyyy-MM-dd HH:mm'))
}

function Show-StructuredReportSelectionPreview {
    param(
        [object]$BaseFolder,
        [object]$BaseFile,
        [object]$CompareFolder,
        [object]$CompareFile
    )

    if ($null -eq $BaseFolder -and $null -eq $BaseFile -and $null -eq $CompareFolder -and $null -eq $CompareFile) {
        return
    }

    Write-Host ''
    Write-Host 'Current Structured Compare Selection' -ForegroundColor Cyan
    Write-Host '-----------------------------------' -ForegroundColor Cyan

    if ($null -ne $BaseFolder) {
        Write-Host ("Base report      : {0}" -f (Get-StructuredReportFolderDisplayLabel -Folder $BaseFolder)) -ForegroundColor Red
        Write-Host ("                  {0}" -f (Get-StructuredReportFolderMetaLine -Folder $BaseFolder)) -ForegroundColor DarkGray
    }

    if ($null -ne $BaseFile) {
        Write-Host ("Base file        : {0}" -f (Get-StructuredReportFileDisplayLabel -File $BaseFile)) -ForegroundColor Red
        Write-Host ("                  {0}" -f (Get-StructuredReportFileMetaLine -File $BaseFile)) -ForegroundColor DarkGray
    }

    if ($null -ne $CompareFolder) {
        Write-Host ("Compare report   : {0}" -f (Get-StructuredReportFolderDisplayLabel -Folder $CompareFolder)) -ForegroundColor Green
        Write-Host ("                  {0}" -f (Get-StructuredReportFolderMetaLine -Folder $CompareFolder)) -ForegroundColor DarkGray
    }

    if ($null -ne $CompareFile) {
        Write-Host ("Compare file     : {0}" -f (Get-StructuredReportFileDisplayLabel -File $CompareFile)) -ForegroundColor Green
        Write-Host ("                  {0}" -f (Get-StructuredReportFileMetaLine -File $CompareFile)) -ForegroundColor DarkGray
    }
}

function Show-StructuredCompareReportFile {
    param(
        [string]$Path,
        [string]$Title,
        [ValidateSet('Extra', 'Missing')]
        [string]$Mode
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        Write-Host ("Το report file δεν βρέθηκε: {0}" -f $Path) -ForegroundColor Yellow
        return
    }

    $lines = [string[]](Get-Content -LiteralPath $Path -ErrorAction Stop)
    $changeColor = if ($Mode -eq 'Extra') { 'Green' } else { 'Red' }
    $index = 0

    while ($index -lt $lines.Count -and -not [string]::IsNullOrWhiteSpace([string]$lines[$index])) {
        $index++
    }

    while ($index -lt $lines.Count -and [string]::IsNullOrWhiteSpace([string]$lines[$index])) {
        $index++
    }

    while ($index -lt $lines.Count) {
        $line = [string]$lines[$index]
        $nextLine = if (($index + 1) -lt $lines.Count) { [string]$lines[$index + 1] } else { '' }

        if (-not [string]::IsNullOrWhiteSpace($line) -and
            -not ($line -match '^\s') -and
            (Test-IsSectionUnderline -Line $nextLine)) {
            Write-Host ''
            Write-Host $line -ForegroundColor Cyan
            Write-Host $nextLine -ForegroundColor Cyan
            $index += 2
            continue
        }

        if ([string]::IsNullOrWhiteSpace($line)) {
            Write-Host ''
            $index++
            continue
        }

        if ($line -match '^No section differences matched this report\.$') {
            Write-Host $line -ForegroundColor DarkGray
            $index++
            continue
        }

        if ($line -match '^\s') {
            Write-Host $line -ForegroundColor Gray
            $index++
            continue
        }

        Write-Host $line -ForegroundColor $changeColor
        $index++
    }
}

function Show-StructuredCompareReportPageHeader {
    param(
        [string]$PageTitle,
        [object]$BaseFolder,
        [object]$CompareFolder
    )

    Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
    Write-Host ''
    Write-Host $PageTitle -ForegroundColor DarkCyan
    Write-Host ('-' * $PageTitle.Length) -ForegroundColor DarkCyan

    if ($null -ne $BaseFolder) {
        Write-Host ("Base    : {0}" -f (Get-StructuredReportFolderDisplayLabel -Folder $BaseFolder)) -ForegroundColor Red
    }

    if ($null -ne $CompareFolder) {
        Write-Host ("Compare : {0}" -f (Get-StructuredReportFolderDisplayLabel -Folder $CompareFolder)) -ForegroundColor Green
    }
}

function Read-StructuredCompareReportExitAction {
    if ([Console]::IsInputRedirected) {
        $choice = Read-HostTrimmed -Prompt 'Πατήστε ENTER ή ESC για επιστροφή στο viewer menu'
        return 'Viewer'
    }

    Write-Host ''
    Write-Host '[ENTER] Return to compare viewer' -ForegroundColor DarkGray
    Write-Host '[ESC] Back to compare viewer' -ForegroundColor DarkGray

    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'Enter' { return 'Viewer' }
                'Escape' { return 'Viewer' }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

function Get-StructuredCompareViewSelection {
    $items = @(
        [pscustomobject]@{ Key = '1'; Label = 'View extra vs base'; Color = 'Green'; Value = 'Extra' },
        [pscustomobject]@{ Key = '2'; Label = 'View missing vs base'; Color = 'Red'; Value = 'Missing' },
        [pscustomobject]@{ Key = '3'; Label = 'View both reports'; Color = 'Cyan'; Value = 'Both' },
        [pscustomobject]@{ Key = '0'; Label = 'Back to main menu'; Color = 'Gray'; Value = 'Back' }
    )

    if ([Console]::IsInputRedirected) {
        Write-Host ''
        foreach ($item in $items) {
            Write-Host ("[{0}] {1}" -f $item.Key, $item.Label) -ForegroundColor $item.Color
        }
        Write-Host '[ESC] Back to main menu' -ForegroundColor DarkGray
        $choice = Read-HostTrimmed -Prompt 'View report'
        if (Test-IsEscapeInput -Value $choice) {
            return 'Back'
        }

        $matchedItem = $items | Where-Object { $_.Key -eq $choice } | Select-Object -First 1
        if ($null -ne $matchedItem) {
            return $matchedItem.Value
        }

        return 'Back'
    }

    $selectedIndex = 0
    $eraseLine = '{0}[K' -f [char]27

    function Write-StructuredCompareViewFrame {
        [Console]::SetCursorPosition(0, $menuTop)
        for ($i = 0; $i -lt $items.Count; $i++) {
            $item = $items[$i]
            $isSelected = $i -eq $selectedIndex
            $prefix = if ($isSelected) { '❯' } else { ' ' }
            $line = Get-ConsoleSafeText -Text ("{0} [{1}] {2}" -f $prefix, $item.Key, $item.Label)
            $color = if ($isSelected) { 'White' } else { $item.Color }
            Write-Host "$line$eraseLine" -ForegroundColor $color
        }

        Write-Host ((Get-ConsoleSafeText -Text '[UP/DOWN] Move  [ENTER] Select  [1-3/0] Shortcut  [ESC] Back') + $eraseLine) -ForegroundColor DarkGray
    }

    [Console]::CursorVisible = $false
    try {
        Write-Host ''
        $menuTop = [Console]::CursorTop
        $frameHeight = $items.Count + 1
        for ($lineIndex = 0; $lineIndex -lt $frameHeight; $lineIndex++) {
            Write-Host ''
        }
        [Console]::SetCursorPosition(0, $menuTop)

        while ($true) {
            Write-StructuredCompareViewFrame
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' {
                    if ($selectedIndex -gt 0) {
                        $selectedIndex--
                    }
                }
                'DownArrow' {
                    if ($selectedIndex -lt ($items.Count - 1)) {
                        $selectedIndex++
                    }
                }
                'Enter' {
                    return $items[$selectedIndex].Value
                }
                'Escape' {
                    return 'Back'
                }
                default {
                    $typedKey = [string]$key.KeyChar
                    if (-not [string]::IsNullOrWhiteSpace($typedKey)) {
                        $matchedIndex = -1
                        for ($i = 0; $i -lt $items.Count; $i++) {
                            if ($items[$i].Key -eq $typedKey) {
                                $matchedIndex = $i
                                break
                            }
                        }

                        if ($matchedIndex -ge 0) {
                            $selectedIndex = $matchedIndex
                            Write-StructuredCompareViewFrame
                            Start-Sleep -Milliseconds 90
                            return $items[$selectedIndex].Value
                        }
                    }
                }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

function Invoke-StructuredCompareReportViewer {
    param(
        [string]$MissingReportPath,
        [string]$ExtraReportPath,
        [object]$BaseFolder,
        [object]$CompareFolder
    )

    while ($true) {
        Clear-HostSafe
        Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
        Show-StructuredReportSelectionPreview -BaseFolder $BaseFolder -CompareFolder $CompareFolder
        Write-Host ''
        Write-Host 'Structured Compare Viewer' -ForegroundColor DarkCyan
        Write-Host '-------------------------' -ForegroundColor DarkCyan

        $viewChoice = Get-StructuredCompareViewSelection
        switch ($viewChoice) {
            'Extra' {
                Clear-HostSafe
                Show-StructuredCompareReportPageHeader -PageTitle 'Extra Vs Base' -BaseFolder $BaseFolder -CompareFolder $CompareFolder
                Show-StructuredCompareReportFile -Path $ExtraReportPath -Title 'Extra Vs Base' -Mode 'Extra'
                $null = Read-StructuredCompareReportExitAction
            }
            'Missing' {
                Clear-HostSafe
                Show-StructuredCompareReportPageHeader -PageTitle 'Missing Vs Base' -BaseFolder $BaseFolder -CompareFolder $CompareFolder
                Show-StructuredCompareReportFile -Path $MissingReportPath -Title 'Missing Vs Base' -Mode 'Missing'
                $null = Read-StructuredCompareReportExitAction
            }
            'Both' {
                Clear-HostSafe
                Show-StructuredCompareReportPageHeader -PageTitle 'Structured Compare Report' -BaseFolder $BaseFolder -CompareFolder $CompareFolder
                Write-Host ''
                Write-Host 'Extra Vs Base' -ForegroundColor Green
                Write-Host ('-' * 13) -ForegroundColor Green
                Show-StructuredCompareReportFile -Path $ExtraReportPath -Title 'Extra Vs Base' -Mode 'Extra'
                Write-Host ''
                Write-Host ('=' * 62) -ForegroundColor DarkGray
                Write-Host ''
                Write-Host 'Missing Vs Base' -ForegroundColor Red
                Write-Host ('-' * 15) -ForegroundColor Red
                Show-StructuredCompareReportFile -Path $MissingReportPath -Title 'Missing Vs Base' -Mode 'Missing'
                $null = Read-StructuredCompareReportExitAction
            }
            default {
                return
            }
        }
    }
}

function Confirm-StructuredReportFolderDeletion {
    param(
        [object]$Folder
    )

    if ($null -eq $Folder) {
        return $false
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $CompareOutputRoot -ErrorAction Stop).ProviderPath.TrimEnd('\')
    $resolvedTarget = (Resolve-Path -LiteralPath $Folder.FullName -ErrorAction Stop).ProviderPath.TrimEnd('\')
    $rootPrefix = $resolvedRoot + '\'

    if (
        $resolvedTarget -eq $resolvedRoot -or
        (-not $resolvedTarget.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase))
    ) {
        Write-Host 'Ακύρωση: το target compare report path βγήκε εκτός του configured compare-output root.' -ForegroundColor Red
        Start-Sleep -Milliseconds 1200
        return $false
    }

    Clear-HostSafe
    Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
    Write-Host ''
    Write-Host 'Delete Compare Report' -ForegroundColor Magenta
    Write-Host '---------------------' -ForegroundColor Magenta
    Write-Host ("Report : {0}" -f (Get-StructuredReportFolderDisplayLabel -Folder $Folder)) -ForegroundColor Yellow
    Write-Host ("Meta   : {0}" -f (Get-StructuredReportFolderMetaLine -Folder $Folder)) -ForegroundColor DarkGray
    Write-Host ("Path   : {0}" -f $resolvedTarget) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '⚠️ IMPORTANT' -ForegroundColor Red
    Write-Host 'Αυτό θα διαγράψει ΟΛΟ το selected compare report folder από το compare-output root.' -ForegroundColor Yellow
    Write-Host '[ENTER] Delete compare report' -ForegroundColor DarkYellow
    Write-Host '[ESC] Cancel' -ForegroundColor DarkGray

    if ([Console]::IsInputRedirected) {
        $confirmation = Read-HostTrimmed -Prompt 'Πάτα ENTER για διαγραφή ή γράψε ESC για ακύρωση'
        if (Test-IsEscapeInput -Value $confirmation) {
            return $false
        }

        return [string]::IsNullOrWhiteSpace($confirmation)
    }

    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'Enter' { return $true }
                'Escape' { return $false }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

function Select-StructuredReportItem {
    param(
        [string]$Prompt,
        [object[]]$Items,
        [scriptblock]$GetLabel,
        [scriptblock]$GetMeta,
        [scriptblock]$PreviewScript,
        [int]$InitialIndex = 0,
        [string]$InvalidSelectionMessage = 'Μη έγκυρη επιλογή.',
        [string]$InputPrompt = 'Διάλεξε αριθμό'
    )

    if ($Items.Count -eq 0) {
        return $null
    }

    $workingItems = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Items)) {
        [void]$workingItems.Add($item)
    }

    if ($InitialIndex -lt 0) {
        $InitialIndex = 0
    }
    if ($InitialIndex -ge $workingItems.Count) {
        $InitialIndex = 0
    }

    while ($true) {
        if ($workingItems.Count -eq 0) {
            return $null
        }

        Clear-HostSafe
        Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
        if ($null -ne $PreviewScript) {
            & $PreviewScript
        }

        Write-Host ''
        Write-Host $Prompt -ForegroundColor Cyan
        Write-Host ('-' * $Prompt.Length) -ForegroundColor Cyan

        if ([Console]::IsInputRedirected) {
            for ($i = 0; $i -lt $workingItems.Count; $i++) {
                $item = $workingItems[$i]
                $label = (& $GetLabel $item)
                $meta = (& $GetMeta $item)
                Write-Host (Get-ConsoleSafeText -Text ("[{0:00}] {1}" -f ($i + 1), $label)) -ForegroundColor Cyan
                Write-Host (Get-ConsoleSafeText -Text "      $meta") -ForegroundColor DarkGray
            }

            Write-Host ''
            Write-Host '[ESC] Cancel selection' -ForegroundColor DarkGray

            $selection = Read-HostTrimmed -Prompt $InputPrompt
            if (Test-IsEscapeInput -Value $selection) {
                return $null
            }

            if ([string]::IsNullOrWhiteSpace($selection)) {
                Write-Host ($InvalidSelectionMessage + ' Δώσε αριθμό ή πάτησε ESC για ακύρωση.') -ForegroundColor Yellow
                Start-Sleep -Milliseconds 900
                continue
            }

            $index = $selection -as [int]
            if ($null -eq $index -or $index -lt 1 -or $index -gt $workingItems.Count) {
                Write-Host $InvalidSelectionMessage -ForegroundColor Yellow
                Start-Sleep -Milliseconds 900
                continue
            }

            return $workingItems[$index - 1]
        }

        $selectedIndex = $InitialIndex
        $eraseLine = '{0}[K' -f [char]27
        $restartPicker = $false

        function Write-StructuredItemPickerFrame {
            [Console]::SetCursorPosition(0, $menuTop)
            for ($i = 0; $i -lt $workingItems.Count; $i++) {
                $item = $workingItems[$i]
                $isSelected = $i -eq $selectedIndex
                $prefix = if ($isSelected) { '❯' } else { ' ' }
                $label = (& $GetLabel $item)
                $meta = (& $GetMeta $item)
                $line = Get-ConsoleSafeText -Text ("{0}[{1:00}] {2}" -f $prefix, ($i + 1), $label)
                $color = if ($isSelected) { 'White' } else { 'Cyan' }
                Write-Host "$line$eraseLine" -ForegroundColor $color
                Write-Host ((Get-ConsoleSafeText -Text ("      {0}" -f $meta)) + $eraseLine) -ForegroundColor DarkGray
            }

            Write-Host ((Get-ConsoleSafeText -Text '[UP/DOWN] Move  [ENTER] Select  [1-9] Shortcut  [D/DEL] Delete  [ESC] Cancel') + $eraseLine) -ForegroundColor DarkGray
        }

        [Console]::CursorVisible = $false
        try {
            Write-Host ''
            $menuTop = [Console]::CursorTop
            $frameHeight = ($workingItems.Count * 2) + 1
            for ($lineIndex = 0; $lineIndex -lt $frameHeight; $lineIndex++) {
                Write-Host ''
            }
            [Console]::SetCursorPosition(0, $menuTop)
            while ($true) {
                Write-StructuredItemPickerFrame
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    'UpArrow' {
                        if ($selectedIndex -gt 0) {
                            $selectedIndex--
                        }
                    }
                    'DownArrow' {
                        if ($selectedIndex -lt ($workingItems.Count - 1)) {
                            $selectedIndex++
                        }
                    }
                    'Enter' {
                        return $workingItems[$selectedIndex]
                    }
                    'Escape' {
                        return $null
                    }
                    'Delete' {
                        $targetItem = $workingItems[$selectedIndex]
                        if (Confirm-StructuredReportFolderDeletion -Folder $targetItem) {
                            Remove-Item -LiteralPath $targetItem.FullName -Recurse -Force -ErrorAction Stop
                            [void]$workingItems.RemoveAt($selectedIndex)
                            if ($selectedIndex -ge $workingItems.Count -and $selectedIndex -gt 0) {
                                $selectedIndex--
                            }
                            $InitialIndex = $selectedIndex
                            if ($workingItems.Count -eq 0) {
                                return $null
                            }
                            $restartPicker = $true
                        }
                        break
                    }
                    default {
                        $typedKey = [string]$key.KeyChar
                        if ($typedKey -match '^[dD]$') {
                            $targetItem = $workingItems[$selectedIndex]
                            if (Confirm-StructuredReportFolderDeletion -Folder $targetItem) {
                                Remove-Item -LiteralPath $targetItem.FullName -Recurse -Force -ErrorAction Stop
                                [void]$workingItems.RemoveAt($selectedIndex)
                                if ($selectedIndex -ge $workingItems.Count -and $selectedIndex -gt 0) {
                                    $selectedIndex--
                                }
                                $InitialIndex = $selectedIndex
                                if ($workingItems.Count -eq 0) {
                                    return $null
                                }
                                $restartPicker = $true
                            }
                            break
                        }

                        if ($typedKey -match '^[1-9]$') {
                            $typedIndex = ([int]$typedKey) - 1
                            if ($typedIndex -lt $workingItems.Count) {
                                $selectedIndex = $typedIndex
                                Write-StructuredItemPickerFrame
                                Start-Sleep -Milliseconds 90
                                return $workingItems[$selectedIndex]
                            }
                        }
                    }
                }

                if ($restartPicker) {
                    break
                }
            }
        }
        finally {
            [Console]::CursorVisible = $true
        }

        if ($restartPicker) {
            continue
        }
    }
}

function Select-Snapshot {
    param(
        [string]$Prompt,
        [string]$RootPath,
        [string]$ExcludedFullName,
        [switch]$Chronological,
        [object]$BeforeSnapshot,
        [object]$AfterSnapshot
    )

    while ($true) {
        $snapshots = @(Get-SnapshotFolders -RootPath $RootPath -Chronological:$Chronological)
        if (-not [string]::IsNullOrWhiteSpace($ExcludedFullName)) {
            $snapshots = @($snapshots | Where-Object { $_.FullName -ne $ExcludedFullName })
        }

        Clear-HostSafe
        Show-LauncherHeader -Snapshots $snapshots
        Show-SelectionPreview -BeforeSnapshot $BeforeSnapshot -AfterSnapshot $AfterSnapshot
        Write-Host ''
        Write-Host $Prompt -ForegroundColor Cyan
        Write-Host ('-' * $Prompt.Length) -ForegroundColor Cyan

        if ($snapshots.Count -eq 0) {
            return $null
        }

        if ([Console]::IsInputRedirected) {
            Show-SnapshotCompactList -Snapshots $snapshots -BaseFullName $(if ($null -ne $BeforeSnapshot) { $BeforeSnapshot.FullName } else { '' }) -CompareFullName $(if ($null -ne $AfterSnapshot) { $AfterSnapshot.FullName } else { '' })
            Write-Host ''
            Write-Host '[ESC] Cancel selection' -ForegroundColor DarkGray

            $selection = Read-HostTrimmed -Prompt 'Διάλεξε αριθμό snapshot'
            if (Test-IsEscapeInput -Value $selection) {
                return $null
            }

            if ([string]::IsNullOrWhiteSpace($selection)) {
                Write-Host 'Δώσε αριθμό snapshot ή πάτησε ESC για ακύρωση.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 900
                continue
            }

            $index = $selection -as [int]
            if ($null -eq $index -or $index -lt 1 -or $index -gt $snapshots.Count) {
                Write-Host 'Μη έγκυρη επιλογή snapshot.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 900
                continue
            }

            return $snapshots[$index - 1]
        }

        $selectedIndex = 0
        $eraseLine = '{0}[K' -f [char]27

        function Write-SnapshotPickerFrame {
            [Console]::SetCursorPosition(0, $menuTop)
            for ($i = 0; $i -lt $snapshots.Count; $i++) {
                $snapshot = $snapshots[$i]
                $isSelected = $i -eq $selectedIndex
                $prefix = if ($isSelected) { '❯' } else { ' ' }
                $title = Get-SnapshotDisplayLabel -Snapshot $snapshot
                $meta = Get-SnapshotMetaLine -Snapshot $snapshot

                $suffix = ''
                $titleColor = 'Cyan'
                if ($null -ne $BeforeSnapshot -and $snapshot.FullName -eq $BeforeSnapshot.FullName) {
                    $suffix = '  <----- Base (Before)'
                    $titleColor = 'Red'
                }
                elseif ($null -ne $AfterSnapshot -and $snapshot.FullName -eq $AfterSnapshot.FullName) {
                    $suffix = '  <----- Compare (After)'
                    $titleColor = 'Green'
                }

                $line = "{0}[{1:00}] {2}{3}" -f $prefix, ($i + 1), $title, $suffix
                $color = if ($isSelected) { 'White' } else { $titleColor }
                Write-Host "$line$eraseLine" -ForegroundColor $color
                Write-Host ("      {0}$eraseLine" -f $meta) -ForegroundColor DarkGray
            }
            Write-Host "[UP/DOWN] Move  [ENTER] Select  [1-9] Shortcut  [ESC] Cancel$eraseLine" -ForegroundColor DarkGray
        }

        [Console]::CursorVisible = $false
        try {
            Write-Host ''
            $menuTop = [Console]::CursorTop
            while ($true) {
                Write-SnapshotPickerFrame
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    'UpArrow' {
                        if ($selectedIndex -gt 0) {
                            $selectedIndex--
                        }
                    }
                    'DownArrow' {
                        if ($selectedIndex -lt ($snapshots.Count - 1)) {
                            $selectedIndex++
                        }
                    }
                    'Enter' {
                        return $snapshots[$selectedIndex]
                    }
                    'Escape' {
                        return $null
                    }
                    default {
                        $typedKey = [string]$key.KeyChar
                        if ($typedKey -match '^[1-9]$') {
                            $typedIndex = ([int]$typedKey) - 1
                            if ($typedIndex -lt $snapshots.Count) {
                                $selectedIndex = $typedIndex
                                Write-SnapshotPickerFrame
                                Start-Sleep -Milliseconds 90
                                return $snapshots[$selectedIndex]
                            }
                        }
                    }
                }
            }
        }
        finally {
            [Console]::CursorVisible = $true
        }
    }
}

function Show-LauncherHeader {
    param(
        [object[]]$Snapshots
    )

    Clear-HostSafe
    Write-Host ('=' * 62) -ForegroundColor Cyan
    Write-Host " $($script:Icons.Title) DriverCheck" -ForegroundColor Cyan -NoNewline
    Write-Host '  main launcher' -ForegroundColor DarkGray
    Write-Host ('=' * 62) -ForegroundColor Cyan
    Write-Host ''

    $snapshotCount = if ($null -eq $Snapshots) { 0 } else { $Snapshots.Count }

    Write-Host "$($script:Icons.Snapshot) Snapshots      : " -NoNewline -ForegroundColor Yellow
    Write-Host $snapshotCount -ForegroundColor Yellow
    Write-Host "$($script:Icons.Tip) Main flow       : save snapshot -> compare -> audit cleanup -> run cleanup" -ForegroundColor DarkYellow
}

function Invoke-SaveSnapshot {
    Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
    Write-Host ''
    $global:DriverCheck_LastSnapshotSaveCanceled = $false
    & (Get-InternalToolPath -ScriptName 'Save-DriverSnapshot.ps1') -OutputRoot $SnapshotsRoot
    if ($global:DriverCheck_LastSnapshotSaveCanceled) {
        $global:DriverCheck_LastSnapshotSaveCanceled = $false
        return
    }

    Pause-Launcher
}

function Invoke-CompareSnapshots {
    $beforeSnapshot = Select-Snapshot -Prompt 'Διάλεξε baseline snapshot' -RootPath $SnapshotsRoot -Chronological
    if ($null -eq $beforeSnapshot) {
        return
    }

    $afterSnapshot = Select-Snapshot -Prompt 'Διάλεξε compare snapshot' -RootPath $SnapshotsRoot -ExcludedFullName $beforeSnapshot.FullName -Chronological -BeforeSnapshot $beforeSnapshot
    if ($null -eq $afterSnapshot) {
        return
    }

    Clear-HostSafe
    Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot -Chronological)
    Show-SelectionPreview -BeforeSnapshot $beforeSnapshot -AfterSnapshot $afterSnapshot
    Write-Host ''

    & (Get-InternalToolPath -ScriptName 'Compare-DriverSnapshots.ps1') -BeforePath $beforeSnapshot.FullName -AfterPath $afterSnapshot.FullName
    Pause-Launcher
}

function Get-CertificateModeSelection {
    while ($true) {
        $items = @(
            [pscustomobject]@{ Key = '1'; Label = 'No certificate cleanup (Recommended)'; Color = 'Cyan'; Value = @{ IncludeCertificates = $false; IncludeRootCertificates = $false } },
            [pscustomobject]@{ Key = '2'; Label = 'Include TrustedPublisher cleanup'; Color = 'Cyan'; Value = @{ IncludeCertificates = $true; IncludeRootCertificates = $false } },
            [pscustomobject]@{ Key = '3'; Label = 'Include TrustedPublisher and ROOT cleanup (Advanced)'; Color = 'Yellow'; Value = @{ IncludeCertificates = $true; IncludeRootCertificates = $true } }
        )

        if ([Console]::IsInputRedirected) {
            Write-Host ''
            foreach ($item in $items) {
                Write-Host ("[{0}] {1}" -f $item.Key, $item.Label) -ForegroundColor $item.Color
            }
            Write-Host '[ESC] Cancel cleanup flow' -ForegroundColor DarkGray

            $choice = Read-HostTrimmed -Prompt 'Certificate mode'
            if (Test-IsEscapeInput -Value $choice) {
                return $null
            }

            $matchedItem = $items | Where-Object { $_.Key -eq $choice } | Select-Object -First 1
            if ($null -ne $matchedItem) {
                return $matchedItem.Value
            }

            Write-Host 'Δώσε 1, 2, 3 ή πάτησε ESC για ακύρωση.' -ForegroundColor Yellow
            Start-Sleep -Milliseconds 900
            continue
        }

        $selectedIndex = 0
        $eraseLine = '{0}[K' -f [char]27

        function Write-CertificateMenuFrame {
            [Console]::SetCursorPosition(0, $menuTop)
            for ($i = 0; $i -lt $items.Count; $i++) {
                $item = $items[$i]
                $isSelected = $i -eq $selectedIndex
                $prefix = if ($isSelected) { '❯' } else { ' ' }
                $line = "{0} [{1}] {2}" -f $prefix, $item.Key, $item.Label
                $color = if ($isSelected) { 'White' } else { $item.Color }
                Write-Host "$line$eraseLine" -ForegroundColor $color
            }
            Write-Host "[UP/DOWN] Move  [ENTER] Select  [1-3] Shortcut  [ESC] Cancel$eraseLine" -ForegroundColor DarkGray
        }

        [Console]::CursorVisible = $false
        try {
            Write-Host ''
            $menuTop = [Console]::CursorTop
            while ($true) {
                Write-CertificateMenuFrame
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    'UpArrow' {
                        if ($selectedIndex -gt 0) {
                            $selectedIndex--
                        }
                    }
                    'DownArrow' {
                        if ($selectedIndex -lt ($items.Count - 1)) {
                            $selectedIndex++
                        }
                    }
                    'Enter' {
                        return $items[$selectedIndex].Value
                    }
                    'Escape' {
                        return $null
                    }
                    default {
                        $typedKey = [string]$key.KeyChar
                        for ($i = 0; $i -lt $items.Count; $i++) {
                            if ($items[$i].Key -eq $typedKey) {
                                $selectedIndex = $i
                                Write-CertificateMenuFrame
                                Start-Sleep -Milliseconds 90
                                return $items[$selectedIndex].Value
                            }
                        }
                    }
                }
            }
        }
        finally {
            [Console]::CursorVisible = $true
        }
    }
}

function Invoke-CleanupFromSnapshots {
    param(
        [switch]$AuditOnly
    )

    $beforeSnapshot = Select-Snapshot -Prompt 'Διάλεξε baseline snapshot' -RootPath $SnapshotsRoot -Chronological
    if ($null -eq $beforeSnapshot) {
        return
    }

    $afterSnapshot = Select-Snapshot -Prompt 'Διάλεξε install snapshot' -RootPath $SnapshotsRoot -ExcludedFullName $beforeSnapshot.FullName -Chronological -BeforeSnapshot $beforeSnapshot
    if ($null -eq $afterSnapshot) {
        return
    }

    $invokeParams = @{
        BeforePath = $beforeSnapshot.FullName
        AfterPath = $afterSnapshot.FullName
    }

    if ($AuditOnly) {
        $invokeParams.AuditOnly = $true
    }
    else {
        $certMode = Get-CertificateModeSelection
        if ($null -eq $certMode) {
            Write-Host 'Ακύρωση cleanup flow από τον χρήστη.' -ForegroundColor Yellow
            return
        }

        if ($certMode.IncludeCertificates) {
            $invokeParams.IncludeCertificates = $true
        }

        if ($certMode.IncludeRootCertificates) {
            $invokeParams.IncludeRootCertificates = $true
        }
    }

    & (Get-InternalToolPath -ScriptName 'Invoke-DriverCleanupFromSnapshots.ps1') @invokeParams
    Pause-Launcher
}

function Invoke-LiveDriverCheck {
    & (Get-InternalToolPath -ScriptName 'Invoke-DriverLiveCheck.ps1') -EmbeddedInLauncher
}

function Invoke-LiveCleanupReports {
    while ($true) {
        $reports = @(Get-LiveCleanupReportFiles -RootPath $script:LiveReportsRoot)
        if ($reports.Count -eq 0) {
            Clear-HostSafe
            Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
            Write-Host ''
            Write-Host 'Live Driver Clean Reports' -ForegroundColor Green
            Write-Host '-------------------------' -ForegroundColor Green
            Write-Host ("Δεν βρέθηκαν live cleanup reports κάτω από: {0}" -f $script:LiveReportsRoot) -ForegroundColor Yellow
            Pause-Launcher
            return
        }

        $selectedReport = Select-LiveCleanupReportItem -Items $reports
        if ($null -eq $selectedReport) {
            return
        }

        $reports = @(Get-LiveCleanupReportFiles -RootPath $script:LiveReportsRoot)
        $selectedReport = $reports | Where-Object { $_.FullName -eq $selectedReport.FullName } | Select-Object -First 1
        if ($null -eq $selectedReport) {
            Clear-HostSafe
            Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
            Write-Host ''
            Write-Host 'Το selected live cleanup report δεν υπάρχει πια.' -ForegroundColor Yellow
            Pause-Launcher
            return
        }

        $viewerAction = Invoke-LiveCleanupReportViewer -Report $selectedReport
        if ($viewerAction -eq 'Deleted') {
            continue
        }
    }
}

function Invoke-DeleteSnapshot {
    $snapshot = Select-Snapshot -Prompt 'Διάλεξε snapshot για διαγραφή' -RootPath $SnapshotsRoot -Chronological
    if ($null -eq $snapshot) {
        return
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $SnapshotsRoot -ErrorAction Stop).ProviderPath.TrimEnd('\')
    $resolvedTarget = (Resolve-Path -LiteralPath $snapshot.FullName -ErrorAction Stop).ProviderPath.TrimEnd('\')
    $rootPrefix = $resolvedRoot + '\'

    if (
        $resolvedTarget -eq $resolvedRoot -or
        (-not $resolvedTarget.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase))
    ) {
        Write-Host 'Ακύρωση: το target snapshot path βγήκε εκτός του configured snapshots root.' -ForegroundColor Red
        Pause-Launcher
        return
    }

    Clear-HostSafe
    Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot -Chronological)
    Write-Host ''
    Write-Host 'Delete Snapshot' -ForegroundColor Magenta
    Write-Host '---------------' -ForegroundColor Magenta
    Write-Host ("Snapshot : {0}" -f (Get-SnapshotDisplayLabel -Snapshot $snapshot)) -ForegroundColor Yellow
    Write-Host ("Time     : {0}" -f (Get-SnapshotMetaLine -Snapshot $snapshot)) -ForegroundColor DarkGray
    Write-Host ("Path     : {0}" -f $resolvedTarget) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '⚠️ IMPORTANT' -ForegroundColor Red
    Write-Host 'Αυτό θα διαγράψει ΟΛΟ το selected snapshot folder από το snapshots root.' -ForegroundColor Yellow
    Write-Host '[ENTER] Delete snapshot' -ForegroundColor DarkYellow
    Write-Host '[ESC] Cancel' -ForegroundColor DarkGray

    $shouldDelete = $false
    if ([Console]::IsInputRedirected) {
        $confirmation = Read-HostTrimmed -Prompt 'Πάτα ENTER για διαγραφή ή γράψε ESC για ακύρωση'
        if (Test-IsEscapeInput -Value $confirmation) {
            Write-Host 'Ακύρωση διαγραφής snapshot από τον χρήστη.' -ForegroundColor Yellow
            return
        }

        $shouldDelete = [string]::IsNullOrWhiteSpace($confirmation)
    }
    else {
        [Console]::CursorVisible = $false
        try {
            while ($true) {
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    'Enter' {
                        $shouldDelete = $true
                    }
                    'Escape' {
                        Write-Host ''
                        Write-Host 'Ακύρωση διαγραφής snapshot από τον χρήστη.' -ForegroundColor Yellow
                        return
                    }
                }

                if ($shouldDelete) {
                    break
                }
            }
        }
        finally {
            [Console]::CursorVisible = $true
        }
    }

    if (-not $shouldDelete) {
        Write-Host 'Η διαγραφή ακυρώθηκε.' -ForegroundColor Yellow
        Pause-Launcher
        return
    }

    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force -ErrorAction Stop
    Write-Host ''
    Write-Host '✅ Το snapshot διαγράφηκε επιτυχώς.' -ForegroundColor Green
    Pause-Launcher
}

function Invoke-CompareStructuredReports {
    $reportFolders = @(Get-StructuredReportFolders -RootPath $CompareOutputRoot)
    if ($reportFolders.Count -eq 0) {
        Clear-HostSafe
        Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
        Write-Host ''
        Write-Host 'Compare Structured Reports' -ForegroundColor DarkCyan
        Write-Host '--------------------------' -ForegroundColor DarkCyan
        Write-Host ("Δεν βρέθηκαν compare report folders με differences-only.txt κάτω από: {0}" -f $CompareOutputRoot) -ForegroundColor Yellow
        Pause-Launcher
        return
    }

    $baseFolder = Select-StructuredReportItem `
        -Prompt 'Διάλεξε base compare report' `
        -Items $reportFolders `
        -GetLabel { param($item) Get-StructuredReportFolderDisplayLabel -Folder $item } `
        -GetMeta { param($item) Get-StructuredReportFolderMetaLine -Folder $item } `
        -PreviewScript { Show-StructuredReportSelectionPreview } `
        -InvalidSelectionMessage 'Μη έγκυρη επιλογή compare report.' `
        -InputPrompt 'Διάλεξε αριθμό compare report'

    if ($null -eq $baseFolder) {
        return
    }

    $reportFolders = @(Get-StructuredReportFolders -RootPath $CompareOutputRoot)
    $baseFolder = $reportFolders | Where-Object { $_.FullName -eq $baseFolder.FullName } | Select-Object -First 1
    if ($null -eq $baseFolder) {
        Clear-HostSafe
        Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
        Write-Host ''
        Write-Host 'Το selected base compare report δεν υπάρχει πια.' -ForegroundColor Yellow
        Pause-Launcher
        return
    }

    $compareFolders = @($reportFolders | Where-Object { $_.FullName -ne $baseFolder.FullName })
    if ($compareFolders.Count -eq 0) {
        Clear-HostSafe
        Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
        Show-StructuredReportSelectionPreview -BaseFolder $baseFolder
        Write-Host ''
        Write-Host 'Δεν βρέθηκε δεύτερο report folder για σύγκριση.' -ForegroundColor Yellow
        Pause-Launcher
        return
    }

    $compareFolder = Select-StructuredReportItem `
        -Prompt 'Διάλεξε compare report' `
        -Items $compareFolders `
        -GetLabel { param($item) Get-StructuredReportFolderDisplayLabel -Folder $item } `
        -GetMeta { param($item) Get-StructuredReportFolderMetaLine -Folder $item } `
        -PreviewScript { Show-StructuredReportSelectionPreview -BaseFolder $baseFolder } `
        -InvalidSelectionMessage 'Μη έγκυρη επιλογή compare report.' `
        -InputPrompt 'Διάλεξε αριθμό compare report'

    if ($null -eq $compareFolder) {
        return
    }

    if (
        (-not (Test-Path -LiteralPath $baseFolder.DifferenceFilePath)) -or
        (-not (Test-Path -LiteralPath $compareFolder.DifferenceFilePath))
    ) {
        Clear-HostSafe
        Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
        Show-StructuredReportSelectionPreview -BaseFolder $baseFolder -CompareFolder $compareFolder
        Write-Host ''
        Write-Host 'Ένα από τα selected compare reports διαγράφηκε ή μετακινήθηκε. Ξαναδοκίμασε από το menu 7.' -ForegroundColor Yellow
        Pause-Launcher
        return
    }

    Clear-HostSafe
    Show-LauncherHeader -Snapshots @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
    Show-StructuredReportSelectionPreview -BaseFolder $baseFolder -CompareFolder $compareFolder
    Write-Host ''

    $compareResult = & (Get-InternalToolPath -ScriptName 'Compare-StructuredTextReport.ps1') `
        -BasePath $baseFolder.DifferenceFilePath `
        -ComparePath $compareFolder.DifferenceFilePath `
        -OutputRoot (Join-Path $CompareOutputRoot 'structured-text')

    if ($null -ne $compareResult) {
        Invoke-StructuredCompareReportViewer `
            -MissingReportPath $compareResult.MissingReportPath `
            -ExtraReportPath $compareResult.ExtraReportPath `
            -BaseFolder $baseFolder `
            -CompareFolder $compareFolder
        return
    }

    Pause-Launcher
}

if (-not (Test-CurrentSessionElevated)) {
    Write-Host 'Administrator rights are recommended for snapshot, compare, and cleanup flows.' -ForegroundColor Yellow
    Write-Host 'Opening an elevated PowerShell window...' -ForegroundColor Cyan
    Start-SelfElevatedInstance
}

$script:Icons = Get-UiIcons

while ($true) {
    $snapshots = @(Get-SnapshotFolders -RootPath $SnapshotsRoot)
    $menuItems = @(Get-LauncherMenuItems)
    $choice = Read-LauncherMenuChoice -MenuItems $menuItems -Snapshots $snapshots

    switch ($choice) {
        '1' { Invoke-SaveSnapshot }
        '2' { Invoke-CompareSnapshots }
        '3' { Invoke-CompareStructuredReports }
        '4' { Invoke-CleanupFromSnapshots -AuditOnly }
        '5' { Invoke-CleanupFromSnapshots }
        '6' { Invoke-LiveDriverCheck }
        '7' { Invoke-LiveCleanupReports }
        '8' { Invoke-DeleteSnapshot }
        '0' { return }
        default {
            Write-Host 'Μη έγκυρη επιλογή.' -ForegroundColor Yellow
            Start-Sleep -Milliseconds 900
        }
    }
}
