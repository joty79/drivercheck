[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BeforePath,
    [Parameter(Mandatory = $true)]
    [string]$AfterPath,
    [switch]$AuditOnly,
    [switch]$IncludeCertificates,
    [switch]$IncludeRootCertificates,
    [switch]$AssumeYes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-CurrentSessionElevated {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SelfElevationArgumentList {
    $argumentList = @('-NoLogo', '-NoProfile', '-File', $PSCommandPath, '-BeforePath', $BeforePath, '-AfterPath', $AfterPath)

    if ($AuditOnly) {
        $argumentList += '-AuditOnly'
    }

    if ($IncludeCertificates) {
        $argumentList += '-IncludeCertificates'
    }

    if ($IncludeRootCertificates) {
        $argumentList += '-IncludeRootCertificates'
    }

    if ($AssumeYes) {
        $argumentList += '-AssumeYes'
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

function Read-JsonFile {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    return Get-Content -Raw $Path | ConvertFrom-Json
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

function Convert-ToArray {
    param(
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return @()
    }

    return @($InputObject)
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

function Get-MapByProperty {
    param(
        [object[]]$Items,
        [string]$PropertyName
    )

    $map = @{}
    foreach ($item in $Items) {
        $key = [string]$item.$PropertyName
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }

        $map[$key] = $item
    }

    return $map
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
            Identity = [string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'Identity' -DefaultValue '')
            RootName = [string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'RootName' -DefaultValue '')
            KeyPath = [string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'KeyPath' -DefaultValue '')
            MatchedTerms = [string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'MatchedTerms' -DefaultValue '')
            MatchSource = [string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'MatchSource' -DefaultValue '')
        }
    }

    $values = foreach ($item in (Convert-ToArray $RegistryData.Values)) {
        $identity = [string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'Identity' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($identity)) {
            $identity = ('{0}::{1}' -f ([string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'KeyPath' -DefaultValue '')), ([string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'ValueName' -DefaultValue '')))
        }

        [pscustomobject]@{
            Identity = $identity
            RootName = [string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'RootName' -DefaultValue '')
            KeyPath = [string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'KeyPath' -DefaultValue '')
            ValueName = [string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'ValueName' -DefaultValue '')
            ValueKind = [string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'ValueKind' -DefaultValue '')
            ValueData = [string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'ValueData' -DefaultValue '')
            MatchedTerms = [string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'MatchedTerms' -DefaultValue '')
            MatchSource = [string](Get-OptionalObjectProperty -InputObject $item -PropertyName 'MatchSource' -DefaultValue '')
        }
    }

    return [pscustomobject]@{
        Keys = @($keys | Sort-Object KeyPath)
        Values = @($values | Sort-Object Identity)
    }
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
        $differences = @()

        foreach ($property in $CompareProperties) {
            $beforeValue = [string]$beforeItem.$property
            $afterValue = [string]$afterItem.$property
            if ($beforeValue -ne $afterValue) {
                $differences += [pscustomobject]@{
                    Property = $property
                    Before = $beforeValue
                    After = $afterValue
                }
            }
        }

        if ($differences.Count -gt 0) {
            [pscustomobject]@{
                Key = $key
                Differences = $differences
            }
        }
    }

    [pscustomobject]@{
        Added = @($added | Sort-Object $KeyProperty)
        Removed = @($removed | Sort-Object $KeyProperty)
        Changed = @($changed | Sort-Object Key)
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

function Get-BcdRelevantLinesFromPath {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return @()
    }

    return Get-BcdRelevantLinesFromLines -Lines (Get-Content $Path)
}

function Get-BcdRelevantLinesFromLines {
    param(
        [string[]]$Lines
    )

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

    return @($Lines | Where-Object {
            $line = $_
            foreach ($pattern in $patterns) {
                if ($line -match $pattern) {
                    return $true
                }
            }

            return $false
        })
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
    $devices = Get-PnpDevice -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Class = $_.Class
            FriendlyName = $_.FriendlyName
            InstanceId = $_.InstanceId
            Present = $_.Present
            Problem = $_.Problem
            Status = $_.Status
        }
    }

    return @($devices | Sort-Object InstanceId)
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

function Should-ManageFileDirectly {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $systemDriversRoot = [IO.Path]::GetFullPath((Join-Path $env:windir 'System32\drivers'))
    $fullPath = [IO.Path]::GetFullPath($Path)
    $systemDriversPrefix = if ($systemDriversRoot.EndsWith([IO.Path]::DirectorySeparatorChar)) {
        $systemDriversRoot
    }
    else {
        $systemDriversRoot + [IO.Path]::DirectorySeparatorChar
    }

    if (
        $fullPath.Equals($systemDriversRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($systemDriversPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        return $true
    }

    return $false
}

function Convert-RegistryKeyPathToProviderPath {
    param(
        [string]$KeyPath
    )

    if ([string]::IsNullOrWhiteSpace($KeyPath)) {
        return ''
    }

    if ($KeyPath -match '^(HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER|HKEY_CLASSES_ROOT|HKEY_USERS|HKEY_CURRENT_CONFIG)\\') {
        return "Registry::$KeyPath"
    }

    return $KeyPath
}

function Test-RegistryKeyPresent {
    param(
        [string]$KeyPath
    )

    $providerPath = Convert-RegistryKeyPathToProviderPath -KeyPath $KeyPath
    if ([string]::IsNullOrWhiteSpace($providerPath)) {
        return $false
    }

    return (Test-Path -LiteralPath $providerPath)
}

function Test-RegistryValuePresent {
    param(
        [string]$KeyPath,
        [string]$ValueName
    )

    $providerPath = Convert-RegistryKeyPathToProviderPath -KeyPath $KeyPath
    if ([string]::IsNullOrWhiteSpace($providerPath) -or -not (Test-Path -LiteralPath $providerPath)) {
        return $false
    }

    try {
        $item = Get-ItemProperty -LiteralPath $providerPath -ErrorAction Stop
    }
    catch {
        return $false
    }

    return ($null -ne $item.PSObject.Properties[$ValueName])
}

function Test-SafeRegistryCleanupKey {
    param(
        [string]$KeyPath
    )

    if ([string]::IsNullOrWhiteSpace($KeyPath)) {
        return $false
    }

    if ($KeyPath -match '^HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\EventLog\\System\\[^\\]+$') {
        return $true
    }

    return $false
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

function Get-RootReviewTag {
    param(
        [object]$Certificate,
        [System.Collections.Generic.HashSet[string]]$PublisherThumbprints
    )

    $thumbprint = [string]$Certificate.Thumbprint
    if ($null -ne $PublisherThumbprints -and $PublisherThumbprints.Contains($thumbprint)) {
        return 'LINKED'
    }

    return 'ROOT-ONLY'
}

function New-CleanupAction {
    param(
        [int]$Order,
        [string]$Kind,
        [string]$Category,
        [string]$Label,
        [string]$Target,
        [string]$CommandPreview,
        [string]$CurrentState,
        [string]$Reason,
        [hashtable]$Extra
    )

    $properties = [ordered]@{
        Order = $Order
        Kind = $Kind
        Category = $Category
        Label = $Label
        Target = $Target
        CommandPreview = $CommandPreview
        CurrentState = $CurrentState
        Reason = $Reason
    }

    foreach ($key in $Extra.Keys) {
        $properties[$key] = $Extra[$key]
    }

    return [pscustomobject]$properties
}

function Format-UninstallEntryLabel {
    param(
        [object]$Entry
    )

    $parts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace([string]$Entry.DisplayName)) {
        $parts.Add([string]$Entry.DisplayName)
    }
    else {
        $parts.Add([string]$Entry.KeyName)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Entry.DisplayVersion)) {
        $parts.Add([string]$Entry.DisplayVersion)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Entry.Publisher)) {
        $parts.Add([string]$Entry.Publisher)
    }

    return ($parts -join ' :: ')
}

function Format-PnpCleanupLabel {
    param(
        [object]$Device
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $friendlyName = [string]$Device.FriendlyName
    $instanceId = [string]$Device.InstanceId

    if (-not [string]::IsNullOrWhiteSpace($friendlyName)) {
        if (-not [string]::IsNullOrWhiteSpace($instanceId)) {
            $parts.Add("$friendlyName [$instanceId]")
        }
        else {
            $parts.Add($friendlyName)
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($instanceId)) {
        $parts.Add($instanceId)
    }

    foreach ($value in @(
            [string](Get-OptionalObjectProperty -InputObject $Device -PropertyName 'InfName' -DefaultValue ''),
            [string](Get-OptionalObjectProperty -InputObject $Device -PropertyName 'ServiceName' -DefaultValue '')
        )) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $parts.Add($value)
        }
    }

    return ($parts -join ' :: ')
}

function Get-UninstallCommandSpec {
    param(
        [object]$Entry
    )

    $quietCommand = [string]$Entry.QuietUninstallString
    $normalCommand = [string]$Entry.UninstallString
    $productCode = [string]$Entry.ProductCode

    if (-not [string]::IsNullOrWhiteSpace($quietCommand)) {
        return [pscustomobject]@{
            CommandLine = $quietCommand
            Preview = $quietCommand
            Source = 'QuietUninstallString'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($normalCommand)) {
        return [pscustomobject]@{
            CommandLine = $normalCommand
            Preview = $normalCommand
            Source = 'UninstallString'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($productCode)) {
        $commandLine = "msiexec.exe /x $productCode /qn /norestart"
        return [pscustomobject]@{
            CommandLine = $commandLine
            Preview = $commandLine
            Source = 'ProductCodeFallback'
        }
    }

    return $null
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

function Get-CurrentBcdActionState {
    param(
        [string[]]$CurrentBcdLines,
        [string]$DataType,
        [string]$ExpectedAction
    )

    $joined = ($CurrentBcdLines -join "`n")

    switch ($ExpectedAction) {
        'SetOff' {
            switch ($DataType) {
                'testsigning' {
                    if ($joined -match '(?im)^\s*testsigning\s+(yes|on)\s*$') {
                        return 'Pending'
                    }
                }
                'debug' {
                    if ($joined -match '(?im)^\s*debug\s+(yes|on)\s*$') {
                        return 'Pending'
                    }
                }
                'bootdebug' {
                    if ($joined -match '(?im)^\s*bootdebug\s+(yes|on)\s*$') {
                        return 'Pending'
                    }
                }
            }
        }
        'DeleteValue' {
            if ($joined -match "(?im)^\s*$DataType\s+") {
                return 'Pending'
            }
        }
    }

    return 'Already reverted'
}

function Get-Choice {
    param(
        [string]$Prompt
    )

    while ($true) {
        $choice = Read-HostTrimmed -Prompt $Prompt
        if ($null -eq $choice) {
            $choice = ''
        }

        $normalizedChoice = ([string]$choice).Trim().ToUpperInvariant()
        if ($normalizedChoice -in @([string][char]27, 'ESC', 'ESCAPE')) {
            return 'QUIT'
        }

        if ($normalizedChoice -in @('Y', 'YES', 'S', 'SKIP', 'Q', 'QUIT')) {
            return $normalizedChoice
        }

        Write-Host 'Παρακαλώ γράψε Y, S ή Q. Το ESC ακυρώνει επίσης.' -ForegroundColor Yellow
    }
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

    foreach ($item in $Items) {
        Write-Host (Get-ConsoleSafeLine -Text ("[{0}] {1}" -f $item.Key, $item.Label)) -ForegroundColor $item.Color
    }
    Write-Host (Get-ConsoleSafeLine -Text ("[ESC] {0}" -f $CancelLabel)) -ForegroundColor DarkGray

    if ([Console]::IsInputRedirected) {
        $choice = Read-HostTrimmed -Prompt $Prompt
        if ($null -eq $choice) {
            return $null
        }

        $normalizedChoice = ([string]$choice).Trim()
        if ($normalizedChoice.Length -eq 1 -and [int][char]$normalizedChoice[0] -eq 27) {
            return $null
        }

        if ($normalizedChoice -match '^(?i:esc|escape)$') {
            return $null
        }

        return ($Items | Where-Object { $_.Key -eq $normalizedChoice } | Select-Object -First 1)
    }

    Write-Host (Get-ConsoleSafeLine -Text ("[{0}] Press a number key or ESC." -f $Prompt)) -ForegroundColor DarkGray
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Escape) {
            Write-Host ''
            return $null
        }

        $typedKey = [string]$key.KeyChar
        if ([string]::IsNullOrWhiteSpace($typedKey)) {
            continue
        }

        $matchedItem = $Items | Where-Object { $_.Key -eq $typedKey } | Select-Object -First 1
        if ($null -ne $matchedItem) {
            Write-Host $typedKey
            return $matchedItem
        }
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

function Write-SummaryCount {
    param(
        [string]$Label,
        [int]$Count
    )

    $color = if ($Count -gt 0) { 'Green' } else { 'DarkGray' }
    Write-Host ("{0,-22}: {1}" -f $Label, $Count) -ForegroundColor $color
}

function Write-ActionList {
    param(
        [object[]]$Actions
    )

    if ($Actions.Count -eq 0) {
        Write-Host 'Δεν προέκυψαν actions από τα snapshots.' -ForegroundColor Green
        return
    }

    $groupTitles = @{
        'Installed Application' = 'Phase 1: Official Uninstall'
        'PnP Device' = 'Phase 2: Remove Devices'
        'Service' = 'Phase 3: Remove Services'
        'Driver Package' = 'Phase 4: Remove Driver Packages'
        'Registry' = 'Phase 5: Remove Registry Leftovers'
        'File' = 'Phase 6: Remove Direct Leftovers'
        'Certificate' = 'Phase 7: Certificate Cleanup'
        'BCD' = 'Phase 8: Boot Configuration Cleanup'
    }

    $groupOrder = @{
        'Installed Application' = 10
        'PnP Device' = 20
        'Service' = 30
        'Driver Package' = 40
        'Registry' = 50
        'File' = 60
        'Certificate' = 70
        'BCD' = 80
    }

    $index = 0
    $groupedActions = $Actions |
        Sort-Object Order, Category, Label |
        Group-Object Category |
        Sort-Object @{ Expression = { if ($groupOrder.ContainsKey($_.Name)) { $groupOrder[$_.Name] } else { 999 } }; Ascending = $true }, Name
    foreach ($group in $groupedActions) {
        $phaseTitle = if ($groupTitles.ContainsKey($group.Name)) { $groupTitles[$group.Name] } else { $group.Name }
        Write-Host ''
        Write-Host $phaseTitle -ForegroundColor Cyan
        Write-Host ('~' * $phaseTitle.Length) -ForegroundColor Cyan

        foreach ($action in $group.Group) {
            $index++
            $color = if ($action.CurrentState -eq 'Pending') { 'Yellow' } else { 'Green' }
            Write-Host ("[{0:00}] [{1}] {2}" -f $index, $action.CurrentState, $action.Label) -ForegroundColor $color
            Write-Host "     Category : $($action.Category)" -ForegroundColor DarkGray
            if ($action.Category -eq 'Installed Application') {
                Write-Host "     Why first : Prefer the software's own uninstaller before residue cleanup." -ForegroundColor DarkGray
            }
            Write-Host "     Command  : $($action.CommandPreview)" -ForegroundColor DarkGray
        }
    }
}

function Write-RecommendedFlow {
    param(
        [int]$PendingUninstallerCount,
        [int]$PendingResidueCount
    )

    Write-Section -Title 'Recommended Flow'

    if ($PendingUninstallerCount -gt 0) {
        Write-Host '1. Run the official uninstaller first.' -ForegroundColor Green
        Write-Host '   Το [4] Run Cleanup From Snapshots μπορεί να το τρέξει αυτόματα από το script.' -ForegroundColor DarkGray
        Write-Host '2. Continue with the remaining device/service/package/file cleanup actions.' -ForegroundColor Green
        Write-Host '3. Take a fresh AfterCleanup snapshot and compare again for leftovers.' -ForegroundColor Green
        return
    }

    if ($PendingResidueCount -gt 0) {
        Write-Host '1. No official uninstaller is pending, so continue with residue cleanup.' -ForegroundColor Green
        Write-Host '2. Remove devices, services, packages, registry leftovers, and direct files in the shown phase order.' -ForegroundColor Green
        Write-Host '3. Take a fresh AfterCleanup snapshot and compare again for leftovers.' -ForegroundColor Green
        return
    }

    Write-Host 'No pending cleanup flow remains in the current system state.' -ForegroundColor Green
}

function Invoke-CleanupAction {
    param(
        [object]$Action
    )

    switch ($Action.Kind) {
        'RemovePnpDevice' {
            $result = Invoke-NativeCapture -FilePath 'pnputil.exe' -Arguments @('/remove-device', $Action.InstanceId)
            return [pscustomobject]@{
                Success = ($result.ExitCode -eq 0)
                Output = @($result.Output)
            }
        }

        'DeleteService' {
            $stopResult = Invoke-NativeCapture -FilePath 'sc.exe' -Arguments @('stop', $Action.ServiceName)
            $deleteResult = Invoke-NativeCapture -FilePath 'sc.exe' -Arguments @('delete', $Action.ServiceName)
            $success = ($deleteResult.ExitCode -eq 0 -or ($deleteResult.Output -join "`n") -match 'SUCCESS')
            return [pscustomobject]@{
                Success = $success
                Output = @($stopResult.Output + '' + $deleteResult.Output)
            }
        }

        'RunUninstaller' {
            $process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', $Action.CommandLine) -Wait -PassThru -WindowStyle Hidden
            return [pscustomobject]@{
                Success = ($null -ne $process -and $process.ExitCode -eq 0)
                Output = @(
                    "Executed $($Action.CommandSource): $($Action.CommandLine)",
                    "ExitCode: $($process.ExitCode)"
                )
            }
        }

        'DeleteDriverPackage' {
            $result = Invoke-NativeCapture -FilePath 'pnputil.exe' -Arguments @('/delete-driver', $Action.PublishedName, '/uninstall', '/force')
            $success = ($result.ExitCode -eq 0)
            return [pscustomobject]@{
                Success = $success
                Output = @($result.Output)
            }
        }

        'RemoveFile' {
            if (-not (Test-Path -LiteralPath $Action.FilePath)) {
                return [pscustomobject]@{
                    Success = $true
                    Output = @("File is already absent: $($Action.FilePath)")
                }
            }

            try {
                Remove-Item -LiteralPath $Action.FilePath -Force -ErrorAction Stop
                return [pscustomobject]@{
                    Success = $true
                    Output = @("Removed: $($Action.FilePath)")
                }
            }
            catch {
                return [pscustomobject]@{
                    Success = $false
                    Output = @($_.Exception.Message)
                }
            }
        }

        'RemoveRegistryKey' {
            $providerPath = Convert-RegistryKeyPathToProviderPath -KeyPath $Action.RegistryKeyPath
            if (-not (Test-Path -LiteralPath $providerPath)) {
                return [pscustomobject]@{
                    Success = $true
                    Output = @("Registry key is already absent: $($Action.RegistryKeyPath)")
                }
            }

            try {
                Remove-Item -LiteralPath $providerPath -Recurse -Force -ErrorAction Stop
                return [pscustomobject]@{
                    Success = $true
                    Output = @("Removed registry key: $($Action.RegistryKeyPath)")
                }
            }
            catch {
                return [pscustomobject]@{
                    Success = $false
                    Output = @($_.Exception.Message)
                }
            }
        }

        'RemoveCertificate' {
            $cert = Get-ChildItem $Action.StorePath -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $Action.Thumbprint } | Select-Object -First 1
            if ($null -eq $cert) {
                return [pscustomobject]@{
                    Success = $true
                    Output = @('Certificate is already absent.')
                }
            }

            try {
                Remove-Item -LiteralPath $cert.PSPath -Force -ErrorAction Stop
                return [pscustomobject]@{
                    Success = $true
                    Output = @("Removed certificate: $($Action.Thumbprint)")
                }
            }
            catch {
                return [pscustomobject]@{
                    Success = $false
                    Output = @($_.Exception.Message)
                }
            }
        }

        'SetBcdOff' {
            $result = Invoke-NativeCapture -FilePath 'bcdedit.exe' -Arguments @('/set', '{current}', $Action.DataType, 'off')
            return [pscustomobject]@{
                Success = ($result.ExitCode -eq 0)
                Output = @($result.Output)
            }
        }

        'DeleteBcdValue' {
            $result = Invoke-NativeCapture -FilePath 'bcdedit.exe' -Arguments @('/deletevalue', '{current}', $Action.DataType)
            return [pscustomobject]@{
                Success = ($result.ExitCode -eq 0)
                Output = @($result.Output)
            }
        }
    }

    return [pscustomobject]@{
        Success = $false
        Output = @("Unsupported action kind: $($Action.Kind)")
    }
}

if (-not (Test-CurrentSessionElevated)) {
    Write-Host 'Administrator rights are required for snapshot-driven cleanup.' -ForegroundColor Yellow
    Write-Host 'Opening an elevated PowerShell window...' -ForegroundColor Cyan
    Start-SelfElevatedInstance
}

$BeforePath = Assert-SnapshotPathReadable -Path $BeforePath -Label 'Before snapshot'
$AfterPath = Assert-SnapshotPathReadable -Path $AfterPath -Label 'After snapshot'

$beforeMetadata = Read-JsonFile -Path (Join-Path $BeforePath 'metadata.json')
$afterMetadata = Read-JsonFile -Path (Join-Path $AfterPath 'metadata.json')

$beforePackages = Convert-ToArray (Read-JsonFile -Path (Join-Path $BeforePath 'driver-packages.json'))
$afterPackages = Convert-ToArray (Read-JsonFile -Path (Join-Path $AfterPath 'driver-packages.json'))
$beforeServices = Convert-ToArray (Read-JsonFile -Path (Join-Path $BeforePath 'services.registry.json'))
$afterServices = Convert-ToArray (Read-JsonFile -Path (Join-Path $AfterPath 'services.registry.json'))
$beforeDevices = Convert-ToArray (Read-JsonFile -Path (Join-Path $BeforePath 'pnp-devices.json'))
$afterDevices = Convert-ToArray (Read-JsonFile -Path (Join-Path $AfterPath 'pnp-devices.json'))
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

$packageDiff = Compare-NamedObjects -BeforeItems $beforePackages -AfterItems $afterPackages -KeyProperty 'PublishedName' -CompareProperties @('OriginalName', 'ProviderName', 'DriverVersion', 'SignerName')
$serviceDiff = Compare-NamedObjects -BeforeItems $beforeServices -AfterItems $afterServices -KeyProperty 'Name' -CompareProperties @('DisplayName', 'ImagePath', 'Start', 'Type', 'ErrorControl', 'Group')
$deviceDiff = Compare-NamedObjects -BeforeItems $beforeDevices -AfterItems $afterDevices -KeyProperty 'InstanceId' -CompareProperties @('Class', 'FriendlyName', 'Present', 'Problem', 'Status')
$rootCertDiff = Compare-NamedObjects -BeforeItems $beforeRootCerts -AfterItems $afterRootCerts -KeyProperty 'Thumbprint' -CompareProperties @('Subject', 'Issuer', 'NotAfter')
$publisherCertDiff = Compare-NamedObjects -BeforeItems $beforePublisherCerts -AfterItems $afterPublisherCerts -KeyProperty 'Thumbprint' -CompareProperties @('Subject', 'Issuer', 'NotAfter')
$registryKeyDiff = Compare-NamedObjects -BeforeItems $beforeRegistryFocus.Keys -AfterItems $afterRegistryFocus.Keys -KeyProperty 'Identity' -CompareProperties @()
$registryValueDiff = Compare-NamedObjects -BeforeItems $beforeRegistryFocus.Values -AfterItems $afterRegistryFocus.Values -KeyProperty 'Identity' -CompareProperties @('RootName', 'KeyPath', 'ValueName', 'ValueKind', 'ValueData')
$fileDiff = Compare-NamedObjects -BeforeItems $beforeFiles -AfterItems $afterFiles -KeyProperty 'FullName' -CompareProperties @('Length', 'Sha256', 'LastWriteTime')
$uninstallEntryDiff = Compare-NamedObjects -BeforeItems $beforeUninstallEntries -AfterItems $afterUninstallEntries -KeyProperty 'Identity' -CompareProperties @('DisplayName', 'DisplayVersion', 'Publisher', 'InstallLocation', 'InstallSource', 'UninstallString', 'QuietUninstallString', 'WindowsInstaller', 'ProductCode')
$directFileCandidates = @($fileDiff.Added | Where-Object { Should-ManageFileDirectly -Path $_.FullName })
$deferredFileCandidates = @($fileDiff.Added | Where-Object { -not (Should-ManageFileDirectly -Path $_.FullName) })
$safeRegistryKeyCandidates = @($registryKeyDiff.Added | Where-Object { Test-SafeRegistryCleanupKey -KeyPath $_.KeyPath })
$safeRegistryValueCandidates = @(
    $registryValueDiff.Added | Where-Object {
        (Test-SafeRegistryCleanupKey -KeyPath $_.KeyPath) -and
        ($safeRegistryKeyCandidates.KeyPath -notcontains $_.KeyPath)
    }
)
$rootAddedCerts = @($rootCertDiff.Added)
$publisherAddedThumbprints = Get-CertThumbprintSet -Items $publisherCertDiff.Added
$relevantRootCerts = @()
if ($IncludeRootCertificates) {
    $relevantRootCerts = @(
        $rootAddedCerts | Where-Object {
            $null -ne $publisherAddedThumbprints -and $publisherAddedThumbprints.Contains([string]$_.Thumbprint)
        }
    )
}
$relevantRootThumbprints = Get-CertThumbprintSet -Items $relevantRootCerts
$reviewOnlyRootCerts = @(
    $rootAddedCerts | Where-Object {
        $null -eq $relevantRootThumbprints -or -not $relevantRootThumbprints.Contains([string]$_.Thumbprint)
    }
)
$relevantPublisherCerts = @($publisherCertDiff.Added)
$publisherDiffThumbprints = Get-CertThumbprintSet -Items $relevantPublisherCerts

$beforeBcd = Get-BcdRelevantLinesFromPath -Path (Join-Path $BeforePath 'bcdedit.enum.all.txt')
$afterBcd = Get-BcdRelevantLinesFromPath -Path (Join-Path $AfterPath 'bcdedit.enum.all.txt')
$bcdAdded = @(Compare-Object -ReferenceObject @($beforeBcd) -DifferenceObject @($afterBcd) -PassThru | Where-Object { $_.SideIndicator -eq '=>' })

$currentPackages = Convert-PnpUtilToDriverPackages -Lines (Invoke-NativeCapture -FilePath 'pnputil.exe' -Arguments @('/enum-drivers')).Output
$currentPackageMap = Get-MapByProperty -Items $currentPackages -PropertyName 'PublishedName'
$currentServices = Get-ServiceRegistrySnapshot
$currentServiceMap = Get-MapByProperty -Items $currentServices -PropertyName 'Name'
$currentDevices = Get-PnpDeviceSnapshot
$currentDeviceMap = Get-MapByProperty -Items $currentDevices -PropertyName 'InstanceId'
$currentRootCerts = Get-CertificateSnapshot -StorePath 'Cert:\LocalMachine\Root'
$currentRootCertMap = Get-MapByProperty -Items $currentRootCerts -PropertyName 'Thumbprint'
$currentPublisherCerts = Get-CertificateSnapshot -StorePath 'Cert:\LocalMachine\TrustedPublisher'
$currentPublisherCertMap = Get-MapByProperty -Items $currentPublisherCerts -PropertyName 'Thumbprint'
$currentUninstallEntries = Get-UninstallEntrySnapshot
$currentUninstallEntryMap = Get-MapByProperty -Items $currentUninstallEntries -PropertyName 'Identity'
$currentBcdLines = Get-BcdRelevantLinesFromLines -Lines (Invoke-NativeCapture -FilePath 'bcdedit.exe' -Arguments @('/enum', 'all')).Output
$currentRelevantRootCerts = @($relevantRootCerts | Where-Object { $currentRootCertMap.ContainsKey([string]$_.Thumbprint) })
$currentRelevantPublisherCerts = @($relevantPublisherCerts | Where-Object { $currentPublisherCertMap.ContainsKey([string]$_.Thumbprint) })
$currentReviewOnlyRootCerts = @($reviewOnlyRootCerts | Where-Object { $currentRootCertMap.ContainsKey([string]$_.Thumbprint) })
$currentCrossStoreReviewCerts = @(
    $currentReviewOnlyRootCerts | Where-Object {
        $null -ne $publisherDiffThumbprints -and $publisherDiffThumbprints.Contains([string]$_.Thumbprint)
    }
)
$currentLinkedReviewRootCerts = @(
    $currentReviewOnlyRootCerts | Where-Object {
        $null -ne $publisherDiffThumbprints -and $publisherDiffThumbprints.Contains([string]$_.Thumbprint)
    }
)
$currentRootOnlyReviewCerts = @(
    $currentReviewOnlyRootCerts | Where-Object {
        $thumbprint = [string]$_.Thumbprint
        $null -eq $publisherDiffThumbprints -or -not $publisherDiffThumbprints.Contains($thumbprint)
    }
)

$actions = New-Object System.Collections.Generic.List[object]

foreach ($entry in $uninstallEntryDiff.Added) {
    $classification = Get-UninstallEntryClassification -Entry $entry
    if ($classification -ne 'LIKELY') {
        continue
    }

    $commandSpec = Get-UninstallCommandSpec -Entry $entry
    if ($null -eq $commandSpec) {
        continue
    }

    $currentState = if ($currentUninstallEntryMap.ContainsKey([string]$entry.Identity)) { 'Pending' } else { 'Already absent' }
    $actions.Add((New-CleanupAction -Order 5 -Kind 'RunUninstaller' -Category 'Installed Application' -Label "[LIKELY] $(Format-UninstallEntryLabel -Entry $entry)" -Target ([string]$entry.Identity) -CommandPreview $commandSpec.Preview -CurrentState $currentState -Reason 'Official uninstall entry was added after install and should run before direct residue cleanup.' -Extra @{
                Identity = [string]$entry.Identity
                CommandLine = [string]$commandSpec.CommandLine
                CommandSource = [string]$commandSpec.Source
                Classification = $classification
            }))
}

foreach ($device in @($deviceDiff.Added | Where-Object { -not (Should-IgnoreDevice -Device $_) })) {
    $currentState = if ($currentDeviceMap.ContainsKey($device.InstanceId)) { 'Pending' } else { 'Already absent' }
    $actions.Add((New-CleanupAction -Order 10 -Kind 'RemovePnpDevice' -Category 'PnP Device' -Label (Format-PnpCleanupLabel -Device $device) -Target $device.InstanceId -CommandPreview "pnputil /remove-device `"$($device.InstanceId)`"" -CurrentState $currentState -Reason 'Present in After snapshot but not in Before snapshot.' -Extra @{
                InstanceId = $device.InstanceId
            }))
}

foreach ($service in $serviceDiff.Added) {
    $currentState = if ($currentServiceMap.ContainsKey($service.Name)) { 'Pending' } else { 'Already absent' }
    $actions.Add((New-CleanupAction -Order 20 -Kind 'DeleteService' -Category 'Service' -Label "$($service.Name) :: $($service.ImagePath)" -Target $service.Name -CommandPreview "sc.exe delete $($service.Name)" -CurrentState $currentState -Reason 'Service key was added after install.' -Extra @{
                ServiceName = $service.Name
            }))
}

foreach ($package in $packageDiff.Added) {
    $currentState = if ($currentPackageMap.ContainsKey($package.PublishedName)) { 'Pending' } else { 'Already absent' }
    $actions.Add((New-CleanupAction -Order 30 -Kind 'DeleteDriverPackage' -Category 'Driver Package' -Label "$($package.PublishedName) :: $($package.OriginalName) :: $($package.ProviderName)" -Target $package.PublishedName -CommandPreview "pnputil /delete-driver $($package.PublishedName) /uninstall /force" -CurrentState $currentState -Reason 'Driver package was staged after install.' -Extra @{
                PublishedName = $package.PublishedName
            }))
}

foreach ($file in $directFileCandidates) {
    $currentState = if (Test-Path $file.FullName) { 'Pending' } else { 'Already absent' }
    $actions.Add((New-CleanupAction -Order 40 -Kind 'RemoveFile' -Category 'File' -Label $file.FullName -Target $file.FullName -CommandPreview "Remove-Item -LiteralPath '$($file.FullName)' -Force" -CurrentState $currentState -Reason 'Focused file was added after install.' -Extra @{
                FilePath = $file.FullName
            }))
}

foreach ($registryKey in $safeRegistryKeyCandidates) {
    $currentState = if (Test-RegistryKeyPresent -KeyPath $registryKey.KeyPath) { 'Pending' } else { 'Already absent' }
    $actions.Add((New-CleanupAction -Order 45 -Kind 'RemoveRegistryKey' -Category 'Registry' -Label $registryKey.KeyPath -Target $registryKey.KeyPath -CommandPreview "Remove-Item -LiteralPath '$(Convert-RegistryKeyPathToProviderPath -KeyPath $registryKey.KeyPath)' -Recurse -Force" -CurrentState $currentState -Reason 'Safe focused registry leftover remained after cleanup.' -Extra @{
                RegistryKeyPath = $registryKey.KeyPath
            }))
}

if ($IncludeCertificates) {
    foreach ($cert in $relevantRootCerts) {
        $currentState = if ($currentRootCertMap.ContainsKey($cert.Thumbprint)) { 'Pending' } else { 'Already absent' }
        $actions.Add((New-CleanupAction -Order 50 -Kind 'RemoveCertificate' -Category 'Certificate' -Label "ROOT :: $($cert.Subject)" -Target $cert.Thumbprint -CommandPreview "Remove certificate $($cert.Thumbprint) from LocalMachine\\Root" -CurrentState $currentState -Reason 'Certificate was added after install.' -Extra @{
                    Thumbprint = $cert.Thumbprint
                    StorePath = 'Cert:\LocalMachine\Root'
                }))
    }

    foreach ($cert in $relevantPublisherCerts) {
        $currentState = if ($currentPublisherCertMap.ContainsKey($cert.Thumbprint)) { 'Pending' } else { 'Already absent' }
        $actions.Add((New-CleanupAction -Order 60 -Kind 'RemoveCertificate' -Category 'Certificate' -Label "TRUSTEDPUBLISHER :: $($cert.Subject)" -Target $cert.Thumbprint -CommandPreview "Remove certificate $($cert.Thumbprint) from LocalMachine\\TrustedPublisher" -CurrentState $currentState -Reason 'Certificate was added after install.' -Extra @{
                    Thumbprint = $cert.Thumbprint
                    StorePath = 'Cert:\LocalMachine\TrustedPublisher'
                }))
    }
}

if (@($bcdAdded | Where-Object { $_ -match '(?i)^\s*testsigning\s+(yes|on)\s*$' }).Count -gt 0) {
    $currentState = Get-CurrentBcdActionState -CurrentBcdLines $currentBcdLines -DataType 'testsigning' -ExpectedAction 'SetOff'
    $actions.Add((New-CleanupAction -Order 70 -Kind 'SetBcdOff' -Category 'BCD' -Label 'Disable TESTSIGNING' -Target 'testsigning' -CommandPreview 'bcdedit /set {current} testsigning off' -CurrentState $currentState -Reason 'TESTSIGNING was enabled after install.' -Extra @{
                DataType = 'testsigning'
            }))
}

if (@($bcdAdded | Where-Object { $_ -match '(?i)^\s*loadoptions\s+.*DISABLE_INTEGRITY_CHECKS' }).Count -gt 0) {
    $currentState = Get-CurrentBcdActionState -CurrentBcdLines $currentBcdLines -DataType 'loadoptions' -ExpectedAction 'DeleteValue'
    $actions.Add((New-CleanupAction -Order 80 -Kind 'DeleteBcdValue' -Category 'BCD' -Label 'Remove loadoptions' -Target 'loadoptions' -CommandPreview 'bcdedit /deletevalue {current} loadoptions' -CurrentState $currentState -Reason 'loadoptions was changed after install.' -Extra @{
                DataType = 'loadoptions'
            }))
}

if (@($bcdAdded | Where-Object { $_ -match '(?i)^\s*nointegritychecks\s+' }).Count -gt 0) {
    $currentState = Get-CurrentBcdActionState -CurrentBcdLines $currentBcdLines -DataType 'nointegritychecks' -ExpectedAction 'DeleteValue'
    $actions.Add((New-CleanupAction -Order 90 -Kind 'DeleteBcdValue' -Category 'BCD' -Label 'Remove nointegritychecks' -Target 'nointegritychecks' -CommandPreview 'bcdedit /deletevalue {current} nointegritychecks' -CurrentState $currentState -Reason 'nointegritychecks was changed after install.' -Extra @{
                DataType = 'nointegritychecks'
            }))
}

if (@($bcdAdded | Where-Object { $_ -match '(?i)^\s*debug\s+(yes|on)\s*$' }).Count -gt 0) {
    $currentState = Get-CurrentBcdActionState -CurrentBcdLines $currentBcdLines -DataType 'debug' -ExpectedAction 'SetOff'
    $actions.Add((New-CleanupAction -Order 100 -Kind 'SetBcdOff' -Category 'BCD' -Label 'Disable DEBUG' -Target 'debug' -CommandPreview 'bcdedit /set {current} debug off' -CurrentState $currentState -Reason 'DEBUG was enabled after install.' -Extra @{
                DataType = 'debug'
            }))
}

if (@($bcdAdded | Where-Object { $_ -match '(?i)^\s*bootdebug\s+(yes|on)\s*$' }).Count -gt 0) {
    $currentState = Get-CurrentBcdActionState -CurrentBcdLines $currentBcdLines -DataType 'bootdebug' -ExpectedAction 'SetOff'
    $actions.Add((New-CleanupAction -Order 110 -Kind 'SetBcdOff' -Category 'BCD' -Label 'Disable BOOTDEBUG' -Target 'bootdebug' -CommandPreview 'bcdedit /set {current} bootdebug off' -CurrentState $currentState -Reason 'BOOTDEBUG was enabled after install.' -Extra @{
                DataType = 'bootdebug'
            }))
}

$sortedActions = @($actions | Sort-Object Order, Category, Label)
$pendingActions = @($sortedActions | Where-Object { $_.CurrentState -eq 'Pending' })
$pendingUninstallCount = @($pendingActions | Where-Object { $_.Category -eq 'Installed Application' }).Count
$likelyUninstallEntries = @($uninstallEntryDiff.Added | Where-Object { (Get-UninstallEntryClassification -Entry $_) -eq 'LIKELY' })
$reviewUninstallEntries = @($uninstallEntryDiff.Added | Where-Object { (Get-UninstallEntryClassification -Entry $_) -eq 'REVIEW' })
$noiseUninstallEntries = @($uninstallEntryDiff.Added | Where-Object { (Get-UninstallEntryClassification -Entry $_) -eq 'NOISE' })
$addedDeviceCount = @($deviceDiff.Added | Where-Object { -not (Should-IgnoreDevice -Device $_) }).Count
$pendingDeviceCount = @($pendingActions | Where-Object { $_.Category -eq 'PnP Device' }).Count
$pendingServiceCount = @($pendingActions | Where-Object { $_.Category -eq 'Service' }).Count
$pendingPackageCount = @($pendingActions | Where-Object { $_.Category -eq 'Driver Package' }).Count
$pendingFileCount = @($pendingActions | Where-Object { $_.Category -eq 'File' }).Count
$pendingRegistryCount = @($pendingActions | Where-Object { $_.Category -eq 'Registry' }).Count
$pendingBcdCount = @($pendingActions | Where-Object { $_.Category -eq 'BCD' }).Count
$pendingCertificateCount = @($pendingActions | Where-Object { $_.Category -eq 'Certificate' }).Count

Write-Host ''
Write-Host 'Snapshot-Driven Driver Cleanup' -ForegroundColor Green
Write-Host '------------------------------' -ForegroundColor Green
Write-Host "Before snapshot : $BeforePath"
Write-Host "After snapshot  : $AfterPath"
Write-Host "Certificate mode: $(if ($IncludeCertificates) { 'Enabled' } else { 'Audit only / skip removal' })"
Write-Host "Root cert auto-actions: $(if ($IncludeRootCertificates) { 'Enabled' } else { 'Review only' })"

Write-Section -Title 'Findings Summary'
Write-SummaryCount -Label 'Added uninstall apps' -Count $uninstallEntryDiff.Added.Count
Write-SummaryCount -Label 'Likely uninstall apps' -Count $likelyUninstallEntries.Count
Write-SummaryCount -Label 'Review uninstall apps' -Count $reviewUninstallEntries.Count
Write-SummaryCount -Label 'Noise uninstall apps' -Count $noiseUninstallEntries.Count
Write-SummaryCount -Label 'Pending uninstallers' -Count $pendingUninstallCount
Write-SummaryCount -Label 'Added driver packages' -Count $packageDiff.Added.Count
Write-SummaryCount -Label 'Pending packages now' -Count $pendingPackageCount
Write-SummaryCount -Label 'Added services' -Count $serviceDiff.Added.Count
Write-SummaryCount -Label 'Pending services now' -Count $pendingServiceCount
Write-SummaryCount -Label 'Added PnP devices' -Count $addedDeviceCount
Write-SummaryCount -Label 'Pending devices now' -Count $pendingDeviceCount
Write-SummaryCount -Label 'Added focused files' -Count $fileDiff.Added.Count
Write-SummaryCount -Label 'Pending file removals' -Count $pendingFileCount
Write-SummaryCount -Label 'Direct file evidence' -Count $directFileCandidates.Count
Write-SummaryCount -Label 'DriverStore-only files' -Count $deferredFileCandidates.Count
Write-SummaryCount -Label 'Added registry keys' -Count $registryKeyDiff.Added.Count
Write-SummaryCount -Label 'Pending registry cleanup' -Count $pendingRegistryCount
Write-SummaryCount -Label 'Added certs' -Count ($rootCertDiff.Added.Count + $publisherCertDiff.Added.Count)
Write-SummaryCount -Label 'Pending cert actions' -Count ($currentRelevantRootCerts.Count + $currentRelevantPublisherCerts.Count)
Write-SummaryCount -Label 'Pending review roots' -Count $currentReviewOnlyRootCerts.Count
Write-SummaryCount -Label 'Review roots linked' -Count $currentLinkedReviewRootCerts.Count
Write-SummaryCount -Label 'Review roots root-only' -Count $currentRootOnlyReviewCerts.Count
Write-SummaryCount -Label 'Pending cert removals' -Count $pendingCertificateCount
Write-SummaryCount -Label 'Relevant BCD changes' -Count $bcdAdded.Count
Write-SummaryCount -Label 'Pending BCD fixes' -Count $pendingBcdCount

Write-RecommendedFlow -PendingUninstallerCount $pendingUninstallCount -PendingResidueCount $pendingActions.Count

Write-Section -Title 'Cleanup Plan'
if ($deferredFileCandidates.Count -gt 0) {
    Write-Host "Note: $($deferredFileCandidates.Count) DriverStore/INF artifacts θα αφεθούν πρώτα στο package cleanup του pnputil και μετά θα ελεγχθούν ξανά." -ForegroundColor DarkYellow
}
if ($currentReviewOnlyRootCerts.Count -gt 0) {
    Write-Host "Note: $($currentReviewOnlyRootCerts.Count) ROOT certificates είναι ΑΚΟΜΑ present αλλά έμειναν σε review-only mode και ΔΕΝ μπήκαν σε auto-cleanup actions." -ForegroundColor DarkYellow
}
if ($IncludeCertificates -and -not $IncludeRootCertificates -and $currentRelevantPublisherCerts.Count -gt 0) {
    Write-Host 'Note: Με enabled certificate cleanup, τα TRUSTEDPUBLISHER certs μπαίνουν σε auto-actions αλλά τα ROOT certs μένουν review-only από default.' -ForegroundColor DarkYellow
}
if ($currentCrossStoreReviewCerts.Count -gt 0) {
    Write-Host "Note: $($currentCrossStoreReviewCerts.Count) thumbprint(s) εμφανίστηκαν και σε TRUSTEDPUBLISHER snapshot diff / cleanup plan και σε ROOT review item. Αυτό είναι αναμενόμενο γιατί τα certificate stores είναι ξεχωριστά." -ForegroundColor DarkYellow
}
if ($currentReviewOnlyRootCerts.Count -gt 0) {
    Write-Host 'Note: Root review tags: [LINKED] = ίδιο thumbprint εμφανίστηκε και σε TRUSTEDPUBLISHER diff, [ROOT-ONLY] = το diff έδειξε μόνο ROOT store addition.' -ForegroundColor DarkYellow
}
if ($reviewUninstallEntries.Count -gt 0 -or $noiseUninstallEntries.Count -gt 0) {
    Write-Host 'Note: Installed applications tagged as REVIEW/NOISE μένουν εκτός auto-cleanup plan.' -ForegroundColor DarkYellow
}
if ($pendingUninstallCount -gt 0) {
    Write-Host 'Note: Official uninstallers in Phase 1 μπορούν να τρέξουν αυτόματα από το [4] Run Cleanup From Snapshots.' -ForegroundColor DarkYellow
}
Write-ActionList -Actions $sortedActions

if ($reviewUninstallEntries.Count -gt 0 -or $noiseUninstallEntries.Count -gt 0) {
    Write-Section -Title 'Installed Application Review'
    foreach ($entry in $likelyUninstallEntries | Sort-Object DisplayName, DisplayVersion) {
        Write-Host "[LIKELY] $(Format-UninstallEntryLabel -Entry $entry)" -ForegroundColor Yellow
    }
    foreach ($entry in $reviewUninstallEntries | Sort-Object DisplayName, DisplayVersion) {
        Write-Host "[REVIEW] $(Format-UninstallEntryLabel -Entry $entry)" -ForegroundColor Cyan
    }
    foreach ($entry in $noiseUninstallEntries | Sort-Object DisplayName, DisplayVersion) {
        Write-Host "[NOISE]  $(Format-UninstallEntryLabel -Entry $entry)" -ForegroundColor DarkGray
    }
}

if ($currentReviewOnlyRootCerts.Count -gt 0) {
    Write-Section -Title 'Root Certificate Review'
    foreach ($cert in $currentReviewOnlyRootCerts | Sort-Object Subject) {
        $tag = Get-RootReviewTag -Certificate $cert -PublisherThumbprints $publisherDiffThumbprints
        Write-Host "ROOT :: [$tag] $($cert.Thumbprint) :: $($cert.Subject)" -ForegroundColor DarkYellow
    }
}

if ($AuditOnly) {
    Write-Host ''
    if ($pendingUninstallCount -gt 0) {
        Write-Host 'AuditOnly mode: δεν έγινε καμία αλλαγή. Το [4] Run Cleanup From Snapshots θα ξεκινήσει πρώτα τον official uninstaller και μετά τα residue steps.' -ForegroundColor Green
    }
    else {
        Write-Host 'AuditOnly mode: δεν έγινε καμία αλλαγή.' -ForegroundColor Green
    }
    exit 0
}

if ($pendingActions.Count -eq 0) {
    Write-Host ''
    Write-Host 'Δεν βρέθηκαν pending actions στο current system state.' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host "Pending actions: $($pendingActions.Count)" -ForegroundColor Yellow
if ($pendingUninstallCount -gt 0) {
    Write-Host 'Το script θα ξεκινήσει με τον official uninstaller και μετά θα προχωρήσει step-by-step στα residue actions.' -ForegroundColor Yellow
}
else {
    Write-Host 'Το script θα προχωρήσει step-by-step και θα ζητήσει επιβεβαίωση σε κάθε action.' -ForegroundColor Yellow
}

if (-not $AssumeYes) {
    $globalConfirm = Read-HostTrimmed -Prompt "Γράψε CLEAN για να ξεκινήσει η step-by-step αφαίρεση"
    $normalizedGlobalConfirm = if ($null -eq $globalConfirm) { '' } else { ([string]$globalConfirm).Trim() }
    if ($normalizedGlobalConfirm.Length -eq 1 -and [int][char]$normalizedGlobalConfirm[0] -eq 27) {
        $normalizedGlobalConfirm = 'ESC'
    }

    if ($normalizedGlobalConfirm -match '^(?i:esc|escape)$' -or $normalizedGlobalConfirm -cne 'CLEAN') {
        Write-Host 'Ακύρωση από τον χρήστη.' -ForegroundColor Yellow
        exit 0
    }
}

$autoApproveRemaining = $AssumeYes.IsPresent
if (-not $AssumeYes) {
    Write-Host ''
    Write-Host '⚠️ EXTRA WARNING' -ForegroundColor Red
    Write-Host 'Το επόμενο mode καθορίζει αν θα ζητείται confirm σε κάθε step ή αν θα τρέξουν ΟΛΑ τα pending actions μετά το CLEAN.' -ForegroundColor Yellow
    Write-Host 'Το Yes to all είναι γρήγορο, αλλά πιο επιθετικό. Χρησιμοποίησέ το μόνο όταν είσαι σίγουρος για το plan.' -ForegroundColor DarkYellow
    Write-Host ''

    $executionMode = Read-SingleChoiceMenu -Items @(
        [pscustomobject]@{ Key = '1'; Label = 'Step-by-step confirms for every action'; Color = 'Cyan'; Value = 'STEP' },
        [pscustomobject]@{ Key = '2'; Label = 'YES TO ALL after CLEAN for the whole run'; Color = 'Yellow'; Value = 'ALL' }
    ) -Prompt 'Execution mode' -CancelLabel 'Cancel cleanup run'

    if ($null -eq $executionMode) {
        Write-Host 'Ακύρωση από τον χρήστη.' -ForegroundColor Yellow
        exit 0
    }

    $autoApproveRemaining = $executionMode.Value -eq 'ALL'
}

$completed = 0
$failed = 0
$skipped = 0
$stepIndex = 0
$quitRequested = $false

foreach ($action in $pendingActions) {
    $stepIndex++
    Write-Section -Title ("Step {0}/{1}" -f $stepIndex, $pendingActions.Count)
    Write-Host "Category : $($action.Category)"
    Write-Host "Target   : $($action.Label)"
    Write-Host "Reason   : $($action.Reason)"
    Write-Host "Command  : $($action.CommandPreview)" -ForegroundColor DarkGray

    if (-not $autoApproveRemaining) {
        $choice = Get-Choice -Prompt 'Run this step? [Y]es / [S]kip / [Q]uit'
        switch ($choice) {
            { $_ -in @('Q', 'QUIT') } {
                Write-Host 'Τερματισμός από τον χρήστη.' -ForegroundColor Yellow
                $quitRequested = $true
                break
            }
            { $_ -in @('S', 'SKIP') } {
                Write-Host 'Skipped.' -ForegroundColor Yellow
                $skipped++
                continue
            }
        }
    }

    if ($quitRequested) {
        break
    }

    $result = Invoke-CleanupAction -Action $action
    if ($result.Success) {
        Write-Host 'Success.' -ForegroundColor Green
        $completed++
    }
    else {
        Write-Host 'Failed.' -ForegroundColor Red
        $failed++
    }

    foreach ($line in @($result.Output | Select-Object -First 12)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            Write-Host "  $line"
        }
    }
}

Write-Section -Title 'Run Summary'
Write-Host "Completed : $completed"
Write-Host "Failed    : $failed"
Write-Host "Skipped   : $skipped"
Write-Host ''
Write-Host 'Προτείνεται νέο snapshot μετά το cleanup για να ελέγξεις τι έμεινε πίσω.' -ForegroundColor Yellow
