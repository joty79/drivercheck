[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DriverName,
    [switch]$EmbeddedInLauncher
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ExitLiveDriverCheck = $false

function Test-CurrentSessionElevated {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-SelfElevatedInstance {
    $pwshPath = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
        $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    }

    $argumentList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if (-not [string]::IsNullOrWhiteSpace($DriverName)) {
        $argumentList += @('-DriverName', $DriverName)
    }
    if ($EmbeddedInLauncher) {
        $argumentList += '-EmbeddedInLauncher'
    }

    Start-Process -FilePath $pwshPath -ArgumentList $argumentList -Verb RunAs | Out-Null
    exit
}

function Get-UiIcons {
    if ($env:WT_SESSION) {
        return @{
            Info = '🔵'
            Warn = '⚠️'
            Ok = '✅'
            Item = '🔸'
            Input = '✍️'
            Path = '📁'
            Package = '📦'
            Device = '🧩'
        }
    }

    return @{
        Info = '[~]'
        Warn = '[!]'
        Ok = '[V]'
        Item = ' ->'
        Input = '[?]'
        Path = '[P]'
        Package = '[PKG]'
        Device = '[DEV]'
    }
}

function Clear-HostSafe {
    try {
        Clear-Host
    }
    catch {
        # Some hosts do not expose a normal console buffer.
    }
}

function Show-Header {
    Clear-HostSafe
    if ($EmbeddedInLauncher) {
        Write-Host ('=' * 62) -ForegroundColor Cyan
        Write-Host ' 🛠️ DriverCheck' -ForegroundColor Cyan -NoNewline
        Write-Host '  main launcher' -ForegroundColor DarkGray
        Write-Host ('=' * 62) -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'Live Driver Check' -ForegroundColor Green
        Write-Host '-----------------' -ForegroundColor Green
    }
    else {
        Write-Host '===============================================' -ForegroundColor Cyan
        Write-Host '           ΔΙΑΧΕΙΡΙΣΗ SYSTEM DRIVERS           ' -ForegroundColor White
        Write-Host '===============================================' -ForegroundColor Cyan
    }
    Write-Host ''
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

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $trimmedValue = $Value.Trim()
    if ($trimmedValue.Length -eq 1 -and [int][char]$trimmedValue[0] -eq 27) {
        return $true
    }

    return $trimmedValue -match '^(?i:esc|escape)$'
}

function Read-SingleChoiceMenu {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,
        [string]$Prompt = 'Choose an option',
        [string]$CancelLabel = 'Cancel'
    )

    function Get-ConsoleSafeLine {
        param(
            [string]$Text
        )

        $rawText = if ($null -eq $Text) { '' } else { [string]$Text }
        try {
            $maxWidth = [Math]::Max(20, [Console]::BufferWidth - 1)
        }
        catch {
            $maxWidth = 120
        }

        if ($rawText.Length -le $maxWidth) {
            return $rawText
        }

        return ($rawText.Substring(0, $maxWidth - 3) + '...')
    }

    function Read-SingleChoiceFallback {
        foreach ($item in $Items) {
            Write-Host (Get-ConsoleSafeLine -Text ("  [{0}] {1}" -f $item.Key, $item.Label)) -ForegroundColor $item.Color
        }
        Write-Host "  [ESC] $CancelLabel" -ForegroundColor DarkGray
        $choice = Read-HostTrimmed -Prompt $Prompt
        if (Test-IsEscapeInput -Value $choice) {
            return $null
        }

        return ($Items | Where-Object { $_.Key -eq $choice } | Select-Object -First 1)
    }

    if ([Console]::IsInputRedirected) {
        return Read-SingleChoiceFallback
    }

    $selectedIndex = 0
    $eraseLine = '{0}[K' -f [char]27
    $frameHeight = $Items.Count + 1

    try {
        $visibleBottom = [Console]::WindowTop + [Console]::WindowHeight - 1
        $availableRows = $visibleBottom - [Console]::CursorTop + 1
    }
    catch {
        $availableRows = 0
    }

    if ($availableRows -gt 0 -and $frameHeight -gt $availableRows) {
        Write-Host ''
        Write-Host 'Long list detected. Using stable prompt mode for this menu.' -ForegroundColor DarkYellow
        return Read-SingleChoiceFallback
    }

    [Console]::CursorVisible = $false
    try {
        $menuTop = [Console]::CursorTop
        $initialBufferWidth = [Console]::BufferWidth
        $initialWindowHeight = [Console]::WindowHeight
        for ($lineIndex = 0; $lineIndex -lt $frameHeight; $lineIndex++) {
            Write-Host ''
        }

        function Write-SingleChoiceFrame {
            [Console]::SetCursorPosition(0, $menuTop)
            for ($i = 0; $i -lt $Items.Count; $i++) {
                $item = $Items[$i]
                $isSelected = $i -eq $selectedIndex
                $prefix = if ($isSelected) { '❯' } else { ' ' }
                $line = Get-ConsoleSafeLine -Text ("{0} [{1}] {2}" -f $prefix, $item.Key, $item.Label)
                $color = if ($isSelected) { 'White' } else { $item.Color }
                Write-Host "$line$eraseLine" -ForegroundColor $color
            }
            $hintLine = Get-ConsoleSafeLine -Text "[UP/DOWN] Move  [ENTER] Select  [1-9] Shortcut  [ESC] $CancelLabel"
            Write-Host "$hintLine$eraseLine" -ForegroundColor DarkGray
        }

        while ($true) {
            if ([Console]::BufferWidth -ne $initialBufferWidth -or [Console]::WindowHeight -ne $initialWindowHeight) {
                [Console]::CursorVisible = $true
                Write-Host ''
                Write-Host 'Resize detected. Falling back to stable prompt for this menu.' -ForegroundColor DarkYellow
                return Read-SingleChoiceFallback
            }

            Write-SingleChoiceFrame
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' {
                    if ($selectedIndex -gt 0) {
                        $selectedIndex--
                    }
                }
                'DownArrow' {
                    if ($selectedIndex -lt ($Items.Count - 1)) {
                        $selectedIndex++
                    }
                }
                'Enter' {
                    return $Items[$selectedIndex]
                }
                'Escape' {
                    return $null
                }
                default {
                    $typedKey = [string]$key.KeyChar
                    for ($i = 0; $i -lt $Items.Count; $i++) {
                        if ($Items[$i].Key -eq $typedKey) {
                            $selectedIndex = $i
                            Write-SingleChoiceFrame
                            Start-Sleep -Milliseconds 90
                            return $Items[$selectedIndex]
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

function Wait-ActionOrRestart {
    Write-Host ''
    $exitText = if ($EmbeddedInLauncher) { 'επιστροφή στο main menu' } else { 'έξοδο (κλείσιμο παραθύρου)' }
    Write-Host "Πατήστε [ENTER] για νέα αναζήτηση ή [ESC] για $exitText..." -ForegroundColor DarkYellow

    try {
        while ($true) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Escape) {
                    $script:ExitLiveDriverCheck = $true
                    return $false
                }

                if ($key.Key -eq [ConsoleKey]::Enter) {
                    return $true
                }
            }

            Start-Sleep -Milliseconds 100
        }
    }
    catch {
        $fallbackPrompt = if ($EmbeddedInLauncher) {
            'ENTER για νέα αναζήτηση ή γράψε Q/ESC για επιστροφή στο main menu'
        }
        else {
            'ENTER για νέα αναζήτηση ή γράψε Q/ESC για έξοδο'
        }

        $fallback = Read-HostTrimmed -Prompt $fallbackPrompt
        if ($fallback -match '^(?i:q)$' -or (Test-IsEscapeInput -Value $fallback)) {
            $script:ExitLiveDriverCheck = $true
            return $false
        }
    }

    return $true
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

function Convert-ToDriverToken {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $trimmed = $Value.Trim().Trim('"')
    $pathMatch = [regex]::Match($trimmed, '(?i)([^\\/:*?""<>| ]+)\.(sys|inf|pnf|cat)\b')
    if ($pathMatch.Success) {
        return $pathMatch.Groups[1].Value
    }

    try {
        $leaf = Split-Path -Leaf $trimmed -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($leaf)) {
            return [System.IO.Path]::GetFileNameWithoutExtension($leaf)
        }
    }
    catch {
        # Fall back to trimmed value.
    }

    return $trimmed
}

function Get-FriendlyErrorMessage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message = ''
    if ($null -ne $ErrorRecord.Exception -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.Exception.Message)) {
        $message = [string]$ErrorRecord.Exception.Message
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$ErrorRecord)) {
        $message = [string]$ErrorRecord
    }

    if ([string]::IsNullOrWhiteSpace($message)) {
        return 'Unknown error.'
    }

    return (($message -split '\r?\n')[0]).Trim()
}

function Test-ServiceNotFoundError {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message = Get-FriendlyErrorMessage -ErrorRecord $ErrorRecord
    return (
        (Test-ContainsInsensitive -Value $message -Needle 'Cannot find any service with service name') -or
        (Test-ContainsInsensitive -Value $message -Needle 'No service found') -or
        (Test-ContainsInsensitive -Value $message -Needle 'Cannot find any service with name')
    )
}

function Test-ContainsInsensitive {
    param(
        [AllowEmptyString()]
        [string]$Value,
        [string]$Needle
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or [string]::IsNullOrWhiteSpace($Needle)) {
        return $false
    }

    return $Value.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Add-SearchTerm {
    param(
        [System.Collections.Generic.HashSet[string]]$Set,
        [AllowEmptyString()]
        [string]$Value,
        [switch]$LiteralOnly
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    $trimmedValue = $Value.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($trimmedValue)) {
        return
    }

    [void]$Set.Add($trimmedValue)

    if ($LiteralOnly) {
        return
    }

    $token = Convert-ToDriverToken -Value $trimmedValue
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        [void]$Set.Add($token)
        [void]$Set.Add("$token.inf")
    }
}

function Test-MatchesAnySearchTerm {
    param(
        [AllowEmptyString()]
        [string]$Value,
        [string[]]$SearchTerms
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $null -eq $SearchTerms -or $SearchTerms.Count -eq 0) {
        return $false
    }

    foreach ($searchTerm in $SearchTerms) {
        if (Test-ContainsInsensitive -Value $Value -Needle $searchTerm) {
            return $true
        }
    }

    return $false
}

function Add-OrUpdatePnpEvidenceEntry {
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
        [string]$Status,
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
        [string]$ClassGuid,
        [AllowEmptyString()]
        [string]$EnumeratorName,
        [AllowEmptyString()]
        [string]$Parent,
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
    elseif (-not [string]::IsNullOrWhiteSpace($InfName)) {
        "INF::$InfName"
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
            Status = ''
            InfName = ''
            DriverName = ''
            Manufacturer = ''
            DriverProviderName = ''
            MatchingDeviceId = ''
            ServiceName = ''
            DriverInfSection = ''
            DriverKey = ''
            ClassGuid = ''
            EnumeratorName = ''
            Parent = ''
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
            @{ Name = 'Status'; Value = $Status },
            @{ Name = 'InfName'; Value = $InfName },
            @{ Name = 'DriverName'; Value = $DriverName },
            @{ Name = 'Manufacturer'; Value = $Manufacturer },
            @{ Name = 'DriverProviderName'; Value = $DriverProviderName },
            @{ Name = 'MatchingDeviceId'; Value = $MatchingDeviceId },
            @{ Name = 'ServiceName'; Value = $ServiceName },
            @{ Name = 'DriverInfSection'; Value = $DriverInfSection },
            @{ Name = 'DriverKey'; Value = $DriverKey },
            @{ Name = 'ClassGuid'; Value = $ClassGuid },
            @{ Name = 'EnumeratorName'; Value = $EnumeratorName },
            @{ Name = 'Parent'; Value = $Parent },
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
                        OriginalToken = Convert-ToDriverToken -Value $current['Original Name']
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
                OriginalToken = Convert-ToDriverToken -Value $current['Original Name']
                ProviderName = $current['Provider Name']
                ClassName = $current['Class Name']
                ClassGuid = $current['Class GUID']
                DriverVersion = $current['Driver Version']
                SignerName = $current['Signer Name']
            })
    }

    return $packages.ToArray()
}

function Get-ServiceRegistryInventory {
    $services = foreach ($serviceKey in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue) {
        try {
            $item = Get-ItemProperty -Path $serviceKey.PSPath -ErrorAction Stop
            [pscustomobject]@{
                Name = $serviceKey.PSChildName
                NameToken = Convert-ToDriverToken -Value $serviceKey.PSChildName
                DisplayName = [string]$item.DisplayName
                ImagePath = [string]$item.ImagePath
                ImageToken = Convert-ToDriverToken -Value ([string]$item.ImagePath)
                KeyPath = $serviceKey.PSPath
                Start = $item.Start
                Type = $item.Type
            }
        }
        catch {
            continue
        }
    }

    return @($services | Sort-Object Name)
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

function Get-DriverQueryEntriesSafe {
    param(
        [string]$ExactDriver
    )

    if ([string]::IsNullOrWhiteSpace($ExactDriver)) {
        return @()
    }

    try {
        $csvLines = @(driverquery /v /fo csv 2>$null)
        if ($csvLines.Count -eq 0) {
            return @()
        }

        $parsedEntries = @($csvLines | ConvertFrom-Csv)
        if ($parsedEntries.Count -eq 0) {
            return @()
        }

        return @(
            $parsedEntries |
                Where-Object { [string]$_.'Module Name' -ieq $ExactDriver } |
                ForEach-Object {
                    [pscustomobject]@{
                        ModuleName  = [string]$_.'Module Name'
                        DisplayName = [string]$_.'Display Name'
                        Description = [string]$_.'Description'
                        DriverType  = [string]$_.'Driver Type'
                        StartMode   = [string]$_.'Start Mode'
                        State       = [string]$_.'State'
                        Status      = [string]$_.'Status'
                        LinkDate    = [string]$_.'Link Date'
                        Path        = [string]$_.'Path'
                        InitBytes   = [string]$_.'Init(bytes)'
                    }
                }
        )
    }
    catch {
        return @()
    }
}

function Get-MatchingTerms {
    param(
        [string[]]$Terms,
        [string[]]$Texts
    )

    $matches = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($term in @($Terms)) {
        if ([string]::IsNullOrWhiteSpace($term)) {
            continue
        }

        foreach ($text in @($Texts)) {
            if (Test-ContainsInsensitive -Value ([string]$text) -Needle $term) {
                [void]$matches.Add($term)
            }
        }
    }

    return @($matches | Sort-Object)
}

function Get-FocusedRegistryEvidence {
    param(
        [string]$ExactDriver,
        [object[]]$DriverPackages,
        [object[]]$RegistryKeys,
        [object[]]$PnpDevices
    )

    $searchTerms = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    Add-SearchTerm -Set $searchTerms -Value $ExactDriver
    Add-SearchTerm -Set $searchTerms -Value "$ExactDriver.inf"

    foreach ($package in @($DriverPackages)) {
        foreach ($term in @($package.PublishedName, $package.OriginalName, $package.OriginalToken)) {
            Add-SearchTerm -Set $searchTerms -Value ([string]$term)
        }
    }

    foreach ($registryKey in @($RegistryKeys)) {
        foreach ($term in @($registryKey.Name, $registryKey.ImageToken)) {
            Add-SearchTerm -Set $searchTerms -Value ([string]$term)
        }
    }

    foreach ($device in @($PnpDevices)) {
        Add-SearchTerm -Set $searchTerms -Value ([string]$device.InstanceId) -LiteralOnly
        foreach ($term in @(
                $device.InfName,
                $device.DriverName,
                $device.MatchingDeviceId,
                $device.ServiceName
            )) {
            Add-SearchTerm -Set $searchTerms -Value ([string]$term)
        }
    }

    $terms = @($searchTerms | Sort-Object)
    if ($terms.Count -eq 0) {
        return [pscustomobject]@{
            Keys = @()
            Values = @()
        }
    }

    $roots = @(
        @{ Name = 'Services'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Services' },
        @{ Name = 'Enum'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Enum' },
        @{ Name = 'Class'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class' },
        @{ Name = 'Uninstall'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
        @{ Name = 'UninstallWow6432'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' }
    )

    $keyHits = New-Object System.Collections.Generic.List[object]
    $valueHits = New-Object System.Collections.Generic.List[object]
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenValues = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root.Path)) {
            continue
        }

        foreach ($registryKey in @(Get-ChildItem -LiteralPath $root.Path -Recurse -ErrorAction SilentlyContinue)) {
            $keyPath = ''
            try {
                $keyPath = $registryKey.Name
            }
            catch {
                continue
            }

            if ([string]::IsNullOrWhiteSpace($keyPath)) {
                continue
            }

            $keyMatchedTerms = @(Get-MatchingTerms -Terms $terms -Texts @($keyPath))
            if ($keyMatchedTerms.Count -gt 0) {
                $identity = $keyPath
                if ($seenKeys.Add($identity)) {
                    $keyHits.Add([pscustomobject]@{
                            Identity = $identity
                            RootName = $root.Name
                            KeyPath = $keyPath
                            MatchedTerms = ($keyMatchedTerms -join ', ')
                            MatchSource = 'KeyPath'
                        })
                }
            }

            try {
                $properties = Get-ItemProperty -LiteralPath $registryKey.PSPath -ErrorAction Stop
            }
            catch {
                continue
            }

            foreach ($property in $properties.PSObject.Properties) {
                if ($property.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) {
                    continue
                }

                $valueName = [string]$property.Name
                $valueData = Convert-RegistryValueDataToString -ValueData $property.Value
                $matchedTerms = @(Get-MatchingTerms -Terms $terms -Texts @($valueName, $valueData))
                if ($matchedTerms.Count -eq 0) {
                    continue
                }

                $identity = '{0}::{1}' -f $keyPath, $valueName
                if ($seenValues.Add($identity)) {
                    $valueHits.Add([pscustomobject]@{
                            Identity = $identity
                            RootName = $root.Name
                            KeyPath = $keyPath
                            ValueName = $valueName
                            ValueData = $valueData
                            MatchedTerms = ($matchedTerms -join ', ')
                            MatchSource = 'Value'
                        })
                }
            }
        }
    }

    return [pscustomobject]@{
        Keys = @($keyHits.ToArray() | Sort-Object KeyPath)
        Values = @($valueHits.ToArray() | Sort-Object KeyPath, ValueName)
    }
}

function Get-RuntimeServicesByNameSafe {
    param(
        [string[]]$ServiceNames
    )

    $services = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]

    foreach ($serviceName in @($ServiceNames) | Sort-Object -Unique) {
        if ([string]::IsNullOrWhiteSpace($serviceName)) {
            continue
        }

        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            if ($null -ne $service) {
                $services.Add($service)
            }
        }
        catch {
            if (Test-ServiceNotFoundError -ErrorRecord $_) {
                continue
            }

            $friendlyMessage = Get-FriendlyErrorMessage -ErrorRecord $_
            $warnings.Add("Runtime service query for [$serviceName] failed: $friendlyMessage")
        }
    }

    return [pscustomobject]@{
        Services = @($services.ToArray() | Sort-Object Name)
        Warnings = @($warnings.ToArray() | Sort-Object -Unique)
    }
}

function Get-ProtectedWindowsServiceTokens {
    $protectedTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($token in @(
            'WUDFWpdFs',
            'WUDFRd',
            'WudfSvc',
            'WudfPf',
            'UMDFReflector'
        )) {
        [void]$protectedTokens.Add($token)
    }

    return $protectedTokens
}

function Resolve-ServiceImagePath {
    param(
        [AllowEmptyString()]
        [string]$ImagePath
    )

    if ([string]::IsNullOrWhiteSpace($ImagePath)) {
        return ''
    }

    $candidatePath = $ImagePath.Trim()
    $pathMatch = [regex]::Match($candidatePath, '(?i)(?<path>(?:%[^%]+%|\\SystemRoot|[A-Z]:|System32\\|\\System32\\)[^"]+?\.(sys|exe|dll))')
    if ($pathMatch.Success) {
        $candidatePath = $pathMatch.Groups['path'].Value
    }
    else {
        $candidatePath = ($candidatePath -split '\s+')[0].Trim('"')
    }

    $candidatePath = [Environment]::ExpandEnvironmentVariables($candidatePath)
    if ($candidatePath -match '^(?i)\\SystemRoot\\') {
        $candidatePath = Join-Path $env:windir ($candidatePath.Substring('\SystemRoot\'.Length))
    }
    elseif ($candidatePath -match '^(?i)System32\\') {
        $candidatePath = Join-Path $env:windir $candidatePath
    }
    elseif ($candidatePath -match '^(?i)\\System32\\') {
        $candidatePath = Join-Path $env:windir ($candidatePath.TrimStart('\'))
    }

    return $candidatePath.Trim('"')
}

function Test-PathUnderWindowsRoot {
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
        $windowsRoot = [System.IO.Path]::GetFullPath($env:windir)
        return $fullPath.StartsWith($windowsRoot, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Get-FileVersionMetadataSafe {
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            CompanyName = ''
            ProductName = ''
            FileDescription = ''
            OriginalFilename = ''
            LegalCopyright = ''
            FileVersion = ''
            ProductVersion = ''
        }
    }

    try {
        $versionInfo = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo
        return [pscustomobject]@{
            CompanyName = [string]$versionInfo.CompanyName
            ProductName = [string]$versionInfo.ProductName
            FileDescription = [string]$versionInfo.FileDescription
            OriginalFilename = [string]$versionInfo.OriginalFilename
            LegalCopyright = [string]$versionInfo.LegalCopyright
            FileVersion = [string]$versionInfo.FileVersion
            ProductVersion = [string]$versionInfo.ProductVersion
        }
    }
    catch {
        return [pscustomobject]@{
            CompanyName = ''
            ProductName = ''
            FileDescription = ''
            OriginalFilename = ''
            LegalCopyright = ''
            FileVersion = ''
            ProductVersion = ''
        }
    }
}

function Get-ProtectionInfoForEvidence {
    param(
        [string]$ExactDriver,
        [object[]]$DriverPackages,
        [object[]]$RegistryKeys,
        [AllowEmptyString()]
        [string]$SystemFilePath,
        [bool]$SystemFileExists,
        [object[]]$AdditionalFiles
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $metadataHints = New-Object System.Collections.Generic.List[string]
    $protectedTokens = Get-ProtectedWindowsServiceTokens

    if ($protectedTokens.Contains($ExactDriver)) {
        [void]$reasons.Add("Known protected Windows service token: $ExactDriver")
    }

    foreach ($package in @($DriverPackages)) {
        if (Test-ContainsInsensitive -Value $package.ProviderName -Needle 'Microsoft') {
            [void]$reasons.Add("Microsoft driver package provider: $($package.PublishedName) / $($package.OriginalName)")
        }
    }

    $candidatePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($SystemFileExists -and -not [string]::IsNullOrWhiteSpace($SystemFilePath)) {
        [void]$candidatePaths.Add($SystemFilePath)
    }

    foreach ($registryKey in @($RegistryKeys)) {
        $resolvedImagePath = Resolve-ServiceImagePath -ImagePath $registryKey.ImagePath
        if (-not [string]::IsNullOrWhiteSpace($resolvedImagePath)) {
            [void]$candidatePaths.Add($resolvedImagePath)
        }
    }

    foreach ($file in @($AdditionalFiles)) {
        if ($null -ne $file -and -not [string]::IsNullOrWhiteSpace([string]$file.FullName)) {
            [void]$candidatePaths.Add([string]$file.FullName)
        }
    }

    foreach ($candidatePath in @($candidatePaths)) {
        if (-not (Test-PathUnderWindowsRoot -Path $candidatePath)) {
            continue
        }

        $fileMetadata = Get-FileVersionMetadataSafe -Path $candidatePath
        $looksMicrosoftOwned = $false

        if (Test-ContainsInsensitive -Value $fileMetadata.CompanyName -Needle 'Microsoft') {
            [void]$reasons.Add("Microsoft-owned Windows binary: $candidatePath")
            $looksMicrosoftOwned = $true
        }
        elseif (
            (Test-ContainsInsensitive -Value $fileMetadata.ProductName -Needle 'Windows') -or
            (Test-ContainsInsensitive -Value $fileMetadata.LegalCopyright -Needle 'Microsoft')
        ) {
            [void]$reasons.Add("Windows OS metadata suggests protected system binary: $candidatePath")
            $looksMicrosoftOwned = $true
        }

        if ($looksMicrosoftOwned) {
            if (-not [string]::IsNullOrWhiteSpace($fileMetadata.FileDescription)) {
                [void]$metadataHints.Add("Description: $($fileMetadata.FileDescription)")
            }
            if (-not [string]::IsNullOrWhiteSpace($fileMetadata.ProductName)) {
                [void]$metadataHints.Add("Product: $($fileMetadata.ProductName)")
            }
            if (-not [string]::IsNullOrWhiteSpace($fileMetadata.OriginalFilename)) {
                [void]$metadataHints.Add("Original filename: $($fileMetadata.OriginalFilename)")
            }
            if (-not [string]::IsNullOrWhiteSpace($fileMetadata.LegalCopyright) -and (Test-ContainsInsensitive -Value $fileMetadata.LegalCopyright -Needle 'Microsoft')) {
                [void]$metadataHints.Add('Copyright: Microsoft Corporation')
            }
        }
    }

    return [pscustomobject]@{
        IsProtected = ($reasons.Count -gt 0)
        Reasons = @($reasons | Sort-Object -Unique)
        MetadataHints = @($metadataHints | Sort-Object -Unique)
    }
}

function Test-ActionableCleanupEvidence {
    param(
        [object]$Evidence
    )

    return (
        $Evidence.DriverPackages.Count -gt 0 -or
        $Evidence.PnpDevices.Count -gt 0 -or
        $Evidence.SystemFileExists -or
        $Evidence.AdditionalFiles.Count -gt 0 -or
        $Evidence.DriverQueryEntries.Count -gt 0
    )
}

function Add-CandidateToken {
    param(
        [System.Collections.Generic.HashSet[string]]$Set,
        [AllowEmptyString()]
        [string]$Value
    )

    $token = Convert-ToDriverToken -Value $Value
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        [void]$Set.Add($token)
    }
}

function Get-AdditionalEvidenceFiles {
    param(
        [string]$ExactDriver
    )

    $roots = @(
        (Join-Path $env:windir 'System32\drivers'),
        (Join-Path $env:windir 'INF'),
        (Join-Path $env:windir 'System32\DriverStore\FileRepository')
    )

    $files = New-Object System.Collections.Generic.List[object]
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        Get-ChildItem -Path $root -Filter "*$ExactDriver*" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if ($seen.Add($_.FullName)) {
                $files.Add([pscustomobject]@{
                        FullName = $_.FullName
                        Length = $_.Length
                    })
            }
        }
    }

    return @($files.ToArray() | Sort-Object FullName)
}

function Get-PnpEvidence {
    param(
        [string]$ExactDriver,
        [object[]]$DriverPackages,
        [object[]]$RegistryKeys
    )

    $searchTerms = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    Add-SearchTerm -Set $searchTerms -Value $ExactDriver
    Add-SearchTerm -Set $searchTerms -Value "$ExactDriver.inf"

    foreach ($package in @($DriverPackages)) {
        foreach ($packageTerm in @($package.PublishedName, $package.OriginalName, $package.OriginalToken)) {
            Add-SearchTerm -Set $searchTerms -Value ([string]$packageTerm)
        }
    }

    foreach ($registryKey in @($RegistryKeys)) {
        foreach ($registryTerm in @($registryKey.Name, $registryKey.DisplayName, $registryKey.ImagePath, $registryKey.ImageToken)) {
            Add-SearchTerm -Set $searchTerms -Value ([string]$registryTerm)
        }
    }

    $allSearchTerms = @($searchTerms | Sort-Object)
    if ($allSearchTerms.Count -eq 0) {
        return @()
    }

    $deviceMap = @{}

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

    foreach ($device in @(Get-PnpDevice -PresentOnly:$false -ErrorAction SilentlyContinue)) {
        $candidateValues = @(
            [string]$device.FriendlyName,
            [string]$device.Name,
            [string]$device.InstanceId,
            [string]$device.Class
        )

        $matchesSearch = $false
        foreach ($candidateValue in $candidateValues) {
            if (Test-MatchesAnySearchTerm -Value $candidateValue -SearchTerms $allSearchTerms) {
                $matchesSearch = $true
                break
            }
        }

        if ($matchesSearch) {
            $displayName = if (-not [string]::IsNullOrWhiteSpace([string]$device.FriendlyName)) {
                [string]$device.FriendlyName
            }
            else {
                [string]$device.Name
            }

            Add-OrUpdatePnpEvidenceEntry -Map $deviceMap `
                -InstanceId ([string]$device.InstanceId) `
                -FriendlyName $displayName `
                -Class ([string]$device.Class) `
                -Present ([string]$device.Present) `
                -Status ([string]$device.Status) `
                -InfName '' `
                -DriverName '' `
                -Manufacturer '' `
                -DriverProviderName '' `
                -MatchingDeviceId '' `
                -ServiceName '' `
                -DriverInfSection '' `
                -DriverKey '' `
                -ClassGuid '' `
                -EnumeratorName '' `
                -Parent '' `
                -DriverVersion '' `
                -DriverDate '' `
                -Source 'Get-PnpDevice'
        }
    }

    foreach ($signedDriver in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue)) {
        $candidateValues = @(
            [string]$signedDriver.DeviceName,
            [string]$signedDriver.FriendlyName,
            [string]$signedDriver.Description,
            [string]$signedDriver.DeviceID,
            [string]$signedDriver.InfName,
            [string]$signedDriver.DriverName,
            [string]$signedDriver.Manufacturer,
            [string]$signedDriver.DriverProviderName
        )

        $matchesSearch = $false
        foreach ($candidateValue in $candidateValues) {
            if (Test-MatchesAnySearchTerm -Value $candidateValue -SearchTerms $allSearchTerms) {
                $matchesSearch = $true
                break
            }
        }

        if ($matchesSearch) {
            $displayName = if (-not [string]::IsNullOrWhiteSpace([string]$signedDriver.DeviceName)) {
                [string]$signedDriver.DeviceName
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$signedDriver.FriendlyName)) {
                [string]$signedDriver.FriendlyName
            }
            else {
                [string]$signedDriver.Description
            }

            Add-OrUpdatePnpEvidenceEntry -Map $deviceMap `
                -InstanceId ([string]$signedDriver.DeviceID) `
                -FriendlyName $displayName `
                -Class ([string]$signedDriver.DeviceClass) `
                -Present '' `
                -Status ([string]$signedDriver.Status) `
                -InfName ([string]$signedDriver.InfName) `
                -DriverName ([string]$signedDriver.DriverName) `
                -Manufacturer ([string]$signedDriver.Manufacturer) `
                -DriverProviderName ([string]$signedDriver.DriverProviderName) `
                -MatchingDeviceId '' `
                -ServiceName '' `
                -DriverInfSection '' `
                -DriverKey '' `
                -ClassGuid ([string]$signedDriver.ClassGuid) `
                -EnumeratorName '' `
                -Parent '' `
                -DriverVersion ([string]$signedDriver.DriverVersion) `
                -DriverDate ([string]$signedDriver.DriverDate) `
                -Source 'Win32_PnPSignedDriver'
        }
    }

    foreach ($entry in @($deviceMap.Values)) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.InstanceId)) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$entry.InfName)) {
            $entry.InfName = Get-PnpPropertyValueSafe -InstanceId $entry.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.MatchingDeviceId)) {
            $entry.MatchingDeviceId = Get-PnpPropertyValueSafe -InstanceId $entry.InstanceId -KeyName 'DEVPKEY_Device_MatchingDeviceId'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.ServiceName)) {
            $entry.ServiceName = Get-PnpPropertyValueSafe -InstanceId $entry.InstanceId -KeyName 'DEVPKEY_Device_Service'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.DriverInfSection)) {
            $entry.DriverInfSection = Get-PnpPropertyValueSafe -InstanceId $entry.InstanceId -KeyName 'DEVPKEY_Device_DriverInfSection'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.DriverKey)) {
            $entry.DriverKey = Get-PnpPropertyValueSafe -InstanceId $entry.InstanceId -KeyName 'DEVPKEY_Device_Driver'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.ClassGuid)) {
            $entry.ClassGuid = Get-PnpPropertyValueSafe -InstanceId $entry.InstanceId -KeyName 'DEVPKEY_Device_ClassGuid'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.EnumeratorName)) {
            $entry.EnumeratorName = Get-PnpPropertyValueSafe -InstanceId $entry.InstanceId -KeyName 'DEVPKEY_Device_EnumeratorName'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.Parent)) {
            $entry.Parent = Get-PnpPropertyValueSafe -InstanceId $entry.InstanceId -KeyName 'DEVPKEY_Device_Parent'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.Manufacturer)) {
            $entry.Manufacturer = Get-PnpPropertyValueSafe -InstanceId $entry.InstanceId -KeyName 'DEVPKEY_Device_Manufacturer'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.DriverProviderName)) {
            $entry.DriverProviderName = Get-PnpPropertyValueSafe -InstanceId $entry.InstanceId -KeyName 'DEVPKEY_Device_DriverProvider'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.DriverVersion)) {
            $entry.DriverVersion = Get-PnpPropertyValueSafe -InstanceId $entry.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion'
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.DriverDate)) {
            $entry.DriverDate = Get-PnpPropertyValueSafe -InstanceId $entry.InstanceId -KeyName 'DEVPKEY_Device_DriverDate'
        }
    }

    return @($deviceMap.Values | Sort-Object InstanceId, FriendlyName)
}

function Get-MatchedDriverPackages {
    param(
        [string]$ExactDriver,
        [object[]]$DriverPackages,
        [object[]]$PnpDevices
    )

    $matchedPackages = New-Object System.Collections.Generic.List[object]
    $seenPublishedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $packageTerms = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    Add-SearchTerm -Set $packageTerms -Value $ExactDriver
    Add-SearchTerm -Set $packageTerms -Value "$ExactDriver.inf"

    foreach ($device in @($PnpDevices)) {
        foreach ($term in @(
                $device.InfName,
                $device.DriverName,
                $device.MatchingDeviceId,
                $device.ServiceName,
                $device.DriverInfSection,
                $device.FriendlyName,
                $device.InstanceId
            )) {
            Add-SearchTerm -Set $packageTerms -Value ([string]$term)
        }
    }

    foreach ($package in @($DriverPackages)) {
        $matchesPackage = (
            $package.OriginalToken -ieq $ExactDriver -or
            (Test-MatchesAnySearchTerm -Value ([string]$package.PublishedName) -SearchTerms @($packageTerms)) -or
            (Test-MatchesAnySearchTerm -Value ([string]$package.OriginalName) -SearchTerms @($packageTerms))
        )

        if ($matchesPackage) {
            $publishedName = [string]$package.PublishedName
            if ([string]::IsNullOrWhiteSpace($publishedName) -or $seenPublishedNames.Add($publishedName)) {
                [void]$matchedPackages.Add($package)
            }
        }
    }

    return @($matchedPackages.ToArray() | Sort-Object PublishedName)
}

function Get-SetupApiLines {
    $logPath = Join-Path $env:windir 'INF\setupapi.dev.log'
    if (-not (Test-Path -LiteralPath $logPath)) {
        return @()
    }

    try {
        $item = Get-Item -LiteralPath $logPath -ErrorAction Stop
        if ($item.Length -gt 60MB) {
            return @(Get-Content -LiteralPath $logPath -Tail 15000 -ErrorAction SilentlyContinue)
        }

        return @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
    }
    catch {
        return @()
    }
}

function Find-SetupApiAnchorWindows {
    param(
        [string[]]$Lines,
        [string[]]$AnchorTerms
    )

    if ($Lines.Count -eq 0 -or $AnchorTerms.Count -eq 0) {
        return @()
    }

    $validTerms = @($AnchorTerms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($validTerms.Count -eq 0) {
        return @()
    }

    $anchorIndexes = New-Object System.Collections.Generic.List[int]
    for ($lineIndex = 0; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $lineText = [string]$Lines[$lineIndex]
        foreach ($term in $validTerms) {
            if (Test-ContainsInsensitive -Value $lineText -Needle $term) {
                $anchorIndexes.Add($lineIndex)
                break
            }
        }
    }

    if ($anchorIndexes.Count -eq 0) {
        return @()
    }

    $windowIndexes = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($anchorIndex in $anchorIndexes) {
        $startIndex = [Math]::Max(0, $anchorIndex - 80)
        $endIndex = [Math]::Min($Lines.Count - 1, $anchorIndex + 400)
        for ($windowIndex = $startIndex; $windowIndex -le $endIndex; $windowIndex++) {
            [void]$windowIndexes.Add($windowIndex)
        }
    }

    return @($windowIndexes | Sort-Object | ForEach-Object { [string]$Lines[$_] })
}

function Add-RelatedReason {
    param(
        [hashtable]$Entry,
        [string]$Reason
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        return
    }

    if (-not $Entry.Reasons.Contains($Reason)) {
        [void]$Entry.Reasons.Add($Reason)
    }
}

function Add-RelatedValue {
    param(
        [hashtable]$Entry,
        [string]$CollectionName,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if (-not $Entry[$CollectionName].Contains($Value)) {
        [void]$Entry[$CollectionName].Add($Value)
    }
}

function Get-OrCreateRelatedEntry {
    param(
        [hashtable]$Map,
        [string]$Token
    )

    if (-not $Map.ContainsKey($Token)) {
        $Map[$Token] = @{
            Token = $Token
            Packages = [System.Collections.Generic.List[string]]::new()
            Services = [System.Collections.Generic.List[string]]::new()
            Reasons = [System.Collections.Generic.List[string]]::new()
        }
    }

    return $Map[$Token]
}

function Get-RelatedPackageDisplayLines {
    param(
        [string[]]$PackageTexts
    )

    if ($null -eq $PackageTexts -or $PackageTexts.Count -eq 0) {
        return @()
    }

    $packageMap = [ordered]@{}
    foreach ($packageText in $PackageTexts) {
        if ([string]::IsNullOrWhiteSpace($packageText)) {
            continue
        }

        $parts = @($packageText -split '\s+::\s+')
        $publishedName = ''
        $originalName = ''

        if ($parts.Count -ge 2) {
            $publishedName = [string]$parts[0]
            $originalName = [string]$parts[1]
        }
        else {
            $originalName = [string]$packageText
        }

        if ([string]::IsNullOrWhiteSpace($originalName)) {
            $originalName = '(unknown package)'
        }

        if (-not $packageMap.Contains($originalName)) {
            $packageMap[$originalName] = [System.Collections.Generic.List[string]]::new()
        }

        if (-not [string]::IsNullOrWhiteSpace($publishedName) -and -not $packageMap[$originalName].Contains($publishedName)) {
            [void]$packageMap[$originalName].Add($publishedName)
        }
    }

    $displayLines = foreach ($originalName in $packageMap.Keys) {
        $publishedNames = @($packageMap[$originalName] | Sort-Object -Unique)
        if ($publishedNames.Count -gt 0) {
            [pscustomobject]@{
                OriginalName = $originalName
                DisplayText = "$originalName ($($publishedNames -join ', '))"
            }
        }
        else {
            [pscustomobject]@{
                OriginalName = $originalName
                DisplayText = $originalName
            }
        }
    }

    return @($displayLines | Sort-Object OriginalName)
}

function Get-RelatedComponentHints {
    param(
        [string]$ExactDriver,
        [object[]]$MatchedPackages,
        [object[]]$MatchedRegistryKeys,
        [object[]]$AllPackages,
        [object[]]$ServiceRegistry
    )

    $setupApiLines = @(Get-SetupApiLines)
    if ($setupApiLines.Count -eq 0) {
        return @()
    }

    $anchorTerms = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$anchorTerms.Add($ExactDriver)
    [void]$anchorTerms.Add("$ExactDriver.inf")

    foreach ($package in $MatchedPackages) {
        foreach ($term in @($package.PublishedName, $package.OriginalName, $package.OriginalToken)) {
            if (-not [string]::IsNullOrWhiteSpace($term)) {
                [void]$anchorTerms.Add([string]$term)
            }
        }
    }

    foreach ($registryKey in $MatchedRegistryKeys) {
        foreach ($term in @($registryKey.Name, $registryKey.ImagePath, $registryKey.ImageToken)) {
            if (-not [string]::IsNullOrWhiteSpace($term)) {
                [void]$anchorTerms.Add([string]$term)
            }
        }
    }

    $windowLines = @(Find-SetupApiAnchorWindows -Lines $setupApiLines -AnchorTerms @($anchorTerms))
    if ($windowLines.Count -eq 0) {
        return @()
    }

    $relatedMap = @{}

    foreach ($package in $AllPackages) {
        $token = [string]$package.OriginalToken
        if ([string]::IsNullOrWhiteSpace($token) -or $token -ieq $ExactDriver) {
            continue
        }

        $packageTerms = @($package.PublishedName, $package.OriginalName, "$token.inf") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $packageMatched = $false

        foreach ($lineText in $windowLines) {
            foreach ($packageTerm in $packageTerms) {
                if (Test-ContainsInsensitive -Value $lineText -Needle $packageTerm) {
                    $packageMatched = $true
                    break
                }
            }

            if ($packageMatched) {
                break
            }
        }

        if ($packageMatched) {
            $entry = Get-OrCreateRelatedEntry -Map $relatedMap -Token $token
            Add-RelatedValue -Entry $entry -CollectionName 'Packages' -Value "$($package.PublishedName) :: $($package.OriginalName)"
            Add-RelatedReason -Entry $entry -Reason "SetupAPI window references package $($package.PublishedName) / $($package.OriginalName)."
        }
    }

    foreach ($serviceEntry in $ServiceRegistry) {
        $serviceName = [string]$serviceEntry.Name
        $serviceToken = [string]$serviceEntry.NameToken
        if ([string]::IsNullOrWhiteSpace($serviceName) -or [string]::IsNullOrWhiteSpace($serviceToken) -or $serviceToken -ieq $ExactDriver) {
            continue
        }

        $servicePatterns = @(
            "Add Service:.*'$([regex]::Escape($serviceName))'",
            "Service Name\\s*=\\s*$([regex]::Escape($serviceName))\\b",
            "service '$([regex]::Escape($serviceName))'",
            "\\b$([regex]::Escape($serviceName))\\b"
        )

        $serviceMatched = $false
        foreach ($lineText in $windowLines) {
            foreach ($servicePattern in $servicePatterns) {
                if ($lineText -match "(?i)$servicePattern") {
                    $serviceMatched = $true
                    break
                }
            }

            if ($serviceMatched) {
                break
            }
        }

        if ($serviceMatched) {
            $entry = Get-OrCreateRelatedEntry -Map $relatedMap -Token $serviceToken
            Add-RelatedValue -Entry $entry -CollectionName 'Services' -Value $serviceName
            Add-RelatedReason -Entry $entry -Reason "SetupAPI window references service $serviceName."
        }
    }

    $results = foreach ($entry in $relatedMap.Values) {
        $relatedRegistryKeys = @($ServiceRegistry | Where-Object {
                $_.NameToken -ieq $entry.Token -or
                $_.ImageToken -ieq $entry.Token -or
                $_.Name -in $entry.Services
            })
        $relatedPackages = @($AllPackages | Where-Object {
                $_.OriginalToken -ieq $entry.Token
            })
        $protectionInfo = Get-ProtectionInfoForEvidence -ExactDriver $entry.Token -DriverPackages $relatedPackages -RegistryKeys $relatedRegistryKeys -SystemFilePath '' -SystemFileExists $false -AdditionalFiles @()

        [pscustomobject]@{
            Token = $entry.Token
            Packages = @($entry.Packages | Sort-Object -Unique)
            Services = @($entry.Services | Sort-Object -Unique)
            Reasons = @($entry.Reasons | Sort-Object -Unique)
            IsProtected = $protectionInfo.IsProtected
            ProtectionReasons = @($protectionInfo.Reasons | Sort-Object -Unique)
            ProtectionMetadataHints = @($protectionInfo.MetadataHints | Sort-Object -Unique)
        }
    }

    return @($results | Sort-Object Token)
}

function Find-DriverCandidates {
    param(
        [string]$SearchTerm,
        [object[]]$ServiceRegistry,
        [object[]]$DriverPackages
    )

    $candidateSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $sysPathBase = Join-Path $env:SystemRoot 'System32\drivers'
    $infPathBase = Join-Path $env:SystemRoot 'INF'

    foreach ($entry in $ServiceRegistry) {
        if (
            (Test-ContainsInsensitive -Value $entry.Name -Needle $SearchTerm) -or
            (Test-ContainsInsensitive -Value $entry.DisplayName -Needle $SearchTerm) -or
            (Test-ContainsInsensitive -Value $entry.ImagePath -Needle $SearchTerm)
        ) {
            Add-CandidateToken -Set $candidateSet -Value $entry.Name
            Add-CandidateToken -Set $candidateSet -Value $entry.ImagePath
        }
    }

    foreach ($file in @(Get-ChildItem -Path $sysPathBase -Filter "*$SearchTerm*.sys" -ErrorAction SilentlyContinue)) {
        Add-CandidateToken -Set $candidateSet -Value $file.BaseName
    }

    foreach ($file in @(Get-ChildItem -Path $infPathBase -Filter "*$SearchTerm*.inf" -ErrorAction SilentlyContinue)) {
        Add-CandidateToken -Set $candidateSet -Value $file.BaseName
    }

    foreach ($package in $DriverPackages) {
        if (
            (Test-ContainsInsensitive -Value $package.OriginalName -Needle $SearchTerm) -or
            (Test-ContainsInsensitive -Value $package.ProviderName -Needle $SearchTerm) -or
            (Test-ContainsInsensitive -Value $package.SignerName -Needle $SearchTerm)
        ) {
            Add-CandidateToken -Set $candidateSet -Value $package.OriginalToken
        }
    }

    return @($candidateSet.GetEnumerator() | ForEach-Object { [string]$_ } | Sort-Object)
}

function Get-DriverEvidence {
    param(
        [string]$ExactDriver,
        [object[]]$ServiceRegistry,
        [object[]]$DriverPackages,
        [switch]$SkipRelatedComponents
    )

    $regexSafeDriver = [regex]::Escape($ExactDriver)
    $matchedServiceKeys = @($ServiceRegistry | Where-Object {
            $_.NameToken -ieq $ExactDriver -or $_.ImageToken -ieq $ExactDriver
        })

    $serviceNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$serviceNames.Add($ExactDriver)
    foreach ($entry in $matchedServiceKeys) {
        if (-not [string]::IsNullOrWhiteSpace($entry.Name)) {
            [void]$serviceNames.Add($entry.Name)
        }
    }

    $runtimeServiceResult = Get-RuntimeServicesByNameSafe -ServiceNames @($serviceNames)
    $runtimeServices = @($runtimeServiceResult.Services)
    $runtimeServiceWarnings = @($runtimeServiceResult.Warnings)

    $sysPath = Join-Path $env:SystemRoot "System32\drivers\$ExactDriver.sys"
    $systemFileExists = Test-Path -LiteralPath $sysPath
    $driverQueryEntries = @(Get-DriverQueryEntriesSafe -ExactDriver $ExactDriver)
    $tokenMatchedPackages = @($DriverPackages | Where-Object {
            $_.OriginalToken -ieq $ExactDriver
        })
    $matchedPnpDevices = @(Get-PnpEvidence -ExactDriver $ExactDriver -DriverPackages $tokenMatchedPackages -RegistryKeys $matchedServiceKeys)
    $matchedPackages = @(Get-MatchedDriverPackages -ExactDriver $ExactDriver -DriverPackages $DriverPackages -PnpDevices $matchedPnpDevices)
    $focusedRegistryEvidence = Get-FocusedRegistryEvidence -ExactDriver $ExactDriver -DriverPackages $matchedPackages -RegistryKeys $matchedServiceKeys -PnpDevices $matchedPnpDevices
    $additionalFiles = @(Get-AdditionalEvidenceFiles -ExactDriver $ExactDriver)
    $relatedComponents = @()
    if (-not $SkipRelatedComponents) {
        $relatedComponents = @(Get-RelatedComponentHints -ExactDriver $ExactDriver -MatchedPackages $matchedPackages -MatchedRegistryKeys $matchedServiceKeys -AllPackages $DriverPackages -ServiceRegistry $ServiceRegistry)
    }
    $protectionInfo = Get-ProtectionInfoForEvidence -ExactDriver $ExactDriver -DriverPackages $matchedPackages -RegistryKeys $matchedServiceKeys -SystemFilePath $sysPath -SystemFileExists $systemFileExists -AdditionalFiles $additionalFiles

    [pscustomobject]@{
        ExactDriver = $ExactDriver
        RuntimeServices = @($runtimeServices | Sort-Object Name)
        RuntimeServiceWarnings = @($runtimeServiceWarnings | Sort-Object -Unique)
        RegistryKeys = @($matchedServiceKeys | Sort-Object Name)
        SystemFilePath = $sysPath
        SystemFileExists = $systemFileExists
        DriverQueryEntries = @($driverQueryEntries)
        DriverPackages = @($matchedPackages | Sort-Object PublishedName)
        PnpDevices = @($matchedPnpDevices | Sort-Object InstanceId)
        FocusedRegistry = $focusedRegistryEvidence
        AdditionalFiles = @($additionalFiles | Sort-Object FullName)
        RelatedComponents = @($relatedComponents | Sort-Object Token)
        ProtectionInfo = $protectionInfo
    }
}

function Show-DriverEvidence {
    param(
        [object]$Evidence
    )

    Write-Host ''
    Write-Host '==============================================='
    Write-Host " ΕΠΙΛΕΓΜΕΝΟΣ DRIVER: $($Evidence.ExactDriver)" -ForegroundColor Magenta
    Write-Host '==============================================='

    Write-Host "`n$I_Info 1. Έλεγχος Υπηρεσίας / Registry Key" -ForegroundColor Cyan
    if ($Evidence.RuntimeServices.Count -eq 0 -and $Evidence.RegistryKeys.Count -eq 0) {
        Write-Host "$I_Ok Δεν βρέθηκε active service ή exact service key." -ForegroundColor Green
    }
    else {
        foreach ($runtimeService in $Evidence.RuntimeServices) {
            Write-Host "$I_Item Service: $($runtimeService.Name) - Status: $($runtimeService.Status)" -ForegroundColor Yellow
        }

        foreach ($registryKey in $Evidence.RegistryKeys) {
            Write-Host "$I_Item Registry key: $($registryKey.Name)" -ForegroundColor Yellow
            if (-not [string]::IsNullOrWhiteSpace($registryKey.DisplayName)) {
                Write-Host "    DisplayName: $($registryKey.DisplayName)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace($registryKey.ImagePath)) {
                Write-Host "    ImagePath  : $($registryKey.ImagePath)" -ForegroundColor DarkYellow
            }
        }
    }

    if ($Evidence.RuntimeServiceWarnings.Count -gt 0) {
        Write-Host "$I_Warn Το runtime service query του συστήματος επέστρεψε προβληματική εγγραφή ή protected-service error." -ForegroundColor Yellow
        Write-Host 'Η αναζήτηση συνεχίστηκε κανονικά με service registry, packages, files και PnP evidence.' -ForegroundColor DarkYellow
        foreach ($warningText in $Evidence.RuntimeServiceWarnings) {
            Write-Host "    $warningText" -ForegroundColor DarkGray
        }
    }

    Write-Host "`n$I_Info 2. Έλεγχος Αρχείου .sys" -ForegroundColor Cyan
    if ($Evidence.SystemFileExists) {
        Write-Host "$I_Item Το ακριβές αρχείο υπάρχει: $($Evidence.SystemFilePath)" -ForegroundColor Yellow
    }
    else {
        Write-Host "$I_Ok Το ακριβές αρχείο δεν βρέθηκε στο System32\\drivers." -ForegroundColor Green
    }

    Write-Host "`n$I_Info 3. Έλεγχος στο DriverQuery" -ForegroundColor Cyan
    if ($Evidence.DriverQueryEntries.Count -gt 0) {
        $hasRunningDriverQueryEntry = @($Evidence.DriverQueryEntries | Where-Object { [string]$_.State -match '^(?i)running$' }).Count -gt 0
        if ($hasRunningDriverQueryEntry) {
            Write-Host "$I_Item Ο driver βρέθηκε στο DriverQuery και είναι active στα Windows." -ForegroundColor Yellow
        }
        else {
            Write-Host "$I_Item Βρέθηκε exact DriverQuery entry για τον driver." -ForegroundColor Yellow
        }
        foreach ($driverQueryEntry in $Evidence.DriverQueryEntries) {
            Write-Host "    Module     : $($driverQueryEntry.ModuleName)" -ForegroundColor DarkYellow
            if (-not [string]::IsNullOrWhiteSpace([string]$driverQueryEntry.DisplayName)) {
                Write-Host "    Display    : $($driverQueryEntry.DisplayName)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$driverQueryEntry.DriverType)) {
                Write-Host "    Type       : $($driverQueryEntry.DriverType.Trim())" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$driverQueryEntry.StartMode)) {
                Write-Host "    StartMode  : $($driverQueryEntry.StartMode)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$driverQueryEntry.State)) {
                Write-Host "    State      : $($driverQueryEntry.State)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$driverQueryEntry.Status)) {
                Write-Host "    Status     : $($driverQueryEntry.Status)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$driverQueryEntry.LinkDate)) {
                Write-Host "    LinkDate   : $($driverQueryEntry.LinkDate)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$driverQueryEntry.Path)) {
                Write-Host "    Path       : $($driverQueryEntry.Path)" -ForegroundColor DarkYellow
            }
        }
    }
    else {
        Write-Host "$I_Ok Δεν βρέθηκε ακριβές module στο driverquery." -ForegroundColor Green
    }

    Write-Host "`n$I_Info 4. Έλεγχος στο Driver Store (pnputil)" -ForegroundColor Cyan
    if ($Evidence.DriverPackages.Count -gt 0) {
        foreach ($package in $Evidence.DriverPackages) {
            Write-Host "$I_Item $($package.PublishedName) :: $($package.OriginalName) :: $($package.ProviderName)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "$I_Ok Δεν βρέθηκε exact package στο Driver Store." -ForegroundColor Green
    }

    Write-Host "`n$I_Info 5. Έλεγχος PnP Device Evidence" -ForegroundColor Cyan
    if ($Evidence.PnpDevices.Count -gt 0) {
        foreach ($device in $Evidence.PnpDevices) {
            Write-Host "$I_Item $($device.InstanceId) :: $($device.FriendlyName)" -ForegroundColor Yellow
            if (-not [string]::IsNullOrWhiteSpace([string]$device.InfName)) {
                Write-Host "    InfName    : $($device.InfName)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.DriverName)) {
                Write-Host "    DriverName : $($device.DriverName)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.DriverInfSection)) {
                Write-Host "    InfSection : $($device.DriverInfSection)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.Manufacturer)) {
                Write-Host "    Manufacturer: $($device.Manufacturer)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.DriverProviderName)) {
                Write-Host "    Provider   : $($device.DriverProviderName)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.MatchingDeviceId)) {
                Write-Host "    MatchId    : $($device.MatchingDeviceId)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.ServiceName)) {
                Write-Host "    Service    : $($device.ServiceName)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.DriverKey)) {
                Write-Host "    DriverKey  : $($device.DriverKey)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.ClassGuid)) {
                Write-Host "    ClassGuid  : $($device.ClassGuid)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.EnumeratorName)) {
                Write-Host "    Enumerator : $($device.EnumeratorName)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.Parent)) {
                Write-Host "    Parent     : $($device.Parent)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.DriverVersion)) {
                Write-Host "    DriverVersion: $($device.DriverVersion)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.DriverDate)) {
                Write-Host "    DriverDate : $($device.DriverDate)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.Class)) {
                Write-Host "    Class      : $($device.Class)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.Present)) {
                Write-Host "    Present    : $($device.Present)" -ForegroundColor DarkYellow
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$device.Status)) {
                Write-Host "    Status     : $($device.Status)" -ForegroundColor DarkYellow
            }
            if ($device.Sources.Count -gt 0) {
                Write-Host "    Source     : $($device.Sources -join ', ')" -ForegroundColor DarkGray
            }
        }
    }
    else {
        Write-Host "$I_Ok Δεν βρέθηκε σχετικό PnP device evidence." -ForegroundColor Green
    }

    Write-Host "`n$I_Info 6. Focused Registry Evidence" -ForegroundColor Cyan
    $registryKeys = @($Evidence.FocusedRegistry.Keys)
    $registryValues = @($Evidence.FocusedRegistry.Values)
    if ($registryKeys.Count -gt 0 -or $registryValues.Count -gt 0) {
        foreach ($registryKey in $registryKeys) {
            Write-Host "$I_Item KEY :: $($registryKey.KeyPath)" -ForegroundColor Yellow
        }
        foreach ($registryValue in $registryValues) {
            Write-Host "$I_Item VALUE :: $($registryValue.KeyPath) :: [$($registryValue.ValueName)] = $($registryValue.ValueData)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "$I_Ok Δεν βρέθηκε σχετικό focused registry evidence." -ForegroundColor Green
    }

    Write-Host "`n$I_Info 7. Πρόσθετο File Evidence σε Windows paths" -ForegroundColor Cyan
    $extraFiles = @($Evidence.AdditionalFiles | Where-Object { $_.FullName -ne $Evidence.SystemFilePath })
    if ($extraFiles.Count -gt 0) {
        foreach ($file in $extraFiles) {
            Write-Host "$I_Item $($file.FullName)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "$I_Ok Δεν βρέθηκαν επιπλέον exact file leftovers στα monitored Windows paths." -ForegroundColor Green
    }

    if ($Evidence.RelatedComponents.Count -gt 0) {
        Write-Host "`n$I_Info 8. Linked Related Components (SetupAPI Evidence)" -ForegroundColor Cyan
        Write-Host "$I_Warn Τα παρακάτω ΔΕΝ είναι hardcoded guesses. Βρέθηκαν linked επειδή εμφανίζονται στο ίδιο SetupAPI install window με το current driver evidence." -ForegroundColor Yellow
        foreach ($relatedItem in $Evidence.RelatedComponents) {
            $relatedColor = 'Yellow'
            $relatedLabel = "$I_Item $($relatedItem.Token)"
            if ($relatedItem.IsProtected) {
                $relatedColor = 'Red'
                $relatedLabel += ' [PROTECTED SYSTEM / review-only]'
            }

            Write-Host $relatedLabel -ForegroundColor $relatedColor
            foreach ($packageLine in (Get-RelatedPackageDisplayLines -PackageTexts $relatedItem.Packages)) {
                Write-Host "    Package: $($packageLine.DisplayText)" -ForegroundColor DarkYellow
            }
            foreach ($serviceText in $relatedItem.Services) {
                Write-Host "    Service: $serviceText" -ForegroundColor DarkYellow
            }
            foreach ($protectionReason in $relatedItem.ProtectionReasons) {
                Write-Host "    Protect : $protectionReason" -ForegroundColor Red
            }
            foreach ($metadataHint in $relatedItem.ProtectionMetadataHints) {
                Write-Host "    Metadata: $metadataHint" -ForegroundColor Yellow
            }
            foreach ($reasonText in $relatedItem.Reasons) {
                Write-Host "    Link   : $reasonText" -ForegroundColor DarkGray
            }
        }
    }
}

function Test-EvidenceFound {
    param(
        [object]$Evidence
    )

    return (
        $Evidence.RuntimeServices.Count -gt 0 -or
        $Evidence.RegistryKeys.Count -gt 0 -or
        $Evidence.SystemFileExists -or
        $Evidence.DriverQueryEntries.Count -gt 0 -or
        $Evidence.DriverPackages.Count -gt 0 -or
        $Evidence.PnpDevices.Count -gt 0 -or
        $Evidence.FocusedRegistry.Keys.Count -gt 0 -or
        $Evidence.FocusedRegistry.Values.Count -gt 0 -or
        $Evidence.AdditionalFiles.Count -gt 0
    )
}

function Test-RelatedEvidenceFound {
    param(
        [object]$Evidence
    )

    return ($Evidence.RelatedComponents.Count -gt 0)
}

function Show-RelatedFollowUpGuidance {
    param(
        [object]$Evidence,
        [switch]$PostCleanup
    )

    if (-not (Test-RelatedEvidenceFound -Evidence $Evidence)) {
        return
    }

    $relatedTokens = @($Evidence.RelatedComponents.Token | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($relatedTokens.Count -eq 0) {
        return
    }

    $actionableRelatedTokens = @($Evidence.RelatedComponents | Where-Object { -not $_.IsProtected } | ForEach-Object { $_.Token } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $protectedRelatedTokens = @($Evidence.RelatedComponents | Where-Object { $_.IsProtected } | ForEach-Object { $_.Token } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    Write-Host ''
    if ($PostCleanup) {
        Write-Host "$I_Warn Το exact evidence για τον driver `"$($Evidence.ExactDriver)`" καθαρίστηκε, αλλά βρέθηκαν LINKED related components από το ίδιο SetupAPI install window." -ForegroundColor Yellow
    }
    else {
        Write-Host "$I_Warn Δεν βρέθηκε direct live evidence για τον driver `"$($Evidence.ExactDriver)`", αλλά βρέθηκαν LINKED related components από το ίδιο SetupAPI install window." -ForegroundColor Yellow
    }

    Write-Host 'Αυτά ΔΕΝ διαγράφονται αυτόματα από αυτή την exact-driver εκτέλεση. Έλεγξέ τα ξεχωριστά μόνο αν τα αναγνωρίζεις ως μέρος του ίδιου install stack.' -ForegroundColor DarkYellow
    if ($actionableRelatedTokens.Count -gt 0) {
        Write-Host 'Προτεινόμενα επόμενα checks:' -ForegroundColor Cyan
        foreach ($relatedToken in $actionableRelatedTokens) {
            Write-Host "  - $relatedToken" -ForegroundColor Yellow
        }
    }

    if ($protectedRelatedTokens.Count -gt 0) {
        Write-Host 'Παραλείφθηκαν protected Windows/core services από τα actionable follow-up targets:' -ForegroundColor DarkCyan
        foreach ($relatedToken in $protectedRelatedTokens) {
            Write-Host "  - $relatedToken" -ForegroundColor DarkYellow
        }
    }
}

function Get-RelatedCleanupCandidates {
    param(
        [object]$Evidence,
        [object[]]$ServiceRegistry,
        [object[]]$DriverPackages
    )

    $candidates = foreach ($relatedItem in $Evidence.RelatedComponents) {
        $relatedToken = [string]$relatedItem.Token
        if ([string]::IsNullOrWhiteSpace($relatedToken) -or $relatedToken -ieq $Evidence.ExactDriver) {
            continue
        }

        $relatedEvidence = Get-DriverEvidence -ExactDriver $relatedToken -ServiceRegistry $ServiceRegistry -DriverPackages $DriverPackages -SkipRelatedComponents
        $isProtected = ($relatedItem.IsProtected -or $relatedEvidence.ProtectionInfo.IsProtected)
        $protectionReasons = @(
            @($relatedItem.ProtectionReasons) +
            @($relatedEvidence.ProtectionInfo.Reasons)
        ) | Sort-Object -Unique
        $hasLiveEvidence = (Test-EvidenceFound -Evidence $relatedEvidence)
        $hasActionableEvidence = (Test-ActionableCleanupEvidence -Evidence $relatedEvidence)
        [pscustomobject]@{
            Token = $relatedToken
            Evidence = $relatedEvidence
            HasLiveEvidence = $hasLiveEvidence
            HasActionableEvidence = $hasActionableEvidence
            IsProtected = $isProtected
            ProtectionReasons = @($protectionReasons)
            ProtectionMetadataHints = @($relatedEvidence.ProtectionInfo.MetadataHints | Sort-Object -Unique)
            CanOfferCleanup = ($hasLiveEvidence -and $hasActionableEvidence -and -not $isProtected)
            HintPackages = @(Get-RelatedPackageDisplayLines -PackageTexts $relatedItem.Packages)
            HintServices = @($relatedItem.Services | Sort-Object -Unique)
        }
    }

    return @($candidates | Sort-Object Token)
}

function Get-EvidenceSummaryText {
    param(
        [object]$Evidence
    )

    $parts = New-Object System.Collections.Generic.List[string]

    if ($Evidence.RuntimeServices.Count -gt 0 -or $Evidence.RegistryKeys.Count -gt 0) {
        [void]$parts.Add('service/registry')
    }
    if ($Evidence.DriverPackages.Count -gt 0) {
        [void]$parts.Add('driver package')
    }
    if ($Evidence.PnpDevices.Count -gt 0) {
        [void]$parts.Add('PnP')
    }
    if ($Evidence.SystemFileExists -or $Evidence.AdditionalFiles.Count -gt 0) {
        [void]$parts.Add('files')
    }
    if ($Evidence.DriverQueryEntries.Count -gt 0) {
        [void]$parts.Add('loaded module')
    }

    if ($parts.Count -eq 0) {
        return 'no current exact evidence'
    }

    return ($parts -join ', ')
}

function Resolve-CleanupTargets {
    param(
        [object]$PrimaryEvidence,
        [object[]]$ServiceRegistry,
        [object[]]$DriverPackages
    )

    $targets = @($PrimaryEvidence)

    if (-not (Test-RelatedEvidenceFound -Evidence $PrimaryEvidence)) {
        return @($targets)
    }

    $relatedCandidates = @(Get-RelatedCleanupCandidates -Evidence $PrimaryEvidence -ServiceRegistry $ServiceRegistry -DriverPackages $DriverPackages)
    $protectedRelatedCandidates = @($relatedCandidates | Where-Object { $_.HasLiveEvidence -and $_.IsProtected })
    $nonActionableRelatedCandidates = @($relatedCandidates | Where-Object { $_.HasLiveEvidence -and -not $_.IsProtected -and -not $_.HasActionableEvidence })
    $liveRelatedCandidates = @($relatedCandidates | Where-Object { $_.CanOfferCleanup })

    if ($protectedRelatedCandidates.Count -gt 0) {
        Write-Host "`n$I_Warn Παραλείφθηκαν protected Windows/core services από το linked cleanup scope." -ForegroundColor Red
        foreach ($candidate in $protectedRelatedCandidates) {
            Write-Host "  - $($candidate.Token)" -ForegroundColor Red
            foreach ($protectionReason in $candidate.ProtectionReasons) {
                Write-Host "      Protect : $protectionReason" -ForegroundColor Red
            }
            foreach ($metadataHint in $candidate.ProtectionMetadataHints) {
                Write-Host "      Metadata: $metadataHint" -ForegroundColor Yellow
            }
        }
    }

    if ($nonActionableRelatedCandidates.Count -gt 0) {
        Write-Host "`n$I_Warn Κάποια linked targets έμειναν review-only επειδή έχουν μόνο service/registry-style evidence χωρίς package/file/PnP proof." -ForegroundColor Yellow
        foreach ($candidate in $nonActionableRelatedCandidates) {
            Write-Host "  - $($candidate.Token) :: $(Get-EvidenceSummaryText -Evidence $candidate.Evidence)" -ForegroundColor DarkYellow
        }
    }

    if ($liveRelatedCandidates.Count -eq 0) {
        return @($targets)
    }

    Write-Host "`n$I_Info Βρέθηκαν linked related components με ΤΩΡΙΝΟ exact live evidence." -ForegroundColor Cyan
    Write-Host 'Μπορείς να κρατήσεις cleanup μόνο για τον primary driver ή να συμπεριλάβεις και linked components από το ίδιο install stack.' -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host 'Linked current targets:' -ForegroundColor Cyan
    foreach ($candidate in $liveRelatedCandidates) {
        Write-Host "  - $($candidate.Token) :: $(Get-EvidenceSummaryText -Evidence $candidate.Evidence)" -ForegroundColor Yellow
    }

    Write-Host ''
    $scopeChoice = Read-SingleChoiceMenu -Items @(
        [pscustomobject]@{ Key = '1'; Label = 'Exact driver only'; Color = 'Green'; Value = '1' },
        [pscustomobject]@{ Key = '2'; Label = "AIO cleanup: exact + ALL linked targets above $I_Warn CAUTION IT will remove everything at once"; Color = 'Yellow'; Value = '2' },
        [pscustomobject]@{ Key = '3'; Label = 'Selective cleanup: exact + choose linked targets you want to remove'; Color = 'Cyan'; Value = '3' },
        [pscustomobject]@{ Key = '0'; Label = 'Cancel'; Color = 'Red'; Value = '0' }
    ) -Prompt "$I_Input Διάλεξε cleanup scope (0-3)" -CancelLabel 'Cancel'
    if ($null -eq $scopeChoice) {
        return @()
    }

    switch ($scopeChoice.Value) {
        '1' {
            return @($targets)
        }
        '2' {
            $targets += @($liveRelatedCandidates | ForEach-Object { $_.Evidence })
            return @($targets)
        }
        '3' {
            Write-Host ''
            Write-Host 'Select linked components to include:' -ForegroundColor Cyan
            for ($index = 0; $index -lt $liveRelatedCandidates.Count; $index++) {
                $candidate = $liveRelatedCandidates[$index]
                Write-Host "  [$($index + 1)] $($candidate.Token) :: $(Get-EvidenceSummaryText -Evidence $candidate.Evidence)" -ForegroundColor Yellow
            }
            Write-Host '  [0] Cancel selective mode' -ForegroundColor Red
            Write-Host '  [ESC] Cancel selective mode' -ForegroundColor DarkGray

            $selectionText = Read-HostTrimmed -Prompt "$I_Input Γράψε αριθμούς χωρισμένους με κόμμα (π.χ. 1,3)"
            if ([string]::IsNullOrWhiteSpace($selectionText) -or (Test-IsEscapeInput -Value $selectionText)) {
                return @()
            }

            if ($selectionText -eq '0') {
                return @()
            }

            $selectedIndexes = @(
                foreach ($part in ($selectionText -split '\s*,\s*')) {
                    $selectionNumber = $part -as [int]
                    if ($null -ne $selectionNumber -and $selectionNumber -ge 1 -and $selectionNumber -le $liveRelatedCandidates.Count) {
                        $selectionNumber - 1
                    }
                }
            ) | Sort-Object -Unique

            if ($selectedIndexes.Count -eq 0) {
                return @()
            }

            foreach ($selectedIndex in $selectedIndexes) {
                $targets += @($liveRelatedCandidates[$selectedIndex].Evidence)
            }

            return @($targets)
        }
        default {
            return @()
        }
    }
}

function Show-CleanupTargetsSummary {
    param(
        [object[]]$Targets
    )

    Write-Host "`n$I_Info Cleanup targets for this run:" -ForegroundColor Cyan
    foreach ($targetEvidence in $Targets) {
        Write-Host "$I_Item $($targetEvidence.ExactDriver) :: $(Get-EvidenceSummaryText -Evidence $targetEvidence)" -ForegroundColor Yellow
    }
}

function Confirm-CleanupTargets {
    param(
        [object[]]$Targets,
        [string]$PrimaryExactDriver,
        [switch]$Continuation
    )

    Show-CleanupTargetsSummary -Targets $Targets

    if ($Continuation) {
        Write-Host "`n$I_Warn ΚΙΝΔΥΝΟΣ: Πρόκειται να προχωρήσετε σε ΣΥΝΕΧΙΣΗ cleanup για additional linked targets." -ForegroundColor Red
    }
    elseif ($Targets.Count -eq 1) {
        Write-Host "`n$I_Warn ΚΙΝΔΥΝΟΣ: Πρόκειται να προχωρήσετε σε ΠΛΗΡΗ ΔΙΑΓΡΑΦΗ του driver: [$PrimaryExactDriver]" -ForegroundColor Red
    }
    else {
        Write-Host "`n$I_Warn ΚΙΝΔΥΝΟΣ: Πρόκειται να προχωρήσετε σε ΠΛΗΡΗ ΔΙΑΓΡΑΦΗ για MULTI-TARGET cleanup." -ForegroundColor Red
    }

    Write-Host 'Η λανθασμένη διαγραφή μπορεί να προκαλέσει αστάθεια ή BSOD στο σύστημα!' -ForegroundColor Red
    $confirmationText = Read-HostTrimmed -Prompt "`n$I_Input Πληκτρολογήστε 'YES' (με ΚΕΦΑΛΑΙΑ γράμματα) για διαγραφή, ή ESC/οτιδήποτε άλλο για ακύρωση"
    return ($confirmationText -ceq 'YES')
}

function Show-RemainingLinkedTargetsSummary {
    param(
        [object[]]$RemainingCandidates
    )

    if ($null -eq $RemainingCandidates -or $RemainingCandidates.Count -eq 0) {
        return
    }

    Write-Host ''
    Write-Host "$I_Warn Υπάρχουν ΑΚΟΜΑ linked components με current exact live evidence εκτός του current cleanup scope." -ForegroundColor Yellow
    Write-Host 'Αυτά δεν καθαρίστηκαν σε αυτό το run και αξίζουν επόμενο έλεγχο/cleanup μόνο αν τα αναγνωρίζεις ως μέρος του ίδιου install stack.' -ForegroundColor DarkYellow
    Write-Host 'Remaining linked targets:' -ForegroundColor Cyan
    foreach ($candidate in $RemainingCandidates) {
        Write-Host "  - $($candidate.Token) :: $(Get-EvidenceSummaryText -Evidence $candidate.Evidence)" -ForegroundColor Yellow
    }
}

function Show-ReviewOnlyRemainingLinkedTargetsSummary {
    param(
        [object[]]$ReviewOnlyCandidates
    )

    if ($null -eq $ReviewOnlyCandidates -or $ReviewOnlyCandidates.Count -eq 0) {
        return
    }

    Write-Host ''
    Write-Host "$I_Warn Υπάρχουν linked components με current live evidence που παραμένουν review-only και ΕΞΑΙΡΟΥΝΤΑΙ από το continuation cleanup." -ForegroundColor Red
    Write-Host 'Δεν θα εμφανιστούν ως cleanup επιλογές σε αυτό το στάδιο. Έλεγξέ τα μόνο χειροκίνητα αν υπάρχει συγκεκριμένος λόγος.' -ForegroundColor DarkYellow
    foreach ($candidate in $ReviewOnlyCandidates) {
        $candidateColor = if ($candidate.IsProtected) { 'Red' } else { 'Yellow' }
        Write-Host "  - $($candidate.Token) :: $(Get-EvidenceSummaryText -Evidence $candidate.Evidence)" -ForegroundColor $candidateColor
        foreach ($protectionReason in $candidate.ProtectionReasons) {
            Write-Host "      Protect : $protectionReason" -ForegroundColor Red
        }
        foreach ($metadataHint in $candidate.ProtectionMetadataHints) {
            Write-Host "      Metadata: $metadataHint" -ForegroundColor Yellow
        }
    }
}

function Resolve-RemainingCleanupTargets {
    param(
        [object[]]$RemainingCandidates
    )

    if ($null -eq $RemainingCandidates -or $RemainingCandidates.Count -eq 0) {
        return @()
    }

    Write-Host ''
    if ($RemainingCandidates.Count -eq 1) {
        $continuationChoice = Read-SingleChoiceMenu -Items @(
            [pscustomobject]@{ Key = '1'; Label = 'Clean remaining linked target now'; Color = 'Yellow'; Value = '1' },
            [pscustomobject]@{ Key = '0'; Label = 'Finish current run'; Color = 'Red'; Value = '0' }
        ) -Prompt "$I_Input Διάλεξε συνέχεια cleanup (0-1)" -CancelLabel 'Finish current run'
        if ($null -eq $continuationChoice) {
            return @()
        }

        switch ($continuationChoice.Value) {
            '1' {
                return @($RemainingCandidates[0].Evidence)
            }
            default {
                return @()
            }
        }
    }

    $continuationChoice = Read-SingleChoiceMenu -Items @(
        [pscustomobject]@{ Key = '1'; Label = 'Clean all remaining linked targets now'; Color = 'Yellow'; Value = '1' },
        [pscustomobject]@{ Key = '2'; Label = 'Select remaining linked targets now'; Color = 'Magenta'; Value = '2' },
        [pscustomobject]@{ Key = '0'; Label = 'Finish current run'; Color = 'Red'; Value = '0' }
    ) -Prompt "$I_Input Διάλεξε συνέχεια cleanup (0-2)" -CancelLabel 'Finish current run'
    if ($null -eq $continuationChoice) {
        return @()
    }

    switch ($continuationChoice.Value) {
        '1' {
            return @($RemainingCandidates | ForEach-Object { $_.Evidence })
        }
        '2' {
            Write-Host ''
            Write-Host 'Select remaining linked targets:' -ForegroundColor Cyan
            for ($index = 0; $index -lt $RemainingCandidates.Count; $index++) {
                $candidate = $RemainingCandidates[$index]
                Write-Host "  [$($index + 1)] $($candidate.Token) :: $(Get-EvidenceSummaryText -Evidence $candidate.Evidence)" -ForegroundColor Yellow
            }
            Write-Host '  [0] Cancel continuation' -ForegroundColor Red
            Write-Host '  [ESC] Cancel continuation' -ForegroundColor DarkGray

            $selectionText = Read-HostTrimmed -Prompt "$I_Input Γράψε αριθμούς χωρισμένους με κόμμα (π.χ. 1,2)"
            if ([string]::IsNullOrWhiteSpace($selectionText) -or $selectionText -eq '0' -or (Test-IsEscapeInput -Value $selectionText)) {
                return @()
            }

            $selectedIndexes = @(
                foreach ($part in ($selectionText -split '\s*,\s*')) {
                    $selectionNumber = $part -as [int]
                    if ($null -ne $selectionNumber -and $selectionNumber -ge 1 -and $selectionNumber -le $RemainingCandidates.Count) {
                        $selectionNumber - 1
                    }
                }
            ) | Sort-Object -Unique

            if ($selectedIndexes.Count -eq 0) {
                return @()
            }

            $selectedTargets = foreach ($selectedIndex in $selectedIndexes) {
                $RemainingCandidates[$selectedIndex].Evidence
            }

            return @($selectedTargets)
        }
        default {
            return @()
        }
    }
}

function Remove-DriverEvidence {
    param(
        [object]$Evidence
    )

    if ($Evidence.ProtectionInfo.IsProtected) {
        Write-Host "`n$I_Warn ΜΠΛΟΚΑΡΙΣΜΑ cleanup: το target `"$($Evidence.ExactDriver)`" μοιάζει με protected Windows/core component." -ForegroundColor Red
        foreach ($protectionReason in $Evidence.ProtectionInfo.Reasons) {
            Write-Host "    Protect : $protectionReason" -ForegroundColor Red
        }
        foreach ($metadataHint in $Evidence.ProtectionInfo.MetadataHints) {
            Write-Host "    Metadata: $metadataHint" -ForegroundColor Yellow
        }
        Write-Host 'Το script σταματά τη destructive ενέργεια για αυτό το target.' -ForegroundColor DarkYellow
        return
    }

    Write-Host "`n$I_Info Έναρξη Διαγραφής για: $($Evidence.ExactDriver)" -ForegroundColor Cyan

    if ($Evidence.PnpDevices.Count -gt 0) {
        foreach ($device in ($Evidence.PnpDevices | Sort-Object InstanceId)) {
            Write-Host "`n$I_Device Αφαίρεση PnP device: $($device.InstanceId)"
            $removeDeviceResult = Invoke-NativeCapture -FilePath 'pnputil.exe' -Arguments @('/remove-device', $device.InstanceId)
            $removeDeviceText = ($removeDeviceResult.Output -join [Environment]::NewLine)
            if ($removeDeviceResult.ExitCode -eq 0 -or $removeDeviceText -match 'successfully' -or $removeDeviceText -match 'removed') {
                Write-Host "$I_Ok Το PnP device αφαιρέθηκε επιτυχώς." -ForegroundColor Green
            }
            elseif ($removeDeviceText -match '(?i)device instance does not exist in the hardware tree') {
                Write-Host "$I_Ok Το PnP device ήταν ήδη εκτός hardware tree / ήδη absent." -ForegroundColor Green
                if (-not [string]::IsNullOrWhiteSpace($removeDeviceText)) {
                    Write-Host "    $removeDeviceText" -ForegroundColor DarkGray
                }
            }
            else {
                Write-Host "$I_Warn Δεν αφαιρέθηκε πλήρως το PnP device." -ForegroundColor Yellow
                if (-not [string]::IsNullOrWhiteSpace($removeDeviceText)) {
                    Write-Host "    $removeDeviceText" -ForegroundColor DarkYellow
                }
            }
        }
    }

    $serviceNamesToDelete = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$serviceNamesToDelete.Add($Evidence.ExactDriver)
    foreach ($entry in $Evidence.RegistryKeys) {
        if (-not [string]::IsNullOrWhiteSpace($entry.Name)) {
            [void]$serviceNamesToDelete.Add($entry.Name)
        }
    }

    foreach ($serviceName in @($serviceNamesToDelete) | Sort-Object) {
        Write-Host "`n$I_Item Διαγραφή service: $serviceName"
        $serviceDeleteResult = Invoke-NativeCapture -FilePath 'sc.exe' -Arguments @('delete', $serviceName)
        $serviceDeleteText = ($serviceDeleteResult.Output -join [Environment]::NewLine)
        if ($serviceDeleteResult.ExitCode -eq 0 -or $serviceDeleteText -match 'DeleteService SUCCESS') {
            Write-Host "$I_Ok Η υπηρεσία διαγράφηκε επιτυχώς." -ForegroundColor Green
        }
        elseif ($serviceDeleteText -match 'FAILED 1060') {
            Write-Host "$I_Ok Η υπηρεσία δεν υπήρχε πλέον ως installed service." -ForegroundColor Green
        }
        else {
            Write-Host "$I_Warn Σφάλμα/Αποτυχία κατά τη διαγραφή υπηρεσίας." -ForegroundColor Yellow
            if (-not [string]::IsNullOrWhiteSpace($serviceDeleteText)) {
                Write-Host "    $serviceDeleteText" -ForegroundColor DarkYellow
            }
        }
    }

    foreach ($registryKey in $Evidence.RegistryKeys | Sort-Object Name) {
        if (Test-Path -LiteralPath $registryKey.KeyPath) {
            Write-Host "`n$I_Item Καθαρισμός orphan service key: $($registryKey.Name)"
            try {
                Remove-Item -LiteralPath $registryKey.KeyPath -Recurse -Force -ErrorAction Stop
                Write-Host "$I_Ok Το service registry key αφαιρέθηκε." -ForegroundColor Green
            }
            catch {
                Write-Host "$I_Warn Δεν ήταν δυνατή η αφαίρεση του service registry key." -ForegroundColor Yellow
                Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }
    }

    foreach ($package in ($Evidence.DriverPackages | Sort-Object PublishedName)) {
        Write-Host "`n$I_Package Απεγκατάσταση $($package.PublishedName) από το Driver Store..."
        $packageDeleteResult = Invoke-NativeCapture -FilePath 'pnputil.exe' -Arguments @('/delete-driver', $package.PublishedName, '/uninstall', '/force')
        $packageDeleteText = ($packageDeleteResult.Output -join [Environment]::NewLine)
        if ($packageDeleteResult.ExitCode -eq 0 -or $packageDeleteText -match 'deleted successfully' -or $packageDeleteText -match 'Driver package deleted successfully') {
            Write-Host "$I_Ok Το package διαγράφηκε από το Driver Store." -ForegroundColor Green
        }
        else {
            Write-Host "$I_Warn Αποτυχία ή μερική επιστροφή σφάλματος από pnputil." -ForegroundColor Yellow
            if (-not [string]::IsNullOrWhiteSpace($packageDeleteText)) {
                Write-Host "    $packageDeleteText" -ForegroundColor DarkYellow
            }
        }
    }

    if ($Evidence.SystemFileExists -and (Test-Path -LiteralPath $Evidence.SystemFilePath)) {
        Write-Host "`n$I_Item Διαγραφή φυσικού αρχείου ($($Evidence.SystemFilePath))..."
        try {
            Remove-Item -LiteralPath $Evidence.SystemFilePath -Force -ErrorAction Stop
            Write-Host "$I_Ok Το αρχείο διεγράφη επιτυχώς από τον δίσκο." -ForegroundColor Green
        }
        catch {
            Write-Host "$I_Warn Ήταν αδύνατη η διαγραφή του φυσικού αρχείου." -ForegroundColor Yellow
            Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
}

if (-not (Test-CurrentSessionElevated)) {
    Start-SelfElevatedInstance
}

$script:Icons = Get-UiIcons
$I_Info = $script:Icons.Info
$I_Warn = $script:Icons.Warn
$I_Ok = $script:Icons.Ok
$I_Item = $script:Icons.Item
$I_Input = $script:Icons.Input
$I_Path = $script:Icons.Path
$I_Package = $script:Icons.Package
$I_Device = $script:Icons.Device

while ($true) {
    $script:ExitLiveDriverCheck = $false
    Show-Header

    $inputDriver = $DriverName
    $DriverName = ''

    if ([string]::IsNullOrWhiteSpace($inputDriver)) {
        if ($EmbeddedInLauncher) {
            Write-Host 'Για επιστροφή στο main menu, άφησέ το κενό και πάτησε [ENTER] ή πάτησε ESC.' -ForegroundColor DarkGray
        }
        else {
            Write-Host 'Για έξοδο από το πρόγραμμα, άφησέ το κενό και πάτησε [ENTER] ή γράψε ESC.' -ForegroundColor DarkGray
        }
        $inputDriver = Read-HostTrimmed -Prompt "$I_Input Εισάγετε όνομα Driver (π.χ. nv, MulttKey)"
    }

    if ([string]::IsNullOrWhiteSpace($inputDriver) -or (Test-IsEscapeInput -Value $inputDriver)) {
        break
    }

    $searchTerm = Convert-ToDriverToken -Value $inputDriver
    Write-Host "`n$I_Info Σάρωση συστήματος για εγγραφές που περιέχουν: `"$searchTerm`"..." -ForegroundColor Cyan

    $serviceRegistry = @(Get-ServiceRegistryInventory)
    $pnpEnumResult = Invoke-NativeCapture -FilePath 'pnputil.exe' -Arguments @('/enum-drivers')
    $driverPackages = @(Convert-PnpUtilToDriverPackages -Lines $pnpEnumResult.Output)
    $candidates = @(Find-DriverCandidates -SearchTerm $searchTerm -ServiceRegistry $serviceRegistry -DriverPackages $driverPackages)

    $exactDriver = ''

    if ($candidates.Count -eq 0) {
        Write-Host "`n$I_Warn Δεν βρέθηκαν broad candidates. Θα γίνει DEEP exact check για το `"$searchTerm`"." -ForegroundColor Yellow
        $exactDriver = $searchTerm
    }
    elseif ($candidates.Count -eq 1) {
        $exactDriver = $candidates[0]
    }
    else {
        Write-Host "`n$I_Warn Βρέθηκαν πολλαπλά αποτελέσματα. Παρακαλώ επιλέξτε τον ΣΩΣΤΟ driver:`n" -ForegroundColor Yellow
        $candidateItems = @()
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $candidateItems += [pscustomobject]@{
                Key = [string]($i + 1)
                Label = [string]$candidates[$i]
                Color = 'Cyan'
                Value = $candidates[$i]
            }
        }
        $candidateItems += [pscustomobject]@{ Key = '0'; Label = 'Ακύρωση'; Color = 'Red'; Value = '' }

        $selectedCandidate = Read-SingleChoiceMenu -Items $candidateItems -Prompt "$I_Input Πληκτρολογήστε τον αριθμό (0-$($candidates.Count))" -CancelLabel 'Ακύρωση'
        if ($null -eq $selectedCandidate) {
            Write-Host "`nΑκύρωση ενέργειας από τον χρήστη." -ForegroundColor Yellow
            if (-not (Wait-ActionOrRestart)) { break }
            continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$selectedCandidate.Value)) {
            Write-Host "`nΑκύρωση ενέργειας από τον χρήστη." -ForegroundColor Yellow
            if (-not (Wait-ActionOrRestart)) { break }
            continue
        }

        $exactDriver = [string]$selectedCandidate.Value
    }

    $evidence = Get-DriverEvidence -ExactDriver $exactDriver -ServiceRegistry $serviceRegistry -DriverPackages $driverPackages
    Show-DriverEvidence -Evidence $evidence

    if (-not (Test-EvidenceFound -Evidence $evidence)) {
        if (Test-RelatedEvidenceFound -Evidence $evidence) {
            Show-RelatedFollowUpGuidance -Evidence $evidence
        }
        else {
            Write-Host "`n$I_Ok Δεν εντοπίστηκε live evidence για τον driver `"$exactDriver`" στο σύστημα." -ForegroundColor Green
            Write-Host 'Αν ξέρεις ότι το install/remove έχει ήδη γίνει, το αποτέλεσμα αυτό σημαίνει συνήθως ότι δεν έχει μείνει κάτι από service, package, device ή monitored Windows file paths.' -ForegroundColor DarkGreen
        }

        if (-not (Wait-ActionOrRestart)) { break }
        continue
    }

    if ($evidence.ProtectionInfo.IsProtected) {
        Write-Host "`n$I_Warn Το target `"$exactDriver`" αναγνωρίστηκε ως protected Windows/core component." -ForegroundColor Red
        foreach ($protectionReason in $evidence.ProtectionInfo.Reasons) {
            Write-Host "    Protect : $protectionReason" -ForegroundColor Red
        }
        foreach ($metadataHint in $evidence.ProtectionInfo.MetadataHints) {
            Write-Host "    Metadata: $metadataHint" -ForegroundColor Yellow
        }
        Write-Host 'Θα παραμείνει review-only και το script δεν θα επιτρέψει cleanup για αυτό το target.' -ForegroundColor DarkYellow
        if (-not (Wait-ActionOrRestart)) { break }
        continue
    }

    $cleanupTargets = @(Resolve-CleanupTargets -PrimaryEvidence $evidence -ServiceRegistry $serviceRegistry -DriverPackages $driverPackages)
    if ($cleanupTargets.Count -eq 0) {
        Write-Host "`n$I_Warn Ακύρωση cleanup scope." -ForegroundColor Yellow
        if (-not (Wait-ActionOrRestart)) { break }
        continue
    }

    if (Confirm-CleanupTargets -Targets $cleanupTargets -PrimaryExactDriver $exactDriver) {
        $allCleanupTargetTokens = @($cleanupTargets | ForEach-Object { $_.ExactDriver } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $pendingCleanupTargets = @($cleanupTargets)

        while ($pendingCleanupTargets.Count -gt 0) {
            foreach ($cleanupEvidence in $pendingCleanupTargets) {
                Remove-DriverEvidence -Evidence $cleanupEvidence
            }

            $postServiceRegistry = @(Get-ServiceRegistryInventory)
            $postDriverPackages = @(Convert-PnpUtilToDriverPackages -Lines (Invoke-NativeCapture -FilePath 'pnputil.exe' -Arguments @('/enum-drivers')).Output)

            Write-Host "`n==============================================="
            Write-Host ' POST-CLEANUP CHECK' -ForegroundColor White
            Write-Host '==============================================='
            $remainingEvidenceFound = $false

            foreach ($cleanupEvidence in $pendingCleanupTargets) {
                $postEvidence = Get-DriverEvidence -ExactDriver $cleanupEvidence.ExactDriver -ServiceRegistry $postServiceRegistry -DriverPackages $postDriverPackages -SkipRelatedComponents
                if (Test-EvidenceFound -Evidence $postEvidence) {
                    $remainingEvidenceFound = $true
                    Write-Host "$I_Warn Έμεινε exact evidence μετά το cleanup για: $($postEvidence.ExactDriver)" -ForegroundColor Yellow
                    Show-DriverEvidence -Evidence $postEvidence
                }
                else {
                    Write-Host "$I_Ok Καθαρό exact live evidence για: $($postEvidence.ExactDriver)" -ForegroundColor Green
                }
            }

            $remainingRelatedCandidates = @(
                Get-RelatedCleanupCandidates -Evidence $evidence -ServiceRegistry $postServiceRegistry -DriverPackages $postDriverPackages |
                Where-Object {
                    $_.HasLiveEvidence -and $_.Token -notin $allCleanupTargetTokens
                }
            )
            $remainingLinkedCandidates = @($remainingRelatedCandidates | Where-Object { $_.CanOfferCleanup })
            $remainingReviewOnlyCandidates = @($remainingRelatedCandidates | Where-Object { -not $_.CanOfferCleanup })

            if ($remainingEvidenceFound) {
                if ($remainingLinkedCandidates.Count -gt 0) {
                    Show-RemainingLinkedTargetsSummary -RemainingCandidates $remainingLinkedCandidates
                }
                if ($remainingReviewOnlyCandidates.Count -gt 0) {
                    Show-ReviewOnlyRemainingLinkedTargetsSummary -ReviewOnlyCandidates $remainingReviewOnlyCandidates
                }
                break
            }

            if ($remainingLinkedCandidates.Count -gt 0) {
                Write-Host "`n$I_Ok Δεν βρέθηκε υπόλοιπο exact live evidence για τα cleanup targets." -ForegroundColor Green
                Show-RemainingLinkedTargetsSummary -RemainingCandidates $remainingLinkedCandidates
                if ($remainingReviewOnlyCandidates.Count -gt 0) {
                    Show-ReviewOnlyRemainingLinkedTargetsSummary -ReviewOnlyCandidates $remainingReviewOnlyCandidates
                }

                $continuationTargets = @(Resolve-RemainingCleanupTargets -RemainingCandidates $remainingLinkedCandidates)
                if ($continuationTargets.Count -eq 0) {
                    break
                }

                if (-not (Confirm-CleanupTargets -Targets $continuationTargets -PrimaryExactDriver $exactDriver -Continuation)) {
                    break
                }

                $pendingCleanupTargets = @($continuationTargets)
                $allCleanupTargetTokens = @(
                    $allCleanupTargetTokens +
                    @($pendingCleanupTargets | ForEach-Object { $_.ExactDriver } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                ) | Sort-Object -Unique
                continue
            }

            if ($remainingReviewOnlyCandidates.Count -gt 0) {
                Write-Host "`n$I_Ok Δεν βρέθηκε υπόλοιπο cleanup-eligible live evidence μετά το cleanup." -ForegroundColor Green
                Show-ReviewOnlyRemainingLinkedTargetsSummary -ReviewOnlyCandidates $remainingReviewOnlyCandidates
                break
            }

            Write-Host "`n$I_Ok Δεν βρέθηκε υπόλοιπο exact live evidence μετά το cleanup." -ForegroundColor Green
            break
        }

                Write-Host "`n$I_Ok Η διαδικασία ολοκληρώθηκε! Συνιστάται επανεκκίνηση αν θέλεις extra verification ή πριν από reinstall / troubleshooting." -ForegroundColor Green
    }
    else {
        Write-Host "`n$I_Warn Δεν δόθηκε η λέξη 'YES'. Ακύρωση διαγραφής." -ForegroundColor Yellow
    }

    if (-not (Wait-ActionOrRestart)) { break }
}
