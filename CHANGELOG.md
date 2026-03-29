# Changelog

Όλες οι notable αλλαγές του project καταγράφονται εδώ.

## 2026-03-28

### Added

- Το `Save-DriverSnapshot.ps1` αποθηκεύει πλέον και `registry-focus.json` με focused registry hits για τα roots `Services`, `Enum`, `Control\Class` και `Uninstall` (`native` + `WOW6432Node`), φιλτραρισμένα μόνο από τα active `FocusTerm` values.
- Το `Compare-DriverSnapshots.ps1` δείχνει πλέον νέο `Focused Registry` section με ξεχωριστά `KEY` additions/removals και `VALUE` additions/removals/changes, ώστε να φαίνεται καθαρά τι registry residue έβαλε ή άλλαξε ένα install flow.

### Documented

- Το `README.md` ενημερώθηκε ώστε το snapshot/compare workflow να αναφέρει ρητά το νέο focused registry capture και το registry diff output.

## 2026-03-29

### Fixed

- Διορθώθηκε runtime bug στο `Save-DriverSnapshot.ps1`: το νέο focused-registry capture χρησιμοποιούσε `HashSet.ToArray()` μέσα στο `Get-MatchingTerms`, κάτι που έσπαγε σε πραγματικό `PowerShell 7` run με `Method invocation failed`. Πλέον το term set επιστρέφεται με απλό enumerable pipeline και το snapshot μπορεί να συνεχίσει κανονικά.
- Διορθώθηκε runtime bug στο `DriverCheck.ps1` για το `Compare Structured Reports`: missing line continuation στο picker call έκανε το `-InvalidSelectionMessage` να εκτελείται σαν ξεχωριστή εντολή αντί για parameter, οπότε το νέο menu έσκαγε αμέσως μόλις άνοιγε.
- Τα interactive redraw menus του `Save-DriverSnapshot.ps1` και του `DriverCheck.ps1` έγιναν πιο ανθεκτικά σε host/viewport quirks: truncation στο console width και reserved redraw region μειώνουν το duplicated menu stacking που εμφανιζόταν μερικές φορές στο `Snapshot mode` και στα structured report pickers.

### Changed

- Το `Compare-DriverSnapshots.ps1` γράφει πλέον compare-output folder με τρία human-readable artifacts: `full-report.txt`, `differences-only.txt`, `similarities-only.txt`, ώστε να μένει και persisted text view πέρα από το live terminal diff.
- Τα generated compare-output folder names του `Compare-DriverSnapshots.ps1` έγιναν πιο σύντομα και path-safe (`cmp__...__vs__... <timestamp>`), ώστε να μην πλησιάζουν άσκοπα Windows path limits όταν τα snapshot labels είναι ήδη μεγάλα.
- Προστέθηκε το `Compare-StructuredTextReport.ps1` ως lightweight structure-aware helper για report-to-report comparison με `Base` semantics και outputs `missing-vs-base.txt` / `extra-vs-base.txt`.
- Το `DriverCheck.ps1` εκθέτει πλέον και το `Compare Structured Reports` από το main menu, με ίδιο launcher-style picker UX για επιλογή report folders/files κάτω από το `compare-output`.
- Το `Compare Structured Reports` launcher flow έγινε πιο ανθρώπινο: δείχνει semantic compare labels derived από το source report και χρησιμοποιεί κατευθείαν το `differences-only.txt`, χωρίς δεύτερο file picker.
- Το `Compare Structured Reports` flow απέκτησε και in-terminal viewer για `extra-vs-base`, `missing-vs-base` ή `both`, με section-aware pretty rendering αντί για σκέτο άνοιγμα raw txt files.
- Το launcher απλοποιήθηκε: το `Current Case` αφαιρέθηκε από το header και το menu, και οι snapshot/cleanup pickers δεν βασίζονται πλέον σε case-priority UX.
- Το `menu 6` του `DriverCheck.ps1` δεν είναι πλέον redundant `List Snapshots`. Αντικαταστάθηκε με guarded `Delete Snapshot` flow, γιατί τα compare/audit/cleanup pickers ήδη δείχνουν όλο το snapshot inventory όταν το χρειάζεσαι.
- Το main launcher menu του `DriverCheck.ps1` υποστηρίζει πλέον `Up/Down`, `Enter`, number shortcuts και `ESC`, ώστε να μένει γρήγορο ακόμα κι όταν το tool μεγαλώνει.
- Το top-level arrow menu του `DriverCheck.ps1` ζωγραφίζει πλέον in-place αντί να ξανακάνει full header redraw σε κάθε keypress, μειώνοντας αισθητά το terminal blink και τα τυχαία cursor flashes.
- Τα snapshot pickers και το certificate-mode selector του launcher απαιτούν πλέον ρητή επιλογή (`1/2/3...`) ή `ESC`· το blank `Enter` δεν λειτουργεί πια ως implicit cancel στα menu-style prompts.
- Το `Save Snapshot` και το `Live Driver Check` έγιναν πιο οπτικά συνεπή με το launcher: το save flow ανοίγει κάτω από το ίδιο header, ενώ το live tool υποστηρίζει πλέον embedded launcher-style header mode.
- Το embedded `Live Driver Check` δεν σκοτώνει πλέον όλο το launcher όταν ο χρήστης πατήσει `ESC` ή blank `ENTER` στο initial prompt. Στο launcher mode αυτά επιστρέφουν πλέον καθαρά στο main menu.
- Τα interactive menus του `DriverCheck.ps1`, του `DriverCheckWorkbench.ps1`, του `Compare-DriverSnapshots.ps1`, του `Save-DriverSnapshot.ps1`, του `Invoke-DriverCleanupFromSnapshots.ps1` και του `Invoke-DriverLiveCheck.ps1` δέχονται πλέον και πραγματικό `Esc` keypress ως σταθερό cancel/exit path, όχι μόνο blank input, `0` ή το να γράφει ο χρήστης τη λέξη `ESC`.
- Το `Invoke-DriverLiveCheck.ps1` χειρίζεται πλέον consistent `ESC` cancel σε driver prompt, candidate selection, cleanup scope, selective linked cleanup και continuation menus.
- Το repo layout έγινε πιο καθαρό για καθημερινή χρήση: το root κρατά πλέον μόνο το `DriverCheck.ps1` ως μοναδικό user-facing PowerShell entry point, ενώ τα υπόλοιπα engine scripts μεταφέρθηκαν στο `internal\`. Το παλιό `driver_check.ps1` μετονομάστηκε σε `Invoke-DriverLiveCheck.ps1`.
- Το `Compare-DriverSnapshots.ps1` έγινε πιο φιλικό για καθημερινή χρήση: αν δεν δοθούν `-BeforePath` / `-AfterPath`, ανοίγει πλέον numbered snapshot picker από το `snapshots` folder.
- Το `Compare-DriverSnapshots.ps1` δέχεται πλέον και απλά snapshot folder names αντί για full paths, λύνοντάς τα αυτόματα κάτω από το `SnapshotsRoot`.
- Το `Save-DriverSnapshot.ps1` ζητά πλέον interactive `Case Name` και `Stage` όταν λείπουν, ώστε να μειώνονται τα generic unlabeled snapshots.
- Το `Save-DriverSnapshot.ps1` γράφει πλέον human-friendly snapshot folder names όπως `Multi-BeforeInstall 03-29-2026 - 01.45`, με safe collision fallback αντί για άκαμπτο timestamp-prefix naming.
- Το snapshot picker UI έγινε πιο καθαρό: το `Focus` αφαιρέθηκε από τις compact λίστες του launcher/compare γιατί μπέρδευε περισσότερο απ' όσο βοηθούσε στο pre-compare stage.
- Τα compare pickers σε `DriverCheck.ps1` και `Compare-DriverSnapshots.ps1` προτιμούν πλέον chronology-friendly σειρά για baseline selection και δείχνουν καθαρό preview/markers για `Base (Before)` και `Compare (After)` πριν τρέξει το diff.
- Το `Compare-DriverSnapshots.ps1` έγινε πιο άμεσο οπτικά στα diffs: τα `+` additions εμφανίζονται πλέον `Green` και τα `-` removals `Red`.
- Το `Invoke-DriverCleanupFromSnapshots.ps1` έγινε πλέον uninstaller-aware: όταν το snapshot diff δείχνει νέο official uninstall entry, το cleanup plan τον προτείνει πρώτο ως `Installed Application` action πριν από direct residue cleanup.
- Το uninstall-entry handling έγινε πιο έξυπνο: `Installed Applications` entries πλέον ταξινομούνται ως `LIKELY`, `REVIEW`, ή `NOISE`, και μόνο τα `LIKELY` μπαίνουν σε auto-cleanup plan.
- Το `Findings Summary` στο `Invoke-DriverCleanupFromSnapshots.ps1` έγινε πιο scan-friendly: non-zero counts εμφανίζονται πλέον `Green`, ενώ τα `0` μένουν `DarkGray`.
- Το snapshot/compare flow κρατά πλέον enriched `PnP` device details (`InfName`, `Service`, `DriverInfSection`, `MatchingDeviceId`, `DriverKey`, `ClassGuid`, `DriverVersion`, `DriverDate`) ώστε η σύνδεση `device -> driver stack` να φαίνεται ρητά.
- Το `Cleanup Plan` δείχνει πλέον `PnP Device` labels μαζί με `InfName` / `Service` όπου υπάρχουν, για πιο καθαρό linking σε cases όπως virtual buses.
- Το cleanup presentation έγινε πιο guided: προστέθηκε `Recommended Flow` section, grouped phase output, και πιο ρητό wording ότι το `[4] Run Cleanup From Snapshots` μπορεί να τρέξει τον official uninstaller αυτόματα.
- Διορθώθηκε runtime edge case στο `Invoke-DriverCleanupFromSnapshots.ps1`: το `BCD` diff path τυλίγει πλέον ρητά τα inputs σε arrays ώστε empty/null snapshot sides να μην οδηγούν σε `ReferenceObject is null`.
- Το `Invoke-DriverCleanupFromSnapshots.ps1` διαβάζει πλέον και το `registry-focus.json` και μπορεί να χτίσει safe targeted `Registry` cleanup actions για leftovers όπως `HKLM\SYSTEM\CurrentControlSet\Services\EventLog\System\<name>`.
- Το cleanup summary/flow δείχνει πλέον και explicit registry cleanup counts/phase, ώστε `BeforeInstall -> AfterCleanup` residue cases να μη μένουν αόρατα στο `[4] Run Cleanup From Snapshots`.
- Το `driver_check.ps1` απέκτησε πλέον live `Focused Registry Evidence` section, ώστε το `[5] Live Driver Check` να δείχνει current residue από `Services`, `Enum`, `Control\Class` και `Uninstall` roots αντί να μένει μόνο σε service/package/file evidence.
- Το live `PnP` output του `driver_check.ps1` δείχνει πλέον και extra binding/context fields όπως `DriverKey`, `ClassGuid`, `Enumerator`, `Parent`, `DriverVersion` και `DriverDate`, ώστε να κουμπώνει καλύτερα με όσα βλέπουμε στα snapshots και στο Device Manager.
- Διορθώθηκε runtime regression στο νέο live registry path του `driver_check.ps1`: το `FocusedRegistry` evidence πρέπει να μείνει object με `.Keys/.Values` και όχι wrapped array, αλλιώς σκάει στο no-hit path.
- Το live focused-registry matcher του `driver_check.ps1` έγινε πιο συντηρητικό: broad metadata όπως provider/manufacturer/class GUID/parent/enum fields δεν μπαίνουν πλέον στα registry search terms, ώστε το νέο section να μένει high-signal αντί για massive noise.
- Διορθώθηκε και δεύτερο live focused-registry noise pattern στο `driver_check.ps1`: structured identifiers όπως `ROOT\SYSTEM\0001` δεν tokenized πλέον σε generic leafs όπως `0001`, ώστε να μη γεμίζει το output με άσχετα `Control\Class\...\0001` hits.
- Το `DriverQuery` section του `driver_check.ps1` έγινε πιο καθαρό: χρησιμοποιεί πλέον parsed `driverquery /v /fo csv` output και δείχνει compact structured fields αντί για raw wrapped line dump, με wording που ξεχωρίζει `active` από απλό `entry found`.
- Το `Delete Snapshot` flow του launcher κάνει path verification μέσα στο configured `snapshots` root, αλλά το confirm απλοποιήθηκε σε `ENTER = delete / ESC = cancel` αντί για typed `DELETE`.

### Added

- Προστέθηκε νέο `DriverCheck.ps1` ως central launcher / main entry point του repo. Από εκεί μπορείς να τρέξεις `Save Snapshot`, `Compare Snapshots`, `Audit Cleanup From Snapshots`, `Run Cleanup From Snapshots` και `Live Driver Check` χωρίς να θυμάσαι τα επιμέρους script names.
- Το `Save-DriverSnapshot.ps1` αποθηκεύει πλέον και `uninstall-entries.json` με structured machine uninstall entries από `HKLM\...\Uninstall` και `WOW6432Node\...\Uninstall`.
- Το `Compare-DriverSnapshots.ps1` δείχνει πλέον νέο `Installed Applications` section με added/removed/changed uninstall entries και hints από `QuietUninstallString` / `UninstallString`.

## 2026-03-25

### Changed

- Το `driver_check.ps1` κάνει πλέον πιο robust `PnP` verification: ενώνει `Get-PnpDevice` και `Win32_PnPSignedDriver`, κάνει exact matching και πάνω σε alias metadata όπως `DeviceName`, `InfName`, `DriverName`, provider/manufacturer και package names τύπου `oemXX.inf`, και δείχνει αυτά τα στοιχεία στο evidence output για πιο αξιόπιστο troubleshooting.
- Το `driver_check.ps1` εμπλουτίζει πλέον τα matched `PnP` devices και με `Get-PnpDeviceProperty` fields όπως `DriverInfPath`, `MatchingDeviceId`, `Service` και `DriverInfSection`, ώστε να χαρτογραφεί καλύτερα `PnP` residue σε πραγματικό `Driver Store` package και να μη μένει εύκολα σε `PnP-only` cleanup scope.
- Το `driver_check.ps1` προσθέτει πλέον και `SetupAPI` fallback για package correlation όταν ένα live `PnP` residue φαίνεται στο current state αλλά δεν εκθέτει πια άμεσα το `oemXX.inf` μέσω WMI/device properties. Το fallback περιορίζεται μόνο σε packages που υπάρχουν ακόμη στο τρέχον `pnputil /enum-drivers`.
- Διορθώθηκε regression στο exact package matching του `driver_check.ps1`: broad heuristics από `ProviderName` και `SetupAPI` fallback μπορούσαν να τραβήξουν άσχετα current packages και να βαφτίσουν λάθος το target ως `protected`. Το exact cleanup scope ξαναγύρισε σε πιο conservative package correlation και το `SetupAPI` μένει πλέον για linked review hints.
- Το `driver_check.ps1` χειρίζεται πλέον πιο σωστά το `pnputil /remove-device` no-op case: αν το εργαλείο επιστρέψει `The device instance does not exist in the hardware tree`, το script το δείχνει ως `already absent` αντί για misleading warning.
- Το τελικό success message του `driver_check.ps1` δεν λέει πλέον ότι reboot προτείνεται `ΠΑΝΤΑ`. Πλέον το reboot εμφανίζεται ως σύσταση για extra verification ή πριν από reinstall / troubleshooting.

## 2026-03-20

### Changed

- Το post-cleanup continuation flow του `driver_check.ps1` δεν προτείνει πλέον protected/review-only linked leftovers ως cleanup επιλογές. Τέτοια targets εμφανίζονται μόνο ως informational review-only note και εξαιρούνται από το `Remaining linked targets` menu.
- Το option `[2]` στο linked cleanup scope menu του `driver_check.ps1` δείχνει πλέον και warning icon ώστε το `AIO cleanup` path να ξεχωρίζει αμέσως ως πιο επιθετική επιλογή.
- Το linked cleanup scope menu του `driver_check.ps1` έγινε πιο ξεκάθαρο σε dark terminals: το `[2]` δηλώνει πλέον ρητά `AIO cleanup` για primary + όλα τα linked targets, ενώ το `[3]` δείχνει καθαρά ότι είναι selective επιλογή.
- Τα protected-detail colors του `driver_check.ps1` έγιναν πιο ευανάγνωστα σε dark background: οι `Protect` γραμμές φωτίστηκαν και τα `Metadata` hints έγιναν yellow για να ξεχωρίζουν εύκολα από τα υπόλοιπα status lines.

## 2026-03-19

### Changed

- Το protected-target detection του `driver_check.ps1` χρησιμοποιεί πλέον και file version metadata (`Description`, `Product`, `OriginalFilename`, Microsoft copyright hints) για πιο ανθρώπινη αναγνώριση system drivers όπως `WUDFWpdFs` / `WUDFRd`.
- Το protected/system UI path του `driver_check.ps1` έγινε πιο έντονο οπτικά: οι protected linked/system targets εμφανίζονται πλέον με πιο ξεκάθαρο red path και metadata hints αντί να μοιάζουν με απλό yellow caution output.
- Το `driver_check.ps1` προστατεύει πλέον linked και exact Windows/core services από destructive cleanup: known tokens όπως `WUDFWpdFs`, Microsoft-owned Windows binaries και Microsoft-provided packages επισημαίνονται ως `review-only` και μπλοκάρονται από cleanup scope/removal.
- Το linked cleanup flow του `driver_check.ps1` έγινε πιο συντηρητικό: service-only related tokens χωρίς package/file/`PnP` proof μένουν πλέον review-only αντί να προσφέρονται ως linked cleanup targets.
- Το `driver_check.ps1` δεν βασίζεται πλέον σε broad full `Get-Service` enumeration για candidate discovery, ώστε broken/protected service entries να μη βγάζουν raw line-number errors που μοιάζουν με syntax/runtime failure.
- Το exact runtime service check του `driver_check.ps1` έγινε πιο ανθεκτικό: αν ένα συγκεκριμένο service query επιστρέψει system-level error, το script δείχνει concise warning και συνεχίζει με registry/package/file/`PnP` evidence.
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

- Το `Save-DriverSnapshot.ps1` γράφει πλέον live per-section timing feedback κατά το snapshot capture, αποθηκεύει `snapshot-timings.json` μέσα σε κάθε snapshot και δείχνει στο τέλος τα slowest sections για real-host profiling.
- Επιβεβαιώθηκε σε elevated host run ότι το μεγάλο bottleneck του save flow δεν είναι το `focused registry` ή το file hashing path, αλλά το `PnP device snapshot`, που μόνο του κατανάλωσε περίπου `49s` σε real Windows installation.
- Το `Save-DriverSnapshot.ps1` δείχνει πλέον και real `PnP` scan progress μέσα στο βαρύτερο section του save flow, με counts για `Get-PnpDevice` property enrichment και `Win32_PnPSignedDriver` merge αντί για γενικό "working" feeling.
- Το `Save-DriverSnapshot.ps1` υποστηρίζει πλέον `Snapshot mode`: `Quick` για faster καθημερινό save και `Full` για deepest `PnP` enrichment. Σε elevated host test το `Quick` mode έριξε το total save time από περίπου `52s` σε περίπου `6s`.
- Το `Compare Structured Reports` picker αγνοεί πλέον το `compare-output\\structured-text` subtree και κάνει dedupe στα compare reports με semantic identity (`Before` / `After` pair + mode), ώστε παλιά timestamped reruns του ίδιου snapshot combo να μη γεμίζουν το menu 7.
- Το `Delete Snapshot` confirm prompt στο launcher εκτελεί πλέον σωστά τη διαγραφή με `ENTER`, αντί να μένει αδρανές μέσα στο key loop.
- Το `Compare Structured Reports` picker υποστηρίζει πλέον inline διαγραφή του highlighted compare report με `D` ή `Delete`, με `ENTER/ESC` confirmation χωρίς να βγαίνεις από το ίδιο menu flow.
- Το `Compare Structured Reports` flow κάνει πλέον σωστό refresh μετά από delete μέσα στο picker και ξαναδιαβάζει τα compare reports από το disk πριν προχωρήσει, ώστε να μη μένουν mixed screens ή stale deleted paths.
- Το `Save Snapshot` flow χρησιμοποιεί πλέον stable text prompt για το `Snapshot mode` αντί για arrow-redraw menu, επειδή το προηγούμενο redraw pattern αποδείχθηκε host-fragile στο Windows Terminal.

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
