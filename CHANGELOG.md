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
