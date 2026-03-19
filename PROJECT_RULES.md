# Project Rules for drivercheck

This document serves as the long-term memory for the `drivercheck` project.
It strictly adheres to the user-defined formatting and documentation protocols.

## Critical Fixes Log

*   **Date:** 2026-03-18
*   **Problem:** User prompted with exact deletion matching without selection, breaking emoji icons in PWSH, abrupt termination instead of loop, permission denied errors on services.
*   **Root Cause:** Substring matches (`-match`) in the old deletion block caused overly broad deletion scopes. `conhost.exe` lacks native color emoji fallback. Loop structure was missing. `Get-Service` trips on PPL protected services like Windows Defender.
*   **Guardrail:** 
    1. Always use multi-stage searches for string matching (candidates list -> exact name match (`-eq` / `regex ^$Exact$`)). 
    2. Fallback to ASCII characters if `$env:WT_SESSION` is NOT defined. 
    3. Use `While($true)` loop and intercept inputs with `[Environment]::Exit(0)` instead of leaving the user in a blank shell tab.
    4. Attach `-ErrorAction SilentlyContinue` when enumerating system services locally or remotely to avert Access Denied floods.
*   **Files affected:** `driver_check.ps1` (formerly `Manage-Driver.ps1`)

*   **Date:** 2026-03-18
*   **Problem:** Cleanup logic based only on ad-hoc command output and fragile text parsing missed real driver leftovers that were visible in manual checks.
*   **Root Cause:** The workflow did not preserve a focused before/after baseline for driver packages, services, PnP devices, certificates, `BCD`, and `SetupAPI` evidence, so removal logic depended on guesses.
*   **Guardrail:**
    1. Before investigating any installer-driven driver problem, capture a focused baseline snapshot first.
    2. Compare before/after snapshots to identify exact additions before writing cleanup logic.
    3. Prefer structured JSON evidence and targeted diffs over loose text scraping whenever possible.
    4. Treat `C:\Windows\INF\setupapi.dev.log` as a primary forensic source for driver install/remove tracking.
*   **Files affected:** `Save-DriverSnapshot.ps1`, `Compare-DriverSnapshots.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation for both scripts; baseline snapshot capture; same-state snapshot diff test

*   **Date:** 2026-03-18
*   **Problem:** Snapshot analysis and live cleanup state can disagree when snapshot files are stored in a shared workspace but the actual target install lives in a different OS context, such as a guest VM.
*   **Root Cause:** The diff is file-based, but `Pending` / `Already absent` cleanup checks depend on the current live system where the cleanup script is executed.
*   **Guardrail:**
    1. Snapshot diff analysis may run anywhere that can read the snapshot folders.
    2. Any actual cleanup status check or removal action must run inside the same target OS that produced the snapshots.
    3. Prefer `CaseName` + `Stage` snapshot naming so multi-step install/remove investigations remain readable for non-technical review.
    4. Keep certificate removal opt-in unless the thumbprints/subjects were explicitly reviewed.
*   **Files affected:** `Save-DriverSnapshot.ps1`, `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Snapshot naming validation run; audit-only cleanup plan run against real install snapshots; current-state context limitation identified and documented

*   **Date:** 2026-03-18
*   **Problem:** The first snapshot-driven cleanup draft was too aggressive for general/non-technical use because it tried to directly remove `DriverStore` / `INF` file artifacts instead of relying on package removal first.
*   **Root Cause:** Focused file evidence from snapshots was being treated as direct deletion targets even when a safer built-in package removal path already existed.
*   **Guardrail:**
    1. Keep `DriverStore` / `INF` artifacts as evidence-first by default.
    2. Prefer `pnputil /delete-driver ... /uninstall /force` before any manual file removal under `DriverStore`.
    3. Limit direct file deletion in default cleanup flow to concrete leftovers under `C:\Windows\System32\drivers`.
    4. If snapshot paths are inaccessible from the current system, fail with a clear path-access message instead of a raw `Join-Path` style error.
*   **Files affected:** `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; audit-only cleanup plan rerun after DriverStore filter fix

*   **Date:** 2026-03-18
*   **Problem:** The first audit summary mixed historical snapshot additions with current pending removals, which was harder to read for non-technical review.
*   **Root Cause:** The UI reported only "added" totals from snapshot diff without clearly separating what was still present in the live target system.
*   **Guardrail:**
    1. Audit summaries must distinguish between snapshot evidence and current pending actions.
    2. Show pending counts per category (`PnP`, services, packages, files, `BCD`) near the top.
    3. Prefer clearer user-facing summaries even when the underlying logic is already correct.
*   **Files affected:** `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; audit-only summary review against real VM cleanup case

*   **Date:** 2026-03-18
*   **Problem:** A cleanup step could be reported as failed even when the target file had already been removed by an earlier successful package-cleanup action.
*   **Root Cause:** The plan was built from the starting state, but the file-removal action did not re-check runtime existence before executing.
*   **Guardrail:**
    1. For sequential cleanup flows, re-check target existence at execution time for file-removal steps.
    2. If a target file is already gone because of an earlier successful step, report a harmless success/absent state instead of a failure.
    3. Prefer user-facing accuracy over rigidly preserving the original pending label.
*   **Files affected:** `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Real VM cleanup transcript review; parser validation after runtime re-check fix

*   **Date:** 2026-03-18
*   **Problem:** Raw compare output still contained benign Hyper-V / remote-session noise and certificate diffs were too opaque for safe review.
*   **Root Cause:** Snapshot compare was treating all `PnP` and `BCD` changes literally, and certificate sections showed only subjects without stable identifiers or confidence hints.
*   **Guardrail:**
    1. Filter known Hyper-V / remote-session `PnP` noise from compare output.
    2. Suppress benign explicit `BCD` negative-state lines such as `testsigning No` when they only add noise.
    3. Show certificate thumbprints in compare output and add simple `LIKELY` / `REVIEW` tags for safer human review.
    4. Keep certificate auto-cleanup narrower than certificate review output; uncertain root additions stay review-only by default.
*   **Files affected:** `Compare-DriverSnapshots.ps1`, `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; compare rerun against `BeforeInstall -> AfterCleanup` and `AfterInstall -> AfterCleanup`

*   **Date:** 2026-03-19
*   **Problem:** Even the more conservative certificate flow was still too aggressive for non-technical/default use if matching `ROOT` certs were allowed into automatic cleanup together with publisher certs.
*   **Root Cause:** `ROOT` trust store changes are more sensitive than `TrustedPublisher` changes and should not share the same default cleanup gate.
*   **Guardrail:**
    1. `-IncludeCertificates` should mean publisher-certificate cleanup only.
    2. `ROOT` certificate auto-cleanup must require an extra explicit opt-in such as `-IncludeRootCertificates`.
    3. By default, `ROOT` additions stay visible in review output but do not become auto-actions.
*   **Files affected:** `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; local audit-only certificate-mode rerun after root-certificate gate split

*   **Date:** 2026-03-19
*   **Problem:** Certificate audit output could still look confusing when the same thumbprint appeared once as a pending `TrustedPublisher` cleanup action and again as a review-only root certificate.
*   **Root Cause:** The review section did not label the store explicitly and did not explain that `ROOT` and `TrustedPublisher` are separate stores.
*   **Guardrail:**
    1. Certificate review output must label the store explicitly, e.g. `ROOT :: REVIEW`.
    2. If the same thumbprint appears in both `TrustedPublisher` actions and root review items, print an explicit cross-store note instead of relying on the user to infer it.
    3. Prefer slightly redundant wording over ambiguous output in security/trust-store reviews.
*   **Files affected:** `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation after output-text update; VM audit output review showed the ambiguity this rule addresses

*   **Date:** 2026-03-19
*   **Problem:** Even after the cross-store note, root certificate review still lacked a simple triage hint about which entries were directly linked to publisher-store activity and which were root-only findings.
*   **Root Cause:** Review output showed all root items with the same generic `REVIEW` wording, so the operator still had to manually correlate thumbprints across sections.
*   **Guardrail:**
    1. Certificate review output should expose simple intent tags such as `LINKED` and `ROOT-ONLY` when that distinction is knowable from the snapshot diff.
    2. `LINKED` should mean the same thumbprint also appeared in `TrustedPublisher` changes.
    3. `ROOT-ONLY` should mean the diff showed only a root-store addition with no matching publisher thumbprint.
*   **Files affected:** `Compare-DriverSnapshots.ps1`, `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation after tag update; local compare rerun planned against existing snapshots

*   **Date:** 2026-03-19
*   **Problem:** After publisher cert cleanup completed, a root cert that was originally linked to the install flow could be mislabeled as `ROOT-ONLY` in the audit view.
*   **Root Cause:** The review tags were derived from the current pending `TrustedPublisher` action set instead of the original snapshot diff that defines install linkage.
*   **Guardrail:**
    1. `LINKED` / `ROOT-ONLY` review tags must be based on snapshot diff evidence, not only on the current pending cleanup state.
    2. Cleanup progress may change whether an auto-action is still pending, but it must not rewrite the historical linkage implied by the install diff.
*   **Files affected:** `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation after tag-source fix; VM audit output exposed the misclassification after publisher cleanup

*   **Date:** 2026-03-19
*   **Problem:** Snapshot workflow was powerful but still too easy to misuse because users had to remember stage names, timing, and the right script order by themselves.
*   **Root Cause:** The toolkit had the low-level pieces, but no single user-friendly shell that guided non-technical operators through the intended investigation flow.
*   **Guardrail:**
    1. Keep a menu-driven workbench as the primary friendly entry point for snapshot/compare/cleanup workflow.
    2. The UI must actively recommend taking `AfterInstall` / `AfterCleanup` snapshots as soon as possible to reduce noise.
    3. Prefer numbered `Read-Host` menus over raw-key capture so terminal output remains copy-friendly.
    4. Use color-coded numbered actions and small icons when they materially improve readability for non-technical users.
    5. When a menu has many actions, group them into scan-friendly sections and prefer stage-specific icons/colors over one repeated generic icon.
*   **Files affected:** `DriverCheckWorkbench.ps1`, `Save-DriverSnapshot.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation planned for new workbench; static review of timing guidance and menu flow

*   **Date:** 2026-03-19
*   **Problem:** The new workbench could crash immediately when older snapshot folders were present.
*   **Root Cause:** Under `Set-StrictMode`, direct property access like `.CaseName` / `.Stage` fails when older `metadata.json` files do not include those newer fields.
*   **Guardrail:**
    1. Menu/workbench code must treat snapshot metadata as versioned and tolerate missing optional fields.
    2. Use safe property reads for optional metadata fields instead of assuming every historical snapshot has the newest schema.
*   **Files affected:** `DriverCheckWorkbench.ps1`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation after safe metadata reader addition; local snapshot inventory confirmed older folders without `CaseName` / `Stage`

*   **Date:** 2026-03-19
*   **Problem:** The workbench could also fail at startup in redirected or non-interactive hosts.
*   **Root Cause:** `Clear-Host` can throw `CursorPosition / handle is invalid` when the host does not expose a normal interactive console buffer.
*   **Guardrail:**
    1. Menu UI scripts must treat screen clearing as optional.
    2. Wrap `Clear-Host` in a safe helper instead of assuming every PowerShell host supports it.
*   **Files affected:** `DriverCheckWorkbench.ps1`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation planned; local smoke test with piped input exposed the startup failure

*   **Date:** 2026-03-19
*   **Problem:** Menu prompt handling could still fail in redirected or exhausted input streams.
*   **Root Cause:** Direct `.Trim()` calls on `Read-Host` results assume a non-null string, but some hosts/redirected runs can yield `$null`.
*   **Guardrail:**
    1. Menu/UI prompts should normalize `Read-Host` results to strings before trimming.
    2. Empty input should be treated as a normal cancel/exit path, not as an exception.
*   **Files affected:** `DriverCheckWorkbench.ps1`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation planned; local piped-input smoke test exposed the null-trim failure

*   **Date:** 2026-03-19
*   **Problem:** The workbench exit option could appear to fail and redraw the menu.
*   **Root Cause:** `break` inside the inner `switch` did not guarantee exit from the outer `while` loop in the intended way for this menu structure.
*   **Guardrail:**
    1. For top-level menu exit paths, use explicit script exit/return behavior instead of relying on `break` inside nested control structures.
    2. Treat redirected-input smoke tests as useful validation for menu lifecycle, not only for parser/syntax checks.
*   **Files affected:** `DriverCheckWorkbench.ps1`, `CHANGELOG.md`
*   **Validation/tests run:** Local piped-input smoke test exposed the redraw/exit problem

*   **Date:** 2026-03-19
*   **Problem:** Setting a brand-new case name could immediately crash the workbench.
*   **Root Cause:** The recommendation helper assumed the filtered case snapshot list had at least one item and used direct array-property access for `.Stage` under `Set-StrictMode`.
*   **Guardrail:**
    1. Empty filtered snapshot lists must be treated as a normal state for brand-new investigations.
    2. For recommendation logic, enumerate stage values through the pipeline instead of relying on direct property access over possibly empty arrays.
*   **Files affected:** `DriverCheckWorkbench.ps1`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation planned; user repro `Set Case Name -> property 'Stage' cannot be found`

*   **Date:** 2026-03-19
*   **Problem:** The legacy live-state remover could miss real leftovers when the main install had already been partially removed, especially in cases where the `.sys` file and active service were gone but `oemXX.inf`, orphan registry keys, or `PnP` residue still remained.
*   **Root Cause:** The old script relied too heavily on a shallow broad-search pass plus a small set of exact checks (`Get-Service`, `System32\drivers`, `driverquery`, loose `pnputil` text scan), so a missed broad candidate could incorrectly look like “nothing is installed”.
*   **Guardrail:**
    1. For current-state cleanup, a no-hit broad search must fall back to a deep exact check for the user-provided driver name.
    2. Legacy/live-state driver detection should check both runtime services and exact registry service keys under `HKLM:\SYSTEM\CurrentControlSet\Services`.
    3. Prefer robust parsed `pnputil /enum-drivers` package data over loose line scraping.
    4. Include `PnP` device evidence and targeted Windows path evidence so partially removed installs still leave visible traces.
    5. After cleanup, rerun the same exact evidence checks immediately so the operator can see what really remains.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; non-destructive smoke tests with `DefinitelyNoSuchDriver123` and `MulttKey`; runtime false-positive fixes during candidate and `PnP` matching

*   **Date:** 2026-03-19
*   **Problem:** Even after the exact-check improvements, the legacy remover could still say “no live evidence” in cases where the searched driver was gone but other components from the same install stack were still present.
*   **Root Cause:** The cleanup verdict was based only on exact live evidence for the searched token and ignored `SetupAPI` evidence that linked other services/packages to the same install window.
*   **Guardrail:**
    1. Distinguish `no exact evidence` from `linked related evidence remains`.
    2. Use `C:\Windows\INF\setupapi.dev.log` only as evidence for related follow-up hints, not as automatic proof that linked components must be deleted in the same exact-driver run.
    3. If linked related components are shown, label them clearly as evidence-based follow-up checks and not as hardcoded guesses.
    4. Post-cleanup verification should report separately when the exact driver is gone but linked components still deserve manual review.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; non-destructive smoke tests with `DefinitelyNoSuchDriver123` and `MulttKey`; snapshot log review showed `MulttKey`, `akshasp`, `aksusb`, and `akshhl` inside the same `SetupAPI` install window

*   **Date:** 2026-03-19
*   **Problem:** The new linked-components section could become noisy and harder to read because repeated reinstall history produced multiple `oemXX.inf` variants for the same underlying `INF`.
*   **Root Cause:** Related package evidence was shown line-by-line at the published-package level instead of being grouped by original `INF` family.
*   **Guardrail:**
    1. In related-evidence output, prefer grouping package variants by original `INF` name.
    2. Show repeated `oemXX.inf` names as compact context inside one human-readable line rather than as separate near-duplicate entries.
    3. Keep the full evidence logic, but compress the display when the extra detail does not help the operator decide.
*   **Files affected:** `driver_check.ps1`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; non-destructive local smoke test after related-package grouping helper was added

*   **Date:** 2026-03-19
*   **Problem:** Even with linked-component hints, the cleanup flow was still awkward because the operator had to rerun the script manually for each related token.
*   **Root Cause:** The legacy remover exposed linkage evidence but still offered only a single-target deletion prompt for the primary exact driver.
*   **Guardrail:**
    1. If linked components also have current exact live evidence, offer an explicit cleanup-scope choice: exact only, exact plus all linked, or exact plus selected linked components.
    2. Do not auto-delete linked items only because `SetupAPI` mentions them; include them in multi-target cleanup only after exact current evidence is verified for each token.
    3. Show a short cleanup-target summary before the final destructive `YES` confirmation so the operator sees the actual scope of the run.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; non-destructive smoke test with `DefinitelyNoSuchDriver123`; VM validation still needed for the linked multi-target branch

*   **Date:** 2026-03-19
*   **Problem:** The first multi-target cleanup prompt was still confusing because the same numeric labels were used both for the linked candidates and for the cleanup-scope menu.
*   **Root Cause:** The UI showed two different numbered groups on the same screen, which made the intended action harder to scan for non-technical users.
*   **Guardrail:**
    1. Do not reuse the same numeric menu labels for two different meanings in the same screen.
    2. Show linked target overview as bullets first.
    3. Open the numbered selector for selective linked cleanup only as a second step after the user explicitly chooses selective mode.
*   **Files affected:** `driver_check.ps1`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; non-destructive smoke test after two-step scope menu update

*   **Date:** 2026-03-19
*   **Problem:** The new selective linked-cleanup branch could crash with `Argument types do not match` when the user entered a list such as `1,3`.
*   **Root Cause:** The first implementation mixed generic collection handling into an interactive PowerShell path where a simpler array-based selection flow was safer and easier to reason about.
*   **Guardrail:**
    1. Prefer plain PowerShell arrays for small interactive selection lists instead of generic collections.
    2. Keep multi-select parsing simple: parse indexes, normalize, sort unique, and append targets without extra generic wrappers.
    3. Treat selective branches as separate runtime validation targets, not only parser-check targets.
*   **Files affected:** `driver_check.ps1`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; normal no-hit smoke test preserved after selective-branch fix

*   **Date:** 2026-03-19
*   **Problem:** Multi-target cleanup output became noisy after successful deletion because post-check logic recomputed linked hints separately for each cleaned target and could surface unrelated-looking follow-up names.
*   **Root Cause:** Post-cleanup review reused per-target `SetupAPI` linkage instead of summarizing only the linked components that were still live after the whole selected cleanup scope finished.
*   **Guardrail:**
    1. In multi-target cleanup, post-check should verify exact evidence per cleaned target without recomputing extra linked hints for each one.
    2. Any linked follow-up after cleanup should be shown once, as an aggregated “remaining linked live evidence” section.
    3. Filter that aggregated section to tokens that are still live and were NOT already included in the chosen cleanup scope.
*   **Files affected:** `driver_check.ps1`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; non-destructive no-hit smoke test preserved after post-cleanup aggregation fix

*   **Date:** 2026-03-19
*   **Problem:** Even after the aggregated `Remaining linked targets` review, the operator still had to restart the script to clean those leftovers, which broke the all-in-one expectation.
*   **Root Cause:** The post-cleanup stage could report remaining linked live evidence but had no continuation action path attached to that result.
*   **Guardrail:**
    1. If post-cleanup finds `Remaining linked targets`, offer continuation options in the same run.
    2. Support both `clean all remaining` and `select remaining` modes.
    3. Continuation cleanup must show a new target summary and require a fresh explicit `YES` before destructive actions.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; non-destructive no-hit smoke test preserved after continuation-flow addition

*   **Date:** 2026-03-19
*   **Problem:** The cleanup menus were still harder to scan than necessary because all action lines used the same color, and the continuation menu showed a useless `select` option even when only one remaining target existed.
*   **Root Cause:** The menu rendering did not adapt color/choice density to the actual branch size.
*   **Guardrail:**
    1. Use different colors for different cleanup-scope actions when it materially improves scan speed.
    2. If a continuation branch has only one remaining linked target, do not show a redundant selective option.
    3. Prefer fewer choices over symmetrical menus when only one choice is meaningful.
*   **Files affected:** `driver_check.ps1`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; non-destructive no-hit smoke test after menu-color and single-remaining-target simplification

*   **Date:** 2026-03-19
*   **Problem:** Generated investigation artifacts under `snapshots/` and `_snapshotstest/` appeared as untracked repo content and could accidentally end up in pushes.
*   **Root Cause:** The repo had no ignore rules for generated snapshot directories.
*   **Guardrail:**
    1. Ignore generated snapshot artifacts by default.
    2. Keep only scripts/docs tracked; treat captured investigation data as local runtime output unless explicitly curated for sharing.
*   **Files affected:** `.gitignore`, `CHANGELOG.md`
*   **Validation/tests run:** Git status review before push showed the unwanted untracked folders
