# DeadLoad

> In structural engineering the dead load is the permanent weight a structure carries.
> DeadLoad removes the dead load Autodesk products leave on engineering workstations,
> and keeps the records worth keeping.

DeadLoad manages disk space used by Autodesk Revit and AutoCAD on Windows workstations:
journals, worker logs, crash dumps, web, graphics and accelerator caches, autosave and temp
leftovers, installer extracts and crash reports. It runs unattended as SYSTEM from its own
scheduled tasks, applies log-management style retention (age, count, size, share of free space,
free-space floor and target), treats Revit journals as records, is configured by Group Policy,
and gives each user a tray app for self-service.

**Status: pre-release (0.1.0).** Engine, Group Policy templates, scheduler, tray app and the
signed Chocolatey package are built and tested; defaults come from measurements on seven
workstations ([docs/MEASUREMENTS.md](docs/MEASUREMENTS.md)). Install, upgrade and uninstall have
not yet run on a test VM, and no pilot has run ([docs/OPERATIONS.md](docs/OPERATIONS.md)).
Read in this order:

1. [PRD.md](PRD.md): what and why.
2. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): decisions, contracts, retention model, safety.
3. [docs/MEASUREMENTS.md](docs/MEASUREMENTS.md): which Autodesk paths are measured, documented,
   or still candidates.
4. [docs/PLAN.md](docs/PLAN.md): phases and acceptance tests.

## See what it would do

Report-only and `-WhatIf` plan every category and change nothing:

```powershell
Import-Module .\src\engine\DeadLoad\DeadLoad.psd1
Invoke-DeadLoad -Mode Maintenance -ReportOnly -DataRoot $env:TEMP\deadload -NoEventLog
Get-DeadLoadConfiguration -Trace | Where-Object Source -ne 'Default'
```

Run elevated or as SYSTEM to include every profile. The summary object lists per-category
counts; the run log (`<DataRoot>\logs`) names the rule behind every item decision.

## Measure a workstation

`tools/Measure-AutodeskFootprint.ps1` is a read-only probe that inventories the Autodesk
footprint of a machine (sizes, ages, file types, installed products, running processes,
Revit.ini journal and cache settings). It never writes, deletes or follows reparse points, and
redacts profile folder names from its output.

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\Measure-AutodeskFootprint.ps1 -RootTimeBudgetSeconds 60 -OutFile C:\Windows\Temp\deadload-probe.json
```

## Tests

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
```

Runs the Pester suite (5.0 or later) under Windows PowerShell 5.1 and PowerShell 7.

## Credits

DeadLoad reuses design and code from [Get-FreeSpace](https://github.com/DailenG/get-freespace)
2.0 by Dailen Gunter (per-item retention plans, measured freed bytes, last-access tracking check).

## License

GPL-3.0. See [LICENSE](LICENSE).
