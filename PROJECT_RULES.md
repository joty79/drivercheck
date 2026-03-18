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
