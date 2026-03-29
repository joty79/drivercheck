[CmdletBinding()]
param(
    [string]$SnapshotsRoot = (Join-Path $PSScriptRoot 'snapshots')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:InternalToolsRoot = Join-Path $PSScriptRoot 'internal'

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
        [pscustomobject]@{ Key = '3'; Label = 'Audit Cleanup From Snapshots'; Color = 'DarkYellow' },
        [pscustomobject]@{ Key = '4'; Label = 'Run Cleanup From Snapshots'; Color = 'Red' },
        [pscustomobject]@{ Key = '5'; Label = 'Live Driver Check'; Color = 'Green' },
        [pscustomobject]@{ Key = '6'; Label = 'Delete Snapshot'; Color = 'Magenta' },
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
                        break
                    }
                    'Escape' {
                        Write-Host ''
                        Write-Host 'Ακύρωση διαγραφής snapshot από τον χρήστη.' -ForegroundColor Yellow
                        return
                    }
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
        '3' { Invoke-CleanupFromSnapshots -AuditOnly }
        '4' { Invoke-CleanupFromSnapshots }
        '5' { Invoke-LiveDriverCheck }
        '6' { Invoke-DeleteSnapshot }
        '0' { return }
        default {
            Write-Host 'Μη έγκυρη επιλογή.' -ForegroundColor Yellow
            Start-Sleep -Milliseconds 900
        }
    }
}
