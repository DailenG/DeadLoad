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
- Legacy retirement also drops Chocolatey's record of a Get-FreeSpace package
  (`choco uninstall <id> -n`), so `choco upgrade all` cannot reinstall it.
- Cleanup review for the DeadLoad window (ARCHITECTURE D22 to D26,
  `docs/design/ENGINE-UI-CONTRACT.md`): a `Risk` tier (Routine, Review, Restricted), display name
  and description per category, shown in the ADMX explain text; `Invoke-DeadLoadAnalysis` and
  `Invoke-DeadLoadCleanup` (user actions `Analyze` and `Clean`, gated by `Tray.AllowCleanTemp`),
  which delete only the reviewed items a fresh plan still selects and report every skip;
  `Invoke-DeadLoad -Category` in User mode, `-IncludePlan` and `-ReviewedItem`. Restricted
  categories never take part in a user-started cleanup, "Clean my temp files" included (D25):
  `autocad.recovery` is no longer a user-action category.
- The DeadLoad window in the tray exe (design slice 4, `docs/design/UI-NOTES.md`): Cleanup
  (Analyze, Review, confirmation, Clean, Complete, and "This computer" with Request a cleanup),
  Details, History, Settings and About; light, dark and high contrast following Windows; per
  monitor DPI; keyboard and screen reader names throughout. "Open DeadLoad" is the bold default
  tray item; "View last report" opens Details (the old report window is gone). New user action
  `-Action Configuration` (contract section 10) for the read-only Settings page. Hidden
  `--render-samples <outdir>` renders every view from embedded samples for design review.

### Fixed

- Tray actions exited 1 with no result on Windows PowerShell 5.1: the user action script's
  module path default used `$PSScriptRoot`, which 5.1 leaves empty in `param()` defaults.
- User-mode runs no longer replace the machine's `last-run.json` or write Application events.
- A what-if run no longer misses running guarded processes (`Invoke-CimMethod` honored
  `-WhatIf`).
