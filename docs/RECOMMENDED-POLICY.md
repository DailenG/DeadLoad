# Recommended DeadLoad policy

**The shipped defaults are the recommendation.** They come from measuring seven engineering
workstations ([MEASUREMENTS.md](MEASUREMENTS.md)) and the decisions recorded in
[ARCHITECTURE.md](ARCHITECTURE.md) section 2 (D10 for the numbers, D17 to D21 for Revit journals,
web caches, temp files of running sessions and Desktop Connector). A Group Policy object for
DeadLoad therefore sets very little. Most organizations set only:

| What | Policy (Group Policy editor) | Registry value under `HKLM\SOFTWARE\Policies\DeadLoad` | Default |
|---|---|---|---|
| When weekly maintenance runs | Schedule > Maintenance time (HH:mm) | `Schedule\MaintenanceTime` (REG_SZ) | `03:00` (local time), on `Sunday` |
| Report only for the pilot | General > Report only (change nothing) | `ReportOnly` (REG_DWORD) | `0` |
| Where "Collect my logs" saves support bundles | Tray app > Support share for collected logs | `Tray\SupportShare` (REG_SZ, a UNC folder) | empty: the user's Desktop |
| Optional: tell users when a cleanup completed | Tray app > Notify when a cleanup completes | `Tray\NotifyOnCompletion` (REG_DWORD) | `0` |
| Optional: low disk notifications | Tray app > Low disk notifications | `Tray\LowDiskNotifications` (REG_DWORD) | `1` |

Everything else (categories, ages, disk pressure floor and target, budgets) is best left at its
default until a pilot shows a reason to change it. The full catalog, with ranges and the default
of every value, is in the ADMX templates and in the
[policy generator](https://daileng.github.io/DeadLoad/policy.html) (`site/policy.html`).

## What the defaults do

- **Schedule**: Maintenance weekly on Sunday at 03:00, started when the machine is next available
  if it was off; a daily pressure check at 12:30 that also runs on low-disk events. Scheduled
  runs do not start on battery power (`AllowOnBattery` 0).
- **Disk pressure** (D10): below the larger of 30 GB and 5 percent free, pressure tiers give up
  eligible items, oldest first, until free space reaches the larger of 45 GB and 8 percent.
- **Budgets**: a run stops cleanly after 20 minutes or 100,000 items; no byte cap.
- **Categories on**: Windows and user temp files (7 days), Revit web cache (14 days), Revit
  content cache (pressure only), Revit journals (compressed after 3 days, archives kept 180 days),
  Revit's own journal retention raised to 14 days, Autodesk crash reports (30 days, newest 5
  kept), Autodesk installer logs (90 days, newest 5 kept).
- **Categories off**: Revit collaboration cache (D7), data of Revit versions no longer installed,
  Autodesk installation files under `C:\Autodesk` (D8), AutoCAD graphics cache, automatic save
  files and error logs. Turn one on only for a measured reason (category policy `Enabled`).

## Per product

The policy generator's **Autodesk products** panel shows each category with its on/off switch
(the category's `Enabled` policy), its risk tier and only the limits its rule uses. Values live
under `HKLM\SOFTWARE\Policies\DeadLoad\Categories\<category id>`. Change one only for a measured
reason; the shipped value is the recommendation.

| Product | Category | Default | Limits worth knowing (shipped value) |
|---|---|---|---|
| Revit | `revit.journals` | on | `AgeDays` compress after 3 days; under pressure `PressureKeepNewest` 20, `PressureAgeDays` 2 (D19) |
| Revit | `revit.journals.archive` | on | `AgeDays` 180; `ProtectNewest` 1 |
| Revit | `revit.ini.journalshelf` | on | `ShelfLifeDays` 14, `ShelfCapacity` 10. Keep it on while journals are compressed: Revit's own cleanup otherwise deletes journals older than 10 days (D18) |
| Revit | `revit.webcache` | on | `AgeDays` 14; `PressureAgeDays` 3 |
| Revit | `revit.paccache` | on | pressure only (D9): `PressureAgeDays` 7 |
| Revit | `revit.collabcache` | off (D7) | pressure only: `PressureAgeDays` 90, `MinAgeHours` 2160. Removing a model's cache can lose changes that were saved but not synchronized; have users synchronize first |
| Revit | `revit.oldversions` | off | `AgeDays` 90; `PressureAgeDays` 30. Deletes whole folders of uninstalled Revit years, journals and model backups included |
| AutoCAD | `autocad.graphicscache` | off | `AgeDays` 30; `PressureAgeDays` 7. Measured too small to need a rule |
| AutoCAD | `autocad.recovery` | off | `AgeDays` 30; `MinAgeHours` 72. Recovery data; never part of a user-started cleanup (D25) |
| AutoCAD | `autocad.errorlogs` | off | `AgeDays` 30 |
| Shared | `autodesk.cer` | on | `AgeDays` 30; `ProtectNewest` 5 |
| Shared | `autodesk.installlogs` | on | `AgeDays` 90; `ProtectNewest` 5 |
| Shared | `autodesk.installers` | off (D8) | pressure only: `PressureAgeDays` 90, `MinAgeHours` 2160. Updates, repairs and reinstalls may need these files |
| Temporary files | `user.temp`, `windows.temp` | on | `AgeDays` 7; `MinAgeHours` 24 |

Civil 3D is not measured or supported. Custom targets (a list policy) are set in the Group Policy
editor, not in the generator.

## Two presets

The [policy generator](https://daileng.github.io/DeadLoad/policy.html) offers both; the values
are the same as here.

### Pilot

Run DeadLoad in report-only mode first: it scans, plans and logs every decision, and changes
nothing. Keep it for at least a week on a few workstations and read the run logs (the
[PRD](../PRD.md) section 7 pilot plan is two weeks report-only, then two weeks live).

| Value | Data |
|---|---|
| `ReportOnly` | `1` |
| `Tray\NotifyOnCompletion` | `1` |

Plus your `Schedule\MaintenanceTime` and `Tray\SupportShare` if the defaults do not suit.

### Recommended

The defaults, with report-only explicitly off:

| Value | Data |
|---|---|
| `ReportOnly` | `0` |

Setting `ReportOnly` to `0` in policy, rather than leaving it not configured, matters when the
package was installed with `/ReportOnly`: that parameter writes the local value
`HKLM\SOFTWARE\DeadLoad\ReportOnly` = 1, which stays until removed. Policy wins over the local
value, so the GPO ends the pilot on every machine at once.

## Apply

1. **Templates.** Copy `DeadLoad.admx` and `en-US\DeadLoad.adml` to the domain's central store
   once per DeadLoad version, from any machine with the package installed
   ([OPERATIONS.md](OPERATIONS.md) section 6):

   ```powershell
   $store = '\\<your domain>\SYSVOL\<your domain>\Policies\PolicyDefinitions'
   Copy-Item -LiteralPath "$env:ProgramFiles\DeadLoad\policy\DeadLoad.admx" -Destination $store
   Copy-Item -LiteralPath "$env:ProgramFiles\DeadLoad\policy\en-US\DeadLoad.adml" -Destination (Join-Path $store 'en-US')
   ```

   Without a domain, install with `/InstallAdmxLocally` and use the Local Group Policy Editor.
2. **GPO.** In the Group Policy Management Console, create a GPO and link it to the
   organizational unit that holds the workstations (start with the pilot machines). Edit it:
   Computer Configuration > Policies > Administrative Templates > DeadLoad. Set the values above.
   Tray settings also exist under User Configuration; machine policy wins over user policy.
3. **Or generate it.** The policy generator writes a PowerShell script that sets the same values
   in a named GPO with `Set-GPRegistryValue` (GroupPolicy module), a `.reg` file for one test
   machine, and a table for setting them by hand.

## Verify

On a workstation, after the next Group Policy refresh (or `gpupdate /target:computer`):

```powershell
Import-Module "$env:ProgramFiles\DeadLoad\engine\DeadLoad\DeadLoad.psd1"
Get-DeadLoadConfiguration -Trace | Where-Object Source -ne 'Default'
```

Each row shows a setting's `Name` (for example `ReportOnly`, `Schedule\MaintenanceTime`,
`Tray\SupportShare`), its effective `Value` and its `Source`: `Policy`, `Local` or `Default`. A
value DeadLoad cannot use (out of range, wrong format) is ignored, logged as event 3002 in the
Application log (source DeadLoad), and the next source applies. Every run also logs the effective
configuration as event 1003, and `%ProgramData%\DeadLoad\last-run.json` shows `ReportOnly` for the
last run.

A new maintenance time reaches the scheduled task at the end of the next Maintenance or
PressureCheck run (the engine re-applies the task triggers from the effective settings, D15);
`Sync-DeadLoadSchedule`, run elevated, applies it at once.
