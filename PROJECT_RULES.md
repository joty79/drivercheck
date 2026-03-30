# Project Rules for drivercheck

This document serves as the long-term memory for the `drivercheck` project.
It strictly adheres to the user-defined formatting and documentation protocols.

## Critical Fixes Log

*   **Date:** 2026-03-29
*   **Problem:** The top-level launcher kept a `List Snapshots` action that added little value because the main compare/audit/cleanup flows already showed the same snapshot inventory, while users still needed a safe way to prune old investigation folders.
*   **Root Cause:** The launcher menu was carrying a passive inventory action instead of a workflow-advancing utility, which made the last menu slot feel redundant.
*   **Guardrail:**
    1. Top-level launcher slots should prefer actions that materially advance the workflow, not passive inventory views that are already covered by other pickers.
    2. If the launcher exposes snapshot deletion, it must be guarded by path verification inside the configured `snapshots` root and a very simple confirm UX (`ENTER = delete`, `ESC = cancel`) instead of heavy typed confirmations.
    3. Never issue recursive snapshot-folder deletion from the launcher without verifying that the resolved target stays under the intended snapshot root and is not the root itself.
*   **Files affected:** `DriverCheck.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation planned for launcher after guarded delete-flow addition

*   **Date:** 2026-03-29
*   **Problem:** Interactive menus across launcher, snapshot flows, cleanup flows, and live driver cleanup did not treat `ESC` consistently, so users could get trapped in numbered menus or rely on blank/`0`-only cancellation.
*   **Root Cause:** Menu/input logic evolved independently in each script and relied on mixed `Read-Host` conventions instead of one stable cancel contract.
*   **Guardrail:**
    1. All interactive drivercheck menus must accept `ESC` as a first-class cancel/exit path, not only blank input or `0`.
    2. `ESC` handling must apply not only to top-level menus but also to pickers, selective lists, certificate-mode prompts, cleanup scope prompts, and continuation menus.
    3. When the host allows console key reads, the real `Esc` keypress must cancel immediately without requiring `Enter`.
    4. When a host does not expose direct key reads, text fallback prompts must still document and accept `ESC`/`ESCAPE`.
*   **Files affected:** `DriverCheck.ps1`, `internal\Compare-DriverSnapshots.ps1`, `internal\DriverCheckWorkbench.ps1`, `internal\Invoke-DriverCleanupFromSnapshots.ps1`, `internal\Invoke-DriverLiveCheck.ps1`, `internal\Save-DriverSnapshot.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation for launcher + internal scripts; elevated smoke run of `internal\Invoke-DriverLiveCheck.ps1 -DriverName 1394ohci`

*   **Date:** 2026-03-29
*   **Problem:** The launcher header/UI carried a `Current Case` concept that confused the user, and menu-style prompts still mixed explicit choices with implicit blank-input cancellation.
*   **Root Cause:** The launcher inherited case-priority helpers from earlier snapshot organization work, but the main daily-use UX no longer needed that extra state.
*   **Guardrail:**
    1. Keep the main launcher header focused on universally useful state only; avoid abstract workflow state like `Current Case` unless it is truly necessary.
    2. In menu-style prompts, prefer explicit numbered choices plus `ESC`; do not overload blank `Enter` as hidden cancel behavior.
    3. Visual style should stay consistent across launcher-driven flows, especially `Save Snapshot` and `Live Driver Check`.
    4. As the launcher grows, prefer arrow-key navigation plus number shortcuts for the top-level menu instead of forcing the user to remember menu numbers.
*   **Files affected:** `DriverCheck.ps1`, `internal\Invoke-DriverLiveCheck.ps1`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; elevated embedded-header smoke run of `internal\Invoke-DriverLiveCheck.ps1 -DriverName 1394ohci -EmbeddedInLauncher`

*   **Date:** 2026-03-29
*   **Problem:** The embedded live tool could still terminate the whole launcher because it kept hard `Exit(0)` behavior for blank/`ESC` paths that were correct only in standalone mode.
*   **Root Cause:** `Invoke-DriverLiveCheck.ps1` was reused inside the launcher, but its exit logic still assumed it owned the whole process.
*   **Guardrail:**
    1. Any tool embedded under `DriverCheck.ps1` must return to the launcher on cancel/blank exit paths instead of terminating the full host process.
    2. Standalone and embedded modes may share logic, but exit behavior must be mode-aware.
*   **Files affected:** `internal\Invoke-DriverLiveCheck.ps1`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; elevated smoke run of `internal\Invoke-DriverLiveCheck.ps1 -DriverName 1394ohci -EmbeddedInLauncher`

*   **Date:** 2026-03-29
*   **Problem:** The first arrow-key launcher menu still blinked because it redrew the whole header and menu on every keypress, and the console cursor could flash unpredictably.
*   **Root Cause:** The menu loop reused the normal header renderer instead of keeping a fixed top area and repainting only the menu block in place.
*   **Guardrail:**
    1. Arrow-key menus should prefer in-place redraw (`SetCursorPosition` + line erase) over full-screen `Clear-Host` redraw on every keypress.
    2. Hide the console cursor while the interactive menu is active, then restore it in `finally`.
*   **Files affected:** `DriverCheck.ps1`, `README.md`, `CHANGELOG.md`
*   **Validation/tests run:** Parser validation; elevated launcher smoke start (interactive timeout expected)

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

*   **Date:** 2026-03-19
*   **Problem:** A broken or protected service entry could leak a raw `Get-Service` error with line numbers during broad candidate discovery, which looked like a script syntax/runtime failure even though the tool should continue investigating leftovers.
*   **Root Cause:** Broad search still depended on full runtime service enumeration, and the user-facing path did not normalize service-query failures into a concise degraded-mode message.
*   **Guardrail:**
    1. Do not depend on broad full `Get-Service` enumeration for candidate discovery on live systems.
    2. Prefer service-registry inventory for broad discovery and use exact runtime service queries only as focused evidence checks.
    3. If a runtime service query returns a system-level error, suppress the raw PowerShell error and replace it with a concise warning that the investigation continued with other evidence sources.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; code review of candidate-discovery and exact-service evidence paths after degraded-query hardening

*   **Date:** 2026-03-19
*   **Problem:** Linked `SetupAPI` evidence could surface real Windows/core services such as `WUDFWpdFs`, and without an explicit protection layer they could look like valid cleanup candidates next to third-party leftovers.
*   **Root Cause:** Linked-component review and cleanup-scope logic treated every live exact token with equal weight and did not distinguish Microsoft/core service evidence from third-party driver residue.
*   **Guardrail:**
    1. Known Windows/core service tokens must stay review-only.
    2. Microsoft-owned Windows binaries and Microsoft-provided driver packages should block destructive cleanup for that target.
    3. Linked service-only evidence without package/file/`PnP` proof should not become automatic linked cleanup scope.
    4. Keep a final destructive-action guard inside the removal function even if earlier UI filtering already skipped the protected target.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; code review of protected-target tagging, linked-scope filtering, and final cleanup block path

*   **Date:** 2026-03-20
*   **Problem:** Even after the protection guard, protected Windows/core services were still harder to recognize quickly in the UI and the explanation relied too much on abstract protection reasons instead of human-friendly file metadata.
*   **Root Cause:** The protection output focused on rule matches (`protected token`, `Microsoft-owned binary`) but did not surface enough familiar file properties like `Description`, `Product`, and `Original filename`, and the color path was still too close to ordinary caution output.
*   **Guardrail:**
    1. For protected Windows/core targets, show recognizable file metadata when available.
    2. Use a stronger visual path for protected/system targets than for ordinary yellow caution output.
    3. Prefer UI clues that help the operator immediately recognize a built-in Windows component before any cleanup decision.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation after metadata-hint and protected-color update; static review against the `WUDFWpdFs` screenshot evidence

*   **Date:** 2026-03-20
*   **Problem:** The linked cleanup scope menu still did not make the `clean all linked` versus `choose linked` decision obvious enough, and some protected-detail colors remained too dim on black terminal backgrounds.
*   **Root Cause:** The menu labels were technically correct but not explicit about `all` versus `select`, and `DarkRed`/neutral metadata colors reduced scan speed in dark themes.
*   **Guardrail:**
    1. In destructive scope menus, label the `all linked` branch explicitly as `AIO` / `ALL linked`.
    2. Label the selective branch explicitly as a choose/include action.
    3. Prefer bright readable warning colors over darker shades for protected-detail output on dark backgrounds.
*   **Files affected:** `driver_check.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation after color/menu text update; static review against the latest dark-background transcript

*   **Date:** 2026-03-20
*   **Problem:** Even after protected-target blocking, the post-cleanup continuation menu could still offer a protected Windows/core linked target such as `WUDFWpdFs` as if it were cleanup-eligible.
*   **Root Cause:** The `Remaining linked targets` branch filtered only by `HasLiveEvidence` and ignored `CanOfferCleanup` / `IsProtected`, so review-only targets leaked into the continuation menu.
*   **Guardrail:**
    1. Post-cleanup continuation menus must offer only cleanup-eligible linked targets.
    2. Protected or otherwise review-only linked leftovers may still be shown as informational notes, but never as continuation cleanup choices.
    3. If only review-only linked leftovers remain, the run should end with an informational review-only summary instead of a cleanup prompt.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation planned after remaining-linked continuation filter fix; user transcript showed the protected-target leak

*   **Date:** 2026-03-25
*   **Problem:** The exact live-evidence scan could still miss real `PnP` leftovers when Device Manager exposed the useful identifier in signed-driver metadata such as `DeviceName`, `InfName` / `oemXX.inf`, or provider/manufacturer fields instead of the narrower `Get-PnpDevice` fields.
*   **Root Cause:** `PnP` matching depended too heavily on `Get-PnpDevice` display fields and exact token checks, so aliases visible through `Win32_PnPSignedDriver` never reached the cleanup verifier.
*   **Guardrail:**
    1. `PnP` evidence for exact-driver verification must merge `Get-PnpDevice` and `Win32_PnPSignedDriver`.
    2. `PnP` matching must consider alias terms from the exact token, matched registry/service metadata, and matched package names including `oemXX.inf`.
    3. When signed-driver metadata contributes the hit, surface `InfName`, `DriverName`, provider/manufacturer, and source in the evidence output so the operator can see why the device matched.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; elevated runtime verification planned with `gsudo`; screenshot evidence showed a Device Manager hit for `Virtual USB MulttKey` while the old `PnP` path reported no match

*   **Date:** 2026-03-25
*   **Problem:** Even after the `PnP` false-negative fix, cleanup scope could still miss the real `Driver Store` package when the exact token appeared only in device metadata while the removable package was exposed as `DEVPKEY_Device_DriverInfPath = oemXX.inf`.
*   **Root Cause:** Exact package matching still centered on `OriginalToken`, so a `PnP` hit without direct package-token alignment could end up as `PnP-only` cleanup even though the same device already exposed the removable `oemXX.inf`.
*   **Guardrail:**
    1. After `PnP` evidence is collected, enrich matched devices with `Get-PnpDeviceProperty` data such as `DriverInfPath`, `MatchingDeviceId`, `Service`, and `DriverInfSection`.
    2. Use those enriched `PnP` aliases to correlate the current exact target with `pnputil /enum-drivers` packages before building cleanup scope.
    3. Prefer showing the correlated `oemXX.inf` in the same evidence run so the operator can remove package + device together.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; VM rerun pending after `PnP`-property correlation patch

*   **Date:** 2026-03-25
*   **Problem:** Some live `PnP` leftovers still surfaced only as a signed-driver device hit with no visible `InfName`, even though Device Manager events clearly showed `oemXX.inf`.
*   **Root Cause:** Current-state WMI / device-property surfaces can omit the package name for phantom or partially removed devices, so package correlation cannot rely only on present `PnP` properties.
*   **Guardrail:**
    1. If `PnP` evidence exists but direct package correlation is still empty, use `SetupAPI` windows anchored on the device instance, matching device ID, service, and INF section as a fallback package-correlation path.
    2. Intersect that fallback only with currently enumerated `pnputil` packages to avoid reporting historical packages that are already gone.
    3. Treat this as correlation help for exact cleanup, not as permission to delete packages absent from current `pnputil` output.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; VM rerun pending after `SetupAPI` package-correlation fallback

*   **Date:** 2026-03-25
*   **Problem:** The new exact package-correlation heuristics became too broad and could pull unrelated current packages into the primary exact target, which in turn caused false `protected` classification and blocked cleanup for an otherwise removable phantom `PnP` residue.
*   **Root Cause:** Matching against generic provider/manufacturer-style metadata plus `SetupAPI` fallback windows allowed adjacent but unrelated packages to be promoted into the exact driver evidence set.
*   **Guardrail:**
    1. Exact cleanup scope must stay conservative: only direct token/INF-name style package evidence may promote a package into the primary exact target.
    2. Do not use `ProviderName`, manufacturer-style metadata, or broad `SetupAPI` windows to auto-attach packages to the exact target.
    3. Keep `SetupAPI` for linked review hints, not for auto-promoting exact `Driver Store` cleanup packages when current package evidence is absent.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; user VM transcript showed false exact package hits (`oem1.inf`, `oem2.inf`) and a bogus `protected` verdict for `multtkey`

*   **Date:** 2026-03-25
*   **Problem:** `pnputil /remove-device` could print a scary failure-style message even when the target phantom device had already disappeared from Device Manager and the post-check was clean.
*   **Root Cause:** The removal path treated `The device instance does not exist in the hardware tree` as a generic warning instead of an `already absent` success-equivalent state.
*   **Guardrail:**
    1. For `PnP` cleanup, treat `device instance does not exist in the hardware tree` as harmless `already absent`.
    2. Prefer user-facing outcome accuracy over raw command pessimism when the post-check confirms no exact live evidence remains.
    3. Reserve yellow failure wording for real unresolved removal problems, not for no-op/already-gone cases.
*   **Files affected:** `driver_check.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; VM transcript showed the device disappearing from Device Manager while `pnputil` still returned the absent-from-hardware-tree message

*   **Date:** 2026-03-25
*   **Problem:** The final success message overstated reboot necessity with `Προτείνεται ΠΑΝΤΑ επανεκκίνηση`, even though the VM cleanup validated clean exact state without reboot being required to complete the removal.
*   **Root Cause:** The UX text used a one-size-fits-all reboot warning instead of distinguishing between `recommended for extra assurance` and `required for completion`.
*   **Guardrail:**
    1. Do not say reboot is always required when post-cleanup verification is already clean.
    2. Phrase reboot as optional-but-recommended for extra verification or before reinstall / troubleshooting.
    3. Keep final success wording aligned with what the script actually verified in that run.
*   **Files affected:** `driver_check.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; Hyper-V checkpoint rerun showed successful `PnP` cleanup and clean post-check before reboot

*   **Date:** 2026-03-28
*   **Problem:** Snapshot compare could still miss high-value install residue because registry evidence outside the service tree was not preserved in the focused baseline.
*   **Root Cause:** The snapshot workflow captured services, packages, files, certs, and `SetupAPI`, but not focused registry changes under `Enum`, `Class`, and `Uninstall` paths that often matter for uninstall forensics.
*   **Guardrail:**
    1. Keep registry capture focused and term-driven; do not introduce broad full-registry dumps into the default snapshot workflow.
    2. Snapshot only high-value uninstall/driver roots such as `Services`, `Enum`, `Control\Class`, and `Uninstall` (`native` + `WOW6432Node`).
    3. Compare output should distinguish `KEY` additions/removals from `VALUE` additions/removals/changes so install residue stays readable for humans.
*   **Files affected:** `Save-DriverSnapshot.ps1`, `Compare-DriverSnapshots.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation for snapshot/compare scripts; synthetic snapshot compare run for focused registry additions and changed values

*   **Date:** 2026-03-29
*   **Problem:** The first live VM run of the new focused-registry snapshot crashed immediately with `Method invocation failed` on `HashSet.ToArray()`.
*   **Root Cause:** A .NET collection method was assumed to be directly callable from the current `PowerShell 7` runtime path, but the `HashSet[string]` instance exposed in script did not support that call shape here.
*   **Guardrail:**
    1. After new collection-based helper logic is added, prefer plain PowerShell enumeration over convenience methods like `.ToArray()` unless the method is known-good in the exact runtime path.
    2. Treat first real VM/host execution as a distinct validation step even after parser validation and synthetic tests pass.
    3. Record real PowerShell runtime incompatibilities immediately in project memory when they surface.
*   **Files affected:** `Save-DriverSnapshot.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Real VM repro from user transcript; parser validation after fix

*   **Date:** 2026-03-29
*   **Problem:** Snapshot compare remained awkward in real use because it expected exact paths even for common repo-local compare runs.
*   **Root Cause:** The script supported only explicit `BeforePath` / `AfterPath` arguments, while the friendlier numbered picker existed only inside the workbench.
*   **Guardrail:**
    1. Standalone snapshot tools should not require absolute paths for common repo-local use.
    2. If a script consumes snapshot folders directly, support at least one friendly path: numbered picker, short folder names, or both.
    3. Keep advanced/manual path support, but do not make it the only everyday UX.
*   **Files affected:** `Compare-DriverSnapshots.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; compare rerun using only snapshot folder names under default `SnapshotsRoot`

*   **Date:** 2026-03-29
*   **Problem:** Even with better pickers, the repo still felt fragmented because normal use required remembering multiple script names and unlabeled snapshot saves quickly made the UI unreadable.
*   **Root Cause:** The repo had useful engine scripts, but lacked one clear main entry point and allowed snapshot capture to proceed too easily without `CaseName` / `Stage` guidance.
*   **Guardrail:**
    1. Keep one clear main launcher script for everyday use, even if engine scripts remain separate underneath.
    2. Snapshot capture should actively prompt for human-readable `CaseName` / `Stage` labels when they are missing.
    3. Engine scripts may stay available for advanced/manual use, but the default UX should optimize for readability over script-name memorization.
*   **Files affected:** `DriverCheck.ps1`, `Save-DriverSnapshot.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation for launcher/save scripts; launcher smoke test planned next

*   **Date:** 2026-03-29
*   **Problem:** Snapshot lists still felt noisy because they surfaced internal `FocusTerm` metadata in the picker before compare results existed.
*   **Root Cause:** UI was exposing capture internals that were useful for forensic metadata but not for everyday snapshot selection.
*   **Guardrail:**
    1. Keep internal capture metadata available, but do not show it by default in compact picker/list UIs unless it directly helps the current choice.
    2. Snapshot selection screens should prioritize human labels (`Case`, `Stage`, time) over internal engine details.
*   **Files affected:** `DriverCheck.ps1`, `Compare-DriverSnapshots.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation after UI output trim; launcher smoke test via `gsudo`

*   **Date:** 2026-03-29
*   **Problem:** Snapshot folders still looked machine-generated and were harder to scan than the human labels the user actually cared about.
*   **Root Cause:** Folder creation always prefixed a raw sortable timestamp (`yyyyMMdd-HHmmss`) ahead of the snapshot label, so even well-labeled `CaseName` / `Stage` snapshots still read like technical artifacts instead of checkpoints.
*   **Guardrail:**
    1. Prefer human-first snapshot folder names for everyday workflows, with `CaseName-Stage MM-dd-yyyy - HH.mm` style formatting when labels are available.
    2. Keep exact timestamps in `metadata.json`; the folder name should optimize for scan/readability, not be the only source of time precision.
    3. Preserve uniqueness with a safe suffix fallback instead of forcing machine-style timestamp prefixes back into the visible folder name.
*   **Files affected:** `Save-DriverSnapshot.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; elevated launcher smoke test; elevated snapshot save rerun pending on next user VM pass

*   **Date:** 2026-03-29
*   **Problem:** Snapshot compare pickers could still nudge the user into awkward choices because the default ordering favored latest-first recency even when selecting the baseline, and the chosen pair was not highlighted clearly before running the diff.
*   **Root Cause:** Picker sorting optimized for general listing rather than compare chronology, and the UI did not surface a clear `Before` / `After` selection state.
*   **Guardrail:**
    1. For compare and cleanup baseline selection, prefer chronology-friendly ordering so earlier snapshots appear first.
    2. Before running compare-style actions, show a clear selected-pair preview with explicit `Base (Before)` and `Compare (After)` labels.
    3. Selection screens should reduce wrong-order mistakes before execution, not rely on the user to infer chronology from timestamps alone.
*   **Files affected:** `DriverCheck.ps1`, `Compare-DriverSnapshots.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; launcher and compare picker smoke tests pending after UI update

*   **Date:** 2026-03-29
*   **Problem:** Snapshot-driven cleanup could delete services/packages/files before trying the software's own uninstaller, which risks breaking the official uninstall path for MSI-backed installs such as HASP tooling.
*   **Root Cause:** The workflow captured uninstall-related registry residue only as focused forensic hits, but did not preserve structured uninstall entries or elevate them into first-class cleanup actions.
*   **Guardrail:**
    1. Preserve structured machine uninstall entries in snapshots as separate evidence, not only as generic registry diff lines.
    2. When a `Before -> After` diff shows a new official uninstall entry, prefer that uninstall action before direct residue cleanup of services/packages/files.
    3. Treat snapshot-driven deletion as leftover cleanup, not as a replacement for a valid official uninstall path when one exists.
    4. Use safe property access when reading uninstall-entry registry values because many entries omit fields like `InstallSource`, `QuietUninstallString`, or `WindowsInstaller`.
*   **Files affected:** `Save-DriverSnapshot.ps1`, `Compare-DriverSnapshots.ps1`, `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; elevated save smoke test; synthetic compare output for uninstall-entry additions; elevated audit-only cleanup plan showing `Installed Application` action

*   **Date:** 2026-03-29
*   **Problem:** Raw uninstall-entry diffs were too noisy because shared Microsoft runtimes and background component churn (for example `EdgeWebView`) appeared next to genuinely relevant vendor runtimes.
*   **Root Cause:** Every uninstall-entry addition was treated as equally important, without any confidence/triage layer based on vendor and product naming.
*   **Guardrail:**
    1. `Installed Applications` output should classify entries as `LIKELY`, `REVIEW`, or `NOISE` instead of presenting them as equal cleanup candidates.
    2. Only `LIKELY` uninstall entries should enter the auto-cleanup plan by default.
    3. Shared runtimes/dependencies such as `Visual C++` should stay `REVIEW` unless stronger install correlation is added later.
    4. Background churn candidates such as `EdgeWebView` should be marked `NOISE`, not promoted into cleanup actions.
*   **Files affected:** `Compare-DriverSnapshots.ps1`, `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; synthetic compare triage test (`Sentinel Runtime`, `Visual C++`, `EdgeWebView`); elevated audit-only cleanup plan showing only `LIKELY` uninstall action

*   **Date:** 2026-03-29
*   **Problem:** The cleanup audit `Findings Summary` was harder to scan quickly because zero and non-zero counts shared the same plain styling.
*   **Root Cause:** Summary lines used uniform `Write-Host` output without a reusable visual rule for value emphasis.
*   **Guardrail:**
    1. In audit/count summaries, non-zero values should stand out positively while zero values should visually fade into the background.
    2. Prefer one reusable helper for summary-count rendering instead of repeating ad-hoc color logic on every line.
    3. Keep live audit interpretation tied to the same target OS that produced the snapshots; do not treat desktop-state audit output as authoritative for VM installs.
*   **Files affected:** `Invoke-DriverCleanupFromSnapshots.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; elevated audit-only smoke run against synthetic zero-count snapshot pair

*   **Date:** 2026-03-29
*   **Problem:** Snapshot compare could still leave uncertainty around whether a problematic `PnP` device was truly tied to the target driver stack, because device entries were preserved only with shallow fields like name/class/status.
*   **Root Cause:** The richer `Device Manager`-style fields already used in `driver_check.ps1` (`INF`, service, matching ID, driver key, provider, version) had not been propagated into the snapshot/compare workflow.
*   **Guardrail:**
    1. `PnP` snapshots should preserve explicit driver-binding fields, not just device identity/status.
    2. For driver uninstall forensics, the most valuable `PnP` links are `InfName`, `Service`, `DriverInfSection`, `MatchingDeviceId`, `DriverKey`, `ClassGuid`, `DriverVersion`, and `DriverDate`.
    3. Compare output should surface these links directly for added devices so the operator does not need to infer the connection from separate sections.
    4. Cleanup plan labels should include `InfName` / `Service` when available so device-removal steps stay visibly tied to the underlying driver stack.
    5. Backward compatibility matters: compare must tolerate older snapshots that do not contain the newer `PnP` fields.
*   **Files affected:** `Save-DriverSnapshot.ps1`, `Compare-DriverSnapshots.ps1`, `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; elevated snapshot save smoke showing enriched `pnp-devices.json`; synthetic compare showing explicit `PnP` detail lines; elevated audit-only cleanup plan showing `PnP Device :: oemX.inf :: service` labeling

*   **Date:** 2026-03-29
*   **Problem:** Compare diffs and cleanup guidance were logically correct but still harder to scan than they needed to be, and a synthetic audit run exposed a null-input `BCD` compare edge case.
*   **Root Cause:** Add/remove lines still used older yellow-toned colors, cleanup actions were shown as one flat list without a clear recommended order, and the `Invoke-DriverCleanupFromSnapshots.ps1` `BCD` diff path passed potentially null arrays straight into `Compare-Object`.
*   **Guardrail:**
    1. In snapshot compare output, prefer stable semantic colors: `+` additions in `Green` and `-` removals in `Red`.
    2. For snapshot-driven cleanup, always surface the recommended removal order explicitly when an official uninstaller exists; do not make the operator infer that `[4]` can launch it automatically.
    3. Group cleanup actions into human-readable phases (`Official Uninstall`, devices, services, packages, files, etc.) instead of one long flat list.
    4. Wrap `Compare-Object` inputs in explicit arrays when either snapshot side may be empty/null, especially for optional evidence like `BCD`.
*   **Files affected:** `Compare-DriverSnapshots.ps1`, `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation for compare/cleanup scripts; elevated synthetic audit-only run after `BCD` null-array fix

*   **Date:** 2026-03-29
*   **Problem:** Even after successful package/service/device cleanup, narrow registry leftovers such as `Services\EventLog\System\hasplms` still remained visible in `BeforeInstall -> AfterCleanup` compare output but could not enter the snapshot-driven cleanup plan.
*   **Root Cause:** `Invoke-DriverCleanupFromSnapshots.ps1` preserved `Focused Registry` only as evidence and ignored it entirely when building cleanup actions.
*   **Guardrail:**
    1. Snapshot-driven cleanup may promote focused-registry evidence into cleanup actions only through narrow safe patterns, not a broad generic registry-delete engine.
    2. Start with high-value low-risk leftovers such as `HKLM\SYSTEM\CurrentControlSet\Services\EventLog\System\<name>`.
    3. Keep all other focused-registry diffs evidence-first until a specific safe cleanup rule is justified and verified.
*   **Files affected:** `Invoke-DriverCleanupFromSnapshots.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; elevated synthetic audit-only smoke run showing pending `Registry` action for a temporary `EventLog\System\CodexSmokeRegistry` key

*   **Date:** 2026-03-29
*   **Problem:** The live `driver_check.ps1` still had weaker registry visibility than the snapshot workflow, even though the snapshot comparisons had already proven that high-value residue often lives in `Enum`, `Class`, `EventLog`, and uninstall roots.
*   **Root Cause:** Live evidence focused mainly on service keys, packages, `PnP`, and files; the richer snapshot-inspired focused-registry view had not been propagated back into the current-state tool.
*   **Guardrail:**
    1. When snapshot investigations reveal stable high-value evidence roots, reflect that learning back into the live current-state tool instead of keeping the two workflows mentally separate.
    2. For live driver forensics, add focused registry evidence before considering broader cleanup expansion.
    3. Preserve structured `FocusedRegistry` data as an object with `.Keys` / `.Values`; do not wrap it in `@()` and accidentally erase the expected shape in no-hit paths.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; elevated no-hit runtime check of `driver_check.ps1 -DriverName DefinitelyNoSuchDriver123`; verified `Focused Registry Evidence` no-hit path after object-shape fix

*   **Date:** 2026-03-29
*   **Problem:** The first live `Focused Registry Evidence` pass in `driver_check.ps1` could explode into unusable output and burn operator attention because it reused too many broad `PnP` / metadata fields as registry search terms.
*   **Root Cause:** Terms such as provider/manufacturer/class GUID/parent/enumerator and other broad `Device Manager` metadata are useful for correlation, but too loose for live registry text matching.
*   **Guardrail:**
    1. Live focused-registry matching must stay narrower than snapshot-style forensic capture.
    2. Prefer exact driver/package/service/device identifiers (`service name`, `oemXX.inf`, `InfName`, `MatchingDeviceId`, `InstanceId`, exact token) over broad metadata fields.
    3. Treat `Device Manager` richness as display/correlation context first, not as permission to widen live registry search aggressively.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; elevated no-hit runtime check after focused-registry term tightening

*   **Date:** 2026-03-29
*   **Problem:** Even after removing broad metadata terms, the live `Focused Registry Evidence` section could still produce large unrelated output for drivers whose `InstanceId` ended in common leaf values such as `ROOT\SYSTEM\0001`.
*   **Root Cause:** `Add-SearchTerm` tokenized structured identifiers and converted `InstanceId` values like `ROOT\SYSTEM\0001` into generic leaf terms like `0001`, which then matched many unrelated `Control\Class\...\0001` and similar registry paths.
*   **Guardrail:**
    1. Structured identifiers such as `InstanceId` must stay literal in live focused-registry matching.
    2. Do not derive fallback leaf tokens from hierarchical IDs when those leafs are too generic to be high-signal.
    3. If a matcher term can plausibly collide with many system paths (`0000`, `0001`, etc.), prefer exact literal evidence over convenience tokenization.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; transcript review of `Administrator PowerShell.txt` isolated the remaining `\0001` collision pattern

*   **Date:** 2026-03-29
*   **Problem:** The live `DriverQuery` section was technically correct but hard to read because it dumped raw wrapped console output from `driverquery /v`.
*   **Root Cause:** The script matched plain text lines from `driverquery /v` and printed them as-is, which breaks badly in narrow terminals and also encouraged wording that implied every match was necessarily `running`.
*   **Guardrail:**
    1. For `DriverQuery` evidence, prefer parsed `driverquery /v /fo csv` output over raw console text.
    2. Show compact structured fields (`Module`, `Display`, `Type`, `StartMode`, `State`, `Status`, `Path`) instead of one long wrapped line.
    3. Do not claim a driver is `loaded/active` unless the parsed `State` actually says `Running`.
*   **Files affected:** `driver_check.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; elevated runtime run of `driver_check.ps1 -DriverName 1394ohci` confirmed structured `DriverQuery` output and correct `Stopped` wording

*   **Date:** 2026-03-29
*   **Problem:** The repo root had grown multiple user-runnable `.ps1` files, which made the project feel less polished than the main launcher and made the intended entry point less obvious.
*   **Root Cause:** Engine scripts accumulated in the root next to the main launcher instead of being grouped behind a single user-facing entry point.
*   **Guardrail:**
    1. Keep only one user-facing PowerShell script in the repo root: `DriverCheck.ps1`.
    2. Move engine/helper scripts under `internal\` so the root stays clean and the main entry point is obvious.
    3. Prefer clearer internal naming for engine scripts, e.g. `Invoke-DriverLiveCheck.ps1` instead of `driver_check.ps1`.
    4. When root/internal layout changes, update launcher references and README examples in the same pass.
*   **Files affected:** `DriverCheck.ps1`, `internal\Invoke-DriverLiveCheck.ps1`, `internal\Save-DriverSnapshot.ps1`, `internal\Compare-DriverSnapshots.ps1`, `internal\Invoke-DriverCleanupFromSnapshots.ps1`, `internal\DriverCheckWorkbench.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Root `.ps1` inventory check; parser validation after path updates; elevated runtime validation of moved live tool via `internal\Invoke-DriverLiveCheck.ps1`

*   **Date:** 2026-03-29
*   **Problem:** `Save-DriverSnapshot.ps1` felt "extremely slow" on a real Windows installation, but the repo had no hard timing data to show where the time was actually going.
*   **Root Cause:** The save flow collected many evidence types in sequence without per-section timing visibility, so the operator could only feel that the snapshot was slow, not identify the actual hotspot.
*   **Guardrail:**
    1. Keep per-section timings in the snapshot save flow and persist them to `snapshot-timings.json`.
    2. Show live section progress while a snapshot is being captured so the operator can see whether the script is still working.
    3. Treat `PnP` enrichment as the primary optimization target before spending time on lighter sections such as certs, `BCD`, or file-write serialization.
    4. Future `Quick Snapshot` work should start by reducing `PnP` snapshot cost, because real host timing showed it dominates the save runtime.
*   **Files affected:** `internal\Save-DriverSnapshot.ps1`, `TODO.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; elevated real-host timing run via `gsudo`; generated `snapshot-timings.json` showed ~`49s` in `Capture PnP device snapshot` and ~`2.4s` in focused registry capture

*   **Date:** 2026-03-29
*   **Problem:** Even after adding timing visibility, the slowest part of snapshot save still felt opaque while it was running because the operator could not tell whether the `PnP` section was actually advancing.
*   **Root Cause:** The save flow reported section start/end times, but the heaviest `PnP` section had no in-flight progress and therefore still looked frozen on real systems.
*   **Guardrail:**
    1. For the heaviest save section, prefer real item-count progress over generic spinner-style output.
    2. `PnP` snapshot progress should expose both expensive phases: `Get-PnpDevice` property enrichment and `Win32_PnPSignedDriver` merge.
    3. Keep the progress implementation lightweight enough that it does not become the new bottleneck; update in batches instead of per-item repaint spam.
*   **Files affected:** `internal\Save-DriverSnapshot.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; elevated real-host snapshot save via `gsudo` after adding `PnP` progress completed successfully

*   **Date:** 2026-03-29
*   **Problem:** After profiling confirmed that `PnP` enrichment dominated snapshot save time, the repo still had no actual fast path for day-to-day use on a real Windows installation.
*   **Root Cause:** The save flow always paid for the deepest `Get-PnpDeviceProperty` enrichment even when the operator only needed a quick before/after snapshot with basic `PnP` identity plus signed-driver/package correlation.
*   **Guardrail:**
    1. `Save-DriverSnapshot.ps1` should support two explicit modes: `Quick` and `Full`.
    2. `Quick` mode may skip expensive per-device `Get-PnpDeviceProperty` enrichment, but it must keep the same output shape and still preserve basic `PnP` identity plus `Win32_PnPSignedDriver` correlation.
    3. `Full` mode remains the source of truth for deepest `PnP` forensic detail.
    4. Interactive save flow should let the operator choose mode explicitly instead of silently changing behavior.
*   **Files affected:** `internal\Save-DriverSnapshot.ps1`, `README.md`, `TODO.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; elevated `Full` timing run (~`52s` total, ~`49s` `PnP`); elevated `Quick` timing run (~`6.36s` total, ~`0.83s` `PnP`); metadata and `pnp-devices.json` structure review for `Quick` output

*   **Date:** 2026-03-29
*   **Problem:** The live terminal compare was useful, but humans still lacked persisted compare artifacts that cleanly separated "everything", "differences only", and "similarities only" for later review.
*   **Root Cause:** `Compare-DriverSnapshots.ps1` only rendered to the console and did not preserve a report set on disk.
*   **Guardrail:**
    1. Every snapshot compare should write a dedicated compare-output folder, not just print to the terminal.
    2. Keep three human-readable text artifacts per compare: `full-report.txt`, `differences-only.txt`, and `similarities-only.txt`.
    3. Report headers should include both snapshot paths and the `SnapshotMode` (`Quick` / `Full`) of each side so later review can interpret missing deep fields correctly.
    4. `full-report.txt` must remain a true single report, not a duplicated-header concatenation artifact.
*   **Files affected:** `internal\Compare-DriverSnapshots.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; non-admin compare run against `Multi-BeforeInstall 03-29-2026 - 06.20` vs `Multi-fast-AfterInstall 03-29-2026 - 19.35`; verified generated compare-output folder and the three report files

*   **Date:** 2026-03-29
*   **Problem:** For `Full` vs `Quick` debugging, a plain text diff between two generated report files was too noisy and did not preserve the section structure that makes driver evidence readable.
*   **Root Cause:** Generic diff tools do not know which lines are section headers, which lines are top-level item blocks, and which indented lines belong to those items.
*   **Guardrail:**
    1. For generated repo reports, prefer a lightweight structure-aware compare helper over raw line diff when section readability matters.
    2. Use explicit `Base` semantics and name the output files by meaning (`missing-vs-base`, `extra-vs-base`) instead of left/right editor position.
    3. Preserve section headers and keep top-level item lines together with their indented detail lines.
    4. Keep the helper profile-driven (`DriverCheck` / `Generic`) instead of trying to overfit a rigid universal diff engine.
*   **Files affected:** `internal\Compare-StructuredTextReport.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation; non-admin runtime compare of `differences-only.txt` from `Multi-slow-AfterInstall` vs `Multi-fast-AfterInstall`; verified `missing-vs-base.txt` and `extra-vs-base.txt` generation under `compare-output\structured-text`

*   **Date:** 2026-03-29
*   **Problem:** A helper that is useful only from CLI is easy to forget, especially in this repo where the main launcher is the intended daily entry point.
*   **Root Cause:** `Compare-StructuredTextReport.ps1` existed as a standalone internal tool, but not yet as a visible launcher action with the same picker-driven UX as the rest of `DriverCheck`.
*   **Guardrail:**
    1. If an internal helper becomes part of the normal investigation/debug workflow, expose it through `DriverCheck.ps1`.
    2. New launcher-integrated tools should reuse the same visual/menu conventions (`ESC`, arrows, number shortcuts, selection preview) instead of inventing a different UI.
    3. For report-to-report compare flows, prefer human-readable report pickers over raw path typing.
*   **Files affected:** `DriverCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation of `DriverCheck.ps1`; non-admin runtime validation of the internal structured comparer path remained green

*   **Date:** 2026-03-29
*   **Problem:** The first launcher version of `Compare Structured Reports` was technically functional but still unreadable, because users had to parse storage-oriented compare-output names and then re-select a report file that the workflow already knew it wanted.
*   **Root Cause:** The launcher exposed folder/file storage details instead of semantic compare context from the generated report itself (`Before` / `After` snapshot labels).
*   **Guardrail:**
    1. Launcher-facing structured compare flows should display semantic compare labels derived from the source compare report, not raw compare-output folder names.
    2. When the workflow is specifically about report differences, default to `differences-only.txt` and remove the extra file picker.
    3. Human readability in the picker is more important than mirroring the on-disk storage name.
    4. If the operator is expected to inspect compare results immediately, prefer an in-terminal pretty viewer over forcing raw txt opening as the first review step.
*   **Files affected:** `DriverCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation of `DriverCheck.ps1`; launcher structured compare flow updated to derive labels from `full-report.txt` and snapshot metadata

*   **Date:** 2026-03-29
*   **Problem:** The new compare-output and structured-report picker flows exposed two UI/ops issues at once: raw compare folder names could become absurdly long on Windows, and some redraw-based menus could occasionally stack duplicate frames instead of repainting cleanly.
*   **Root Cause:** Compare report folders originally reused too much raw snapshot naming, while a few arrow-key redraw menus still relied on host behavior that breaks when lines wrap or the redraw region is not explicitly reserved.
*   **Guardrail:**
    1. Generated compare-output folder names must stay short and path-safe; prefer compact semantic tokens (`Case-Stage`) plus a short timestamp over full snapshot folder names.
    2. Reusable redraw menus must truncate visible lines to the current console width and reserve their paint region before entering the key loop.
    3. If a multiline function call in launcher UI code spans parameters across lines, keep explicit continuation markers so named parameters do not accidentally execute as standalone commands.
*   **Files affected:** `internal\Compare-DriverSnapshots.ps1`, `internal\Save-DriverSnapshot.ps1`, `DriverCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation for launcher/save/compare scripts; non-admin compare run verified new short compare-output folder name; non-admin structured compare helper remained runnable

*   **Date:** 2026-03-29
*   **Problem:** Menu `7` (`Compare Structured Reports`) could still show the same snapshot compare combo multiple times because older timestamped compare-output folders remained on disk.
*   **Root Cause:** The structured report picker originally deduped too literally and still traversed the `compare-output\structured-text` subtree, so historical reruns of the same semantic compare could leak into the launcher menu.
*   **Guardrail:**
    1. Structured compare pickers must ignore generated helper-output subtrees such as `compare-output\structured-text`.
    2. Deduplication for compare reports should prefer semantic identity (`Before` label + `After` label + mode) over raw folder name/path, because folder names may change across storage formats.
    3. When historical reruns exist for the same semantic compare, show only the newest entry in launcher-facing menus.
*   **Files affected:** `DriverCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation of `DriverCheck.ps1`; non-admin probe over `compare-output` confirmed only the newest `Slow` and newest `Fast` compare identities remain after semantic dedupe

*   **Date:** 2026-03-29
*   **Problem:** The launcher `Delete Snapshot` confirm screen showed the correct `[ENTER] Delete snapshot` instruction, but pressing `ENTER` could appear to do nothing.
*   **Root Cause:** The key loop relied on ambiguous `switch`/`while` flow control instead of an explicit post-key exit check, so the confirmation state was set but the loop did not reliably advance to the actual `Remove-Item` path.
*   **Guardrail:**
    1. For PowerShell key-driven confirmation prompts, do not rely on implicit `break` behavior inside nested `switch` + `while` structures.
    2. After mutating a confirmation state inside a key handler, use an explicit outer-loop exit check before leaving the input loop.
    3. Destructive prompts should keep the input path simple and deterministic: `ENTER` confirms, `ESC` cancels, and both paths should be obvious in code review.
*   **Files affected:** `DriverCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation of `DriverCheck.ps1`; non-admin code-path inspection of the launcher delete confirmation loop

*   **Date:** 2026-03-29
*   **Problem:** Once compare reports became part of the normal launcher workflow, stale compare-output folders were hard to clean up because deletion existed only for snapshots, not for report pickers.
*   **Root Cause:** Menu `7` originally treated compare reports as read-only picker items, even though they are disposable generated artifacts and benefit from inline cleanup.
*   **Guardrail:**
    1. Launcher pickers for generated artifacts may support inline deletion when the artifact lives under a known safe root.
    2. Inline delete should act on the currently highlighted item, use the same `ENTER` confirm / `ESC` cancel pattern, and then refresh the same picker instead of bouncing the user through another menu.
    3. For compare report cleanup, restrict deletion to paths under the configured `compare-output` root.
*   **Files affected:** `DriverCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation of `DriverCheck.ps1`

*   **Date:** 2026-03-29
*   **Problem:** Deleting compare reports inline from menu `7` could leave a mixed screen and stale deleted report references, especially when one of only two reports was removed.
*   **Root Cause:** The picker refreshed only its local in-memory list, while the surrounding structured compare flow still held an older report list and selection state built before the deletion.
*   **Guardrail:**
    1. If a picker supports inline deletion, successful delete must restart the picker screen cleanly instead of continuing to paint inside the old frame.
    2. After a destructive action that changes the underlying folder set, re-read the current items from disk before building the next step of the workflow.
    3. Before launching report-to-report compare logic, validate that both selected source files still exist and fail gracefully if one was deleted during the same menu flow.
*   **Files affected:** `DriverCheck.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation of `DriverCheck.ps1`

*   **Date:** 2026-03-30
*   **Problem:** The `Snapshot mode` submenu in `Save Snapshot` kept producing stacked redraw artifacts in Windows Terminal, even after multiple cursor-reset and repaint tweaks.
*   **Root Cause:** The redraw-based arrow menu for `Snapshot mode` was host-fragile and could still desync after previous interactive writes, so more micro-fixes were not a reliable use of time.
*   **Guardrail:**
    1. If a specific interactive submenu remains terminal-fragile after repeated repaint fixes, stop polishing the redraw path and replace it with a stable text prompt.
    2. Prefer robust `1/2/ESC` selection over animated cursor UI for narrow, low-choice prompts where reliability matters more than visual consistency.
    3. Keep arrow-key menus where they are stable, but do not force redraw-based UI into every branch of the workflow.
*   **Files affected:** `internal\Save-DriverSnapshot.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation of `internal\Save-DriverSnapshot.ps1`

*   **Date:** 2026-03-30
*   **Problem:** Persisted live cleanup transcripts existed on disk, but the launcher had no first-class way to re-read them with the same terminal feel or delete stale ones from inside the normal workflow.
*   **Root Cause:** The `live\` folder was only storage; launcher UX covered snapshots and compare reports, but not saved live cleanup artifacts.
*   **Guardrail:**
    1. If live cleanup persists reports under repo-root `live\`, the main launcher should expose a first-class menu entry for browsing them.
    2. Re-reading saved live cleanup reports should prefer terminal-style rendering over raw markdown preview when the goal is to recreate the original cleanup output feel.
    3. Saved live cleanup artifacts should support guarded inline deletion from the same picker flow, with root-bound path verification under `live\`.
*   **Files affected:** `DriverCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation of `DriverCheck.ps1`; code-path review of live report picker/viewer/delete flow

*   **Date:** 2026-03-30
*   **Problem:** Confirmed live cleanup runs produced useful destructive-output transcripts in chat/manual copy, but the repo had no automatic persisted artifact for the exact `YES` path.
*   **Root Cause:** `Invoke-DriverLiveCheck.ps1` showed the cleanup/post-check output only in the terminal and did not save the confirmed run to disk.
*   **Guardrail:**
    1. After the operator confirms live cleanup with exact `YES`, persist that cleanup/output block automatically under repo-root `live\`.
    2. Live destructive-output artifacts should use stable human-readable names that include the primary driver token and timestamp.
    3. Keep the persisted live report scoped to the confirmed cleanup section; do not require transcript capture for the entire interactive discovery flow.
*   **Files affected:** `internal\Invoke-DriverLiveCheck.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation of `internal\Invoke-DriverLiveCheck.ps1`; non-admin code-path review of transcript start/stop flow

*   **Date:** 2026-03-30
*   **Problem:** Even after human-readable compare labels moved into the launcher UI, long compare-output folder names could still be annoying or even fail in Explorer/VM copy workflows because Windows path handling is still fragile in practice.
*   **Root Cause:** Storage naming still carried too much semantic text, even though the actual human-facing selection logic already came from report metadata and not from folder names.
*   **Guardrail:**
    1. Keep compare-output storage names short and opaque if the launcher/report metadata already provides the readable context.
    2. Prefer compact stable ids (for example `cmp__<short-id>`) over long semantic folder names for generated artifacts.
    3. Use the on-disk folder name for storage only; use report metadata for human-readable UI labels.
*   **Files affected:** `internal\Compare-DriverSnapshots.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation of `internal\Compare-DriverSnapshots.ps1`

*   **Date:** 2026-03-30
*   **Problem:** In sequential wizard-style prompts, `ESC` could feel wrong when it always aborted the whole flow instead of backing up one step.
*   **Root Cause:** The flow treated all cancel tokens the same, even in cases where the operator was clearly still inside a multi-step decision sequence.
*   **Guardrail:**
    1. In sequential same-screen wizard flows, `ESC` should normally cancel the current step and return to the previous step, not eject the user from the whole workflow.
    2. Reserve “cancel the whole flow / return to main menu” behavior for the top-most prompt in the sequence.
    3. Prompt text should say what `ESC` actually does (`Back to Stage selection`, not generic `Cancel snapshot save`).
*   **Files affected:** `internal\Save-DriverSnapshot.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation of `internal\Save-DriverSnapshot.ps1`

*   **Date:** 2026-03-30
*   **Problem:** The `Save Snapshot` flow had repeated repaint failures in Windows Terminal around `Stage` / `Snapshot mode`, and keeping mixed UI paradigms there was costing more time than it was worth.
*   **Root Cause:** Redraw-based arrow menus were being used in a narrow wizard path that really only needed a few deterministic choices, so the UI complexity was higher than the value of the animation.
*   **Guardrail:**
    1. For short sequential setup wizards, prefer a fully stable text-based prompt sequence over a hybrid redraw UI if the redraw path has already proven host-fragile.
    2. Keep the interaction model consistent inside the same wizard; do not mix animated cursor menus with fallback text prompts unless there is a strong reason.
    3. Save the richer arrow-key UX for larger pickers where it materially improves navigation.
*   **Files affected:** `internal\Save-DriverSnapshot.ps1`, `CHANGELOG.md`, `PROJECT_RULES.md`
*   **Validation/tests run:** Parser validation of `internal\Save-DriverSnapshot.ps1`
