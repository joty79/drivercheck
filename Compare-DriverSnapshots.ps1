[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BeforePath,
    [Parameter(Mandatory = $true)]
    [string]$AfterPath
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

    [pscustomobject]@{
        Added = @($added | Sort-Object $KeyProperty)
        Removed = @($removed | Sort-Object $KeyProperty)
        Changed = @($changed | Sort-Object Key)
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
$beforeSetupApi = Read-JsonFile -Path (Join-Path $BeforePath 'setupapi.dev-log.json')
$afterSetupApi = Read-JsonFile -Path (Join-Path $AfterPath 'setupapi.dev-log.json')

$packageDiff = Compare-NamedObjects -BeforeItems $beforePackages -AfterItems $afterPackages -KeyProperty 'PublishedName' -CompareProperties @('OriginalName', 'ProviderName', 'DriverVersion', 'SignerName')
$serviceDiff = Compare-NamedObjects -BeforeItems $beforeServices -AfterItems $afterServices -KeyProperty 'Name' -CompareProperties @('DisplayName', 'ImagePath', 'Start', 'Type', 'ErrorControl', 'Group')
$deviceDiff = Compare-NamedObjects -BeforeItems $beforeDevices -AfterItems $afterDevices -KeyProperty 'InstanceId' -CompareProperties @('Class', 'FriendlyName', 'Present', 'Problem', 'Status')
$rootCertDiff = Compare-NamedObjects -BeforeItems $beforeRootCerts -AfterItems $afterRootCerts -KeyProperty 'Thumbprint' -CompareProperties @('Subject', 'Issuer', 'NotAfter')
$publisherCertDiff = Compare-NamedObjects -BeforeItems $beforePublisherCerts -AfterItems $afterPublisherCerts -KeyProperty 'Thumbprint' -CompareProperties @('Subject', 'Issuer', 'NotAfter')
$fileDiff = Compare-NamedObjects -BeforeItems $beforeFiles -AfterItems $afterFiles -KeyProperty 'FullName' -CompareProperties @('Length', 'Sha256', 'LastWriteTime')
$publisherAddedThumbprints = Get-CertThumbprintSet -Items $publisherCertDiff.Added
$publisherRemovedThumbprints = Get-CertThumbprintSet -Items $publisherCertDiff.Removed

$beforeBcd = Get-BcdRelevantLines -Path (Join-Path $BeforePath 'bcdedit.enum.all.txt')
$afterBcd = Get-BcdRelevantLines -Path (Join-Path $AfterPath 'bcdedit.enum.all.txt')
$bcdAdded = @(Compare-Object -ReferenceObject $beforeBcd -DifferenceObject $afterBcd -PassThru | Where-Object { $_.SideIndicator -eq '=>' })
$bcdRemoved = @(Compare-Object -ReferenceObject $beforeBcd -DifferenceObject $afterBcd -PassThru | Where-Object { $_.SideIndicator -eq '<=' })
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

Write-Host ''
Write-Host 'Driver Snapshot Compare' -ForegroundColor Green
Write-Host '-----------------------' -ForegroundColor Green
Write-Host "Before : $BeforePath"
Write-Host "After  : $AfterPath"
if ($beforeMetadata -and $afterMetadata) {
    Write-Host "Focus  : $((@($afterMetadata.FocusTerm)) -join ', ')"
}

Write-Section -Title 'Driver Packages'
if ($packageDiff.Added.Count -eq 0 -and $packageDiff.Removed.Count -eq 0 -and $packageDiff.Changed.Count -eq 0) {
    Write-Host 'No driver package changes detected.'
}
else {
    foreach ($item in $packageDiff.Added) {
        Write-Host "+ $($item.PublishedName) :: $($item.OriginalName) :: $($item.ProviderName)" -ForegroundColor Yellow
    }
    foreach ($item in $packageDiff.Removed) {
        Write-Host "- $($item.PublishedName) :: $($item.OriginalName) :: $($item.ProviderName)" -ForegroundColor DarkYellow
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
        Write-Host "+ $($item.Name) :: $($item.ImagePath)" -ForegroundColor Yellow
    }
    foreach ($item in $serviceDiff.Removed) {
        Write-Host "- $($item.Name) :: $($item.ImagePath)" -ForegroundColor DarkYellow
    }
    foreach ($item in $serviceDiff.Changed) {
        Write-Host "* $($item.Key)" -ForegroundColor White
        foreach ($diff in $item.Differences) {
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
        Write-Host "+ $($item.InstanceId) :: $($item.FriendlyName)" -ForegroundColor Yellow
    }
    foreach ($item in $deviceRemoved) {
        Write-Host "- $($item.InstanceId) :: $($item.FriendlyName)" -ForegroundColor DarkYellow
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
        Write-Host "+ ROOT :: [$tag] $($item.Thumbprint) :: $($item.Subject)" -ForegroundColor Yellow
    }
    foreach ($item in $rootCertDiff.Removed) {
        $tag = Get-CertificateTag -Certificate $item -StoreName 'ROOT' -PublisherThumbprints $publisherRemovedThumbprints
        Write-Host "- ROOT :: [$tag] $($item.Thumbprint) :: $($item.Subject)" -ForegroundColor DarkYellow
    }
    foreach ($item in $publisherCertDiff.Added) {
        $tag = Get-CertificateTag -Certificate $item -StoreName 'TRUSTEDPUBLISHER' -PublisherThumbprints $publisherAddedThumbprints
        Write-Host "+ TRUSTEDPUBLISHER :: [$tag] $($item.Thumbprint) :: $($item.Subject)" -ForegroundColor Yellow
    }
    foreach ($item in $publisherCertDiff.Removed) {
        $tag = Get-CertificateTag -Certificate $item -StoreName 'TRUSTEDPUBLISHER' -PublisherThumbprints $publisherRemovedThumbprints
        Write-Host "- TRUSTEDPUBLISHER :: [$tag] $($item.Thumbprint) :: $($item.Subject)" -ForegroundColor DarkYellow
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
        Write-Host "+ $($item.FullName)" -ForegroundColor Yellow
    }
    foreach ($item in $fileDiff.Removed) {
        Write-Host "- $($item.FullName)" -ForegroundColor DarkYellow
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
        Write-Host "+ $line" -ForegroundColor Yellow
    }
    foreach ($line in $bcdRemoved) {
        Write-Host "- $line" -ForegroundColor DarkYellow
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
