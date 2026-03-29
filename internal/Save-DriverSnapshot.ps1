[CmdletBinding()]
param(
    [string]$Name,
    [string]$CaseName,
    [string]$Stage,
    [string]$SnapshotMode,
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'snapshots'),
    [string[]]$FocusTerm = @('MulttKey', 'hasp')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SnapshotSetupCanceled = $false
$script:CancelInputToken = '__ESC_CANCEL__'
$global:DriverCheck_LastSnapshotSaveCanceled = $false

function Test-CurrentSessionElevated {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SelfElevationArgumentList {
    $argumentList = @('-NoLogo', '-NoProfile', '-File', $PSCommandPath)

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $argumentList += @('-Name', $Name)
    }

    if (-not [string]::IsNullOrWhiteSpace($CaseName)) {
        $argumentList += @('-CaseName', $CaseName)
    }

    if (-not [string]::IsNullOrWhiteSpace($Stage)) {
        $argumentList += @('-Stage', $Stage)
    }

    if (-not [string]::IsNullOrWhiteSpace($SnapshotMode)) {
        $argumentList += @('-SnapshotMode', $SnapshotMode)
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
        $argumentList += @('-OutputRoot', $OutputRoot)
    }

    foreach ($term in $FocusTerm) {
        $argumentList += @('-FocusTerm', $term)
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

function Resolve-SnapshotMode {
    param(
        [string]$Mode,
        [string]$DefaultMode = 'Full'
    )

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        return $DefaultMode
    }

    switch -Regex ($Mode.Trim()) {
        '^(?i:quick)$' { return 'Quick' }
        '^(?i:full)$' { return 'Full' }
        default { return $DefaultMode }
    }
}

function Get-StageSelection {
    param(
        [string]$CurrentStage
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentStage)) {
        return $CurrentStage
    }

    $stageItems = @(
        [pscustomobject]@{ Key = '1'; Label = 'BeforeInstall'; Color = 'Yellow'; Value = 'BeforeInstall' },
        [pscustomobject]@{ Key = '2'; Label = 'AfterInstall'; Color = 'Cyan'; Value = 'AfterInstall' },
        [pscustomobject]@{ Key = '3'; Label = 'AfterRemove'; Color = 'Magenta'; Value = 'AfterRemove' },
        [pscustomobject]@{ Key = '4'; Label = 'AfterCleanup'; Color = 'Green'; Value = 'AfterCleanup' },
        [pscustomobject]@{ Key = '5'; Label = 'AfterCertCleanup'; Color = 'DarkCyan'; Value = 'AfterCertCleanup' },
        [pscustomobject]@{ Key = '6'; Label = 'Custom stage'; Color = 'Gray'; Value = '__CUSTOM__' }
    )

    if ([Console]::IsInputRedirected) {
        Write-Host ''
        Write-Host 'Διάλεξε Stage για το snapshot' -ForegroundColor Cyan
        Write-Host '----------------------------' -ForegroundColor Cyan
        foreach ($item in $stageItems) {
            Write-Host ("[{0}] {1}" -f $item.Key, $item.Label) -ForegroundColor $item.Color
        }
        Write-Host '[ENTER] Leave empty (not recommended)' -ForegroundColor DarkGray
        Write-Host '[ESC] Cancel snapshot save' -ForegroundColor DarkGray

        $choice = Read-HostTrimmed -Prompt 'Stage'
        if (Test-IsEscapeInput -Value $choice) {
            return $script:CancelInputToken
        }

        switch ($choice) {
            '1' { return 'BeforeInstall' }
            '2' { return 'AfterInstall' }
            '3' { return 'AfterRemove' }
            '4' { return 'AfterCleanup' }
            '5' { return 'AfterCertCleanup' }
            '6' {
                $customStage = Read-HostTrimmed -Prompt 'Custom Stage'
                if (Test-IsEscapeInput -Value $customStage) {
                    return $script:CancelInputToken
                }

                return $customStage
            }
            default {
                return ''
            }
        }
    }

    $eraseLine = '{0}[K' -f [char]27
    $selectedIndex = 0

    function Write-StageMenuFrame {
        [Console]::SetCursorPosition(0, $menuTop)
        for ($i = 0; $i -lt $stageItems.Count; $i++) {
            $item = $stageItems[$i]
            $isSelected = $i -eq $selectedIndex
            $prefix = if ($isSelected) { '❯' } else { ' ' }
            $line = Get-ConsoleSafeText -Text ("{0} [{1}] {2}" -f $prefix, $item.Key, $item.Label)
            $color = if ($isSelected) { 'White' } else { $item.Color }
            Write-Host "$line$eraseLine" -ForegroundColor $color
        }
        Write-Host ((Get-ConsoleSafeText -Text '[ENTER] Select highlighted stage') + $eraseLine) -ForegroundColor DarkGray
        Write-Host ((Get-ConsoleSafeText -Text '[ESC] Cancel snapshot save') + $eraseLine) -ForegroundColor DarkGray
    }

    [Console]::CursorVisible = $false
    try {
        Write-Host ''
        Write-Host 'Διάλεξε Stage για το snapshot' -ForegroundColor Cyan
        Write-Host '----------------------------' -ForegroundColor Cyan
        Write-Host ''
        $menuTop = [Console]::CursorTop
        $frameHeight = $stageItems.Count + 2
        for ($lineIndex = 0; $lineIndex -lt $frameHeight; $lineIndex++) {
            Write-Host ''
        }
        [Console]::SetCursorPosition(0, $menuTop)

        while ($true) {
            Write-StageMenuFrame

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' {
                    if ($selectedIndex -gt 0) {
                        $selectedIndex--
                    }
                }
                'DownArrow' {
                    if ($selectedIndex -lt ($stageItems.Count - 1)) {
                        $selectedIndex++
                    }
                }
                'Enter' {
                    $selectedItem = $stageItems[$selectedIndex]
                    if ($selectedItem.Value -eq '__CUSTOM__') {
                        [Console]::CursorVisible = $true
                        $customStage = Read-HostTrimmed -Prompt 'Custom Stage'
                        [Console]::CursorVisible = $false
                        if (Test-IsEscapeInput -Value $customStage) {
                            return $script:CancelInputToken
                        }

                        return $customStage
                    }

                    return $selectedItem.Value
                }
                'Escape' {
                    return $script:CancelInputToken
                }
                default {
                    $typedKey = [string]$key.KeyChar
                    if (-not [string]::IsNullOrWhiteSpace($typedKey)) {
                        $matchedIndex = -1
                        for ($i = 0; $i -lt $stageItems.Count; $i++) {
                            if ($stageItems[$i].Key -eq $typedKey) {
                                $matchedIndex = $i
                                break
                            }
                        }

                        if ($matchedIndex -ge 0) {
                            $selectedIndex = $matchedIndex
                            Write-StageMenuFrame
                            Start-Sleep -Milliseconds 90
                            $matchedItem = $stageItems[$selectedIndex]
                            if ($matchedItem.Value -eq '__CUSTOM__') {
                                [Console]::CursorVisible = $true
                                $customStage = Read-HostTrimmed -Prompt 'Custom Stage'
                                [Console]::CursorVisible = $false
                                if (Test-IsEscapeInput -Value $customStage) {
                                    return $script:CancelInputToken
                                }

                                return $customStage
                            }

                            return $matchedItem.Value
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

function Get-SnapshotModeSelection {
    param(
        [string]$CurrentMode
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentMode)) {
        return (Resolve-SnapshotMode -Mode $CurrentMode -DefaultMode 'Full')
    }

    $modeItems = @(
        [pscustomobject]@{
            Key = '1'
            Label = 'Quick snapshot (faster, lighter PnP details)'
            Color = 'Green'
            Value = 'Quick'
        },
        [pscustomobject]@{
            Key = '2'
            Label = 'Full snapshot (slower, deepest PnP details)'
            Color = 'Yellow'
            Value = 'Full'
        }
    )

    if ([Console]::IsInputRedirected) {
        Write-Host ''
        Write-Host 'Διάλεξε Snapshot mode' -ForegroundColor Cyan
        Write-Host '---------------------' -ForegroundColor Cyan
        foreach ($item in $modeItems) {
            Write-Host ("[{0}] {1}" -f $item.Key, $item.Label) -ForegroundColor $item.Color
        }
        Write-Host '[ESC] Cancel snapshot save' -ForegroundColor DarkGray

        $choice = Read-HostTrimmed -Prompt 'Mode'
        if (Test-IsEscapeInput -Value $choice) {
            return $script:CancelInputToken
        }

        switch ($choice) {
            '1' { return 'Quick' }
            '2' { return 'Full' }
            default { return 'Quick' }
        }
    }

    $eraseLine = '{0}[K' -f [char]27
    $selectedIndex = 0

    function Write-SnapshotModeFrame {
        [Console]::SetCursorPosition(0, $menuTop)
        for ($i = 0; $i -lt $modeItems.Count; $i++) {
            $item = $modeItems[$i]
            $isSelected = $i -eq $selectedIndex
            $prefix = if ($isSelected) { '❯' } else { ' ' }
            $line = Get-ConsoleSafeText -Text ("{0} [{1}] {2}" -f $prefix, $item.Key, $item.Label)
            $color = if ($isSelected) { 'White' } else { $item.Color }
            Write-Host "$line$eraseLine" -ForegroundColor $color
        }
        Write-Host ((Get-ConsoleSafeText -Text '[ENTER] Select highlighted mode') + $eraseLine) -ForegroundColor DarkGray
        Write-Host ((Get-ConsoleSafeText -Text '[ESC] Cancel snapshot save') + $eraseLine) -ForegroundColor DarkGray
    }

    [Console]::CursorVisible = $false
    try {
        Write-Host ''
        Write-Host 'Διάλεξε Snapshot mode' -ForegroundColor Cyan
        Write-Host '---------------------' -ForegroundColor Cyan
        Write-Host ''
        $menuTop = [Console]::CursorTop
        $frameHeight = $modeItems.Count + 2
        for ($lineIndex = 0; $lineIndex -lt $frameHeight; $lineIndex++) {
            Write-Host ''
        }
        [Console]::SetCursorPosition(0, $menuTop)

        while ($true) {
            Write-SnapshotModeFrame

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' {
                    if ($selectedIndex -gt 0) {
                        $selectedIndex--
                    }
                }
                'DownArrow' {
                    if ($selectedIndex -lt ($modeItems.Count - 1)) {
                        $selectedIndex++
                    }
                }
                'Enter' {
                    return $modeItems[$selectedIndex].Value
                }
                'Escape' {
                    return $script:CancelInputToken
                }
                default {
                    $typedKey = [string]$key.KeyChar
                    if (-not [string]::IsNullOrWhiteSpace($typedKey)) {
                        $matchedIndex = -1
                        for ($i = 0; $i -lt $modeItems.Count; $i++) {
                            if ($modeItems[$i].Key -eq $typedKey) {
                                $matchedIndex = $i
                                break
                            }
                        }

                        if ($matchedIndex -ge 0) {
                            $selectedIndex = $matchedIndex
                            Write-SnapshotModeFrame
                            Start-Sleep -Milliseconds 90
                            return $modeItems[$selectedIndex].Value
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

function Initialize-SnapshotContext {
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $script:SnapshotMode = Resolve-SnapshotMode -Mode $SnapshotMode -DefaultMode 'Full'
        return
    }

    if ([string]::IsNullOrWhiteSpace($CaseName)) {
        Write-Host ''
        Write-Host 'Snapshot labels help the picker and compare flow stay readable.' -ForegroundColor Yellow
        Write-Host '[ESC] Cancel snapshot save and return to the main menu' -ForegroundColor DarkGray
        Write-Host '[ENTER] Leave blank for a generic snapshot label' -ForegroundColor DarkGray
        $script:CaseName = Read-HostTrimmed -Prompt 'Case Name (recommended)'
        if (Test-IsEscapeInput -Value $script:CaseName) {
            Write-Host 'Ακύρωση αποθήκευσης snapshot από τον χρήστη.' -ForegroundColor Yellow
            $script:SnapshotSetupCanceled = $true
            $global:DriverCheck_LastSnapshotSaveCanceled = $true
            return
        }
    }

    $selectedStage = Get-StageSelection -CurrentStage $Stage
    if ($selectedStage -eq $script:CancelInputToken) {
        Write-Host 'Ακύρωση αποθήκευσης snapshot από τον χρήστη.' -ForegroundColor Yellow
        $script:SnapshotSetupCanceled = $true
        $global:DriverCheck_LastSnapshotSaveCanceled = $true
        return
    }

    $script:Stage = $selectedStage

    $selectedMode = Get-SnapshotModeSelection -CurrentMode $SnapshotMode
    if ($selectedMode -eq $script:CancelInputToken) {
        Write-Host 'Ακύρωση αποθήκευσης snapshot από τον χρήστη.' -ForegroundColor Yellow
        $script:SnapshotSetupCanceled = $true
        $global:DriverCheck_LastSnapshotSaveCanceled = $true
        return
    }

    $script:SnapshotMode = $selectedMode

    if ([string]::IsNullOrWhiteSpace($CaseName) -and [string]::IsNullOrWhiteSpace($Stage)) {
        Write-Host '⚠️ IMPORTANT' -ForegroundColor Yellow
        Write-Host 'Το snapshot θα αποθηκευτεί ως generic "Snapshot" χωρίς Case/Stage labels.' -ForegroundColor Yellow
    }
}

function Invoke-NativeCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    [pscustomobject]@{
        FilePath = $FilePath
        Arguments = @($Arguments)
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Convert-PnpUtilToDriverPackages {
    param(
        [string[]]$Lines
    )

    $packages = New-Object System.Collections.Generic.List[object]
    $current = [ordered]@{}

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($current.Count -gt 0 -and $current.Contains('Published Name')) {
                $packages.Add([pscustomobject]@{
                        PublishedName = $current['Published Name']
                        OriginalName = $current['Original Name']
                        ProviderName = $current['Provider Name']
                        ClassName = $current['Class Name']
                        ClassGuid = $current['Class GUID']
                        DriverVersion = $current['Driver Version']
                        SignerName = $current['Signer Name']
                    })
            }

            $current = [ordered]@{}
            continue
        }

        if ($line -match '^\s*([^:]+):\s+(.*)$') {
            $current[$matches[1].Trim()] = $matches[2].Trim()
        }
    }

    if ($current.Count -gt 0 -and $current.Contains('Published Name')) {
        $packages.Add([pscustomobject]@{
                PublishedName = $current['Published Name']
                OriginalName = $current['Original Name']
                ProviderName = $current['Provider Name']
                ClassName = $current['Class Name']
                ClassGuid = $current['Class GUID']
                DriverVersion = $current['Driver Version']
                SignerName = $current['Signer Name']
            })
    }

    return $packages.ToArray()
}

function Get-ServiceRegistrySnapshot {
    $services = foreach ($serviceKey in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue) {
        try {
            $item = Get-ItemProperty -Path $serviceKey.PSPath -ErrorAction Stop
            [pscustomobject]@{
                Name = $serviceKey.PSChildName
                DisplayName = $item.DisplayName
                ImagePath = $item.ImagePath
                Start = $item.Start
                Type = $item.Type
                ErrorControl = $item.ErrorControl
                Group = $item.Group
            }
        }
        catch {
            continue
        }
    }

    return @($services | Sort-Object Name)
}

function Get-PnpDeviceSnapshot {
    param(
        [string]$SnapshotMode = 'Full'
    )

    function Get-ObjectPropertyValue {
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

    function Get-PnpPropertyValueSafe {
        param(
            [string]$InstanceId,
            [string]$KeyName
        )

        if ([string]::IsNullOrWhiteSpace($InstanceId) -or [string]::IsNullOrWhiteSpace($KeyName)) {
            return ''
        }

        try {
            $property = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop
            if ($null -eq $property -or $null -eq $property.Data) {
                return ''
            }

            if ($property.Data -is [System.Array]) {
                return (@($property.Data) -join '; ')
            }

            return [string]$property.Data
        }
        catch {
            return ''
        }
    }

    function Add-OrUpdateSnapshotPnpEntry {
        param(
            [hashtable]$Map,
            [AllowEmptyString()]
            [string]$InstanceId,
            [AllowEmptyString()]
            [string]$FriendlyName,
            [AllowEmptyString()]
            [string]$Class,
            [AllowEmptyString()]
            [string]$Present,
            [AllowEmptyString()]
            [string]$Problem,
            [AllowEmptyString()]
            [string]$Status,
            [AllowEmptyString()]
            [string]$ClassGuid,
            [AllowEmptyString()]
            [string]$InfName,
            [AllowEmptyString()]
            [string]$DriverName,
            [AllowEmptyString()]
            [string]$Manufacturer,
            [AllowEmptyString()]
            [string]$DriverProviderName,
            [AllowEmptyString()]
            [string]$MatchingDeviceId,
            [AllowEmptyString()]
            [string]$ServiceName,
            [AllowEmptyString()]
            [string]$DriverInfSection,
            [AllowEmptyString()]
            [string]$DriverKey,
            [AllowEmptyString()]
            [string]$EnumeratorName,
            [AllowEmptyString()]
            [string]$Parent,
            [AllowEmptyString()]
            [string]$HardwareIds,
            [AllowEmptyString()]
            [string]$CompatibleIds,
            [AllowEmptyString()]
            [string]$DriverVersion,
            [AllowEmptyString()]
            [string]$DriverDate,
            [string]$Source
        )

        $key = if (-not [string]::IsNullOrWhiteSpace($InstanceId)) {
            $InstanceId
        }
        elseif (-not [string]::IsNullOrWhiteSpace($FriendlyName)) {
            "NAME::$FriendlyName"
        }
        else {
            return
        }

        if (-not $Map.ContainsKey($key)) {
            $Map[$key] = [pscustomobject]@{
                FriendlyName = ''
                InstanceId = ''
                Class = ''
                Present = ''
                Problem = ''
                Status = ''
                ClassGuid = ''
                InfName = ''
                DriverName = ''
                Manufacturer = ''
                DriverProviderName = ''
                MatchingDeviceId = ''
                ServiceName = ''
                DriverInfSection = ''
                DriverKey = ''
                EnumeratorName = ''
                Parent = ''
                HardwareIds = ''
                CompatibleIds = ''
                DriverVersion = ''
                DriverDate = ''
                Sources = [System.Collections.Generic.List[string]]::new()
            }
        }

        $entry = $Map[$key]
        foreach ($fieldUpdate in @(
                @{ Name = 'FriendlyName'; Value = $FriendlyName },
                @{ Name = 'InstanceId'; Value = $InstanceId },
                @{ Name = 'Class'; Value = $Class },
                @{ Name = 'Present'; Value = $Present },
                @{ Name = 'Problem'; Value = $Problem },
                @{ Name = 'Status'; Value = $Status },
                @{ Name = 'ClassGuid'; Value = $ClassGuid },
                @{ Name = 'InfName'; Value = $InfName },
                @{ Name = 'DriverName'; Value = $DriverName },
                @{ Name = 'Manufacturer'; Value = $Manufacturer },
                @{ Name = 'DriverProviderName'; Value = $DriverProviderName },
                @{ Name = 'MatchingDeviceId'; Value = $MatchingDeviceId },
                @{ Name = 'ServiceName'; Value = $ServiceName },
                @{ Name = 'DriverInfSection'; Value = $DriverInfSection },
                @{ Name = 'DriverKey'; Value = $DriverKey },
                @{ Name = 'EnumeratorName'; Value = $EnumeratorName },
                @{ Name = 'Parent'; Value = $Parent },
                @{ Name = 'HardwareIds'; Value = $HardwareIds },
                @{ Name = 'CompatibleIds'; Value = $CompatibleIds },
                @{ Name = 'DriverVersion'; Value = $DriverVersion },
                @{ Name = 'DriverDate'; Value = $DriverDate }
            )) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.($fieldUpdate.Name)) -and -not [string]::IsNullOrWhiteSpace([string]$fieldUpdate.Value)) {
                $entry.($fieldUpdate.Name) = [string]$fieldUpdate.Value
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($Source) -and -not $entry.Sources.Contains($Source)) {
            [void]$entry.Sources.Add($Source)
        }
    }

    function Write-PnpSnapshotProgress {
        param(
            [string]$PhaseName,
            [int]$CurrentItem,
            [int]$PhaseTotal,
            [int]$GlobalCurrent,
            [int]$GlobalTotal
        )

        $safeGlobalTotal = [Math]::Max(1, $GlobalTotal)
        $safePhaseTotal = [Math]::Max(1, $PhaseTotal)
        $percentComplete = [math]::Min(100, [math]::Round(($GlobalCurrent / $safeGlobalTotal) * 100, 0))
        $status = "{0} ({1}/{2})  |  overall {3}/{4}" -f $PhaseName, $CurrentItem, $safePhaseTotal, $GlobalCurrent, $safeGlobalTotal
        Write-Progress -Id 1 -Activity 'Capture PnP device snapshot' -Status $status -PercentComplete $percentComplete
    }

    $deviceMap = @{}
    $devices = @(Get-PnpDevice -PresentOnly:$false -ErrorAction SilentlyContinue)
    $signedDrivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue)
    $deviceCount = @($devices).Count
    $signedDriverCount = @($signedDrivers).Count
    $totalProgressItems = $deviceCount + $signedDriverCount
    $globalProgressIndex = 0

    try {
        for ($deviceIndex = 0; $deviceIndex -lt $deviceCount; $deviceIndex++) {
            $device = $devices[$deviceIndex]
            $displayName = if (-not [string]::IsNullOrWhiteSpace([string]$device.FriendlyName)) {
                [string]$device.FriendlyName
            }
            else {
                [string]$device.Name
            }

            $classGuidValue = ''
            $infNameValue = ''
            $manufacturerValue = ''
            $driverProviderValue = ''
            $matchingDeviceIdValue = ''
            $serviceNameValue = ''
            $driverInfSectionValue = ''
            $driverKeyValue = ''
            $enumeratorNameValue = ''
            $parentValue = ''
            $hardwareIdsValue = ''
            $compatibleIdsValue = ''

            if ($SnapshotMode -eq 'Full') {
                $classGuidValue = Get-PnpPropertyValueSafe -InstanceId ([string]$device.InstanceId) -KeyName 'DEVPKEY_Device_ClassGuid'
                $infNameValue = Get-PnpPropertyValueSafe -InstanceId ([string]$device.InstanceId) -KeyName 'DEVPKEY_Device_DriverInfPath'
                $manufacturerValue = Get-PnpPropertyValueSafe -InstanceId ([string]$device.InstanceId) -KeyName 'DEVPKEY_Device_Manufacturer'
                $driverProviderValue = Get-PnpPropertyValueSafe -InstanceId ([string]$device.InstanceId) -KeyName 'DEVPKEY_Device_DriverProvider'
                $matchingDeviceIdValue = Get-PnpPropertyValueSafe -InstanceId ([string]$device.InstanceId) -KeyName 'DEVPKEY_Device_MatchingDeviceId'
                $serviceNameValue = Get-PnpPropertyValueSafe -InstanceId ([string]$device.InstanceId) -KeyName 'DEVPKEY_Device_Service'
                $driverInfSectionValue = Get-PnpPropertyValueSafe -InstanceId ([string]$device.InstanceId) -KeyName 'DEVPKEY_Device_DriverInfSection'
                $driverKeyValue = Get-PnpPropertyValueSafe -InstanceId ([string]$device.InstanceId) -KeyName 'DEVPKEY_Device_Driver'
                $enumeratorNameValue = Get-PnpPropertyValueSafe -InstanceId ([string]$device.InstanceId) -KeyName 'DEVPKEY_Device_EnumeratorName'
                $parentValue = Get-PnpPropertyValueSafe -InstanceId ([string]$device.InstanceId) -KeyName 'DEVPKEY_Device_Parent'
                $hardwareIdsValue = Get-PnpPropertyValueSafe -InstanceId ([string]$device.InstanceId) -KeyName 'DEVPKEY_Device_HardwareIds'
                $compatibleIdsValue = Get-PnpPropertyValueSafe -InstanceId ([string]$device.InstanceId) -KeyName 'DEVPKEY_Device_CompatibleIds'
            }

            Add-OrUpdateSnapshotPnpEntry -Map $deviceMap `
                -InstanceId ([string]$device.InstanceId) `
                -FriendlyName $displayName `
                -Class ([string]$device.Class) `
                -Present ([string]$device.Present) `
                -Problem ([string]$device.Problem) `
                -Status ([string]$device.Status) `
                -ClassGuid $classGuidValue `
                -InfName $infNameValue `
                -DriverName '' `
                -Manufacturer $manufacturerValue `
                -DriverProviderName $driverProviderValue `
                -MatchingDeviceId $matchingDeviceIdValue `
                -ServiceName $serviceNameValue `
                -DriverInfSection $driverInfSectionValue `
                -DriverKey $driverKeyValue `
                -EnumeratorName $enumeratorNameValue `
                -Parent $parentValue `
                -HardwareIds $hardwareIdsValue `
                -CompatibleIds $compatibleIdsValue `
                -DriverVersion '' `
                -DriverDate '' `
                -Source 'Get-PnpDevice'

            $globalProgressIndex++
            if ((($deviceIndex + 1) % 5) -eq 0 -or ($deviceIndex + 1) -eq $deviceCount) {
                $phaseName = if ($SnapshotMode -eq 'Quick') { 'Get-PnpDevice base capture' } else { 'Get-PnpDevice property enrichment' }
                Write-PnpSnapshotProgress -PhaseName $phaseName `
                    -CurrentItem ($deviceIndex + 1) `
                    -PhaseTotal $deviceCount `
                    -GlobalCurrent $globalProgressIndex `
                    -GlobalTotal $totalProgressItems
            }
        }

        for ($signedDriverIndex = 0; $signedDriverIndex -lt $signedDriverCount; $signedDriverIndex++) {
            $signedDriver = $signedDrivers[$signedDriverIndex]
            $displayName = if (-not [string]::IsNullOrWhiteSpace([string]$signedDriver.DeviceName)) {
                [string]$signedDriver.DeviceName
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$signedDriver.FriendlyName)) {
                [string]$signedDriver.FriendlyName
            }
            else {
                [string]$signedDriver.Description
            }

            $driverDateText = ''
            if ($null -ne $signedDriver.DriverDate) {
                try {
                    $driverDateText = ([datetime]$signedDriver.DriverDate).ToString('yyyy-MM-dd')
                }
                catch {
                    $driverDateText = [string]$signedDriver.DriverDate
                }
            }

            Add-OrUpdateSnapshotPnpEntry -Map $deviceMap `
                -InstanceId ([string](Get-ObjectPropertyValue -InputObject $signedDriver -PropertyName 'DeviceID' -DefaultValue '')) `
                -FriendlyName $displayName `
                -Class ([string](Get-ObjectPropertyValue -InputObject $signedDriver -PropertyName 'DeviceClass' -DefaultValue '')) `
                -Present '' `
                -Problem '' `
                -Status ([string](Get-ObjectPropertyValue -InputObject $signedDriver -PropertyName 'Status' -DefaultValue '')) `
                -ClassGuid ([string](Get-ObjectPropertyValue -InputObject $signedDriver -PropertyName 'ClassGuid' -DefaultValue '')) `
                -InfName ([string](Get-ObjectPropertyValue -InputObject $signedDriver -PropertyName 'InfName' -DefaultValue '')) `
                -DriverName ([string](Get-ObjectPropertyValue -InputObject $signedDriver -PropertyName 'DriverName' -DefaultValue '')) `
                -Manufacturer ([string](Get-ObjectPropertyValue -InputObject $signedDriver -PropertyName 'Manufacturer' -DefaultValue '')) `
                -DriverProviderName ([string](Get-ObjectPropertyValue -InputObject $signedDriver -PropertyName 'DriverProviderName' -DefaultValue '')) `
                -MatchingDeviceId '' `
                -ServiceName ([string](Get-ObjectPropertyValue -InputObject $signedDriver -PropertyName 'Service' -DefaultValue '')) `
                -DriverInfSection '' `
                -DriverKey '' `
                -EnumeratorName '' `
                -Parent '' `
                -HardwareIds '' `
                -CompatibleIds '' `
                -DriverVersion ([string]$signedDriver.DriverVersion) `
                -DriverDate $driverDateText `
                -Source 'Win32_PnPSignedDriver'

            $globalProgressIndex++
            if ((($signedDriverIndex + 1) % 10) -eq 0 -or ($signedDriverIndex + 1) -eq $signedDriverCount) {
                Write-PnpSnapshotProgress -PhaseName 'Merge Win32_PnPSignedDriver details' `
                    -CurrentItem ($signedDriverIndex + 1) `
                    -PhaseTotal $signedDriverCount `
                    -GlobalCurrent $globalProgressIndex `
                    -GlobalTotal $totalProgressItems
            }
        }
    }
    finally {
        Write-Progress -Id 1 -Activity 'Capture PnP device snapshot' -Completed
    }

    return @($deviceMap.Values | Sort-Object InstanceId, FriendlyName)
}

function Get-CertificateSnapshot {
    param(
        [string]$StorePath
    )

    $certs = Get-ChildItem $StorePath -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Thumbprint = $_.Thumbprint
            Subject = $_.Subject
            Issuer = $_.Issuer
            NotAfter = $_.NotAfter
        }
    }

    return @($certs | Sort-Object Thumbprint)
}

function Get-RegistryFocusRoots {
    return @(
        [pscustomobject]@{
            Name = 'Services'
            Path = 'HKLM:\SYSTEM\CurrentControlSet\Services'
        },
        [pscustomobject]@{
            Name = 'Enum'
            Path = 'HKLM:\SYSTEM\CurrentControlSet\Enum'
        },
        [pscustomobject]@{
            Name = 'Class'
            Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class'
        },
        [pscustomobject]@{
            Name = 'Uninstall'
            Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        },
        [pscustomobject]@{
            Name = 'UninstallWow6432'
            Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        }
    )
}

function Get-UninstallEntrySnapshot {
    function Get-PropertyValue {
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

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $entries = foreach ($rootPath in $roots) {
        foreach ($entryKey in Get-ChildItem -LiteralPath $rootPath -ErrorAction SilentlyContinue) {
            try {
                $item = Get-ItemProperty -LiteralPath $entryKey.PSPath -ErrorAction Stop
            }
            catch {
                continue
            }

            $displayName = [string](Get-PropertyValue -InputObject $item -PropertyName 'DisplayName' -DefaultValue '')
            $uninstallString = [string](Get-PropertyValue -InputObject $item -PropertyName 'UninstallString' -DefaultValue '')
            $quietUninstallString = [string](Get-PropertyValue -InputObject $item -PropertyName 'QuietUninstallString' -DefaultValue '')
            $productCode = if ($entryKey.PSChildName -match '^\{[0-9A-Fa-f\-]+\}$') { $entryKey.PSChildName } else { '' }

            if (
                [string]::IsNullOrWhiteSpace($displayName) -and
                [string]::IsNullOrWhiteSpace($uninstallString) -and
                [string]::IsNullOrWhiteSpace($quietUninstallString)
            ) {
                continue
            }

            [pscustomobject]@{
                Identity = $entryKey.Name
                RegistryKeyPath = $entryKey.Name
                RootPath = $rootPath
                KeyName = $entryKey.PSChildName
                ProductCode = $productCode
                DisplayName = $displayName
                DisplayVersion = [string](Get-PropertyValue -InputObject $item -PropertyName 'DisplayVersion' -DefaultValue '')
                Publisher = [string](Get-PropertyValue -InputObject $item -PropertyName 'Publisher' -DefaultValue '')
                InstallLocation = [string](Get-PropertyValue -InputObject $item -PropertyName 'InstallLocation' -DefaultValue '')
                InstallSource = [string](Get-PropertyValue -InputObject $item -PropertyName 'InstallSource' -DefaultValue '')
                UninstallString = $uninstallString
                QuietUninstallString = $quietUninstallString
                WindowsInstaller = [int](Get-PropertyValue -InputObject $item -PropertyName 'WindowsInstaller' -DefaultValue 0)
            }
        }
    }

    return @($entries | Sort-Object DisplayName, DisplayVersion, RegistryKeyPath)
}

function Convert-RegistryValueDataToString {
    param(
        [object]$ValueData
    )

    if ($null -eq $ValueData) {
        return ''
    }

    if ($ValueData -is [byte[]]) {
        return ('HEX:{0}' -f ([System.BitConverter]::ToString($ValueData)))
    }

    if ($ValueData -is [string[]]) {
        return ($ValueData -join '; ')
    }

    if ($ValueData -is [System.Array]) {
        return ((@($ValueData) | ForEach-Object { [string]$_ }) -join '; ')
    }

    return [string]$ValueData
}

function Get-MatchingTerms {
    param(
        [string[]]$Terms,
        [string[]]$Texts
    )

    $matchedTerms = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($term in $Terms) {
        if ([string]::IsNullOrWhiteSpace($term)) {
            continue
        }

        foreach ($text in $Texts) {
            if ([string]::IsNullOrWhiteSpace($text)) {
                continue
            }

            if ($text.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                [void]$matchedTerms.Add($term)
                break
            }
        }
    }

    return @($matchedTerms | Sort-Object)
}

function Get-RegistryValueKindName {
    param(
        [object]$RegistryKey,
        [string]$ValueName
    )

    try {
        return [string]$RegistryKey.GetValueKind($ValueName)
    }
    catch {
        return 'Unknown'
    }
}

function Get-FocusedRegistrySnapshot {
    param(
        [string[]]$Terms
    )

    $roots = @(Get-RegistryFocusRoots)
    $keys = New-Object System.Collections.Generic.List[object]
    $values = New-Object System.Collections.Generic.List[object]
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenValues = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $excludedPropertyNames = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root.Path)) {
            continue
        }

        $rootKey = Get-Item -LiteralPath $root.Path -ErrorAction SilentlyContinue
        if ($null -eq $rootKey) {
            continue
        }

        $pendingKeys = [System.Collections.Generic.Stack[object]]::new()
        $pendingKeys.Push($rootKey)

        while ($pendingKeys.Count -gt 0) {
            $registryKey = $pendingKeys.Pop()
            $keyPath = [string]$registryKey.Name
            $keyMatchedTerms = @(Get-MatchingTerms -Terms $Terms -Texts @($keyPath))

            if ($keyMatchedTerms.Count -gt 0 -and $seenKeys.Add($keyPath)) {
                $keys.Add([pscustomobject]@{
                        Identity = $keyPath
                        RootName = $root.Name
                        KeyPath = $keyPath
                        MatchedTerms = ($keyMatchedTerms -join ', ')
                        MatchSource = 'KeyPath'
                    })
            }

            $keyItem = $null
            try {
                $keyItem = Get-ItemProperty -LiteralPath $registryKey.PSPath -ErrorAction Stop
            }
            catch {
                $keyItem = $null
            }

            if ($null -ne $keyItem) {
                $properties = @(
                    $keyItem.PSObject.Properties |
                    Where-Object { $excludedPropertyNames -notcontains $_.Name }
                )

                foreach ($property in $properties) {
                    $valueName = if ([string]::IsNullOrWhiteSpace($property.Name)) { '(Default)' } else { $property.Name }
                    $valueData = Convert-RegistryValueDataToString -ValueData $property.Value
                    $matchedTerms = @(Get-MatchingTerms -Terms $Terms -Texts @($valueName, $valueData))
                    if ($matchedTerms.Count -eq 0) {
                        continue
                    }

                    if ($seenKeys.Add($keyPath)) {
                        $keys.Add([pscustomobject]@{
                                Identity = $keyPath
                                RootName = $root.Name
                                KeyPath = $keyPath
                                MatchedTerms = ($matchedTerms -join ', ')
                                MatchSource = 'Value'
                            })
                    }

                    $valueIdentity = '{0}::{1}' -f $keyPath, $valueName
                    if ($seenValues.Add($valueIdentity)) {
                        $values.Add([pscustomobject]@{
                                Identity = $valueIdentity
                                RootName = $root.Name
                                KeyPath = $keyPath
                                ValueName = $valueName
                                ValueKind = Get-RegistryValueKindName -RegistryKey $registryKey -ValueName $property.Name
                                ValueData = $valueData
                                MatchedTerms = ($matchedTerms -join ', ')
                                MatchSource = 'Value'
                            })
                    }
                }
            }

            foreach ($childKey in Get-ChildItem -LiteralPath $registryKey.PSPath -ErrorAction SilentlyContinue) {
                $pendingKeys.Push($childKey)
            }
        }
    }

    return [pscustomobject]@{
        Roots = $roots
        Keys = @($keys.ToArray() | Sort-Object KeyPath)
        Values = @($values.ToArray() | Sort-Object Identity)
    }
}

function Get-FocusFileSnapshot {
    param(
        [string[]]$Terms
    )

    $roots = @(
        (Join-Path $env:windir 'System32\drivers'),
        (Join-Path $env:windir 'INF'),
        (Join-Path $env:windir 'System32\DriverStore\FileRepository')
    )

    $files = New-Object System.Collections.Generic.List[object]
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($root in $roots) {
        if (-not (Test-Path $root)) {
            continue
        }

        foreach ($term in $Terms) {
            if ([string]::IsNullOrWhiteSpace($term)) {
                continue
            }

            Get-ChildItem -Path $root -Filter "*$term*" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                if ($seen.Add($_.FullName)) {
                    $hash = $null
                    try {
                        $hash = (Get-FileHash -Path $_.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                    }
                    catch {
                        $hash = $null
                    }

                    $files.Add([pscustomobject]@{
                            FullName = $_.FullName
                            Length = $_.Length
                            LastWriteTime = $_.LastWriteTime
                            Sha256 = $hash
                        })
                }
            }
        }
    }

    return @($files.ToArray() | Sort-Object FullName)
}

function Get-SetupApiSnapshot {
    $logPath = Join-Path $env:windir 'INF\setupapi.dev.log'
    if (-not (Test-Path $logPath)) {
        return [pscustomobject]@{
            Path = $logPath
            Exists = $false
            Length = 0
            LastWriteTime = $null
            Tail = @()
        }
    }

    $item = Get-Item $logPath
    $tail = Get-Content -Path $logPath -Tail 800 -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        Path = $logPath
        Exists = $true
        Length = $item.Length
        LastWriteTime = $item.LastWriteTime
        Tail = @($tail)
    }
}

function Get-SnapshotLabel {
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        return $Name
    }

    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($CaseName)) {
        $parts += $CaseName
    }

    if (-not [string]::IsNullOrWhiteSpace($Stage)) {
        $parts += $Stage
    }

    if ($parts.Count -gt 0) {
        return ($parts -join '-')
    }

    return 'Snapshot'
}

function Get-SnapshotFolderLabel {
    param(
        [datetime]$Timestamp
    )

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        return $Name
    }

    $prefixParts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($CaseName)) {
        $prefixParts.Add($CaseName.Trim())
    }

    if (-not [string]::IsNullOrWhiteSpace($Stage)) {
        $prefixParts.Add($Stage.Trim())
    }

    $prefix = if ($prefixParts.Count -gt 0) { $prefixParts -join '-' } else { 'Snapshot' }
    return '{0} {1:MM-dd-yyyy} - {1:HH.mm}' -f $prefix, $Timestamp
}

function Convert-ToSafeSnapshotName {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'Snapshot'
    }

    $safeValue = $Value.Trim()
    $safeValue = $safeValue -replace '[\\/:*?"<>|]+', '-'
    $safeValue = $safeValue -replace '\s{2,}', ' '
    $safeValue = $safeValue.Trim(' ', '.', '-')

    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        return 'Snapshot'
    }

    return $safeValue
}

function New-UniqueSnapshotPath {
    param(
        [string]$RootPath,
        [string]$BaseName
    )

    $candidatePath = Join-Path $RootPath $BaseName
    if (-not (Test-Path -LiteralPath $candidatePath)) {
        return $candidatePath
    }

    $counter = 2
    while ($true) {
        $candidatePath = Join-Path $RootPath ("{0} ({1})" -f $BaseName, $counter)
        if (-not (Test-Path -LiteralPath $candidatePath)) {
            return $candidatePath
        }

        $counter++
    }
}

function Format-ElapsedSeconds {
    param(
        [timespan]$Elapsed
    )

    return ('{0:N2}s' -f $Elapsed.TotalSeconds)
}

function Write-SnapshotSectionStatus {
    param(
        [string]$SectionName,
        [ValidateSet('Start', 'Done')]
        [string]$State,
        [timespan]$Elapsed = [timespan]::Zero
    )

    switch ($State) {
        'Start' {
            Write-Host ("[Snapshot] {0}..." -f $SectionName) -ForegroundColor DarkCyan
        }
        'Done' {
            Write-Host ("[Snapshot] {0} done in {1}" -f $SectionName, (Format-ElapsedSeconds -Elapsed $Elapsed)) -ForegroundColor DarkGray
        }
    }
}

function Invoke-TimedSnapshotSection {
    param(
        [string]$SectionName,
        [System.Collections.Generic.List[object]]$TimingSink,
        [scriptblock]$ScriptBlock
    )

    Write-SnapshotSectionStatus -SectionName $SectionName -State Start
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        return (& $ScriptBlock)
    }
    finally {
        $stopwatch.Stop()
        $elapsed = $stopwatch.Elapsed
        $TimingSink.Add([pscustomobject]@{
                Name = $SectionName
                DurationMs = [math]::Round($elapsed.TotalMilliseconds)
                DurationSeconds = [math]::Round($elapsed.TotalSeconds, 3)
            })
        Write-SnapshotSectionStatus -SectionName $SectionName -State Done -Elapsed $elapsed
    }
}

function Get-StageRecommendation {
    param(
        [string]$CurrentStage
    )

    switch -Regex ($CurrentStage) {
        '^BeforeInstall$' {
            return 'Πρόταση: Τρέξε το install τώρα και πάρε το AfterInstall snapshot ΑΜΕΣΩΣ μετά για λιγότερο noise.'
        }
        '^AfterInstall$' {
            return 'Πρόταση: Κάνε uninstall/cleanup τώρα και πάρε το AfterRemove ή AfterCleanup snapshot ΑΜΕΣΩΣ μετά.'
        }
        '^(AfterRemove|AfterCleanup)$' {
            return 'Πρόταση: Σύγκρινε αυτό το snapshot με το BeforeInstall και το AfterInstall για να δεις τι έμεινε πίσω.'
        }
        '^AfterCertCleanup$' {
            return 'Πρόταση: Σύγκρινε αυτό το snapshot με το BeforeInstall για να δεις αν έμειναν μόνο review-only root certs.'
        }
        default {
            return 'Πρόταση: Για καθαρό diff, πάρε τα snapshots όσο πιο κοντά γίνεται στο install ή cleanup event.'
        }
    }
}

if (-not (Test-CurrentSessionElevated)) {
    Write-Host 'Administrator rights are required for a reliable driver snapshot.' -ForegroundColor Yellow
    Write-Host 'Opening an elevated PowerShell window...' -ForegroundColor Cyan
    Start-SelfElevatedInstance
}

Initialize-SnapshotContext
if ($script:SnapshotSetupCanceled) {
    return
}

$global:DriverCheck_LastSnapshotSaveCanceled = $false

$timestamp = Get-Date
$snapshotLabel = Get-SnapshotLabel
$snapshotFolderLabel = Get-SnapshotFolderLabel -Timestamp $timestamp
$safeName = Convert-ToSafeSnapshotName -Value $snapshotFolderLabel
$snapshotPath = New-UniqueSnapshotPath -RootPath $OutputRoot -BaseName $safeName
New-Item -ItemType Directory -Path $snapshotPath -Force | Out-Null

$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$sectionTimings = [System.Collections.Generic.List[object]]::new()

$metadata = [pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    SnapshotName = $snapshotLabel
    CaseName = $CaseName
    Stage = $Stage
    SnapshotMode = $SnapshotMode
    SnapshotPath = $snapshotPath
    Timestamp = $timestamp
    IsAdministrator = $true
    FocusTerm = @($FocusTerm)
}

$bcdResult = Invoke-TimedSnapshotSection -SectionName 'Capture BCD state' -TimingSink $sectionTimings -ScriptBlock {
    Invoke-NativeCapture -FilePath 'bcdedit.exe' -Arguments @('/enum', 'all')
}
$pnpResult = Invoke-TimedSnapshotSection -SectionName 'Enumerate driver packages' -TimingSink $sectionTimings -ScriptBlock {
    Invoke-NativeCapture -FilePath 'pnputil.exe' -Arguments @('/enum-drivers')
}
$driverPackages = Invoke-TimedSnapshotSection -SectionName 'Parse driver packages' -TimingSink $sectionTimings -ScriptBlock {
    @(Convert-PnpUtilToDriverPackages -Lines $pnpResult.Output)
}
$serviceRegistry = Invoke-TimedSnapshotSection -SectionName 'Capture service registry snapshot' -TimingSink $sectionTimings -ScriptBlock {
    @(Get-ServiceRegistrySnapshot)
}
$pnpDevices = Invoke-TimedSnapshotSection -SectionName 'Capture PnP device snapshot' -TimingSink $sectionTimings -ScriptBlock {
    @(Get-PnpDeviceSnapshot -SnapshotMode $SnapshotMode)
}
$rootCerts = Invoke-TimedSnapshotSection -SectionName 'Capture ROOT certificates' -TimingSink $sectionTimings -ScriptBlock {
    @(Get-CertificateSnapshot -StorePath 'Cert:\LocalMachine\Root')
}
$trustedPublisherCerts = Invoke-TimedSnapshotSection -SectionName 'Capture TrustedPublisher certificates' -TimingSink $sectionTimings -ScriptBlock {
    @(Get-CertificateSnapshot -StorePath 'Cert:\LocalMachine\TrustedPublisher')
}
$registryFocus = Invoke-TimedSnapshotSection -SectionName 'Capture focused registry snapshot' -TimingSink $sectionTimings -ScriptBlock {
    Get-FocusedRegistrySnapshot -Terms $FocusTerm
}
$focusFiles = Invoke-TimedSnapshotSection -SectionName 'Capture focused file snapshot' -TimingSink $sectionTimings -ScriptBlock {
    @(Get-FocusFileSnapshot -Terms $FocusTerm)
}
$uninstallEntries = Invoke-TimedSnapshotSection -SectionName 'Capture uninstall entries' -TimingSink $sectionTimings -ScriptBlock {
    @(Get-UninstallEntrySnapshot)
}
$setupApi = Invoke-TimedSnapshotSection -SectionName 'Capture SetupAPI snapshot' -TimingSink $sectionTimings -ScriptBlock {
    Get-SetupApiSnapshot
}

$metadata | Add-Member -NotePropertyName CollectionTimings -NotePropertyValue @($sectionTimings.ToArray())

Invoke-TimedSnapshotSection -SectionName 'Write snapshot files' -TimingSink $sectionTimings -ScriptBlock {
    $metadata | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $snapshotPath 'metadata.json') -Encoding utf8
    $bcdResult.Output | Set-Content -Path (Join-Path $snapshotPath 'bcdedit.enum.all.txt') -Encoding utf8
    $pnpResult.Output | Set-Content -Path (Join-Path $snapshotPath 'pnputil.enum-drivers.txt') -Encoding utf8
    $driverPackages | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'driver-packages.json') -Encoding utf8
    $serviceRegistry | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'services.registry.json') -Encoding utf8
    $pnpDevices | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'pnp-devices.json') -Encoding utf8
    $rootCerts | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'cert-root.json') -Encoding utf8
    $trustedPublisherCerts | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'cert-trustedpublisher.json') -Encoding utf8
    $registryFocus | ConvertTo-Json -Depth 7 | Set-Content -Path (Join-Path $snapshotPath 'registry-focus.json') -Encoding utf8
    $focusFiles | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'focus-files.json') -Encoding utf8
    $uninstallEntries | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $snapshotPath 'uninstall-entries.json') -Encoding utf8
    $setupApi | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'setupapi.dev-log.json') -Encoding utf8
    $setupApi.Tail | Set-Content -Path (Join-Path $snapshotPath 'setupapi.dev-log.tail.txt') -Encoding utf8
}

$totalStopwatch.Stop()
$timingSummary = @($sectionTimings.ToArray() | Sort-Object DurationMs -Descending)
$timingReport = [pscustomobject]@{
    TotalDurationMs = [math]::Round($totalStopwatch.Elapsed.TotalMilliseconds)
    TotalDurationSeconds = [math]::Round($totalStopwatch.Elapsed.TotalSeconds, 3)
    Sections = $timingSummary
}
$timingReport | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'snapshot-timings.json') -Encoding utf8

Write-Host ''
Write-Host 'Driver Snapshot Saved' -ForegroundColor Green
Write-Host '---------------------' -ForegroundColor Green
Write-Host "Path           : $snapshotPath"
Write-Host "Label          : $snapshotLabel"
Write-Host "Snapshot mode  : $SnapshotMode"
Write-Host "Focus terms    : $($FocusTerm -join ', ')"
Write-Host "Driver packages: $(@($driverPackages).Count)"
Write-Host "PnP devices    : $(@($pnpDevices).Count)"
Write-Host "Service keys   : $(@($serviceRegistry).Count)"
Write-Host "Registry keys  : $(@($registryFocus.Keys).Count)"
Write-Host "Registry values: $(@($registryFocus.Values).Count)"
Write-Host "Focus files    : $(@($focusFiles).Count)"
Write-Host "Uninstall apps : $(@($uninstallEntries).Count)"
Write-Host "Total save time: $(Format-ElapsedSeconds -Elapsed $totalStopwatch.Elapsed)"
if (-not [string]::IsNullOrWhiteSpace($Stage)) {
    Write-Host "Stage          : $Stage"
}
Write-Host ''
Write-Host 'Slowest sections' -ForegroundColor Cyan
Write-Host '----------------' -ForegroundColor Cyan
foreach ($timedSection in @($timingSummary | Select-Object -First 5)) {
    Write-Host ("{0,-32} {1,8:N2}s" -f $timedSection.Name, $timedSection.DurationSeconds)
}
Write-Host ''
Write-Host "Timing report  : $(Join-Path $snapshotPath 'snapshot-timings.json')" -ForegroundColor DarkGray
Write-Host ''
Write-Host (Get-StageRecommendation -CurrentStage $Stage) -ForegroundColor DarkYellow
