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

| # | Tool | Description |
|:-:|------|-------------|
| 🛠️ | **[Driver Check](#driver-check)** | Κάνει broad search για drivers και προχωρά σε ακριβή, επιβεβαιωμένη διαγραφή μόνο μετά από explicit `YES`. |

<a id="driver-check"></a>
## 🛠️ Driver Check

> Ένα single-script workflow για να δεις αν ένας driver υπάρχει ακόμα και να τον καθαρίσεις από τα βασικά σημεία του συστήματος.

### Το Πρόβλημα

- Ένας προβληματικός driver μπορεί να αφήνει ίχνη ως service, `.sys` αρχείο, loaded module ή Driver Store entry.
- Η μερική διαγραφή συχνά αφήνει leftovers που μπλοκάρουν reinstall ή troubleshooting.
- Το απλό substring match είναι επικίνδυνο όταν πολλά drivers μοιάζουν μεταξύ τους.

### Η Λύση

Το script ξεκινά με ευρύ search για candidates, αλλά πριν από κάθε καταστροφική ενέργεια σε αναγκάζει να επιλέξεις ακριβές όνομα driver. Μετά κάνει verification σε πολλαπλές πηγές και προχωρά σε cleanup μόνο αν γράψεις ακριβώς `YES`.

```text
Search term
   |
   v
Candidate discovery
   |-- Get-Service
   |-- C:\Windows\System32\drivers\*.sys
   |-- pnputil /enum-drivers
   v
Exact driver selection
   |
   v
Verification
   |-- Service check
   |-- Exact .sys file check
   |-- driverquery /v
   |-- Driver Store mapping
   v
Typed confirmation: YES
   |
   v
Cleanup
   |-- sc.exe delete
   |-- pnputil /delete-driver /uninstall /force
   |-- Remove-Item <driver>.sys
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

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-DriverName` | `string` | empty | Προγεμίζει τον αρχικό όρο αναζήτησης για να μπεις κατευθείαν στο search flow. |

### Τι Ακριβώς Ελέγχει

| Source | Method | Purpose |
|--------|--------|---------|
| Service registry | `Get-Service` | Βρίσκει service entries που ταιριάζουν με τον driver. |
| Driver file | `C:\Windows\System32\drivers\<name>.sys` | Επιβεβαιώνει αν υπάρχει το φυσικό `.sys` αρχείο. |
| Loaded driver list | `driverquery /v` | Δείχνει αν το module φαίνεται φορτωμένο στα Windows. |
| Driver Store | `pnputil /enum-drivers` | Εντοπίζει σχετικά `oemXX.inf` entries για cleanup. |

## 📦 Installation

### Quick Setup

```powershell
# Clone
git clone https://github.com/joty79/drivercheck.git
Set-Location .\drivercheck

# Run
pwsh -ExecutionPolicy Bypass -File .\driver_check.ps1

# Remove local copy
Set-Location ..
Remove-Item .\drivercheck -Recurse -Force
```

### Requirements

| Requirement | Details |
|-------------|---------|
| **OS** | Windows 10 ή Windows 11 |
| **Shell** | PowerShell 5.1 ή PowerShell 7+ |
| **Privileges** | Administrator rights για verification/cleanup |
| **Built-in tools** | `sc.exe`, `pnputil`, `driverquery` |

## 📁 Project Structure

```text
drivercheck/
├── .gitignore         # Ignore rules για local Gemini notes/state
├── CHANGELOG.md       # Ιστορικό notable changes
├── driver_check.ps1   # Κύριο interactive script για driver discovery και cleanup
├── PROJECT_RULES.md   # Μακροχρόνια project memory και guardrails
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
<summary><b>Γιατί υπάρχουν emoji μόνο σε Windows Terminal και ASCII fallback αλλού;</b></summary>

Ορισμένα κλασικά console hosts στα Windows δεν αποδίδουν σωστά color emoji. Το script ανιχνεύει Windows Terminal και αλλιώς πέφτει πίσω σε ASCII icons για να παραμένει αναγνώσιμο παντού.

</details>

---

<p align="center">
  <sub>Built with PowerShell · exact-match safety flow · Windows-native tooling</sub>
</p>
