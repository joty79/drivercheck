# Changelog

Όλες οι notable αλλαγές του project καταγράφονται εδώ.

## 2026-03-19

### Changed

- Το `driver_check.ps1` έγινε πολύ πιο αξιόπιστο για already-removed installs με leftovers: αν το broad search δεν βρει candidates, κάνει πλέον `deep exact check` αντί να υποθέτει ότι δεν υπάρχει τίποτα.
- Το legacy current-state cleanup του `driver_check.ps1` ελέγχει πλέον περισσότερες πηγές live evidence: exact service keys στο registry, robust `pnputil` package parsing, `PnP` device evidence, extra Windows file evidence, και post-cleanup recheck.
- Προστέθηκε το `DriverCheckWorkbench.ps1` ως menu-driven shell για snapshots, compare και cleanup από ένα σημείο, με explicit timing guidance για `BeforeInstall`, `AfterInstall` και `AfterCleanup`.
- Το `DriverCheckWorkbench.ps1` έγινε πιο ευανάγνωστο οπτικά: color-coded numbered actions, icons, και πιο καθαρό status/header block για non-technical χρήση.
- Το menu του `DriverCheckWorkbench.ps1` έγινε πιο “scan-friendly”: grouped sections (`Setup`, `Snapshot Flow`, `Review And Diff`, `Cleanup Tools`) και stage-specific icons για να ξεχωρίζουν καλύτερα οι numbered επιλογές.
- Το `Save-DriverSnapshot.ps1` δίνει πλέον stage-specific recommendation αμέσως μετά το save, ώστε να σε σπρώχνει να παίρνεις τα επόμενα snapshots πιο γρήγορα και με λιγότερο noise.
- Διορθώθηκε compatibility bug στο `DriverCheckWorkbench.ps1`: παλιότερα snapshot folders χωρίς `CaseName` / `Stage` fields φορτώνονται πλέον κανονικά αντί να σπάνε το menu με property error.
- Διορθώθηκε startup bug στο `DriverCheckWorkbench.ps1`: το `Clear-Host` γίνεται πλέον safe no-op σε redirected/non-interactive hosts που έδιναν `CursorPosition / handle is invalid`.
- Το `DriverCheckWorkbench.ps1` έγινε πιο ανθεκτικό και σε exhausted/redirected input streams: τα menu prompts χειρίζονται πλέον safe κενό/null input χωρίς `.Trim()` crash.
- Το `[0] Exit` του `DriverCheckWorkbench.ps1` βγαίνει πλέον καθαρά από όλο το script και όχι μόνο από το εσωτερικό `switch`, ώστε να μην κάνει accidental δεύτερο render του menu.
- Διορθώθηκε `Case Name` bug στο `DriverCheckWorkbench.ps1`: όταν ο χρήστης διαλέγει νέο case χωρίς existing snapshots, το recommendation flow δεν σπάει πια στο empty-stage lookup.
- Το certificate audit/cleanup output έγινε πιο καθαρό: το review section δείχνει ρητά `ROOT :: REVIEW`, και όταν ίδιο thumbprint εμφανίζεται σε `TrustedPublisher` action και `ROOT` review το script το εξηγεί ως expected cross-store case αντί να μοιάζει με duplicate bug.
- Το certificate triage έγινε πιο κατανοητό: το compare χρησιμοποιεί πλέον tags όπως `PUBLISHER` και `LINKED`, ενώ το cleanup audit ξεχωρίζει τα review-only root certs σε `LINKED` και `ROOT-ONLY`.
- Διορθώθηκε cert-tagging bug στο cleanup audit: τα `LINKED` / `ROOT-ONLY` tags βασίζονται πλέον στο snapshot diff και όχι μόνο στο current pending `TrustedPublisher` state μετά από cleanup.
- Το cross-store certificate note έγινε πιο ακριβές: αναφέρεται πλέον σε `snapshot diff / cleanup plan` αντί να ακούγεται σαν να υπάρχει ακόμα pending publisher action.
- Το `driver_check.ps1` δείχνει πλέον `SetupAPI`-linked related components ως follow-up hints όταν δεν υπάρχει πια exact live evidence για το searched driver, ώστε να μην παρουσιάζει το σύστημα ως “καθαρό” ενώ μπορεί να έχουν μείνει linked leftovers από το ίδιο install window.
- Το linked related-components output του `driver_check.ps1` έγινε πιο καθαρό: πολλαπλά historical `oemXX.inf` variants του ίδιου `INF` συμπτύσσονται πλέον σε μία πιο ανθρώπινη γραμμή αντί για spam από σχεδόν ίδιες package entries.
- Το `driver_check.ps1` έγινε πιο handy για real cleanup: όταν υπάρχουν `SetupAPI`-linked components με current exact live evidence, ρωτά πλέον αν θέλεις `exact only`, `exact + all linked`, ή `exact + selected linked`, αντί να σε αναγκάζει να τα τρέχεις ένα-ένα.
- Το linked cleanup scope menu του `driver_check.ps1` έγινε πιο καθαρό: τα linked current targets εμφανίζονται πρώτα ως bullets, και το numbered selector για selective cleanup ανοίγει μόνο στο δεύτερο βήμα ώστε να μην υπάρχουν δύο διαφορετικά `[1][2][3]` sets στο ίδιο screen.
- Διορθώθηκε runtime bug στο selective linked cleanup branch του `driver_check.ps1`: το `1,3` style selection δεν χρησιμοποιεί πια generic collection handling που μπορούσε να πετάξει `Argument types do not match`, και βασίζεται πλέον σε απλό PowerShell array flow.
- Το `POST-CLEANUP CHECK` του `driver_check.ps1` έγινε πιο καθαρό σε multi-target runs: δεν ξαναχτίζει noisy linked hints για κάθε cleaned target, αλλά δείχνει μία aggregated λίστα μόνο με τα linked leftovers που έχουν ΑΚΟΜΑ current live evidence εκτός του current cleanup scope.
- Το `driver_check.ps1` χειρίζεται πλέον και το `Remaining linked targets` stage ως πραγματικό continuation flow: μπορείς να συνεχίσεις από το ίδιο run με `clean all remaining` ή `select remaining`, με νέο summary και νέο explicit `YES`.
- Τα cleanup menus του `driver_check.ps1` έγιναν πιο readable: τα main scope options έχουν πλέον διαφορετικά colors ανά γραμμή, και όταν υπάρχει μόνο ένα `Remaining linked target` το continuation menu κρύβει το άχρηστο `select` option και δείχνει μόνο `clean now` ή `finish`.
- Το repo αγνοεί πλέον τα generated `snapshots/` και `_snapshotstest/` folders μέσω `.gitignore`, ώστε τα investigation artifacts να μη μπαίνουν κατά λάθος σε commits/pushes.

## 2026-03-18

### Added

- Προστέθηκε πλήρες `README.md` με usage examples, safety notes, requirements, project structure και technical notes.
- Προστέθηκε `CHANGELOG.md` για σταθερό release/documentation history.
- Προστέθηκε το `Save-DriverSnapshot.ps1` για focused before/after capture σε `BCD`, driver packages, `PnP` devices, services, certs, files και `SetupAPI` evidence.
- Προστέθηκε το `Compare-DriverSnapshots.ps1` για diff μεταξύ snapshots με συνοπτικό report αλλαγών.
- Προστέθηκε το `Invoke-DriverCleanupFromSnapshots.ps1` για step-by-step cleanup plan και removal βασισμένο σε `Before/After` snapshots.
- Προστέθηκαν `CaseName` / `Stage` labels στο `Save-DriverSnapshot.ps1` για πιο καθαρό snapshot naming.
- Το cleanup plan έγινε πιο ασφαλές: direct file deletions περιορίστηκαν στα πραγματικά `System32\drivers` leftovers, ενώ `DriverStore` / `INF` artifacts μένουν evidence-first και αφήνονται πρώτα στο `pnputil`.
- Το audit summary έγινε πιο ανθρώπινο: ξεχωρίζει πλέον τι βρήκε το snapshot diff από το τι είναι πραγματικά `Pending` στο current system.
- Το file cleanup step έγινε πιο ανθεκτικό: αν το file έχει ήδη φύγει από προηγούμενο package cleanup step, αντιμετωπίζεται ως harmless success και όχι ως failure.
- Το compare output έγινε πιο καθαρό: αγνοεί known Hyper-V / remote-session `PnP` noise, κρύβει benign `BCD` lines όπως explicit `No/off`, και δείχνει certificate thumbprints με `LIKELY` / `REVIEW` tags.
- Το certificate cleanup path έγινε πιο συντηρητικό: `-IncludeCertificates` στο cleanup προτείνει auto-removal μόνο για πιο likely relevant certs και κρατά τα υπόλοιπα root additions σε review-only mode.
- Το certificate cleanup έγινε ακόμα πιο ασφαλές: by default το `-IncludeCertificates` στο cleanup αγγίζει μόνο `TrustedPublisher`, ενώ τα `ROOT` certs χρειάζονται ξεχωριστό `-IncludeRootCertificates`.

### Documented

- Τεκμηριώθηκε το exact-match deletion flow μετά από broad candidate search.
- Τεκμηριώθηκε το auto-elevation behavior και η multi-source verification λογική.
- Τεκμηριώθηκε το `ENTER` / `ESC` restart-exit loop και το ASCII fallback εκτός Windows Terminal.
- Τεκμηριώθηκε το snapshot-first workflow για driver install investigation πριν από cleanup logic.
- Τεκμηριώθηκε ότι snapshot diff analysis μπορεί να γίνει οπουδήποτε, αλλά live cleanup status και actual removal πρέπει να τρέχουν μέσα στο target system που παρήγαγε τα snapshots.
- Τεκμηριώθηκε ότι inaccessible snapshot paths πρέπει να δίνουν καθαρό user-facing error και όχι ακατέργαστο PowerShell path failure.
