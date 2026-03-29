[CmdletBinding()]
param(
    [string]$CaseName,
    [string]$SnapshotsRoot = (Join-Path $PSScriptRoot 'snapshots')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-CurrentSessionElevated {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SelfElevationArgumentList {
    $argumentList = @('-NoLogo', '-NoProfile', '-File', $PSCommandPath)

    if (-not [string]::IsNullOrWhiteSpace($CaseName)) {
        $argumentList += @('-CaseName', $CaseName)
    }

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

function Get-UiIcons {
    if ($env:WT_SESSION) {
        return @{
            Section = '🔵'
            Tip = '💡'
            Warn = '⚠️'
            Ok = '✅'
            Path = '📁'
            Action = '🔸'
            Case = '🧪'
            Admin = '🛡'
            Snapshot = '📸'
            BeforeInstall = '📥'
            AfterInstall = '⚡'
            AfterRemove = '📤'
            AfterCleanup = '✅'
            AfterCertCleanup = '🔐'
            CustomStage = '✍'
            List = '📚'
            Compare = '🔍'
            Audit = '🧭'
            Cleanup = '🧹'
            Legacy = '🛠'
            Exit = '🚪'
        }
    }

    return @{
        Section = '[~]'
        Tip = '[i]'
        Warn = '[!]'
        Ok = '[V]'
        Path = '[P]'
        Action = ' ->'
        Case = '[C]'
        Admin = '[A]'
        Snapshot = '[S]'
        BeforeInstall = '[B]'
        AfterInstall = '[I]'
        AfterRemove = '[R]'
        AfterCleanup = '[C+]'
        AfterCertCleanup = '[TC]'
        CustomStage = '[CS]'
        List = '[LS]'
        Compare = '[?]'
        Audit = '[A]'
        Cleanup = '[X]'
        Legacy = '[L]'
        Exit = '[E]'
    }
}

function Clear-HostSafe {
    try {
        Clear-Host
    }
    catch {
        # Some redirected/non-interactive hosts throw "CursorPosition: The handle is invalid."
    }
}

function Write-Section {
    param(
        [string]$Title
    )

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor Cyan
}

function Write-AccentRule {
    param(
        [int]$Length = 60
    )

    Write-Host ('─' * $Length) -ForegroundColor Cyan
}

function Pause-Workbench {
    Write-Host ''
    $null = Read-HostTrimmed -Prompt 'Πατήστε ENTER για επιστροφή στο menu ή γράψε ESC για ακύρωση'
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
        [string]$PreferredCaseName
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
        $snapshotNameValue = [string](Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'SnapshotName' -DefaultValue '')
        $snapshotName = if (-not [string]::IsNullOrWhiteSpace($snapshotNameValue)) { $snapshotNameValue } else { $dir.Name }
        $timestampValue = Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'Timestamp' -DefaultValue $null
        $timestampText = if ($null -ne $timestampValue -and -not [string]::IsNullOrWhiteSpace([string]$timestampValue)) { [datetime]$timestampValue } else { $dir.LastWriteTime }
        $focusTermValue = Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'FocusTerm' -DefaultValue @()
        $focusTerms = if ($null -ne $focusTermValue) { @($focusTermValue) -join ', ' } else { '' }
        $casePriority = if (-not [string]::IsNullOrWhiteSpace($PreferredCaseName) -and $snapshotCase -eq $PreferredCaseName) { 0 } else { 1 }

        [pscustomobject]@{
            Name = $dir.Name
            FullName = $dir.FullName
            SnapshotName = $snapshotName
            CaseName = $snapshotCase
            Stage = $snapshotStage
            Timestamp = $timestampText
            FocusTerms = $focusTerms
            CasePriority = $casePriority
        }
    }

    return @(
        $items |
        Sort-Object @{ Expression = 'CasePriority'; Ascending = $true }, @{ Expression = 'Timestamp'; Descending = $true }
    )
}

function Show-SnapshotList {
    param(
        [object[]]$Snapshots,
        [string]$CurrentCaseName
    )

    if ($Snapshots.Count -eq 0) {
        Write-Host 'Δεν βρέθηκαν snapshot folders ακόμα.' -ForegroundColor Yellow
        return
    }

    for ($i = 0; $i -lt $Snapshots.Count; $i++) {
        $snapshot = $Snapshots[$i]
        $marker = if (-not [string]::IsNullOrWhiteSpace($CurrentCaseName) -and $snapshot.CaseName -eq $CurrentCaseName) { '*' } else { ' ' }
        $stageText = if ([string]::IsNullOrWhiteSpace($snapshot.Stage)) { 'NoStage' } else { $snapshot.Stage }
        $caseText = if ([string]::IsNullOrWhiteSpace($snapshot.CaseName)) { 'NoCase' } else { $snapshot.CaseName }
        Write-Host ("[{0:00}] {1} {2}" -f ($i + 1), $marker, $snapshot.Name) -ForegroundColor Cyan
        Write-Host "     Case  : $caseText" -ForegroundColor DarkGray
        Write-Host "     Stage : $stageText" -ForegroundColor DarkGray
        Write-Host "     Time  : $($snapshot.Timestamp)" -ForegroundColor DarkGray
        if (-not [string]::IsNullOrWhiteSpace($snapshot.FocusTerms)) {
            Write-Host "     Focus : $($snapshot.FocusTerms)" -ForegroundColor DarkGray
        }
    }
}

function Select-Snapshot {
    param(
        [string]$Prompt,
        [string]$CurrentCaseName,
        [string]$RootPath
    )

    while ($true) {
        $snapshots = @(Get-SnapshotFolders -RootPath $RootPath -PreferredCaseName $CurrentCaseName)
        if ($snapshots.Count -eq 0) {
            Write-Host 'Δεν υπάρχουν snapshots για επιλογή.' -ForegroundColor Yellow
            return $null
        }

        Write-Section -Title $Prompt

        if ([Console]::IsInputRedirected) {
            Show-SnapshotList -Snapshots $snapshots -CurrentCaseName $CurrentCaseName
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
                $marker = if (-not [string]::IsNullOrWhiteSpace($CurrentCaseName) -and $snapshot.CaseName -eq $CurrentCaseName) { '*' } else { ' ' }
                $line = "{0}[{1:00}] {2} {3}" -f $prefix, ($i + 1), $marker, $snapshot.Name
                $color = if ($isSelected) { 'White' } else { 'Cyan' }
                $caseText = if ([string]::IsNullOrWhiteSpace($snapshot.CaseName)) { 'NoCase' } else { $snapshot.CaseName }
                $stageText = if ([string]::IsNullOrWhiteSpace($snapshot.Stage)) { 'NoStage' } else { $snapshot.Stage }
                Write-Host "$line$eraseLine" -ForegroundColor $color
                Write-Host ("     Case  : {0}$eraseLine" -f $caseText) -ForegroundColor DarkGray
                Write-Host ("     Stage : {0}$eraseLine" -f $stageText) -ForegroundColor DarkGray
                Write-Host ("     Time  : {0}$eraseLine" -f $snapshot.Timestamp) -ForegroundColor DarkGray
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

function Get-RecommendedHint {
    param(
        [string]$CurrentCaseName,
        [object[]]$Snapshots
    )

    if ([string]::IsNullOrWhiteSpace($CurrentCaseName)) {
        return 'Βάλε πρώτα ένα Case Name και μετά πάρε BeforeInstall snapshot ακριβώς πριν το install.'
    }

    $caseSnapshots = @($Snapshots | Where-Object { $_.CaseName -eq $CurrentCaseName })
    $stages = @(
        $caseSnapshots |
        ForEach-Object { $_.Stage } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )

    if ($stages -notcontains 'BeforeInstall') {
        return 'Next recommended: Πάρε BeforeInstall snapshot ακριβώς πριν ξεκινήσει το install.'
    }

    if ($stages -notcontains 'AfterInstall') {
        return 'Next recommended: Μόλις τελειώσει το install, πάρε ΑΜΕΣΩΣ το AfterInstall snapshot για λιγότερο noise.'
    }

    if (($stages -notcontains 'AfterRemove') -and ($stages -notcontains 'AfterCleanup')) {
        return 'Next recommended: Μετά το uninstall/cleanup, πάρε ΑΜΕΣΩΣ AfterRemove ή AfterCleanup snapshot.'
    }

    return 'Next recommended: Σύγκρινε snapshots ή τρέξε audit cleanup flow για να βρεις leftovers.'
}

function Ensure-CaseName {
    if (-not [string]::IsNullOrWhiteSpace($script:CurrentCaseName)) {
        return $true
    }

    $value = Read-HostTrimmed -Prompt 'Δώσε Case Name για αυτό το investigation'
    if ([string]::IsNullOrWhiteSpace($value) -or (Test-IsEscapeInput -Value $value)) {
        Write-Host 'Το Case Name έμεινε κενό. Η ενέργεια ακυρώθηκε.' -ForegroundColor Yellow
        return $false
    }

    $script:CurrentCaseName = $value
    return $true
}

function Invoke-SnapshotCapture {
    param(
        [string]$Stage
    )

    if (-not (Ensure-CaseName)) {
        return
    }

    Write-Section -Title "Create Snapshot - $Stage"
    switch ($Stage) {
        'BeforeInstall' {
            Write-Host 'Πρόταση: Πάρε αυτό το snapshot ακριβώς πριν τρέξεις το install.' -ForegroundColor DarkYellow
        }
        'AfterInstall' {
            Write-Host 'Πρόταση: Πάρε αυτό το snapshot ΑΜΕΣΩΣ μετά το install. Όσο περιμένεις, τόσο αυξάνει το noise.' -ForegroundColor DarkYellow
        }
        'AfterRemove' {
            Write-Host 'Πρόταση: Πάρε αυτό το snapshot ΑΜΕΣΩΣ μετά το uninstall/remove flow.' -ForegroundColor DarkYellow
        }
        'AfterCleanup' {
            Write-Host 'Πρόταση: Πάρε αυτό το snapshot ΑΜΕΣΩΣ μετά το δικό μας cleanup script.' -ForegroundColor DarkYellow
        }
        'AfterCertCleanup' {
            Write-Host 'Πρόταση: Χρησιμοποίησέ το μόνο όταν τελειώσεις και το publisher-cert cleanup.' -ForegroundColor DarkYellow
        }
    }

    & (Join-Path $PSScriptRoot 'Save-DriverSnapshot.ps1') -CaseName $script:CurrentCaseName -Stage $Stage -OutputRoot $SnapshotsRoot
    Pause-Workbench
}

function Invoke-CustomSnapshotCapture {
    if (-not (Ensure-CaseName)) {
        return
    }

    Write-Section -Title 'Create Custom Snapshot'
    Write-Host 'Πρόταση: Τα standard stages κρατάνε το flow πιο καθαρό. Custom stage μόνο αν όντως το χρειάζεσαι.' -ForegroundColor DarkYellow
    $stage = Read-HostTrimmed -Prompt 'Custom Stage'
    if ([string]::IsNullOrWhiteSpace($stage) -or (Test-IsEscapeInput -Value $stage)) {
        Write-Host 'Το Stage έμεινε κενό. Η ενέργεια ακυρώθηκε.' -ForegroundColor Yellow
        Pause-Workbench
        return
    }

    & (Join-Path $PSScriptRoot 'Save-DriverSnapshot.ps1') -CaseName $script:CurrentCaseName -Stage $stage -OutputRoot $SnapshotsRoot
    Pause-Workbench
}

function Invoke-CompareWorkflow {
    $beforeSnapshot = Select-Snapshot -Prompt 'Διάλεξε baseline snapshot' -CurrentCaseName $script:CurrentCaseName -RootPath $SnapshotsRoot
    if ($null -eq $beforeSnapshot) {
        Pause-Workbench
        return
    }

    $afterSnapshot = Select-Snapshot -Prompt 'Διάλεξε δεύτερο snapshot για compare' -CurrentCaseName $script:CurrentCaseName -RootPath $SnapshotsRoot
    if ($null -eq $afterSnapshot) {
        Pause-Workbench
        return
    }

    & (Join-Path $PSScriptRoot 'Compare-DriverSnapshots.ps1') -BeforePath $beforeSnapshot.FullName -AfterPath $afterSnapshot.FullName
    Pause-Workbench
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

function Invoke-CleanupWorkflow {
    param(
        [switch]$AuditOnly
    )

    $beforeSnapshot = Select-Snapshot -Prompt 'Διάλεξε Before/baseline snapshot' -CurrentCaseName $script:CurrentCaseName -RootPath $SnapshotsRoot
    if ($null -eq $beforeSnapshot) {
        Pause-Workbench
        return
    }

    $afterSnapshot = Select-Snapshot -Prompt 'Διάλεξε AfterInstall snapshot' -CurrentCaseName $script:CurrentCaseName -RootPath $SnapshotsRoot
    if ($null -eq $afterSnapshot) {
        Pause-Workbench
        return
    }

    Write-Section -Title 'Cleanup Options'
    Write-Host 'Πρόταση: Χρησιμοποίησε snapshots που πάρθηκαν όσο πιο κοντά γίνεται στο install για λιγότερο noise.' -ForegroundColor DarkYellow
    $certMode = Get-CertificateModeSelection
    if ($null -eq $certMode) {
        Write-Host 'Ακύρωση cleanup flow από τον χρήστη.' -ForegroundColor Yellow
        Pause-Workbench
        return
    }

    $invokeParams = @{
        BeforePath = $beforeSnapshot.FullName
        AfterPath = $afterSnapshot.FullName
    }

    if ($AuditOnly) {
        $invokeParams.AuditOnly = $true
    }

    if ($certMode.IncludeCertificates) {
        $invokeParams.IncludeCertificates = $true
    }

    if ($certMode.IncludeRootCertificates) {
        $invokeParams.IncludeRootCertificates = $true
    }

    & (Join-Path $PSScriptRoot 'Invoke-DriverCleanupFromSnapshots.ps1') @invokeParams
    Pause-Workbench
}

function Invoke-LegacyDriverCheck {
    & (Join-Path $PSScriptRoot 'Invoke-DriverLiveCheck.ps1')
}

function Write-InfoLine {
    param(
        [string]$Icon,
        [string]$Label,
        [string]$Value,
        [string]$ValueColor = 'White',
        [string]$IconColor = 'Gray'
    )

    Write-Host "$Icon " -NoNewline -ForegroundColor $IconColor
    Write-Host ($Label.PadRight(15)) -NoNewline -ForegroundColor DarkYellow
    Write-Host ' : ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $ValueColor
}

function Write-MenuItem {
    param(
        [string]$Number,
        [string]$Icon,
        [string]$Label,
        [string]$NumberColor,
        [string]$LabelColor
    )

    Write-Host '[' -NoNewline -ForegroundColor DarkGray
    Write-Host $Number -NoNewline -ForegroundColor $NumberColor
    Write-Host '] ' -NoNewline -ForegroundColor DarkGray

    if (-not [string]::IsNullOrWhiteSpace($Icon)) {
        Write-Host "$Icon " -NoNewline -ForegroundColor Gray
    }

    Write-Host $Label -ForegroundColor $LabelColor
}

function Write-MenuGroup {
    param(
        [string]$Title
    )

    Write-Host ''
    Write-Host $Title -ForegroundColor White
    Write-Host ('·' * $Title.Length) -ForegroundColor DarkGray
}

function Show-Header {
    param(
        [object[]]$Snapshots
    )

    Clear-HostSafe
    Write-AccentRule
    Write-Host ' DriverCheck Workbench' -ForegroundColor Cyan -NoNewline
    Write-Host '  -  Snapshot / Compare / Cleanup' -ForegroundColor DarkGray
    Write-AccentRule
    Write-Host ''
    $sessionMode = if (Test-CurrentSessionElevated) { 'Admin' } else { 'Standard' }
    $sessionColor = if ($sessionMode -eq 'Admin') { 'Cyan' } else { 'Yellow' }
    $currentCaseText = if ([string]::IsNullOrWhiteSpace($script:CurrentCaseName)) { '<not set>' } else { $script:CurrentCaseName }
    $currentCaseColor = if ([string]::IsNullOrWhiteSpace($script:CurrentCaseName)) { 'DarkGray' } else { 'Green' }
    $snapshotCountColor = if ($Snapshots.Count -gt 0) { 'Yellow' } else { 'DarkGray' }

    Write-InfoLine -Icon $script:Icons.Path -Label 'Repo' -Value $PSScriptRoot -ValueColor 'DarkGray' -IconColor 'Yellow'
    Write-InfoLine -Icon $script:Icons.Path -Label 'Snapshots Root' -Value $SnapshotsRoot -ValueColor 'DarkGray' -IconColor 'Cyan'
    Write-InfoLine -Icon $script:Icons.Admin -Label 'Session Mode' -Value $sessionMode -ValueColor $sessionColor -IconColor 'Red'
    Write-InfoLine -Icon $script:Icons.Case -Label 'Current Case' -Value $currentCaseText -ValueColor $currentCaseColor -IconColor 'Magenta'
    Write-InfoLine -Icon $script:Icons.Snapshot -Label 'Snapshots' -Value ([string]$Snapshots.Count) -ValueColor $snapshotCountColor -IconColor 'DarkYellow'
    Write-Host ''
    Write-Host "$($script:Icons.Tip) Timing matters:" -ForegroundColor Yellow
    Write-Host '    BeforeInstall  -> ακριβώς πριν το install' -ForegroundColor DarkYellow
    Write-Host '    AfterInstall   -> ΑΜΕΣΩΣ μετά το install για λιγότερο noise' -ForegroundColor DarkYellow
    Write-Host '    AfterCleanup   -> ΑΜΕΣΩΣ μετά το uninstall/cleanup flow' -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host "$($script:Icons.Tip) $($script:RecommendedHint)" -ForegroundColor Yellow
    Write-MenuGroup -Title 'Setup'
    Write-MenuItem -Number '1' -Icon $script:Icons.Case -Label 'Set or change Case Name' -NumberColor 'Green' -LabelColor 'Green'

    Write-MenuGroup -Title 'Snapshot Flow'
    Write-MenuItem -Number '2' -Icon $script:Icons.BeforeInstall -Label 'Create BeforeInstall snapshot' -NumberColor 'DarkYellow' -LabelColor 'Yellow'
    Write-MenuItem -Number '3' -Icon $script:Icons.AfterInstall -Label 'Create AfterInstall snapshot' -NumberColor 'Cyan' -LabelColor 'Cyan'
    Write-MenuItem -Number '4' -Icon $script:Icons.AfterRemove -Label 'Create AfterRemove snapshot' -NumberColor 'Magenta' -LabelColor 'Magenta'
    Write-MenuItem -Number '5' -Icon $script:Icons.AfterCleanup -Label 'Create AfterCleanup snapshot' -NumberColor 'Blue' -LabelColor 'Blue'
    Write-MenuItem -Number '6' -Icon $script:Icons.AfterCertCleanup -Label 'Create AfterCertCleanup snapshot' -NumberColor 'DarkCyan' -LabelColor 'DarkCyan'
    Write-MenuItem -Number '7' -Icon $script:Icons.CustomStage -Label 'Create custom snapshot stage' -NumberColor 'Gray' -LabelColor 'Gray'

    Write-MenuGroup -Title 'Review And Diff'
    Write-MenuItem -Number '8' -Icon $script:Icons.List -Label 'List snapshots' -NumberColor 'Yellow' -LabelColor 'White'
    Write-MenuItem -Number '9' -Icon $script:Icons.Compare -Label 'Compare two snapshots' -NumberColor 'Cyan' -LabelColor 'White'
    Write-MenuItem -Number '10' -Icon $script:Icons.Audit -Label 'Audit cleanup from snapshots' -NumberColor 'Yellow' -LabelColor 'Yellow'

    Write-MenuGroup -Title 'Cleanup Tools'
    Write-MenuItem -Number '11' -Icon $script:Icons.Cleanup -Label 'Run cleanup from snapshots' -NumberColor 'Red' -LabelColor 'Red'
    Write-MenuItem -Number '12' -Icon $script:Icons.Legacy -Label 'Open legacy driver checker' -NumberColor 'DarkGreen' -LabelColor 'DarkGreen'
    Write-MenuItem -Number '0' -Icon $script:Icons.Exit -Label 'Exit' -NumberColor 'Gray' -LabelColor 'Gray'
}

if (-not (Test-CurrentSessionElevated)) {
    Write-Host 'Administrator rights are recommended for the workbench because snapshot and cleanup tasks need elevation.' -ForegroundColor Yellow
    Write-Host 'Opening an elevated PowerShell window...' -ForegroundColor Cyan
    Start-SelfElevatedInstance
}

$script:Icons = Get-UiIcons
$script:CurrentCaseName = $CaseName

while ($true) {
    $snapshots = @(Get-SnapshotFolders -RootPath $SnapshotsRoot -PreferredCaseName $script:CurrentCaseName)
    $script:RecommendedHint = Get-RecommendedHint -CurrentCaseName $script:CurrentCaseName -Snapshots $snapshots
    Show-Header -Snapshots $snapshots

    $choice = Read-HostTrimmed -Prompt 'Choose an option'
    if (Test-IsEscapeInput -Value $choice) {
        return
    }

    switch ($choice) {
        '1' {
            $value = Read-HostTrimmed -Prompt 'Case Name'
            if (Test-IsEscapeInput -Value $value) {
                Write-Host 'Ακύρωση αλλαγής Case Name.' -ForegroundColor Yellow
            }
            elseif (-not [string]::IsNullOrWhiteSpace($value)) {
                $script:CurrentCaseName = $value
            }
        }
        '2' { Invoke-SnapshotCapture -Stage 'BeforeInstall' }
        '3' { Invoke-SnapshotCapture -Stage 'AfterInstall' }
        '4' { Invoke-SnapshotCapture -Stage 'AfterRemove' }
        '5' { Invoke-SnapshotCapture -Stage 'AfterCleanup' }
        '6' { Invoke-SnapshotCapture -Stage 'AfterCertCleanup' }
        '7' { Invoke-CustomSnapshotCapture }
        '8' {
            Write-Section -Title 'Snapshot List'
            Show-SnapshotList -Snapshots $snapshots -CurrentCaseName $script:CurrentCaseName
            Pause-Workbench
        }
        '9' { Invoke-CompareWorkflow }
        '10' { Invoke-CleanupWorkflow -AuditOnly }
        '11' { Invoke-CleanupWorkflow }
        '12' { Invoke-LegacyDriverCheck }
        '0' { return }
        default {
            Write-Host 'Μη έγκυρη επιλογή.' -ForegroundColor Yellow
            Start-Sleep -Milliseconds 900
        }
    }
}
