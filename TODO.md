# TODO

- Profile `Save-DriverSnapshot.ps1` on a real Windows host with per-section timings.
- Identify the biggest bottlenecks in `PnP`, focused registry, and focused file collection.
- Add a future `Quick Snapshot` mode for daily use:
  - lighter `PnP` enrichment
  - lighter focused registry scan
  - no file hashing by default
- Keep the current full snapshot path available for deeper forensic runs.
