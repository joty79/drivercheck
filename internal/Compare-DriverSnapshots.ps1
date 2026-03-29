[CmdletBinding()]
param(
    [string]$BeforePath,
    [string]$AfterPath,
    [string]$SnapshotsRoot = (Join-Path $PSScriptRoot 'snapshots'),
    [string]$CaseName,
    [string]$CompareOutputRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'compare-output')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonFile {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    return Get-Content -Raw $Path | ConvertFrom-Json
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

function Resolve-SnapshotInputPath {
    param(
        [string]$Path,
        [string]$RootPath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if (Test-Path -LiteralPath $Path) {
        return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    }

    if (-not [string]::IsNullOrWhiteSpace($RootPath)) {
        $candidate = Join-Path $RootPath $Path
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).ProviderPath
        }
    }

    return $Path
}

function Assert-SnapshotPathReadable {
    param(
        [string]$Path,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label path is empty."
    }

    try {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        throw "$Label path is not accessible from this system: $Path"
    }

    $resolvedPath = $resolved.ProviderPath
    $metadataPath = Join-Path $resolvedPath 'metadata.json'
    if (-not (Test-Path $metadataPath)) {
        throw "$Label snapshot folder is missing metadata.json: $resolvedPath"
    }

    return $resolvedPath
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
        $snapshotNameValue = [string](Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'SnapshotName' -DefaultValue '')
        $snapshotName = if (-not [string]::IsNullOrWhiteSpace($snapshotNameValue)) { $snapshotNameValue } else { $dir.Name }
        $timestampValue = Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'Timestamp' -DefaultValue $null
        $timestampText = if ($null -ne $timestampValue -and -not [string]::IsNullOrWhiteSpace([string]$timestampValue)) { [datetime]$timestampValue } else { $dir.LastWriteTime }
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
            Timestamp = $timestampText
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

function Convert-ToArray {
    param(
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return @()
    }

    return @($InputObject)
}

function Show-SnapshotList {
    param(
        [object[]]$Snapshots,
        [string]$CurrentCaseName,
        [string]$BaseFullName,
        [string]$CompareFullName
    )

    if ($Snapshots.Count -eq 0) {
        Write-Host 'Δεν βρέθηκαν snapshot folders ακόμα.' -ForegroundColor Yellow
        return
    }

    for ($i = 0; $i -lt $Snapshots.Count; $i++) {
        $snapshot = $Snapshots[$i]
        $marker = if (-not [string]::IsNullOrWhiteSpace($CurrentCaseName) -and $snapshot.CaseName -eq $CurrentCaseName) { '*' } else { ' ' }
        $title = if (-not [string]::IsNullOrWhiteSpace([string]$snapshot.CaseName) -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.Stage)) {
            "$($snapshot.CaseName) / $($snapshot.Stage)"
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$snapshot.Stage)) {
            [string]$snapshot.Stage
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$snapshot.CaseName)) {
            [string]$snapshot.CaseName
        }
        else {
            [string]$snapshot.Name
        }

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

        Write-Host ("[{0:00}] {1} {2}{3}" -f ($i + 1), $marker, $title, $suffix) -ForegroundColor $titleColor
        Write-Host ("      {0:yyyy-MM-dd HH:mm}" -f ([datetime]$snapshot.Timestamp)) -ForegroundColor DarkGray
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
        $beforeLabel = if (-not [string]::IsNullOrWhiteSpace([string]$BeforeSnapshot.CaseName) -and -not [string]::IsNullOrWhiteSpace([string]$BeforeSnapshot.Stage)) {
            "$($BeforeSnapshot.CaseName) / $($BeforeSnapshot.Stage)"
        }
        else {
            [string]$BeforeSnapshot.Name
        }
        Write-Host ("Base (Before)   : {0}" -f $beforeLabel) -ForegroundColor Red
    }

    if ($null -ne $AfterSnapshot) {
        $afterLabel = if (-not [string]::IsNullOrWhiteSpace([string]$AfterSnapshot.CaseName) -and -not [string]::IsNullOrWhiteSpace([string]$AfterSnapshot.Stage)) {
            "$($AfterSnapshot.CaseName) / $($AfterSnapshot.Stage)"
        }
        else {
            [string]$AfterSnapshot.Name
        }
        Write-Host ("Compare (After) : {0}" -f $afterLabel) -ForegroundColor Green
    }
}

function Select-Snapshot {
    param(
        [string]$Prompt,
        [string]$CurrentCaseName,
        [string]$RootPath,
        [string]$ExcludedFullName,
        [switch]$Chronological,
        [object]$BeforeSnapshot,
        [object]$AfterSnapshot
    )

    while ($true) {
        $snapshots = @(Get-SnapshotFolders -RootPath $RootPath -PreferredCaseName $CurrentCaseName -Chronological:$Chronological)
        if (-not [string]::IsNullOrWhiteSpace($ExcludedFullName)) {
            $snapshots = @($snapshots | Where-Object { $_.FullName -ne $ExcludedFullName })
        }

        if ($snapshots.Count -eq 0) {
            Write-Host 'Δεν υπάρχουν snapshots για επιλογή.' -ForegroundColor Yellow
            return $null
        }

        Write-Section -Title $Prompt
        Show-SelectionPreview -BeforeSnapshot $BeforeSnapshot -AfterSnapshot $AfterSnapshot

        if ([Console]::IsInputRedirected) {
            Show-SnapshotList -Snapshots $snapshots -CurrentCaseName $CurrentCaseName -BaseFullName $(if ($null -ne $BeforeSnapshot) { $BeforeSnapshot.FullName } else { '' }) -CompareFullName $(if ($null -ne $AfterSnapshot) { $AfterSnapshot.FullName } else { '' })
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
                Write-Host ''
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
                $title = if (-not [string]::IsNullOrWhiteSpace([string]$snapshot.CaseName) -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.Stage)) {
                    "$($snapshot.CaseName) / $($snapshot.Stage)"
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$snapshot.Stage)) {
                    [string]$snapshot.Stage
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$snapshot.CaseName)) {
                    [string]$snapshot.CaseName
                }
                else {
                    [string]$snapshot.Name
                }

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
                Write-Host ("      {0:yyyy-MM-dd HH:mm}$eraseLine" -f ([datetime]$snapshot.Timestamp)) -ForegroundColor DarkGray
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

function Expand-RegistryFocusData {
    param(
        [object]$RegistryData
    )

    if ($null -eq $RegistryData) {
        return [pscustomobject]@{
            Keys = @()
            Values = @()
        }
    }

    $keys = foreach ($item in (Convert-ToArray $RegistryData.Keys)) {
        [pscustomobject]@{
            Identity = [string]$item.Identity
            RootName = [string]$item.RootName
            KeyPath = [string]$item.KeyPath
            MatchedTerms = [string]$item.MatchedTerms
            MatchSource = [string]$item.MatchSource
        }
    }

    $values = foreach ($item in (Convert-ToArray $RegistryData.Values)) {
        $identity = [string]$item.Identity
        if ([string]::IsNullOrWhiteSpace($identity)) {
            $identity = ('{0}::{1}' -f ([string]$item.KeyPath), ([string]$item.ValueName))
        }

        [pscustomobject]@{
            Identity = $identity
            RootName = [string]$item.RootName
            KeyPath = [string]$item.KeyPath
            ValueName = [string]$item.ValueName
            ValueKind = [string]$item.ValueKind
            ValueData = [string]$item.ValueData
            MatchedTerms = [string]$item.MatchedTerms
            MatchSource = [string]$item.MatchSource
        }
    }

    return [pscustomobject]@{
        Keys = @($keys | Sort-Object KeyPath)
        Values = @($values | Sort-Object Identity)
    }
}

function Get-MapByProperty {
    param(
        [object[]]$Items,
        [string]$PropertyName
    )

    $map = @{}
    foreach ($item in $Items) {
        $key = $item.$PropertyName
        if ([string]::IsNullOrWhiteSpace([string]$key)) {
            continue
        }

        $map[[string]$key] = $item
    }

    return $map
}

function Compare-NamedObjects {
    param(
        [object[]]$BeforeItems,
        [object[]]$AfterItems,
        [string]$KeyProperty,
        [string[]]$CompareProperties
    )

    $beforeMap = Get-MapByProperty -Items $BeforeItems -PropertyName $KeyProperty
    $afterMap = Get-MapByProperty -Items $AfterItems -PropertyName $KeyProperty

    $added = foreach ($key in $afterMap.Keys) {
        if (-not $beforeMap.ContainsKey($key)) {
            $afterMap[$key]
        }
    }

    $removed = foreach ($key in $beforeMap.Keys) {
        if (-not $afterMap.ContainsKey($key)) {
            $beforeMap[$key]
        }
    }

    $changed = foreach ($key in $afterMap.Keys) {
        if (-not $beforeMap.ContainsKey($key)) {
            continue
        }

        $beforeItem = $beforeMap[$key]
        $afterItem = $afterMap[$key]
        $diffs = @()

        foreach ($property in $CompareProperties) {
            $beforeValue = [string]$beforeItem.$property
            $afterValue = [string]$afterItem.$property
            if ($beforeValue -ne $afterValue) {
                $diffs += [pscustomobject]@{
                    Property = $property
                    Before = $beforeValue
                    After = $afterValue
                }
            }
        }

        if ($diffs.Count -gt 0) {
            [pscustomobject]@{
                Key = $key
                Differences = $diffs
            }
        }
    }

    $unchanged = foreach ($key in $afterMap.Keys) {
        if (-not $beforeMap.ContainsKey($key)) {
            continue
        }

        $beforeItem = $beforeMap[$key]
        $afterItem = $afterMap[$key]
        $hasDifferences = $false

        foreach ($property in $CompareProperties) {
            $beforeValue = [string]$beforeItem.$property
            $afterValue = [string]$afterItem.$property
            if ($beforeValue -ne $afterValue) {
                $hasDifferences = $true
                break
            }
        }

        if (-not $hasDifferences) {
            $afterItem
        }
    }

    [pscustomobject]@{
        Added = @($added | Sort-Object $KeyProperty)
        Removed = @($removed | Sort-Object $KeyProperty)
        Changed = @($changed | Sort-Object Key)
        Unchanged = @($unchanged | Sort-Object $KeyProperty)
    }
}

function Should-IgnoreDevice {
    param(
        [object]$Device
    )

    $friendlyName = [string]$Device.FriendlyName
    $instanceId = [string]$Device.InstanceId

    if ($friendlyName -match 'Hyper-V Remote Desktop' -or $friendlyName -match '^Remote Desktop ') {
        return $true
    }

    $ignorePatterns = @(
        '^VMBUS\\\{F9E9C0D3-B511-4A48-8046-D38079A8830C\}\\',
        '^TERMINPUT_BUS\\',
        '^UMB\\UMB\\',
        '^SWD\\REMOTEDISPLAYENUM\\',
        '^TS_USB_HUB_ENUMERATOR\\'
    )

    foreach ($pattern in $ignorePatterns) {
        if ($instanceId -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-BcdNoiseFilteredLines {
    param(
        [string[]]$Lines,
        [string]$Mode
    )

    $filtered = foreach ($line in $Lines) {
        if ($Mode -eq 'Added') {
            if ($line -match '(?im)^\s*(testsigning|debug|bootdebug|nointegritychecks)\s+(no|off)\s*$') {
                continue
            }
        }

        $line
    }

    return @($filtered)
}

function Get-CertThumbprintSet {
    param(
        [object[]]$Items
    )

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Items) {
        $thumbprint = [string]$item.Thumbprint
        if (-not [string]::IsNullOrWhiteSpace($thumbprint)) {
            [void]$set.Add($thumbprint)
        }
    }

    return $set
}

function Get-CertificateTag {
    param(
        [object]$Certificate,
        [string]$StoreName,
        [System.Collections.Generic.HashSet[string]]$PublisherThumbprints
    )

    $thumbprint = [string]$Certificate.Thumbprint
    $subject = [string]$Certificate.Subject

    if ($StoreName -eq 'TRUSTEDPUBLISHER') {
        return 'PUBLISHER'
    }

    if ($null -ne $PublisherThumbprints -and $PublisherThumbprints.Contains($thumbprint)) {
        return 'LINKED'
    }

    return 'REVIEW'
}

function Get-BcdRelevantLines {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return @()
    }

    $patterns = @(
        'testsigning',
        'loadoptions',
        'nointegritychecks',
        'debug',
        'bootdebug',
        'bootmenupolicy',
        'timeout',
        'default',
        'displayorder'
    )

    return @(Get-Content $Path | Where-Object {
            $line = $_
            foreach ($pattern in $patterns) {
                if ($line -match $pattern) {
                    return $true
                }
            }
            return $false
        })
}

function Write-Section {
    param(
        [string]$Title
    )

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor Cyan
}

function Format-DisplayText {
    param(
        [AllowEmptyString()]
        [string]$Value,
        [int]$MaxLength = 120
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return '(empty)'
    }

    if ($Value.Length -le $MaxLength) {
        return $Value
    }

    return ($Value.Substring(0, $MaxLength) + '...')
}

function Format-UninstallEntryLabel {
    param(
        [object]$Entry
    )

    $displayName = [string]$Entry.DisplayName
    $displayVersion = [string]$Entry.DisplayVersion
    $publisher = [string]$Entry.Publisher

    $parts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($displayName)) {
        $parts.Add($displayName)
    }
    else {
        $parts.Add([string]$Entry.KeyName)
    }

    if (-not [string]::IsNullOrWhiteSpace($displayVersion)) {
        $parts.Add($displayVersion)
    }

    if (-not [string]::IsNullOrWhiteSpace($publisher)) {
        $parts.Add($publisher)
    }

    return ($parts -join ' :: ')
}

function Get-UninstallEntryClassification {
    param(
        [object]$Entry
    )

    $displayName = [string]$Entry.DisplayName
    $publisher = [string]$Entry.Publisher
    $combined = ($displayName + ' ' + $publisher).Trim()

    if ($combined -match '(?i)EdgeWebView|Microsoft Edge WebView') {
        return 'NOISE'
    }

    if ($combined -match '(?i)Sentinel|HASP|Thales|Gemalto|Aladdin|MultiKey|SolidCAM|Mastercam') {
        return 'LIKELY'
    }

    if ($combined -match '(?i)Visual C\+\+|Redistributable|\.NET|ASP\.NET|Desktop Runtime|Runtime') {
        return 'REVIEW'
    }

    if ($publisher -match '(?i)^Microsoft') {
        return 'REVIEW'
    }

    return 'REVIEW'
}

function Get-UninstallEntryColor {
    param(
        [string]$Classification,
        [string]$ChangeKind
    )

    if ($ChangeKind -eq 'Added') {
        return 'Green'
    }

    if ($ChangeKind -eq 'Removed') {
        return 'Red'
    }

    switch ($Classification) {
        'LIKELY' { return 'White' }
        'NOISE' { return 'DarkGray' }
        default { return 'White' }
    }
}

function Get-DiffColor {
    param(
        [string]$ChangeKind
    )

    switch ($ChangeKind) {
        'Added' { return 'Green' }
        'Removed' { return 'Red' }
        default { return 'White' }
    }
}

function Get-UninstallEntryCommandHint {
    param(
        [object]$Entry
    )

    $quiet = [string]$Entry.QuietUninstallString
    $normal = [string]$Entry.UninstallString

    if (-not [string]::IsNullOrWhiteSpace($quiet)) {
        return "QuietUninstallString = $(Format-DisplayText -Value $quiet)"
    }

    if (-not [string]::IsNullOrWhiteSpace($normal)) {
        return "UninstallString = $(Format-DisplayText -Value $normal)"
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Entry.ProductCode)) {
        return "ProductCode = $([string]$Entry.ProductCode)"
    }

    return ''
}

function Convert-ToSafeReportName {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'compare'
    }

    $safeValue = $Value.Trim()
    $safeValue = $safeValue -replace '[\\/:*?"<>|]+', '-'
    $safeValue = $safeValue -replace '\s{2,}', ' '
    $safeValue = $safeValue.Trim(' ', '.', '-')

    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        return 'compare'
    }

    return $safeValue
}

function Get-CompareReportToken {
    param(
        [string]$SnapshotPath,
        [string]$FallbackLabel
    )

    $metadata = Read-JsonFile -Path (Join-Path $SnapshotPath 'metadata.json')
    $caseName = [string](Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'CaseName' -DefaultValue '')
    $stage = [string](Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'Stage' -DefaultValue '')
    $snapshotName = [string](Get-OptionalObjectProperty -InputObject $metadata -PropertyName 'SnapshotName' -DefaultValue '')

    $token = switch ($true) {
        { -not [string]::IsNullOrWhiteSpace($caseName) -and -not [string]::IsNullOrWhiteSpace($stage) } { "$caseName-$stage"; break }
        { -not [string]::IsNullOrWhiteSpace($stage) } { $stage; break }
        { -not [string]::IsNullOrWhiteSpace($snapshotName) -and $snapshotName -ne 'Snapshot' } { $snapshotName; break }
        default { $FallbackLabel }
    }

    $safeToken = Convert-ToSafeReportName -Value $token
    if ($safeToken.Length -gt 20) {
        $safeToken = $safeToken.Substring(0, 20).TrimEnd(' ', '.', '-')
    }

    return $safeToken
}

function Get-ShortStableCompareId {
    param(
        [string]$BeforeSnapshotPath,
        [string]$AfterSnapshotPath
    )

    $identityText = '{0}|{1}' -f ($BeforeSnapshotPath ?? ''), ($AfterSnapshotPath ?? '')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($identityText)
        $hashBytes = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    $hashText = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
    return $hashText.Substring(0, 10)
}

function Add-ReportLine {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [AllowEmptyString()]
        [string]$Text = ''
    )

    $Lines.Add(($Text ?? ''))
}

function Add-ReportSection {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Title
    )

    Add-ReportLine -Lines $Lines
    Add-ReportLine -Lines $Lines -Text $Title
    Add-ReportLine -Lines $Lines -Text ('-' * $Title.Length)
}

function Get-PnpDeviceDetailTextLines {
    param(
        [object]$Device
    )

    $details = @(
        @{ Label = 'InfName'; Value = [string]$Device.InfName },
        @{ Label = 'InfSection'; Value = [string]$Device.DriverInfSection },
        @{ Label = 'Provider'; Value = [string]$Device.DriverProviderName },
        @{ Label = 'MatchingDeviceId'; Value = [string]$Device.MatchingDeviceId },
        @{ Label = 'Service'; Value = [string]$Device.ServiceName },
        @{ Label = 'DriverKey'; Value = [string]$Device.DriverKey },
        @{ Label = 'Enumerator'; Value = [string]$Device.EnumeratorName },
        @{ Label = 'Parent'; Value = [string]$Device.Parent },
        @{ Label = 'ClassGuid'; Value = [string]$Device.ClassGuid },
        @{ Label = 'DriverVersion'; Value = [string]$Device.DriverVersion },
        @{ Label = 'DriverDate'; Value = [string]$Device.DriverDate }
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($detail in $details) {
        if (-not [string]::IsNullOrWhiteSpace($detail.Value)) {
            $lines.Add(("    {0,-16}: {1}" -f $detail.Label, $detail.Value))
        }
    }

    return @($lines)
}

function Get-CommonTextItems {
    param(
        [string[]]$BeforeItems,
        [string[]]$AfterItems
    )

    $beforeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($BeforeItems)) {
        if (-not [string]::IsNullOrWhiteSpace($item)) {
            [void]$beforeSet.Add($item)
        }
    }

    $common = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($AfterItems)) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }

        if ($beforeSet.Contains($item)) {
            $common.Add($item)
        }
    }

    return @($common | Sort-Object -Unique)
}

function New-CompareReportPath {
    param(
        [string]$RootPath,
        [string]$BeforeSnapshotPath,
        [string]$AfterSnapshotPath
    )

    $compareId = Get-ShortStableCompareId -BeforeSnapshotPath $BeforeSnapshotPath -AfterSnapshotPath $AfterSnapshotPath
    $folderName = 'cmp__{0}' -f $compareId
    $targetPath = Join-Path $RootPath $folderName
    New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
    return $targetPath
}

function Write-PnpDeviceDetailLines {
    param(
        [object]$Device
    )

    foreach ($detail in @(
            @{ Label = 'InfName'; Value = [string]$Device.InfName },
            @{ Label = 'Driver'; Value = [string]$Device.DriverName },
            @{ Label = 'Service'; Value = [string]$Device.ServiceName },
            @{ Label = 'Provider'; Value = [string]$Device.DriverProviderName },
            @{ Label = 'Section'; Value = [string]$Device.DriverInfSection },
            @{ Label = 'MatchId'; Value = [string]$Device.MatchingDeviceId },
            @{ Label = 'DriverKey'; Value = [string]$Device.DriverKey },
            @{ Label = 'ClassGuid'; Value = [string]$Device.ClassGuid },
            @{ Label = 'Enumerator'; Value = [string]$Device.EnumeratorName },
            @{ Label = 'Parent'; Value = [string]$Device.Parent },
            @{ Label = 'DriverVersion'; Value = [string]$Device.DriverVersion },
            @{ Label = 'DriverDate'; Value = [string]$Device.DriverDate }
        )) {
        if (-not [string]::IsNullOrWhiteSpace($detail.Value)) {
            Write-Host ("    {0,-13}: {1}" -f $detail.Label, $detail.Value) -ForegroundColor DarkGray
        }
    }
}

function Expand-UninstallEntries {
    param(
        [object[]]$Entries
    )

    $expanded = foreach ($entry in (Convert-ToArray $Entries)) {
        [pscustomobject]@{
            Identity = [string](Get-OptionalObjectProperty -InputObject $entry -PropertyName 'Identity' -DefaultValue '')
            RegistryKeyPath = [string](Get-OptionalObjectProperty -InputObject $entry -PropertyName 'RegistryKeyPath' -DefaultValue '')
            RootPath = [string](Get-OptionalObjectProperty -InputObject $entry -PropertyName 'RootPath' -DefaultValue '')
            KeyName = [string](Get-OptionalObjectProperty -InputObject $entry -PropertyName 'KeyName' -DefaultValue '')
            ProductCode = [string](Get-OptionalObjectProperty -InputObject $entry -PropertyName 'ProductCode' -DefaultValue '')
            DisplayName = [string](Get-OptionalObjectProperty -InputObject $entry -PropertyName 'DisplayName' -DefaultValue '')
            DisplayVersion = [string](Get-OptionalObjectProperty -InputObject $entry -PropertyName 'DisplayVersion' -DefaultValue '')
            Publisher = [string](Get-OptionalObjectProperty -InputObject $entry -PropertyName 'Publisher' -DefaultValue '')
            InstallLocation = [string](Get-OptionalObjectProperty -InputObject $entry -PropertyName 'InstallLocation' -DefaultValue '')
            InstallSource = [string](Get-OptionalObjectProperty -InputObject $entry -PropertyName 'InstallSource' -DefaultValue '')
            UninstallString = [string](Get-OptionalObjectProperty -InputObject $entry -PropertyName 'UninstallString' -DefaultValue '')
            QuietUninstallString = [string](Get-OptionalObjectProperty -InputObject $entry -PropertyName 'QuietUninstallString' -DefaultValue '')
            WindowsInstaller = [string](Get-OptionalObjectProperty -InputObject $entry -PropertyName 'WindowsInstaller' -DefaultValue '')
        }
    }

    return @($expanded)
}

function Expand-PnpDevices {
    param(
        [object[]]$Devices
    )

    $expanded = foreach ($device in (Convert-ToArray $Devices)) {
        [pscustomobject]@{
            Class = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'Class' -DefaultValue '')
            FriendlyName = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'FriendlyName' -DefaultValue '')
            InstanceId = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'InstanceId' -DefaultValue '')
            Present = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'Present' -DefaultValue '')
            Problem = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'Problem' -DefaultValue '')
            Status = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'Status' -DefaultValue '')
            InfName = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'InfName' -DefaultValue '')
            DriverName = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'DriverName' -DefaultValue '')
            Manufacturer = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'Manufacturer' -DefaultValue '')
            DriverProviderName = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'DriverProviderName' -DefaultValue '')
            MatchingDeviceId = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'MatchingDeviceId' -DefaultValue '')
            ServiceName = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'ServiceName' -DefaultValue '')
            DriverInfSection = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'DriverInfSection' -DefaultValue '')
            DriverKey = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'DriverKey' -DefaultValue '')
            ClassGuid = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'ClassGuid' -DefaultValue '')
            EnumeratorName = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'EnumeratorName' -DefaultValue '')
            Parent = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'Parent' -DefaultValue '')
            HardwareIds = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'HardwareIds' -DefaultValue '')
            CompatibleIds = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'CompatibleIds' -DefaultValue '')
            DriverVersion = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'DriverVersion' -DefaultValue '')
            DriverDate = [string](Get-OptionalObjectProperty -InputObject $device -PropertyName 'DriverDate' -DefaultValue '')
        }
    }

    return @($expanded)
}

$selectedBefore = $null
$selectedAfter = $null

$BeforePath = Resolve-SnapshotInputPath -Path $BeforePath -RootPath $SnapshotsRoot
$AfterPath = Resolve-SnapshotInputPath -Path $AfterPath -RootPath $SnapshotsRoot

if ([string]::IsNullOrWhiteSpace($BeforePath)) {
    $selectedBefore = Select-Snapshot -Prompt 'Διάλεξε baseline snapshot' -CurrentCaseName $CaseName -RootPath $SnapshotsRoot -Chronological
    if ($null -eq $selectedBefore) {
        Write-Host 'Η επιλογή baseline snapshot ακυρώθηκε.' -ForegroundColor Yellow
        return
    }

    $BeforePath = $selectedBefore.FullName
}

if ([string]::IsNullOrWhiteSpace($AfterPath)) {
    $selectedAfter = Select-Snapshot -Prompt 'Διάλεξε δεύτερο snapshot για compare' -CurrentCaseName $CaseName -RootPath $SnapshotsRoot -ExcludedFullName $BeforePath -Chronological -BeforeSnapshot $selectedBefore
    if ($null -eq $selectedAfter) {
        Write-Host 'Η επιλογή compare snapshot ακυρώθηκε.' -ForegroundColor Yellow
        return
    }

    $AfterPath = $selectedAfter.FullName
}

$BeforePath = Assert-SnapshotPathReadable -Path $BeforePath -Label 'Before snapshot'
$AfterPath = Assert-SnapshotPathReadable -Path $AfterPath -Label 'After snapshot'

$beforeMetadata = Read-JsonFile -Path (Join-Path $BeforePath 'metadata.json')
$afterMetadata = Read-JsonFile -Path (Join-Path $AfterPath 'metadata.json')

$beforePackages = Convert-ToArray (Read-JsonFile -Path (Join-Path $BeforePath 'driver-packages.json'))
$afterPackages = Convert-ToArray (Read-JsonFile -Path (Join-Path $AfterPath 'driver-packages.json'))
$beforeServices = Convert-ToArray (Read-JsonFile -Path (Join-Path $BeforePath 'services.registry.json'))
$afterServices = Convert-ToArray (Read-JsonFile -Path (Join-Path $AfterPath 'services.registry.json'))
$beforeDevices = Expand-PnpDevices -Devices (Convert-ToArray (Read-JsonFile -Path (Join-Path $BeforePath 'pnp-devices.json')))
$afterDevices = Expand-PnpDevices -Devices (Convert-ToArray (Read-JsonFile -Path (Join-Path $AfterPath 'pnp-devices.json')))
$beforeRootCerts = Convert-ToArray (Read-JsonFile -Path (Join-Path $BeforePath 'cert-root.json'))
$afterRootCerts = Convert-ToArray (Read-JsonFile -Path (Join-Path $AfterPath 'cert-root.json'))
$beforePublisherCerts = Convert-ToArray (Read-JsonFile -Path (Join-Path $BeforePath 'cert-trustedpublisher.json'))
$afterPublisherCerts = Convert-ToArray (Read-JsonFile -Path (Join-Path $AfterPath 'cert-trustedpublisher.json'))
$beforeRegistryFocus = Expand-RegistryFocusData -RegistryData (Read-JsonFile -Path (Join-Path $BeforePath 'registry-focus.json'))
$afterRegistryFocus = Expand-RegistryFocusData -RegistryData (Read-JsonFile -Path (Join-Path $AfterPath 'registry-focus.json'))
$beforeFiles = Convert-ToArray (Read-JsonFile -Path (Join-Path $BeforePath 'focus-files.json'))
$afterFiles = Convert-ToArray (Read-JsonFile -Path (Join-Path $AfterPath 'focus-files.json'))
$beforeUninstallEntries = Expand-UninstallEntries -Entries (Convert-ToArray (Read-JsonFile -Path (Join-Path $BeforePath 'uninstall-entries.json')))
$afterUninstallEntries = Expand-UninstallEntries -Entries (Convert-ToArray (Read-JsonFile -Path (Join-Path $AfterPath 'uninstall-entries.json')))
$beforeSetupApi = Read-JsonFile -Path (Join-Path $BeforePath 'setupapi.dev-log.json')
$afterSetupApi = Read-JsonFile -Path (Join-Path $AfterPath 'setupapi.dev-log.json')

$packageDiff = Compare-NamedObjects -BeforeItems $beforePackages -AfterItems $afterPackages -KeyProperty 'PublishedName' -CompareProperties @('OriginalName', 'ProviderName', 'DriverVersion', 'SignerName')
$serviceDiff = Compare-NamedObjects -BeforeItems $beforeServices -AfterItems $afterServices -KeyProperty 'Name' -CompareProperties @('DisplayName', 'ImagePath', 'Start', 'Type', 'ErrorControl', 'Group')
$deviceDiff = Compare-NamedObjects -BeforeItems $beforeDevices -AfterItems $afterDevices -KeyProperty 'InstanceId' -CompareProperties @('Class', 'FriendlyName', 'Present', 'Problem', 'Status', 'InfName', 'DriverName', 'Manufacturer', 'DriverProviderName', 'MatchingDeviceId', 'ServiceName', 'DriverInfSection', 'DriverKey', 'ClassGuid', 'EnumeratorName', 'Parent', 'DriverVersion', 'DriverDate')
$rootCertDiff = Compare-NamedObjects -BeforeItems $beforeRootCerts -AfterItems $afterRootCerts -KeyProperty 'Thumbprint' -CompareProperties @('Subject', 'Issuer', 'NotAfter')
$publisherCertDiff = Compare-NamedObjects -BeforeItems $beforePublisherCerts -AfterItems $afterPublisherCerts -KeyProperty 'Thumbprint' -CompareProperties @('Subject', 'Issuer', 'NotAfter')
$registryKeyDiff = Compare-NamedObjects -BeforeItems $beforeRegistryFocus.Keys -AfterItems $afterRegistryFocus.Keys -KeyProperty 'Identity' -CompareProperties @()
$registryValueDiff = Compare-NamedObjects -BeforeItems $beforeRegistryFocus.Values -AfterItems $afterRegistryFocus.Values -KeyProperty 'Identity' -CompareProperties @('RootName', 'KeyPath', 'ValueName', 'ValueKind', 'ValueData')
$fileDiff = Compare-NamedObjects -BeforeItems $beforeFiles -AfterItems $afterFiles -KeyProperty 'FullName' -CompareProperties @('Length', 'Sha256', 'LastWriteTime')
$uninstallEntryDiff = Compare-NamedObjects -BeforeItems $beforeUninstallEntries -AfterItems $afterUninstallEntries -KeyProperty 'Identity' -CompareProperties @('DisplayName', 'DisplayVersion', 'Publisher', 'InstallLocation', 'InstallSource', 'UninstallString', 'QuietUninstallString', 'WindowsInstaller', 'ProductCode')
$publisherAddedThumbprints = Get-CertThumbprintSet -Items $publisherCertDiff.Added
$publisherRemovedThumbprints = Get-CertThumbprintSet -Items $publisherCertDiff.Removed

$beforeBcd = Get-BcdRelevantLines -Path (Join-Path $BeforePath 'bcdedit.enum.all.txt')
$afterBcd = Get-BcdRelevantLines -Path (Join-Path $AfterPath 'bcdedit.enum.all.txt')
$bcdAdded = @(Compare-Object -ReferenceObject @($beforeBcd) -DifferenceObject @($afterBcd) -PassThru | Where-Object { $_.SideIndicator -eq '=>' })
$bcdRemoved = @(Compare-Object -ReferenceObject @($beforeBcd) -DifferenceObject @($afterBcd) -PassThru | Where-Object { $_.SideIndicator -eq '<=' })
$bcdAdded = @(Get-BcdNoiseFilteredLines -Lines $bcdAdded -Mode 'Added')
$bcdRemoved = @(Get-BcdNoiseFilteredLines -Lines $bcdRemoved -Mode 'Removed')

$deviceAdded = @($deviceDiff.Added | Where-Object { -not (Should-IgnoreDevice -Device $_) })
$deviceRemoved = @($deviceDiff.Removed | Where-Object { -not (Should-IgnoreDevice -Device $_) })
$deviceChanged = @($deviceDiff.Changed | Where-Object {
        $beforeDevice = [pscustomobject]@{
            FriendlyName = $_.Differences | Where-Object { $_.Property -eq 'FriendlyName' } | Select-Object -First 1 -ExpandProperty Before -ErrorAction SilentlyContinue
        }
        $afterDevice = [pscustomobject]@{
            FriendlyName = $_.Differences | Where-Object { $_.Property -eq 'FriendlyName' } | Select-Object -First 1 -ExpandProperty After -ErrorAction SilentlyContinue
            InstanceId = $_.Key
        }

        -not (Should-IgnoreDevice -Device ([pscustomobject]@{ FriendlyName = $afterDevice.FriendlyName; InstanceId = $_.Key }))
    })
$deviceUnchanged = @($deviceDiff.Unchanged | Where-Object { -not (Should-IgnoreDevice -Device $_) })

$commonBcd = @(Get-CommonTextItems -BeforeItems $beforeBcd -AfterItems $afterBcd)
$reportOutputPath = New-CompareReportPath -RootPath $CompareOutputRoot -BeforeSnapshotPath $BeforePath -AfterSnapshotPath $AfterPath
$fullReportLines = [System.Collections.Generic.List[string]]::new()
$differenceReportLines = [System.Collections.Generic.List[string]]::new()
$similarityReportLines = [System.Collections.Generic.List[string]]::new()

foreach ($reportLines in @($fullReportLines, $differenceReportLines, $similarityReportLines)) {
    Add-ReportLine -Lines $reportLines -Text 'Driver Snapshot Compare'
    Add-ReportLine -Lines $reportLines -Text '-----------------------'
    Add-ReportLine -Lines $reportLines -Text "Before : $BeforePath"
    Add-ReportLine -Lines $reportLines -Text "After  : $AfterPath"
    Add-ReportLine -Lines $reportLines -Text ("Before mode : {0}" -f ([string](Get-OptionalObjectProperty -InputObject $beforeMetadata -PropertyName 'SnapshotMode' -DefaultValue 'Full')))
    Add-ReportLine -Lines $reportLines -Text ("After mode  : {0}" -f ([string](Get-OptionalObjectProperty -InputObject $afterMetadata -PropertyName 'SnapshotMode' -DefaultValue 'Full')))
}

Add-ReportSection -Lines $differenceReportLines -Title 'Driver Packages'
if ($packageDiff.Added.Count -eq 0 -and $packageDiff.Removed.Count -eq 0 -and $packageDiff.Changed.Count -eq 0) {
    Add-ReportLine -Lines $differenceReportLines -Text 'No driver package changes detected.'
}
else {
    foreach ($item in $packageDiff.Added) { Add-ReportLine -Lines $differenceReportLines -Text "+ $($item.PublishedName) :: $($item.OriginalName) :: $($item.ProviderName)" }
    foreach ($item in $packageDiff.Removed) { Add-ReportLine -Lines $differenceReportLines -Text "- $($item.PublishedName) :: $($item.OriginalName) :: $($item.ProviderName)" }
    foreach ($item in $packageDiff.Changed) {
        Add-ReportLine -Lines $differenceReportLines -Text "* $($item.Key)"
        foreach ($diff in $item.Differences) {
            Add-ReportLine -Lines $differenceReportLines -Text "    $($diff.Property): '$($diff.Before)' -> '$($diff.After)'"
        }
    }
}

Add-ReportSection -Lines $similarityReportLines -Title 'Driver Packages'
if ($packageDiff.Unchanged.Count -eq 0) {
    Add-ReportLine -Lines $similarityReportLines -Text 'No unchanged driver packages detected.'
}
else {
    foreach ($item in $packageDiff.Unchanged) { Add-ReportLine -Lines $similarityReportLines -Text "= $($item.PublishedName) :: $($item.OriginalName) :: $($item.ProviderName)" }
}

Add-ReportSection -Lines $differenceReportLines -Title 'Services'
if ($serviceDiff.Added.Count -eq 0 -and $serviceDiff.Removed.Count -eq 0 -and $serviceDiff.Changed.Count -eq 0) {
    Add-ReportLine -Lines $differenceReportLines -Text 'No service changes detected.'
}
else {
    foreach ($item in $serviceDiff.Added) { Add-ReportLine -Lines $differenceReportLines -Text "+ $($item.Name) :: $($item.ImagePath)" }
    foreach ($item in $serviceDiff.Removed) { Add-ReportLine -Lines $differenceReportLines -Text "- $($item.Name) :: $($item.ImagePath)" }
    foreach ($item in $serviceDiff.Changed) {
        Add-ReportLine -Lines $differenceReportLines -Text "* $($item.Key)"
        foreach ($diff in $item.Differences) {
            Add-ReportLine -Lines $differenceReportLines -Text "    $($diff.Property): '$($diff.Before)' -> '$($diff.After)'"
        }
    }
}

Add-ReportSection -Lines $similarityReportLines -Title 'Services'
if ($serviceDiff.Unchanged.Count -eq 0) {
    Add-ReportLine -Lines $similarityReportLines -Text 'No unchanged services detected.'
}
else {
    foreach ($item in $serviceDiff.Unchanged) { Add-ReportLine -Lines $similarityReportLines -Text "= $($item.Name) :: $($item.ImagePath)" }
}

Add-ReportSection -Lines $differenceReportLines -Title 'Installed Applications'
if ($uninstallEntryDiff.Added.Count -eq 0 -and $uninstallEntryDiff.Removed.Count -eq 0 -and $uninstallEntryDiff.Changed.Count -eq 0) {
    Add-ReportLine -Lines $differenceReportLines -Text 'No uninstall-entry changes detected.'
}
else {
    foreach ($item in $uninstallEntryDiff.Added) {
        $classification = Get-UninstallEntryClassification -Entry $item
        Add-ReportLine -Lines $differenceReportLines -Text "+ [$classification] $(Format-UninstallEntryLabel -Entry $item)"
        $commandHint = Get-UninstallEntryCommandHint -Entry $item
        if (-not [string]::IsNullOrWhiteSpace($commandHint)) { Add-ReportLine -Lines $differenceReportLines -Text "    $commandHint" }
    }
    foreach ($item in $uninstallEntryDiff.Removed) {
        $classification = Get-UninstallEntryClassification -Entry $item
        Add-ReportLine -Lines $differenceReportLines -Text "- [$classification] $(Format-UninstallEntryLabel -Entry $item)"
    }
    foreach ($item in $uninstallEntryDiff.Changed) {
        $afterEntry = $afterUninstallEntries | Where-Object { $_.Identity -eq $item.Key } | Select-Object -First 1
        $beforeEntry = $beforeUninstallEntries | Where-Object { $_.Identity -eq $item.Key } | Select-Object -First 1
        $entryForClass = if ($null -ne $afterEntry) { $afterEntry } else { $beforeEntry }
        $classification = Get-UninstallEntryClassification -Entry $entryForClass
        Add-ReportLine -Lines $differenceReportLines -Text "* [$classification] $($item.Key)"
        foreach ($diff in $item.Differences) {
            $beforeValue = if ($diff.Property -match 'UninstallString') { Format-DisplayText -Value $diff.Before } else { $diff.Before }
            $afterValue = if ($diff.Property -match 'UninstallString') { Format-DisplayText -Value $diff.After } else { $diff.After }
            Add-ReportLine -Lines $differenceReportLines -Text "    $($diff.Property): '$beforeValue' -> '$afterValue'"
        }
    }
}

Add-ReportSection -Lines $similarityReportLines -Title 'Installed Applications'
if ($uninstallEntryDiff.Unchanged.Count -eq 0) {
    Add-ReportLine -Lines $similarityReportLines -Text 'No unchanged uninstall entries detected.'
}
else {
    foreach ($item in $uninstallEntryDiff.Unchanged) {
        $classification = Get-UninstallEntryClassification -Entry $item
        Add-ReportLine -Lines $similarityReportLines -Text "= [$classification] $(Format-UninstallEntryLabel -Entry $item)"
    }
}

Add-ReportSection -Lines $differenceReportLines -Title 'Focused Registry'
$hasRegistryChanges = $registryKeyDiff.Added.Count -gt 0 -or
    $registryKeyDiff.Removed.Count -gt 0 -or
    $registryValueDiff.Added.Count -gt 0 -or
    $registryValueDiff.Removed.Count -gt 0 -or
    $registryValueDiff.Changed.Count -gt 0
if (-not $hasRegistryChanges) {
    Add-ReportLine -Lines $differenceReportLines -Text 'No focused registry changes detected.'
}
else {
    foreach ($item in $registryKeyDiff.Added) { Add-ReportLine -Lines $differenceReportLines -Text "+ KEY :: $($item.KeyPath)" }
    foreach ($item in $registryKeyDiff.Removed) { Add-ReportLine -Lines $differenceReportLines -Text "- KEY :: $($item.KeyPath)" }
    foreach ($item in $registryValueDiff.Added) { Add-ReportLine -Lines $differenceReportLines -Text "+ VALUE :: $($item.KeyPath) :: [$($item.ValueName)] = $(Format-DisplayText -Value $item.ValueData)" }
    foreach ($item in $registryValueDiff.Removed) { Add-ReportLine -Lines $differenceReportLines -Text "- VALUE :: $($item.KeyPath) :: [$($item.ValueName)] = $(Format-DisplayText -Value $item.ValueData)" }
    foreach ($item in $registryValueDiff.Changed) {
        Add-ReportLine -Lines $differenceReportLines -Text "* VALUE :: $($item.Key)"
        foreach ($diff in $item.Differences) {
            if ($diff.Property -eq 'ValueData') {
                Add-ReportLine -Lines $differenceReportLines -Text "    $($diff.Property): '$(Format-DisplayText -Value $diff.Before)' -> '$(Format-DisplayText -Value $diff.After)'"
            }
            else {
                Add-ReportLine -Lines $differenceReportLines -Text "    $($diff.Property): '$($diff.Before)' -> '$($diff.After)'"
            }
        }
    }
}

Add-ReportSection -Lines $similarityReportLines -Title 'Focused Registry'
if ($registryKeyDiff.Unchanged.Count -eq 0 -and $registryValueDiff.Unchanged.Count -eq 0) {
    Add-ReportLine -Lines $similarityReportLines -Text 'No unchanged focused registry items detected.'
}
else {
    foreach ($item in $registryKeyDiff.Unchanged) { Add-ReportLine -Lines $similarityReportLines -Text "= KEY :: $($item.KeyPath)" }
    foreach ($item in $registryValueDiff.Unchanged) { Add-ReportLine -Lines $similarityReportLines -Text "= VALUE :: $($item.KeyPath) :: [$($item.ValueName)] = $(Format-DisplayText -Value $item.ValueData)" }
}

Add-ReportSection -Lines $differenceReportLines -Title 'PnP Devices'
if ($deviceAdded.Count -eq 0 -and $deviceRemoved.Count -eq 0 -and $deviceChanged.Count -eq 0) {
    Add-ReportLine -Lines $differenceReportLines -Text 'No PnP device changes detected.'
}
else {
    foreach ($item in $deviceAdded) {
        Add-ReportLine -Lines $differenceReportLines -Text "+ $($item.InstanceId) :: $($item.FriendlyName)"
        foreach ($line in @(Get-PnpDeviceDetailTextLines -Device $item)) { Add-ReportLine -Lines $differenceReportLines -Text $line }
    }
    foreach ($item in $deviceRemoved) {
        Add-ReportLine -Lines $differenceReportLines -Text "- $($item.InstanceId) :: $($item.FriendlyName)"
        foreach ($line in @(Get-PnpDeviceDetailTextLines -Device $item)) { Add-ReportLine -Lines $differenceReportLines -Text $line }
    }
    foreach ($item in $deviceChanged) {
        Add-ReportLine -Lines $differenceReportLines -Text "* $($item.Key)"
        foreach ($diff in $item.Differences) {
            Add-ReportLine -Lines $differenceReportLines -Text "    $($diff.Property): '$($diff.Before)' -> '$($diff.After)'"
        }
    }
}

Add-ReportSection -Lines $similarityReportLines -Title 'PnP Devices'
if ($deviceUnchanged.Count -eq 0) {
    Add-ReportLine -Lines $similarityReportLines -Text 'No unchanged PnP devices detected.'
}
else {
    foreach ($item in $deviceUnchanged) {
        Add-ReportLine -Lines $similarityReportLines -Text "= $($item.InstanceId) :: $($item.FriendlyName)"
        foreach ($line in @(Get-PnpDeviceDetailTextLines -Device $item)) { Add-ReportLine -Lines $similarityReportLines -Text $line }
    }
}

Add-ReportSection -Lines $differenceReportLines -Title 'Certificates'
$certChangeCount = $rootCertDiff.Added.Count + $rootCertDiff.Removed.Count + $publisherCertDiff.Added.Count + $publisherCertDiff.Removed.Count
if ($certChangeCount -eq 0) {
    Add-ReportLine -Lines $differenceReportLines -Text 'No LocalMachine certificate additions/removals detected.'
}
else {
    foreach ($item in $rootCertDiff.Added) {
        $tag = Get-CertificateTag -Certificate $item -StoreName 'ROOT' -PublisherThumbprints $publisherAddedThumbprints
        Add-ReportLine -Lines $differenceReportLines -Text "+ ROOT :: [$tag] $($item.Thumbprint) :: $($item.Subject)"
    }
    foreach ($item in $rootCertDiff.Removed) {
        $tag = Get-CertificateTag -Certificate $item -StoreName 'ROOT' -PublisherThumbprints $publisherRemovedThumbprints
        Add-ReportLine -Lines $differenceReportLines -Text "- ROOT :: [$tag] $($item.Thumbprint) :: $($item.Subject)"
    }
    foreach ($item in $publisherCertDiff.Added) {
        $tag = Get-CertificateTag -Certificate $item -StoreName 'TRUSTEDPUBLISHER' -PublisherThumbprints $publisherAddedThumbprints
        Add-ReportLine -Lines $differenceReportLines -Text "+ TRUSTEDPUBLISHER :: [$tag] $($item.Thumbprint) :: $($item.Subject)"
    }
    foreach ($item in $publisherCertDiff.Removed) {
        $tag = Get-CertificateTag -Certificate $item -StoreName 'TRUSTEDPUBLISHER' -PublisherThumbprints $publisherRemovedThumbprints
        Add-ReportLine -Lines $differenceReportLines -Text "- TRUSTEDPUBLISHER :: [$tag] $($item.Thumbprint) :: $($item.Subject)"
    }
}

Add-ReportSection -Lines $similarityReportLines -Title 'Certificates'
if ($rootCertDiff.Unchanged.Count -eq 0 -and $publisherCertDiff.Unchanged.Count -eq 0) {
    Add-ReportLine -Lines $similarityReportLines -Text 'No unchanged LocalMachine certificate items detected.'
}
else {
    foreach ($item in $rootCertDiff.Unchanged) { Add-ReportLine -Lines $similarityReportLines -Text "= ROOT :: $($item.Thumbprint) :: $($item.Subject)" }
    foreach ($item in $publisherCertDiff.Unchanged) { Add-ReportLine -Lines $similarityReportLines -Text "= TRUSTEDPUBLISHER :: $($item.Thumbprint) :: $($item.Subject)" }
}

Add-ReportSection -Lines $differenceReportLines -Title 'Focused Files'
if ($fileDiff.Added.Count -eq 0 -and $fileDiff.Removed.Count -eq 0 -and $fileDiff.Changed.Count -eq 0) {
    Add-ReportLine -Lines $differenceReportLines -Text 'No focused file changes detected.'
}
else {
    foreach ($item in $fileDiff.Added) { Add-ReportLine -Lines $differenceReportLines -Text "+ $($item.FullName)" }
    foreach ($item in $fileDiff.Removed) { Add-ReportLine -Lines $differenceReportLines -Text "- $($item.FullName)" }
    foreach ($item in $fileDiff.Changed) {
        Add-ReportLine -Lines $differenceReportLines -Text "* $($item.Key)"
        foreach ($diff in $item.Differences) {
            Add-ReportLine -Lines $differenceReportLines -Text "    $($diff.Property): '$($diff.Before)' -> '$($diff.After)'"
        }
    }
}

Add-ReportSection -Lines $similarityReportLines -Title 'Focused Files'
if ($fileDiff.Unchanged.Count -eq 0) {
    Add-ReportLine -Lines $similarityReportLines -Text 'No unchanged focused files detected.'
}
else {
    foreach ($item in $fileDiff.Unchanged) { Add-ReportLine -Lines $similarityReportLines -Text "= $($item.FullName)" }
}

Add-ReportSection -Lines $differenceReportLines -Title 'BCD Changes'
if ($bcdAdded.Count -eq 0 -and $bcdRemoved.Count -eq 0) {
    Add-ReportLine -Lines $differenceReportLines -Text 'No tracked BCD changes detected.'
}
else {
    foreach ($line in $bcdAdded) { Add-ReportLine -Lines $differenceReportLines -Text "+ $line" }
    foreach ($line in $bcdRemoved) { Add-ReportLine -Lines $differenceReportLines -Text "- $line" }
}

Add-ReportSection -Lines $similarityReportLines -Title 'BCD Changes'
if ($commonBcd.Count -eq 0) {
    Add-ReportLine -Lines $similarityReportLines -Text 'No unchanged tracked BCD lines detected.'
}
else {
    foreach ($line in $commonBcd) { Add-ReportLine -Lines $similarityReportLines -Text "= $line" }
}

Add-ReportSection -Lines $differenceReportLines -Title 'SetupAPI Log'
if ($beforeSetupApi -and $afterSetupApi) {
    Add-ReportLine -Lines $differenceReportLines -Text "Before size : $($beforeSetupApi.Length)"
    Add-ReportLine -Lines $differenceReportLines -Text "After size  : $($afterSetupApi.Length)"
    Add-ReportLine -Lines $differenceReportLines -Text "Before time : $($beforeSetupApi.LastWriteTime)"
    Add-ReportLine -Lines $differenceReportLines -Text "After time  : $($afterSetupApi.LastWriteTime)"
}
else {
    Add-ReportLine -Lines $differenceReportLines -Text 'SetupAPI metadata was not available in both snapshots.'
}

Add-ReportSection -Lines $similarityReportLines -Title 'SetupAPI Log'
if ($beforeSetupApi -and $afterSetupApi -and [string]$beforeSetupApi.Length -eq [string]$afterSetupApi.Length -and [string]$beforeSetupApi.LastWriteTime -eq [string]$afterSetupApi.LastWriteTime) {
    Add-ReportLine -Lines $similarityReportLines -Text "Size/time unchanged :: $($afterSetupApi.Length) :: $($afterSetupApi.LastWriteTime)"
}
else {
    Add-ReportLine -Lines $similarityReportLines -Text 'No unchanged SetupAPI metadata summary detected.'
}

foreach ($line in $differenceReportLines) { $fullReportLines.Add($line) }
Add-ReportLine -Lines $fullReportLines
Add-ReportLine -Lines $fullReportLines -Text 'Similarities'
Add-ReportLine -Lines $fullReportLines -Text '------------'
foreach ($line in $similarityReportLines | Select-Object -Skip 6) { $fullReportLines.Add($line) }

while ($fullReportLines.Count -gt 6 -and
    $fullReportLines[0] -eq 'Driver Snapshot Compare' -and
    $fullReportLines[6] -eq 'Driver Snapshot Compare') {
    $fullReportLines.RemoveRange(0, 6)
}

$fullReportPath = Join-Path $reportOutputPath 'full-report.txt'
$differenceReportPath = Join-Path $reportOutputPath 'differences-only.txt'
$similarityReportPath = Join-Path $reportOutputPath 'similarities-only.txt'
$fullReportLines | Set-Content -Path $fullReportPath -Encoding utf8
$differenceReportLines | Set-Content -Path $differenceReportPath -Encoding utf8
$similarityReportLines | Set-Content -Path $similarityReportPath -Encoding utf8

Write-Host ''
Write-Host 'Driver Snapshot Compare' -ForegroundColor Green
Write-Host '-----------------------' -ForegroundColor Green
Write-Host "Before : $BeforePath"
Write-Host "After  : $AfterPath"

Write-Section -Title 'Driver Packages'
if ($packageDiff.Added.Count -eq 0 -and $packageDiff.Removed.Count -eq 0 -and $packageDiff.Changed.Count -eq 0) {
    Write-Host 'No driver package changes detected.'
}
else {
    foreach ($item in $packageDiff.Added) {
        Write-Host "+ $($item.PublishedName) :: $($item.OriginalName) :: $($item.ProviderName)" -ForegroundColor (Get-DiffColor -ChangeKind 'Added')
    }
    foreach ($item in $packageDiff.Removed) {
        Write-Host "- $($item.PublishedName) :: $($item.OriginalName) :: $($item.ProviderName)" -ForegroundColor (Get-DiffColor -ChangeKind 'Removed')
    }
    foreach ($item in $packageDiff.Changed) {
        Write-Host "* $($item.Key)" -ForegroundColor White
        foreach ($diff in $item.Differences) {
            Write-Host "    $($diff.Property): '$($diff.Before)' -> '$($diff.After)'" -ForegroundColor DarkGray
        }
    }
}

Write-Section -Title 'Services'
if ($serviceDiff.Added.Count -eq 0 -and $serviceDiff.Removed.Count -eq 0 -and $serviceDiff.Changed.Count -eq 0) {
    Write-Host 'No service changes detected.'
}
else {
    foreach ($item in $serviceDiff.Added) {
        Write-Host "+ $($item.Name) :: $($item.ImagePath)" -ForegroundColor (Get-DiffColor -ChangeKind 'Added')
    }
    foreach ($item in $serviceDiff.Removed) {
        Write-Host "- $($item.Name) :: $($item.ImagePath)" -ForegroundColor (Get-DiffColor -ChangeKind 'Removed')
    }
    foreach ($item in $serviceDiff.Changed) {
        Write-Host "* $($item.Key)" -ForegroundColor White
        foreach ($diff in $item.Differences) {
            Write-Host "    $($diff.Property): '$($diff.Before)' -> '$($diff.After)'" -ForegroundColor DarkGray
        }
    }
}

Write-Section -Title 'Installed Applications'
if ($uninstallEntryDiff.Added.Count -eq 0 -and $uninstallEntryDiff.Removed.Count -eq 0 -and $uninstallEntryDiff.Changed.Count -eq 0) {
    Write-Host 'No uninstall-entry changes detected.'
}
else {
    foreach ($item in $uninstallEntryDiff.Added) {
        $classification = Get-UninstallEntryClassification -Entry $item
        Write-Host "+ [$classification] $(Format-UninstallEntryLabel -Entry $item)" -ForegroundColor (Get-UninstallEntryColor -Classification $classification -ChangeKind 'Added')
        $commandHint = Get-UninstallEntryCommandHint -Entry $item
        if (-not [string]::IsNullOrWhiteSpace($commandHint)) {
            Write-Host "    $commandHint" -ForegroundColor DarkGray
        }
    }
    foreach ($item in $uninstallEntryDiff.Removed) {
        $classification = Get-UninstallEntryClassification -Entry $item
        Write-Host "- [$classification] $(Format-UninstallEntryLabel -Entry $item)" -ForegroundColor (Get-UninstallEntryColor -Classification $classification -ChangeKind 'Removed')
    }
    foreach ($item in $uninstallEntryDiff.Changed) {
        $afterEntry = $afterUninstallEntries | Where-Object { $_.Identity -eq $item.Key } | Select-Object -First 1
        $beforeEntry = $beforeUninstallEntries | Where-Object { $_.Identity -eq $item.Key } | Select-Object -First 1
        $entryForClass = if ($null -ne $afterEntry) { $afterEntry } else { $beforeEntry }
        $classification = Get-UninstallEntryClassification -Entry $entryForClass
        Write-Host "* [$classification] $($item.Key)" -ForegroundColor (Get-UninstallEntryColor -Classification $classification -ChangeKind 'Changed')
        foreach ($diff in $item.Differences) {
            $beforeValue = if ($diff.Property -match 'UninstallString') { Format-DisplayText -Value $diff.Before } else { $diff.Before }
            $afterValue = if ($diff.Property -match 'UninstallString') { Format-DisplayText -Value $diff.After } else { $diff.After }
            Write-Host "    $($diff.Property): '$beforeValue' -> '$afterValue'" -ForegroundColor DarkGray
        }
    }

    Write-Host 'Note: [LIKELY] = vendor/runtime that likely belongs to the install story, [REVIEW] = shared runtime/dependency, [NOISE] = background churn candidate.' -ForegroundColor DarkGray
}

Write-Section -Title 'Focused Registry'
$hasRegistryChanges = $registryKeyDiff.Added.Count -gt 0 -or
    $registryKeyDiff.Removed.Count -gt 0 -or
    $registryValueDiff.Added.Count -gt 0 -or
    $registryValueDiff.Removed.Count -gt 0 -or
    $registryValueDiff.Changed.Count -gt 0

if (-not $hasRegistryChanges) {
    Write-Host 'No focused registry changes detected.'
}
else {
    foreach ($item in $registryKeyDiff.Added) {
        Write-Host "+ KEY :: $($item.KeyPath)" -ForegroundColor (Get-DiffColor -ChangeKind 'Added')
    }
    foreach ($item in $registryKeyDiff.Removed) {
        Write-Host "- KEY :: $($item.KeyPath)" -ForegroundColor (Get-DiffColor -ChangeKind 'Removed')
    }
    foreach ($item in $registryValueDiff.Added) {
        Write-Host "+ VALUE :: $($item.KeyPath) :: [$($item.ValueName)] = $(Format-DisplayText -Value $item.ValueData)" -ForegroundColor (Get-DiffColor -ChangeKind 'Added')
    }
    foreach ($item in $registryValueDiff.Removed) {
        Write-Host "- VALUE :: $($item.KeyPath) :: [$($item.ValueName)] = $(Format-DisplayText -Value $item.ValueData)" -ForegroundColor (Get-DiffColor -ChangeKind 'Removed')
    }
    foreach ($item in $registryValueDiff.Changed) {
        Write-Host "* VALUE :: $($item.Key)" -ForegroundColor White
        foreach ($diff in $item.Differences) {
            if ($diff.Property -eq 'ValueData') {
                Write-Host "    $($diff.Property): '$(Format-DisplayText -Value $diff.Before)' -> '$(Format-DisplayText -Value $diff.After)'" -ForegroundColor DarkGray
                continue
            }

            Write-Host "    $($diff.Property): '$($diff.Before)' -> '$($diff.After)'" -ForegroundColor DarkGray
        }
    }
}

Write-Section -Title 'PnP Devices'
if ($deviceAdded.Count -eq 0 -and $deviceRemoved.Count -eq 0 -and $deviceChanged.Count -eq 0) {
    Write-Host 'No PnP device changes detected.'
}
else {
    foreach ($item in $deviceAdded) {
        Write-Host "+ $($item.InstanceId) :: $($item.FriendlyName)" -ForegroundColor (Get-DiffColor -ChangeKind 'Added')
        Write-PnpDeviceDetailLines -Device $item
    }
    foreach ($item in $deviceRemoved) {
        Write-Host "- $($item.InstanceId) :: $($item.FriendlyName)" -ForegroundColor (Get-DiffColor -ChangeKind 'Removed')
        Write-PnpDeviceDetailLines -Device $item
    }
    foreach ($item in $deviceChanged) {
        Write-Host "* $($item.Key)" -ForegroundColor White
        foreach ($diff in $item.Differences) {
            Write-Host "    $($diff.Property): '$($diff.Before)' -> '$($diff.After)'" -ForegroundColor DarkGray
        }
    }
}

Write-Section -Title 'Certificates'
$certChangeCount = $rootCertDiff.Added.Count + $rootCertDiff.Removed.Count + $publisherCertDiff.Added.Count + $publisherCertDiff.Removed.Count
if ($certChangeCount -eq 0) {
    Write-Host 'No LocalMachine certificate additions/removals detected.'
}
else {
    foreach ($item in $rootCertDiff.Added) {
        $tag = Get-CertificateTag -Certificate $item -StoreName 'ROOT' -PublisherThumbprints $publisherAddedThumbprints
        Write-Host "+ ROOT :: [$tag] $($item.Thumbprint) :: $($item.Subject)" -ForegroundColor (Get-DiffColor -ChangeKind 'Added')
    }
    foreach ($item in $rootCertDiff.Removed) {
        $tag = Get-CertificateTag -Certificate $item -StoreName 'ROOT' -PublisherThumbprints $publisherRemovedThumbprints
        Write-Host "- ROOT :: [$tag] $($item.Thumbprint) :: $($item.Subject)" -ForegroundColor (Get-DiffColor -ChangeKind 'Removed')
    }
    foreach ($item in $publisherCertDiff.Added) {
        $tag = Get-CertificateTag -Certificate $item -StoreName 'TRUSTEDPUBLISHER' -PublisherThumbprints $publisherAddedThumbprints
        Write-Host "+ TRUSTEDPUBLISHER :: [$tag] $($item.Thumbprint) :: $($item.Subject)" -ForegroundColor (Get-DiffColor -ChangeKind 'Added')
    }
    foreach ($item in $publisherCertDiff.Removed) {
        $tag = Get-CertificateTag -Certificate $item -StoreName 'TRUSTEDPUBLISHER' -PublisherThumbprints $publisherRemovedThumbprints
        Write-Host "- TRUSTEDPUBLISHER :: [$tag] $($item.Thumbprint) :: $($item.Subject)" -ForegroundColor (Get-DiffColor -ChangeKind 'Removed')
    }

    $linkedRootCount = @($rootCertDiff.Added + $rootCertDiff.Removed | Where-Object {
            $thumbprint = [string]$_.Thumbprint
            ($null -ne $publisherAddedThumbprints -and $publisherAddedThumbprints.Contains($thumbprint)) -or
            ($null -ne $publisherRemovedThumbprints -and $publisherRemovedThumbprints.Contains($thumbprint))
        }).Count

    if ($linkedRootCount -gt 0) {
        Write-Host 'Note: [LINKED] means the same thumbprint also appeared in TRUSTEDPUBLISHER changes.' -ForegroundColor DarkYellow
    }
}

Write-Section -Title 'Focused Files'
if ($fileDiff.Added.Count -eq 0 -and $fileDiff.Removed.Count -eq 0 -and $fileDiff.Changed.Count -eq 0) {
    Write-Host 'No focused file changes detected.'
}
else {
    foreach ($item in $fileDiff.Added) {
        Write-Host "+ $($item.FullName)" -ForegroundColor (Get-DiffColor -ChangeKind 'Added')
    }
    foreach ($item in $fileDiff.Removed) {
        Write-Host "- $($item.FullName)" -ForegroundColor (Get-DiffColor -ChangeKind 'Removed')
    }
    foreach ($item in $fileDiff.Changed) {
        Write-Host "* $($item.Key)" -ForegroundColor White
        foreach ($diff in $item.Differences) {
            Write-Host "    $($diff.Property): '$($diff.Before)' -> '$($diff.After)'" -ForegroundColor DarkGray
        }
    }
}

Write-Section -Title 'BCD Changes'
if ($bcdAdded.Count -eq 0 -and $bcdRemoved.Count -eq 0) {
    Write-Host 'No tracked BCD changes detected.'
}
else {
    foreach ($line in $bcdAdded) {
        Write-Host "+ $line" -ForegroundColor (Get-DiffColor -ChangeKind 'Added')
    }
    foreach ($line in $bcdRemoved) {
        Write-Host "- $line" -ForegroundColor (Get-DiffColor -ChangeKind 'Removed')
    }
}

Write-Section -Title 'SetupAPI Log'
if ($beforeSetupApi -and $afterSetupApi) {
    Write-Host "Before size : $($beforeSetupApi.Length)"
    Write-Host "After size  : $($afterSetupApi.Length)"
    Write-Host "Before time : $($beforeSetupApi.LastWriteTime)"
    Write-Host "After time  : $($afterSetupApi.LastWriteTime)"
}
else {
    Write-Host 'SetupAPI metadata was not available in both snapshots.'
}

Write-Section -Title 'Compare Reports'
Write-Host "Folder              : $reportOutputPath" -ForegroundColor DarkGray
Write-Host "Full report         : $fullReportPath" -ForegroundColor DarkGray
Write-Host "Differences only    : $differenceReportPath" -ForegroundColor DarkGray
Write-Host "Similarities only   : $similarityReportPath" -ForegroundColor DarkGray
