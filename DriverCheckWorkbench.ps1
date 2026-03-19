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
    Read-Host 'Πατήστε ENTER για επιστροφή στο menu' | Out-Null
}

function Read-HostTrimmed {
    param(
        [string]$Prompt
    )

    try {
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

    $snapshots = @(Get-SnapshotFolders -RootPath $RootPath -PreferredCaseName $CurrentCaseName)
    if ($snapshots.Count -eq 0) {
        Write-Host 'Δεν υπάρχουν snapshots για επιλογή.' -ForegroundColor Yellow
        return $null
    }

    Write-Section -Title $Prompt
    Show-SnapshotList -Snapshots $snapshots -CurrentCaseName $CurrentCaseName
    Write-Host ''
    $selection = Read-HostTrimmed -Prompt 'Διάλεξε αριθμό snapshot ή άφησέ το κενό για ακύρωση'
    if ([string]::IsNullOrWhiteSpace($selection)) {
        return $null
    }

    $index = $selection -as [int]
    if ($null -eq $index -or $index -lt 1 -or $index -gt $snapshots.Count) {
        Write-Host 'Μη έγκυρη επιλογή snapshot.' -ForegroundColor Yellow
        return $null
    }

    return $snapshots[$index - 1]
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
    if ([string]::IsNullOrWhiteSpace($value)) {
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
    if ([string]::IsNullOrWhiteSpace($stage)) {
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
    Write-Host ''
    Write-Host '[1] No certificate cleanup (Recommended)' -ForegroundColor Cyan
    Write-Host '[2] Include TrustedPublisher cleanup' -ForegroundColor Cyan
    Write-Host '[3] Include TrustedPublisher and ROOT cleanup (Advanced)' -ForegroundColor Yellow
    $choice = Read-HostTrimmed -Prompt 'Certificate mode'

    switch ($choice) {
        '2' {
            return @{
                IncludeCertificates = $true
                IncludeRootCertificates = $false
            }
        }
        '3' {
            return @{
                IncludeCertificates = $true
                IncludeRootCertificates = $true
            }
        }
        default {
            return @{
                IncludeCertificates = $false
                IncludeRootCertificates = $false
            }
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
    & (Join-Path $PSScriptRoot 'driver_check.ps1')
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

    switch ($choice) {
        '1' {
            $value = Read-HostTrimmed -Prompt 'Case Name'
            if (-not [string]::IsNullOrWhiteSpace($value)) {
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
