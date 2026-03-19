<p align="center">
  <img src="https://img.shields.io/badge/Platform-Windows_10%2F11-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Platform">
  <img src="https://img.shields.io/badge/Language-PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white" alt="Language">
  <img src="https://img.shields.io/badge/License-Unspecified-lightgrey?style=for-the-badge" alt="License">
</p>

<h1 align="center">🛠️ drivercheck</h1>

<p align="center">
  <b>Interactive PowerShell utility για εντοπισμό και πλήρη αφαίρεση επίμονων Windows drivers.</b><br>
  <sub>Search term → exact selection → multi-source verification → explicit cleanup</sub>
</p>

## ✨ Τι Περιλαμβάνει

| #   | Tool                                                      | Description                                                                                                |
|:---:| --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| 🧭  | **[DriverCheck Workbench](#drivercheck-workbench)**       | Menu-driven shell που σε καθοδηγεί για snapshots, compare και cleanup με σωστό timing και readable names.  |
| 🛠️ | **[Driver Check](#driver-check)**                         | Κάνει broad search για drivers και προχωρά σε ακριβή, επιβεβαιωμένη διαγραφή μόνο μετά από explicit `YES`. |
| 📸  | **[Save Driver Snapshot](#save-driver-snapshot)**         | Παίρνει focused πριν/μετά snapshot για `BCD`, drivers, devices, services, certs και `SetupAPI` evidence.   |
| 🔍  | **[Compare Driver Snapshots](#compare-driver-snapshots)** | Συγκρίνει δύο snapshots και δείχνει ακριβώς τι πρόσθεσε ή τι άφησε πίσω ένα install/remove flow.           |
| 🧹  | **[Cleanup From Snapshots](#cleanup-from-snapshots)**     | Χτίζει step-by-step cleanup plan από `Before/After` snapshots και προχωρά μόνο με δική σου επιβεβαίωση.    |

<a id="drivercheck-workbench"></a>

## 🧭 DriverCheck Workbench

> Το πιο φιλικό entry point του repo για non-technical workflow γύρω από snapshots, compare και cleanup.

### Τι Λύνει

- Δεν χρειάζεται να θυμάσαι κάθε φορά ποιο script τρέχει ποια δουλειά.
- Σου προτείνει το σωστό snapshot timing ώστε να μειώνεις install/uninstall noise.
- Ελέγχεις όλο το flow από ένα απλό numbered menu με `Read-Host`, άρα μένει copy-friendly.
- Χρησιμοποιεί color-coded numbered actions, grouped menu sections και stage-specific icons ώστε το menu να διαβάζεται πιο εύκολα από non-technical χρήστη.

### Usage

```powershell
pwsh -ExecutionPolicy Bypass -File .\DriverCheckWorkbench.ps1
pwsh -ExecutionPolicy Bypass -File .\DriverCheckWorkbench.ps1 -CaseName HaspTest
```

| Parameter        | Type     | Default       | Description                                                                      |
| ---------------- | -------- | ------------- | -------------------------------------------------------------------------------- |
| `-CaseName`      | `string` | empty         | Προαιρετικό initial case name για να ξεκινήσεις αμέσως το current investigation. |
| `-SnapshotsRoot` | `string` | `.\snapshots` | Root folder από όπου διαβάζει και όπου αποθηκεύει snapshots.                     |

💡 Το workbench προτείνει ενεργά:

- `BeforeInstall` ακριβώς πριν το install
- `AfterInstall` ΑΜΕΣΩΣ μετά το install
- `AfterRemove` / `AfterCleanup` ΑΜΕΣΩΣ μετά το uninstall/cleanup

Αυτό μειώνει το background noise και κάνει τα diffs πιο αξιόπιστα.

<a id="driver-check"></a>

## 🛠️ Driver Check

> Ένα single-script workflow για να δεις αν ένας driver υπάρχει ακόμα και να τον καθαρίσεις από τα βασικά σημεία του συστήματος.

### Το Πρόβλημα

- Ένας προβληματικός driver μπορεί να αφήνει ίχνη ως service, `.sys` αρχείο, loaded module ή Driver Store entry.
- Μερικές φορές το install έχει ήδη “σβηστεί”, αλλά έχουν μείνει orphan service keys, `oemXX.inf` packages ή `PnP` leftovers.
- Η μερική διαγραφή συχνά αφήνει leftovers που μπλοκάρουν reinstall ή troubleshooting.
- Το απλό substring match είναι επικίνδυνο όταν πολλά drivers μοιάζουν μεταξύ τους.

### Η Λύση

Το script ξεκινά με ευρύ search για candidates, αλλά αν αυτό δεν βρει τίποτα κάνει και `deep exact check` για το όνομα που έδωσες. Μετά κάνει verification σε πολλαπλές πηγές, μπορεί να δείξει `SetupAPI`-linked related components ως follow-up hints, και προχωρά σε cleanup μόνο αν γράψεις ακριβώς `YES`.

```text
Search term
   |
   v
Candidate discovery
   |-- HKLM:\SYSTEM\CurrentControlSet\Services
   |-- C:\Windows\System32\drivers\*.sys
   |-- pnputil /enum-drivers
   v
Exact driver selection
   |-- If no broad hit, force deep exact check
   |
   v
Verification
   |-- Service + service registry key
   |-- Exact .sys file check
   |-- driverquery /v
   |-- Driver Store mapping
   |-- PnP device evidence
   |-- Focused Windows file leftovers
   v
Typed confirmation: YES
   |
   v
Cleanup
   |-- pnputil /remove-device
   |-- sc.exe delete
   |-- orphan service-key cleanup
   |-- pnputil /delete-driver /uninstall /force
   |-- Remove-Item <driver>.sys
   |-- post-cleanup recheck
```

Αυτό το flow είναι πιο ασφαλές από ένα "search and delete" pattern, γιατί χωρίζει το broad discovery από το exact-match deletion.

### Usage

⚠️ Το tool είναι destructive. Διάβαζε πάντα τα ευρήματα πριν πληκτρολογήσεις `YES`.

**Interactive mode**

```powershell
pwsh -ExecutionPolicy Bypass -File .\driver_check.ps1
```

**Pre-filled search term**

```powershell
pwsh -ExecutionPolicy Bypass -File .\driver_check.ps1 -DriverName nv
pwsh -ExecutionPolicy Bypass -File .\driver_check.ps1 -DriverName MulttKey
```

**Behavior notes**

- Αν δεν τρέχεις ως Administrator, το script κάνει relaunch τον εαυτό του elevated.
- Κενό input στο prompt τερματίζει το πρόγραμμα.
- Μετά από κάθε run, `ENTER` ξεκινά νέα αναζήτηση και `ESC` κλείνει το παράθυρο.
- Αν το broad search δεν βρει candidates, το script κάνει fallback σε `deep exact check` για να πιάσει leftovers τύπου `service gone / sys gone / oemXX.inf still present`.
- Αν ένα exact runtime service query πέσει πάνω σε broken/protected system entry, το script δείχνει concise warning και συνεχίζει με registry/package/file/`PnP` evidence αντί να πετάξει raw PowerShell error με line number.
- Αν δεν υπάρχει πια exact live evidence αλλά το `setupapi.dev.log` δείχνει linked components από το ίδιο install window, το script τα εμφανίζει ως follow-up hints και ΟΧΙ ως auto-delete targets.
- Αν υπάρχουν linked components με current exact live evidence, το script ρωτά πλέον αν θέλεις cleanup μόνο για τον primary driver, για όλο το linked set, ή για επιλεγμένα linked components.
- Αν μετά το cleanup μείνουν `Remaining linked targets`, μπορείς να συνεχίσεις από το ίδιο run και να καθαρίσεις όλα ή επιλεγμένα leftovers χωρίς να ξαναξεκινήσεις το script από την αρχή.

| Parameter     | Type     | Default | Description                                                                   |
| ------------- | -------- | ------- | ----------------------------------------------------------------------------- |
| `-DriverName` | `string` | empty   | Προγεμίζει τον αρχικό όρο αναζήτησης για να μπεις κατευθείαν στο search flow. |

### Τι Ακριβώς Ελέγχει

| Source | Method | Purpose |
|--------|--------|---------|
| Runtime service | `Get-Service -Name <exact>` | Βλέπει αν υπάρχει active/installed service με exact name, αλλά πλέον εμφανίζει safe warning αν το system service query είναι degraded. |
| Service registry | `HKLM:\SYSTEM\CurrentControlSet\Services` | Πιάνει orphan service keys και `ImagePath` leftovers ακόμα κι όταν το `Get-Service` δεν δείχνει κάτι χρήσιμο. |
| Driver file | `C:\Windows\System32\drivers\<name>.sys` | Επιβεβαιώνει αν υπάρχει το φυσικό `.sys` αρχείο. |
| Loaded driver list | `driverquery /v` | Δείχνει αν το module φαίνεται φορτωμένο στα Windows. |
| Driver Store | `pnputil /enum-drivers` | Εντοπίζει σχετικά `oemXX.inf` entries για cleanup. |
| PnP evidence | `Get-PnpDevice -PresentOnly:$false` | Πιάνει device leftovers / instance IDs για remove step. |
| Additional Windows files | `System32\drivers`, `INF`, `DriverStore\FileRepository` | Δείχνει extra file evidence στα βασικά Windows paths. |
| SetupAPI linkage hints | `C:\Windows\INF\setupapi.dev.log` | Αν το exact driver evidence έχει ήδη φύγει, βοηθά να φανεί ποια related components εμφανίστηκαν στο ίδιο install window. |

<a id="save-driver-snapshot"></a>

## 📸 Save Driver Snapshot

> Focused baseline/after snapshot tool για driver install investigations, χωρίς full-disk noise.

### Τι Κρατάει

- `bcdedit /enum all`
- `pnputil /enum-drivers`
- parsed driver packages σε JSON
- `Get-PnpDevice`
- `HKLM\SYSTEM\CurrentControlSet\Services`
- machine certificate stores `Root` και `TrustedPublisher`
- focused file hits σε `C:\Windows\System32\drivers`, `C:\Windows\INF`, `C:\Windows\System32\DriverStore\FileRepository`
- `C:\Windows\INF\setupapi.dev.log` metadata και tail

### Usage

```powershell
pwsh -ExecutionPolicy Bypass -File .\Save-DriverSnapshot.ps1 -CaseName HaspTest -Stage BeforeInstall
pwsh -ExecutionPolicy Bypass -File .\Save-DriverSnapshot.ps1 -CaseName HaspTest -Stage AfterInstall
pwsh -ExecutionPolicy Bypass -File .\Save-DriverSnapshot.ps1 -Name CustomLabel -FocusTerm MulttKey,hasp
```

| Parameter     | Type       | Default            | Description                                                                               |
| ------------- | ---------- | ------------------ | ----------------------------------------------------------------------------------------- |
| `-Name`       | `string`   | auto               | Explicit label για το snapshot folder. Αν δοθεί, έχει προτεραιότητα από `CaseName/Stage`. |
| `-CaseName`   | `string`   | empty              | Group label για ένα συγκεκριμένο investigation/test cycle.                                |
| `-Stage`      | `string`   | empty              | Stage label όπως `BeforeInstall`, `AfterInstall`, `AfterRemove`.                          |
| `-OutputRoot` | `string`   | `.\snapshots`      | Root folder όπου αποθηκεύονται τα snapshots.                                              |
| `-FocusTerm`  | `string[]` | `MulttKey`, `hasp` | Terms για focused file and service evidence search.                                       |

<a id="compare-driver-snapshots"></a>

## 🔍 Compare Driver Snapshots

> Δείχνει γρήγορα τι άλλαξε μεταξύ δύο snapshots ώστε να ξέρεις τι εγκαταστάθηκε ή τι έμεινε πίσω μετά από cleanup.

### Usage

```powershell
pwsh -ExecutionPolicy Bypass -File .\Compare-DriverSnapshots.ps1 `
  -BeforePath .\snapshots\20260318-220000-BeforeInstall `
  -AfterPath .\snapshots\20260318-221500-AfterInstall
```

### Τι Συγκρίνει

- driver packages
- services
- PnP devices
- machine certificates
- focused files
- tracked `BCD` lines όπως `testsigning`, `loadoptions`, `debug`, `default`, `displayorder`
- `setupapi.dev.log` size/time changes

### Compare Notes

- αγνοεί γνωστό Hyper-V / remote-session noise στα `PnP` results
- κρύβει benign `BCD` noise όπως explicit `testsigning No`
- στα certificates δείχνει thumbprints και tags όπως `PUBLISHER`, `LINKED`, `REVIEW` για πιο ασφαλές manual review
- `LINKED` σημαίνει ότι το ίδιο thumbprint εμφανίστηκε και σε `TrustedPublisher` change, άρα το `ROOT` εύρημα είναι πιο άμεσα συνδεδεμένο με το install flow

<a id="cleanup-from-snapshots"></a>

## 🧹 Cleanup From Snapshots

> Snapshot-driven cleanup workflow για cases όπου ένα installer βάζει drivers/services/packages και το bundled uninstall αφήνει leftovers.

### Τι Κάνει

- διαβάζει `Before` και `AfterInstall` snapshots
- βρίσκει τι προστέθηκε
- φιλτράρει γνωστό remote-session noise
- χτίζει step-by-step cleanup plan
- ξεχωρίζει στο summary το `snapshot evidence` από τα `pending actions now`
- δείχνει τι είναι `Pending` και τι είναι ήδη gone
- εκτελεί κάθε step μόνο μετά από δική σου επιβεβαίωση
- ξαναελέγχει runtime state σε ευαίσθητα steps, ώστε ένα file που έφυγε ήδη από package cleanup να μη μετρηθεί ως false failure
- αφήνει τα `DriverStore` / `INF` file artifacts στο package cleanup του `pnputil` αντί για άμεσο raw file deletion

### Usage

**Audit only**

```powershell
pwsh -ExecutionPolicy Bypass -File .\Invoke-DriverCleanupFromSnapshots.ps1 `
  -BeforePath .\snapshots\20260318-220000-HaspTest-BeforeInstall `
  -AfterPath .\snapshots\20260318-221500-HaspTest-AfterInstall `
  -AuditOnly
```

**Step-by-step cleanup**

```powershell
pwsh -ExecutionPolicy Bypass -File .\Invoke-DriverCleanupFromSnapshots.ps1 `
  -BeforePath .\snapshots\20260318-220000-HaspTest-BeforeInstall `
  -AfterPath .\snapshots\20260318-221500-HaspTest-AfterInstall
```

**Publisher certificate cleanup**

```powershell
pwsh -ExecutionPolicy Bypass -File .\Invoke-DriverCleanupFromSnapshots.ps1 `
  -BeforePath .\snapshots\20260318-220000-HaspTest-BeforeInstall `
  -AfterPath .\snapshots\20260318-221500-HaspTest-AfterInstall `
  -IncludeCertificates
```

**Advanced root certificate cleanup**

```powershell
pwsh -ExecutionPolicy Bypass -File .\Invoke-DriverCleanupFromSnapshots.ps1 `
  -BeforePath .\snapshots\20260318-220000-HaspTest-BeforeInstall `
  -AfterPath .\snapshots\20260318-221500-HaspTest-AfterInstall `
  -IncludeCertificates `
  -IncludeRootCertificates
```

| Parameter                  | Type     | Default  | Description                                                                                                     |
| -------------------------- | -------- | -------- | --------------------------------------------------------------------------------------------------------------- |
| `-BeforePath`              | `string` | required | Baseline snapshot path.                                                                                         |
| `-AfterPath`               | `string` | required | Snapshot path μετά το install.                                                                                  |
| `-AuditOnly`               | `switch` | off      | Δείχνει findings και plan χωρίς να εκτελέσει cleanup.                                                           |
| `-IncludeCertificates`     | `switch` | off      | Προσθέτει certificate cleanup μόνο για `TrustedPublisher` certs.                                                |
| `-IncludeRootCertificates` | `switch` | off      | Επιτρέπει auto-cleanup actions και για matching `ROOT` certs. Χρησιμοποίησέ το μόνο μετά από προσεκτικό review. |
| `-AssumeYes`               | `switch` | off      | Παρακάμπτει τα per-step prompts. Χρήσιμο μόνο όταν έχεις ήδη επαληθεύσει το plan.                               |

💡 Όταν χρησιμοποιείς `-IncludeCertificates`, το default plan κρατά πιο συντηρητική στάση:

- auto-cleanup actions μόνο για `TrustedPublisher` certs
- `ROOT` additions παραμένουν `review-only` μέχρι να δώσεις και `-IncludeRootCertificates`
- το ίδιο thumbprint μπορεί να εμφανιστεί και στο `TrustedPublisher` snapshot diff / cleanup plan και ως `ROOT` review item, γιατί τα stores είναι ξεχωριστά
- στο `Root Certificate Review`, το tag `LINKED` σημαίνει cross-store overlap με `TrustedPublisher` στο snapshot diff, ενώ το `ROOT-ONLY` σημαίνει ότι το diff έδειξε μόνο `ROOT` addition

## 📦 Installation

### Quick Setup

```powershell
# Clone
git clone https://github.com/joty79/drivercheck.git
Set-Location .\drivercheck

# Run the menu workbench
pwsh -ExecutionPolicy Bypass -File .\DriverCheckWorkbench.ps1

# Or run the tools directly
pwsh -ExecutionPolicy Bypass -File .\driver_check.ps1
pwsh -ExecutionPolicy Bypass -File .\Save-DriverSnapshot.ps1 -CaseName Demo -Stage BeforeInstall
pwsh -ExecutionPolicy Bypass -File .\Compare-DriverSnapshots.ps1 -BeforePath .\snapshots\<before> -AfterPath .\snapshots\<after>
pwsh -ExecutionPolicy Bypass -File .\Invoke-DriverCleanupFromSnapshots.ps1 -BeforePath .\snapshots\<before> -AfterPath .\snapshots\<after>

# Remove local copy
Set-Location ..
Remove-Item .\drivercheck -Recurse -Force
```

### Requirements

| Requirement        | Details                                       |
| ------------------ | --------------------------------------------- |
| **OS**             | Windows 10 ή Windows 11                       |
| **Shell**          | PowerShell 5.1 ή PowerShell 7+                |
| **Privileges**     | Administrator rights για verification/cleanup |
| **Built-in tools** | `sc.exe`, `pnputil`, `driverquery`            |

## 📁 Project Structure

```text
drivercheck/
├── .gitignore         # Ignore rules για local Gemini notes/state
├── CHANGELOG.md       # Ιστορικό notable changes
├── Compare-DriverSnapshots.ps1
│   # Σύγκριση before/after snapshots
├── DriverCheckWorkbench.ps1
│   # Menu-driven shell για snapshot timing, compare και cleanup workflow
├── driver_check.ps1   # Κύριο interactive script για driver discovery και cleanup
├── Invoke-DriverCleanupFromSnapshots.ps1
│   # Step-by-step cleanup plan και removal από Before/After snapshots
├── PROJECT_RULES.md   # Μακροχρόνια project memory και guardrails
├── Save-DriverSnapshot.ps1
│   # Focused baseline/after capture για driver investigations
└── README.md          # Τεκμηρίωση του project
```

Το repo είναι intentionally μικρό. Τοπικά ignored artifacts, όπως `gemini chat.txt`, μπορεί να υπάρχουν στο workspace αλλά δεν αποτελούν μέρος του tracked project surface.

## 🧠 Technical Notes

<details>
<summary><b>Γιατί το script κάνει relaunch ως Administrator;</b></summary>

Η ανάγνωση και ειδικά η διαγραφή driver-related resources συχνά αποτυγχάνει χωρίς elevation. Το auto-relaunch κρατά το workflow απλό και αποφεύγει μισά αποτελέσματα από ανεπαρκή δικαιώματα.

</details>

<details>
<summary><b>Γιατί γίνεται broad search και μετά exact selection;</b></summary>

Το broad search βοηθά όταν θυμάσαι μόνο μέρος του ονόματος. Η πραγματική διαγραφή όμως βασίζεται σε **ακριβές όνομα**, ώστε ένα substring match να μη μετατραπεί σε λάθος cleanup στόχο.

</details>

<details>
<summary><b>Γιατί ελέγχονται πολλές πηγές αντί για μία μόνο εντολή;</b></summary>

Ένας driver μπορεί να αφήσει ίχνη σε διαφορετικά layers του συστήματος. Ο συνδυασμός **service check**, **physical file check**, **driverquery** και **Driver Store scan** δίνει πιο καθαρή εικόνα από οποιαδήποτε μεμονωμένη εντολή.

</details>

<details>
<summary><b>Γιατί δεν γίνεται broad full Get-Service enumeration;</b></summary>

Σε μερικά corporate ή partially-cleaned systems, ένα full `Get-Service` scan μπορεί να πετάξει raw errors για broken ή protected services και να μοιάζει με script failure. Το broad discovery βασίζεται πλέον κυρίως στο **service registry inventory**, ενώ τα exact runtime checks συνεχίζουν να γίνονται με safe handling και καθαρό warning όταν το λειτουργικό επιστρέφει προβληματική service κατάσταση.

</details>

<details>
<summary><b>Γιατί να παίρνω snapshots πριν και μετά από install/remove;</b></summary>

Το driver cleanup γίνεται πολύ πιο αξιόπιστο όταν ξέρεις ακριβώς τι πρόσθεσε ένα installer. Το before/after diff αποκαλύπτει νέα `oemXX.inf`, services, devices, certificates και `BCD` changes χωρίς να βασίζεσαι μόνο σε guesswork ή fragile text parsing.

Το timing έχει σημασία: αν αφήσεις πολλή ώρα ανάμεσα στο install και στο `AfterInstall` snapshot, αυξάνει το background noise από Windows activity, `PnP` re-enumeration, cert churn και `SetupAPI` log growth.

</details>

<details>
<summary><b>Γιατί το cleanup script πρέπει να τρέχει μέσα στο target system;</b></summary>

Το snapshot diff μπορεί να αναλυθεί από οποιοδήποτε machine που βλέπει τα αρχεία. Το `current live state` όμως που χρησιμοποιεί το cleanup plan για να δείξει `Pending` ή `Already absent` αφορά ΜΟΝΟ το σύστημα όπου τρέχει το script. Αν τα snapshots προέρχονται από guest VM, το actual cleanup πρέπει να τρέξει μέσα στη guest VM και όχι σε host/shared workspace.

</details>

<details>
<summary><b>Γιατί τα certificates είναι optional cleanup step;</b></summary>

Τα certificate stores είναι πιο ευαίσθητα και μερικές φορές έχουν περισσότερο noise από services/packages/files. Γι' αυτό το certificate removal είναι opt-in μέσω `-IncludeCertificates`, ώστε να προηγείται προσεκτικό review των thumbprints και subjects.

</details>

<details>
<summary><b>Γιατί το script δεν σβήνει απευθείας DriverStore files από default;</b></summary>

Για non-technical και γενική χρήση είναι ασφαλέστερο να αφήνεις πρώτα το `pnputil /delete-driver` να καθαρίσει το package σωστά. Τα `DriverStore` / `INF` file artifacts παραμένουν σημαντικό evidence, αλλά δεν πρέπει να γίνονται raw deletes από default flow αν υπάρχει built-in package removal path.

</details>

<details>
<summary><b>Γιατί υπάρχουν emoji μόνο σε Windows Terminal και ASCII fallback αλλού;</b></summary>

Ορισμένα κλασικά console hosts στα Windows δεν αποδίδουν σωστά color emoji. Το script ανιχνεύει Windows Terminal και αλλιώς πέφτει πίσω σε ASCII icons για να παραμένει αναγνώσιμο παντού.

</details>

---

<p align="center">
  <sub>Built with PowerShell · exact-match safety flow · Windows-native tooling</sub>
</p>
