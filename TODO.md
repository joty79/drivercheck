# TODO

- [x] Profile `Save-DriverSnapshot.ps1` on a real Windows host with per-section timings.
- [x] Identify the biggest bottlenecks in `PnP`, focused registry, and focused file collection.
  - Real host timing result:
    - `Capture PnP device snapshot` ~= `49s`
    - `Capture focused registry snapshot` ~= `2.4s`
    - everything else was near-zero by comparison
- Add a future `Quick Snapshot` mode for daily use:
  - [x] lighter `PnP` enrichment
  - lighter focused registry scan
  - no file hashing by default
- Consider split `PnP` modes:
  - [x] `Quick` = basic device list first
  - [x] `Full` = expensive `Get-PnpDeviceProperty` / `Win32_PnPSignedDriver` enrichment
- Keep the current full snapshot path available for deeper forensic runs.
