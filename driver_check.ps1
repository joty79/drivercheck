[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$DriverName
)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $exe = "pwsh.exe"
    } else {
        $exe = "powershell.exe"
    }
    
    $argsList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if (-not [string]::IsNullOrWhiteSpace($DriverName)) {
        $argsList += " -DriverName `"$DriverName`""
    }
    
    Start-Process -FilePath $exe -ArgumentList $argsList -Verb RunAs
    exit
}

$isWT = [bool]($env:WT_SESSION)

if ($isWT) {
    $I_Info  = "🔵"
    $I_Warn  = "⚠️"
    $I_Ok    = "✅"
    $I_Item  = "🔸"
    $I_Input = "✍️"
} else {
    $I_Info  = "[~]"
    $I_Warn  = "[!]"
    $I_Ok    = "[V]"
    $I_Item  = " ->"
    $I_Input = "[?]"
}

function Show-Header {
    Clear-Host
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "           ΔΙΑΧΕΙΡΙΣΗ SYSTEM DRIVERS           " -ForegroundColor White
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host ""
}

function Wait-ActionOrRestart {
    Write-Host "`nΠατήστε [ENTER] για νέα αναζήτηση ή [ESC] για έξοδο (κλείσιμο παραθύρου)..." -ForegroundColor DarkYellow
    while ($true) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Escape) {
                [Environment]::Exit(0)
            }
            if ($key.Key -eq [ConsoleKey]::Enter) {
                return
            }
        }
        Start-Sleep -Milliseconds 100
    }
}

while ($true) {
    Show-Header
    
    $inputDriver = $DriverName
    $DriverName = "" # Clean for next loop iteration
    
    if ([string]::IsNullOrWhiteSpace($inputDriver)) {
        Write-Host "Για έξοδο από το πρόγραμμα, απλά αφήστε το κενό και πατήστε [ENTER]." -ForegroundColor DarkGray
        $inputDriver = Read-Host "$I_Input Εισάγετε όνομα Driver (π.χ. nv, MulttKey)"
    }
    
    if ([string]::IsNullOrWhiteSpace($inputDriver)) {
        [Environment]::Exit(0)
    }

    $SearchTerm = $inputDriver.Replace(".sys", "").Trim()

    Write-Host "`n$I_Info Σάρωση συστήματος για εγγραφές που περιέχουν: `"$SearchTerm`"..." -ForegroundColor Cyan

    $candidates = @()

    # 1. Υπηρεσίες
    $svcs = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $SearchTerm -or $_.DisplayName -match $SearchTerm }
    if ($svcs) { $candidates += $svcs.Name }

    # 2. Αρχεία στο System32
    $sysPathBase = Join-Path $env:SystemRoot "System32\drivers"
    $files = Get-ChildItem -Path $sysPathBase -Filter "*$SearchTerm*.sys" -ErrorAction SilentlyContinue
    if ($files) { $candidates += $files.BaseName }

    # 3. PnP Driver Store
    Write-Host "$I_Item Εντοπισμός στο Driver Store (μπορεί να πάρει λίγο χρόνο)..." -ForegroundColor DarkGray
    $allPnp = pnputil /enum-drivers
    foreach ($line in $allPnp) {
        # Ψάχνουμε το Original Name που να περιέχει τον όρο
        if ($line -match "Original Name:\s+(.*?$SearchTerm.*?)\.(inf|sys)") {
            $candidates += $matches[1]
        }
    }

    # Φιλτράρισμα και Μοναδικότητα
    $candidates = $candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique | Sort-Object

    if ($candidates.Count -eq 0) {
        Write-Host "`n$I_Ok Δεν βρέθηκε κανένας driver / υπηρεσία που να ταιριάζει με το `"$SearchTerm`"." -ForegroundColor Green
        Wait-ActionOrRestart
        continue
    }

    $ExactDriver = ""

    if ($candidates.Count -eq 1) {
        $ExactDriver = $candidates[0]
    } else {
        Write-Host "`n$I_Warn Βρέθηκαν πολλαπλά αποτελέσματα. Παρακαλώ επιλέξτε τον ΣΩΣΤΟ driver:`n" -ForegroundColor Yellow
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host "  [$($i+1)] $($candidates[$i])" -ForegroundColor Cyan
        }
        Write-Host "  [0] Ακύρωση" -ForegroundColor Red
        
        $selStr = Read-Host "`n$I_Input Πληκτρολογήστε τον αριθμό (0-$($candidates.Count))"
        $selNum = $selStr -as [int]
        
        if ($null -eq $selNum -or $selNum -eq 0 -or $selNum -lt 0 -or $selNum -gt $candidates.Count) {
            Write-Host "`nΑκύρωση ενέργειας από τον χρήστη." -ForegroundColor Yellow
            Wait-ActionOrRestart
            continue
        }
        
        $ExactDriver = $candidates[$selNum - 1]
    }

    Write-Host "`n==============================================="
    Write-Host " ΕΠΙΛΕΓΜΕΝΟΣ DRIVER: $ExactDriver" -ForegroundColor Magenta
    Write-Host "==============================================="

    $driverFoundExact = $false

    Write-Host "`n$I_Info 1. Έλεγχος Κατάστασης Υπηρεσίας (Service)" -ForegroundColor Cyan
    $svcE = Get-Service -Name $ExactDriver -ErrorAction SilentlyContinue
    if ($svcE) {
        Write-Host "$I_Item Βρέθηκε υπηρεσία: $($svcE.Name) - Κατάσταση: $($svcE.Status)" -ForegroundColor Yellow
        $driverFoundExact = $true
    } else {
        Write-Host "$I_Ok Δεν βρέθηκε ενεργή ή καταχωρημένη υπηρεσία με το ΑΚΡΙΒΕΣ όνομα: $ExactDriver" -ForegroundColor Green
    }

    Write-Host "`n$I_Info 2. Έλεγχος Αρχείου .sys" -ForegroundColor Cyan
    $sysPathE = Join-Path $env:SystemRoot "System32\drivers\$ExactDriver.sys"
    if (Test-Path $sysPathE) {
        Write-Host "$I_Item Το αρχείο υπάρχει: $sysPathE" -ForegroundColor Yellow
        $driverFoundExact = $true
    } else {
        Write-Host "$I_Ok Το αρχείο δεν βρέθηκε στο System32\drivers." -ForegroundColor Green
    }

    Write-Host "`n$I_Info 3. Έλεγχος στο DriverQuery" -ForegroundColor Cyan
    # Αναζητούμε ακριβώς στην αρχή της γραμμής (\s+ κάνει match τα κενά)
    $dqExact = driverquery /v | Select-String "(?i)^$ExactDriver\s+"
    if ($dqExact) {
        Write-Host "$I_Item Ο driver βρέθηκε φορτωμένος από τα Windows!" -ForegroundColor Yellow
        $dqExact | ForEach-Object { Write-Host "    $($_.Line.Trim())" -ForegroundColor DarkYellow }
        $driverFoundExact = $true
    } else {
        Write-Host "$I_Ok Δεν βρέθηκε ακριβές module στο driverquery." -ForegroundColor Green
    }

    Write-Host "`n$I_Info 4. Έλεγχος στο Driver Store (pnputil)" -ForegroundColor Cyan
    $currentInf = $null
    $infsToRemove = @()
    $foundPnp = $false

    foreach ($line in $allPnp) {
        if ($line -match 'Published Name:\s+(oem\d+\.inf)') {
            $currentInf = $matches[1]
        }
        if ($line -match "Original Name:\s+(.*)") {
            $origMap = $matches[1]
            if ($origMap -match "(?i)^$ExactDriver\.(inf|sys)") {
                $infsToRemove += $currentInf
                $foundPnp = $true
            }
        }
    }

    if ($foundPnp) {
        Write-Host "$I_Item Βρέθηκαν εγγραφές στο Driver Store:" -ForegroundColor Yellow
        $infsToRemove | Select-Object -Unique | ForEach-Object {
            Write-Host "    Αρχείο INF: $_" -ForegroundColor DarkYellow
        }
        $driverFoundExact = $true
    } else {
        Write-Host "$I_Ok Δεν βρέθηκε στο Driver Store." -ForegroundColor Green
    }

    Write-Host "`n==============================================="

    if (-not $driverFoundExact) {
        Write-Host "$I_Ok Δεν εντοπίστηκε καμία εγκατάσταση του `$ExactDriver` στο σύστημα. Η διαδικασία τερματίζεται." -ForegroundColor Green
        Wait-ActionOrRestart
        continue
    }

    Write-Host "`n$I_Warn ΚΙΝΔΥΝΟΣ: Πρόκειται να προχωρήσετε σε ΠΛΗΡΗ ΔΙΑΓΡΑΦΗ του driver: [$ExactDriver]" -ForegroundColor Red
    Write-Host "Η λανθασμένη διαγραφή μπορεί να προκαλέσει ασταθεια ή BSOD στο σύστημα!" -ForegroundColor Red
    $action = Read-Host "`n$I_Input Πληκτρολογήστε 'YES' (με ΚΕΦΑΛΑΙΑ γράμματα) για διαγραφή ή οτιδήποτε άλλο για ακύρωση"

    if ($action -ceq 'YES') {
        Write-Host "`n$I_Info Έναρξη Διαγραφής για: $ExactDriver" -ForegroundColor Cyan
        
        # 1. Διαγραφή Service
        Write-Host "$I_Item Διαγραφή υπηρεσίας..."
        $scOut = sc.exe delete $ExactDriver 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $scOut -match "SUCCESS") {
            Write-Host "$I_Ok Η υπηρεσία διαγράφηκε επιτυχώς." -ForegroundColor Green
        } else {
            Write-Host "$I_Warn Σφάλμα/Αποτυχία κατά τη διαγραφή υπηρεσίας:" -ForegroundColor Yellow
            Write-Host "    $($scOut.Trim())" -ForegroundColor DarkYellow
        }
        
        # 2. Διαγραφή από Driver Store
        if ($infsToRemove.Count -gt 0) {
            $infsToRemove | Select-Object -Unique | ForEach-Object {
                $inf = $_
                Write-Host "`n$I_Item Απεγκατάσταση $inf από το Driver Store..."
                $pnpOut = pnputil /delete-driver $inf /uninstall /force 2>&1 | Out-String
                if ($LASTEXITCODE -eq 0 -or $pnpOut -match "Deleted successfully") {
                    Write-Host "$I_Ok Διαγράφηκε με επιτυχία από το Store." -ForegroundColor Green
                } else {
                    Write-Host "$I_Warn Αποτυχία ή μερική επιστροφή σφάλματος από pnputil:" -ForegroundColor Yellow
                    Write-Host "    $($pnpOut.Trim())" -ForegroundColor DarkYellow
                }
            }
        }
        
        # 3. Διαγραφή φυσικού αρχείου (.sys)
        if (Test-Path $sysPathE) {
            Write-Host "`n$I_Item Διαγραφή φυσικού αρχείου ($sysPathE)..."
            try {
                Remove-Item -Path $sysPathE -Force -ErrorAction Stop
                Write-Host "$I_Ok Το αρχείο διεγράφη επιτυχώς από τον δίσκο." -ForegroundColor Green
            } catch {
                Write-Host "$I_Warn Ήταν αδύνατη η διαγραφή (ενδέχεται να είναι κλειδωμένο ή να απαιτεί δικαιώματα SYSTEM)." -ForegroundColor Yellow
                Write-Host "    Σφάλμα Windows: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        
        Write-Host "`n$I_Ok Η διαδικασία ολοκληρώθηκε! Προτείνεται ΠΑΝΤΑ επανεκκίνηση του συστήματος." -ForegroundColor Green
    } else {
        Write-Host "`n$I_Warn Δεν δόθηκε η λέξη 'YES'. Ακύρωση διαγραφής." -ForegroundColor Yellow
    }

    Wait-ActionOrRestart
    continue
}
