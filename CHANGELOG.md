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
