[CmdletBinding()]
param(
    [string]$Name,
    [string]$CaseName,
    [string]$Stage,
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'snapshots'),
    [string[]]$FocusTerm = @('MulttKey', 'hasp')
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

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $argumentList += @('-Name', $Name)
    }

    if (-not [string]::IsNullOrWhiteSpace($CaseName)) {
        $argumentList += @('-CaseName', $CaseName)
    }

    if (-not [string]::IsNullOrWhiteSpace($Stage)) {
        $argumentList += @('-Stage', $Stage)
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

function Convert-ToSafeSnapshotName {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'Snapshot'
    }

    return ($Value -replace '[^\w\-]+', '_').Trim('_')
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

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$snapshotLabel = Get-SnapshotLabel
$safeName = Convert-ToSafeSnapshotName -Value $snapshotLabel
$snapshotPath = Join-Path $OutputRoot "$timestamp-$safeName"
New-Item -ItemType Directory -Path $snapshotPath -Force | Out-Null

$metadata = [pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    SnapshotName = $snapshotLabel
    CaseName = $CaseName
    Stage = $Stage
    SnapshotPath = $snapshotPath
    Timestamp = (Get-Date)
    IsAdministrator = $true
    FocusTerm = @($FocusTerm)
}

$bcdResult = Invoke-NativeCapture -FilePath 'bcdedit.exe' -Arguments @('/enum', 'all')
$pnpResult = Invoke-NativeCapture -FilePath 'pnputil.exe' -Arguments @('/enum-drivers')
$driverPackages = @(Convert-PnpUtilToDriverPackages -Lines $pnpResult.Output)
$serviceRegistry = @(Get-ServiceRegistrySnapshot)
$pnpDevices = @(Get-PnpDeviceSnapshot)
$rootCerts = @(Get-CertificateSnapshot -StorePath 'Cert:\LocalMachine\Root')
$trustedPublisherCerts = @(Get-CertificateSnapshot -StorePath 'Cert:\LocalMachine\TrustedPublisher')
$focusFiles = @(Get-FocusFileSnapshot -Terms $FocusTerm)
$setupApi = Get-SetupApiSnapshot

$metadata | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'metadata.json') -Encoding utf8
$bcdResult.Output | Set-Content -Path (Join-Path $snapshotPath 'bcdedit.enum.all.txt') -Encoding utf8
$pnpResult.Output | Set-Content -Path (Join-Path $snapshotPath 'pnputil.enum-drivers.txt') -Encoding utf8
$driverPackages | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'driver-packages.json') -Encoding utf8
$serviceRegistry | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'services.registry.json') -Encoding utf8
$pnpDevices | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'pnp-devices.json') -Encoding utf8
$rootCerts | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'cert-root.json') -Encoding utf8
$trustedPublisherCerts | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'cert-trustedpublisher.json') -Encoding utf8
$focusFiles | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'focus-files.json') -Encoding utf8
$setupApi | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $snapshotPath 'setupapi.dev-log.json') -Encoding utf8
$setupApi.Tail | Set-Content -Path (Join-Path $snapshotPath 'setupapi.dev-log.tail.txt') -Encoding utf8

Write-Host ''
Write-Host 'Driver Snapshot Saved' -ForegroundColor Green
Write-Host '---------------------' -ForegroundColor Green
Write-Host "Path           : $snapshotPath"
Write-Host "Label          : $snapshotLabel"
Write-Host "Focus terms    : $($FocusTerm -join ', ')"
Write-Host "Driver packages: $($driverPackages.Count)"
Write-Host "PnP devices    : $($pnpDevices.Count)"
Write-Host "Service keys   : $($serviceRegistry.Count)"
Write-Host "Focus files    : $($focusFiles.Count)"
if (-not [string]::IsNullOrWhiteSpace($Stage)) {
    Write-Host "Stage          : $Stage"
}
Write-Host ''
Write-Host (Get-StageRecommendation -CurrentStage $Stage) -ForegroundColor DarkYellow
