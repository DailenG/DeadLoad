# Changelog

## Unreleased

- Product requirements, architecture and decision record, measurement record and phased plan.
- `tools/Measure-AutodeskFootprint.ps1` 1.0.0: read-only inventory of Autodesk Revit, AutoCAD
  and shared component disk usage per profile, never following reparse points.
- Probe 1.1.0: whole-run time budget with a fair share per root, compact JSON and folding of
  small deep folders (output fits RMM consoles that keep about 100 KB), seed `Revit.ini`
  files, `CrashDumps`, Desktop Connector and CER registry settings, journal session numbers
  and age counts, owner-profile tokenizing of process paths, and a final redaction of every
  profile folder name from the output.
- Engine module `DeadLoad` 0.1.0: category-driven retention (protect, routine age/count/size/
  share limits with OR semantics, pressure tiers to a target), reparse-safe enumeration and a
  re-checking deletion primitive, per-profile process guard, verified journal compression into
  monthly archives, Copy/Move actions, budgets, Revit.ini journal shelf management, report
  (`last-run.json`), event log and run log, integrity check of signed data files, support
  bundle export, and the policy > local > default configuration reader with source trace.
- Pester suite for PLAN phase 1 (tests 1.1 to 1.22) on Windows PowerShell 5.1 and PowerShell 7.
- Scheduler: `Start-DeadLoad.ps1` task entry point and `Sync-DeadLoadSchedule` (Maintenance,
  PressureCheck with the low-disk event, OnDemand startable by users), triggers from policy.
- Group Policy templates `policy/DeadLoad.admx` and `en-US/DeadLoad.adml`, generated from the
  settings catalog by `build/New-DeadLoadAdmx.ps1`.
- Tray app `DeadLoadTray.exe` (.NET Framework 4.8) and `Invoke-DeadLoadUserAction.ps1`.
- Chocolatey package `deadload`, `build/Build.ps1` (build, stage, sign, verify, pack), legacy
  Get-FreeSpace 1.3.5 retirement, and `docs/OPERATIONS.md`.
- Windows Sandbox acceptance run of the install procedure (`tests/Sandbox`).

### Fixed

- Tray actions exited 1 with no result on Windows PowerShell 5.1: the user action script's
  module path default used `$PSScriptRoot`, which 5.1 leaves empty in `param()` defaults.
- User-mode runs no longer replace the machine's `last-run.json` or write Application events.
- A what-if run no longer misses running guarded processes (`Invoke-CimMethod` honored
  `-WhatIf`).
