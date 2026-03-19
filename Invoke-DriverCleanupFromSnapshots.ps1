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
        $choice = (Read-Host $Prompt).Trim().ToUpperInvariant()
        if ($choice -in @('Y', 'YES', 'S', 'SKIP', 'Q', 'QUIT')) {
            return $choice
        }

        Write-Host 'Παρακαλώ γράψε Y, S ή Q.' -ForegroundColor Yellow
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

function Write-ActionList {
    param(
        [object[]]$Actions
    )

    if ($Actions.Count -eq 0) {
        Write-Host 'Δεν προέκυψαν actions από τα snapshots.' -ForegroundColor Green
        return
    }

    $index = 0
    foreach ($action in $Actions | Sort-Object Order, Category, Label) {
        $index++
        $color = if ($action.CurrentState -eq 'Pending') { 'Yellow' } else { 'Green' }
        Write-Host ("[{0:00}] [{1}] {2}" -f $index, $action.CurrentState, $action.Label) -ForegroundColor $color
        Write-Host "     Category : $($action.Category)" -ForegroundColor DarkGray
        Write-Host "     Command  : $($action.CommandPreview)" -ForegroundColor DarkGray
    }
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
$beforeFiles = Convert-ToArray (Read-JsonFile -Path (Join-Path $BeforePath 'focus-files.json'))
$afterFiles = Convert-ToArray (Read-JsonFile -Path (Join-Path $AfterPath 'focus-files.json'))

$packageDiff = Compare-NamedObjects -BeforeItems $beforePackages -AfterItems $afterPackages -KeyProperty 'PublishedName' -CompareProperties @('OriginalName', 'ProviderName', 'DriverVersion', 'SignerName')
$serviceDiff = Compare-NamedObjects -BeforeItems $beforeServices -AfterItems $afterServices -KeyProperty 'Name' -CompareProperties @('DisplayName', 'ImagePath', 'Start', 'Type', 'ErrorControl', 'Group')
$deviceDiff = Compare-NamedObjects -BeforeItems $beforeDevices -AfterItems $afterDevices -KeyProperty 'InstanceId' -CompareProperties @('Class', 'FriendlyName', 'Present', 'Problem', 'Status')
$rootCertDiff = Compare-NamedObjects -BeforeItems $beforeRootCerts -AfterItems $afterRootCerts -KeyProperty 'Thumbprint' -CompareProperties @('Subject', 'Issuer', 'NotAfter')
$publisherCertDiff = Compare-NamedObjects -BeforeItems $beforePublisherCerts -AfterItems $afterPublisherCerts -KeyProperty 'Thumbprint' -CompareProperties @('Subject', 'Issuer', 'NotAfter')
$fileDiff = Compare-NamedObjects -BeforeItems $beforeFiles -AfterItems $afterFiles -KeyProperty 'FullName' -CompareProperties @('Length', 'Sha256', 'LastWriteTime')
$directFileCandidates = @($fileDiff.Added | Where-Object { Should-ManageFileDirectly -Path $_.FullName })
$deferredFileCandidates = @($fileDiff.Added | Where-Object { -not (Should-ManageFileDirectly -Path $_.FullName) })
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
$bcdAdded = @(Compare-Object -ReferenceObject $beforeBcd -DifferenceObject $afterBcd -PassThru | Where-Object { $_.SideIndicator -eq '=>' })

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

foreach ($device in @($deviceDiff.Added | Where-Object { -not (Should-IgnoreDevice -Device $_) })) {
    $currentState = if ($currentDeviceMap.ContainsKey($device.InstanceId)) { 'Pending' } else { 'Already absent' }
    $actions.Add((New-CleanupAction -Order 10 -Kind 'RemovePnpDevice' -Category 'PnP Device' -Label "$($device.FriendlyName) [$($device.InstanceId)]" -Target $device.InstanceId -CommandPreview "pnputil /remove-device `"$($device.InstanceId)`"" -CurrentState $currentState -Reason 'Present in After snapshot but not in Before snapshot.' -Extra @{
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
$addedDeviceCount = @($deviceDiff.Added | Where-Object { -not (Should-IgnoreDevice -Device $_) }).Count
$pendingDeviceCount = @($pendingActions | Where-Object { $_.Category -eq 'PnP Device' }).Count
$pendingServiceCount = @($pendingActions | Where-Object { $_.Category -eq 'Service' }).Count
$pendingPackageCount = @($pendingActions | Where-Object { $_.Category -eq 'Driver Package' }).Count
$pendingFileCount = @($pendingActions | Where-Object { $_.Category -eq 'File' }).Count
$pendingBcdCount = @($pendingActions | Where-Object { $_.Category -eq 'BCD' }).Count
$pendingCertificateCount = @($pendingActions | Where-Object { $_.Category -eq 'Certificate' }).Count

Write-Host ''
Write-Host 'Snapshot-Driven Driver Cleanup' -ForegroundColor Green
Write-Host '------------------------------' -ForegroundColor Green
Write-Host "Before snapshot : $BeforePath"
Write-Host "After snapshot  : $AfterPath"
if ($afterMetadata) {
    Write-Host "Focus terms     : $((@($afterMetadata.FocusTerm)) -join ', ')"
}
Write-Host "Certificate mode: $(if ($IncludeCertificates) { 'Enabled' } else { 'Audit only / skip removal' })"
Write-Host "Root cert auto-actions: $(if ($IncludeRootCertificates) { 'Enabled' } else { 'Review only' })"

Write-Section -Title 'Findings Summary'
Write-Host "Added driver packages : $($packageDiff.Added.Count)"
Write-Host "Pending packages now  : $pendingPackageCount"
Write-Host "Added services        : $($serviceDiff.Added.Count)"
Write-Host "Pending services now  : $pendingServiceCount"
Write-Host "Added PnP devices     : $addedDeviceCount"
Write-Host "Pending devices now   : $pendingDeviceCount"
Write-Host "Added focused files   : $($fileDiff.Added.Count)"
Write-Host "Pending file removals : $pendingFileCount"
Write-Host "Direct file evidence  : $($directFileCandidates.Count)"
Write-Host "DriverStore-only files: $($deferredFileCandidates.Count)"
Write-Host "Added certs           : $($rootCertDiff.Added.Count + $publisherCertDiff.Added.Count)"
Write-Host "Pending cert actions  : $($currentRelevantRootCerts.Count + $currentRelevantPublisherCerts.Count)"
Write-Host "Pending review roots  : $($currentReviewOnlyRootCerts.Count)"
Write-Host "Review roots linked   : $($currentLinkedReviewRootCerts.Count)"
Write-Host "Review roots root-only: $($currentRootOnlyReviewCerts.Count)"
Write-Host "Pending cert removals : $pendingCertificateCount"
Write-Host "Relevant BCD changes  : $($bcdAdded.Count)"
Write-Host "Pending BCD fixes     : $pendingBcdCount"

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
Write-ActionList -Actions $sortedActions

if ($currentReviewOnlyRootCerts.Count -gt 0) {
    Write-Section -Title 'Root Certificate Review'
    foreach ($cert in $currentReviewOnlyRootCerts | Sort-Object Subject) {
        $tag = Get-RootReviewTag -Certificate $cert -PublisherThumbprints $publisherDiffThumbprints
        Write-Host "ROOT :: [$tag] $($cert.Thumbprint) :: $($cert.Subject)" -ForegroundColor DarkYellow
    }
}

if ($AuditOnly) {
    Write-Host ''
    Write-Host 'AuditOnly mode: δεν έγινε καμία αλλαγή.' -ForegroundColor Green
    exit 0
}

if ($pendingActions.Count -eq 0) {
    Write-Host ''
    Write-Host 'Δεν βρέθηκαν pending actions στο current system state.' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host "Pending actions: $($pendingActions.Count)" -ForegroundColor Yellow
Write-Host 'Το script θα προχωρήσει step-by-step και θα ζητήσει επιβεβαίωση σε κάθε action.' -ForegroundColor Yellow

if (-not $AssumeYes) {
    $globalConfirm = Read-Host "Γράψε CLEAN για να ξεκινήσει η step-by-step αφαίρεση"
    if ($globalConfirm -cne 'CLEAN') {
        Write-Host 'Ακύρωση από τον χρήστη.' -ForegroundColor Yellow
        exit 0
    }
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

    if (-not $AssumeYes) {
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
