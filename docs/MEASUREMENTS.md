# DeadLoad: Path Measurements

Every built-in category targets paths graded here. A category ships enabled only when its paths
are **M**.

| Grade | Meaning |
|---|---|
| **M** | Measured on a real installation; the row says which product build and when. |
| **D** | Stated in Autodesk documentation (URL given); not yet seen on a workstation. |
| **F** | Forum, blog or Autodesk staff answer outside official docs. |
| **C** | Candidate: inferred or taken from another tool; no source. |

Hosts are recorded by anonymous label (Host A, Host B, ...). Raw probe output contains computer
names, SIDs and journal file names and stays in `measurements/raw/` (gitignored).

## 1. How to measure

Run the read-only probe on a workstation with the products installed, elevated or as SYSTEM so
every profile is visible:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\Measure-AutodeskFootprint.ps1 -OutFile C:\Windows\Temp\deadload-probe.json
```

It writes nothing else, never follows reparse points, and never enters Desktop Connector
workspaces or other user-data folders. Copy the JSON to `measurements/raw/<label>.json`, then
update the tables below: change the grade to M, add the host label, product build and date.

Probe 1.0.0 smoke-tested 2026-11-03 on Windows PowerShell 5.1 and PowerShell 7.6, unelevated,
on a machine with no Autodesk products and planted fixtures (fake Revit journals, a Revit.ini,
a junction to a canary folder): the junction was counted and not followed, the canary was
untouched, and the output contained no user name. Not yet run elevated, as SYSTEM, or on a
machine with Autodesk products.

## 2. Revit

| Item | Path / value | Grade | Source |
|---|---|---|---|
| Journals | `{LocalAppData}\Autodesk\Revit\Autodesk Revit <year>\Journals\journal.NNNN.txt`, one per session, highest number newest | M (2023.1.6, one host, 2026-09-16); D (all versions, 2019 help identical) | field notes; https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Location-of-journal-files.html |
| Crash dumps | `...\Journals\journal.NNNN.MMMM.dmp`; `DUMP*.txt` also appear | M (dmp, 2023); D | same |
| Worker logs | `...\Journals\*worker*` (exact pattern undocumented) | M (presence, 2023) | field notes |
| Backup RVT/RFA copies in Journals | Created on saves to network locations; cannot be disabled; recovery data | D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/How-to-prevent-Revit-from-creating-backup-files-in-the-journal-folder.html |
| Journal sizes | Revit 2026: 0.5 MB to 28.8 MB per session; heavy user about 75 MB in 4 working days | M (2026, several hosts, 2026-11-03) | field notes |
| Journal shelf | `Revit.ini` `[Backups]` `JournalShelfCapacity` (default 10), `JournalShelfLife` (default 10 days) | D | https://help.autodesk.com/cloudhelp/2025/ENU/Revit-Customize/files/GUID-37D80997-3F1E-4C2C-9678-9B3F3EEC40FC.htm |
| Revit.ini | User: `{AppData}\Autodesk\Revit\Autodesk Revit <year>\Revit.ini`; seed: `{ProgramData}\Autodesk\RVT <year>\UserDataCache\Revit.ini` | D | https://help.autodesk.com/cloudhelp/2025/ENU/Revit-Customize/files/GUID-ECD1B2C6-7612-431E-ACDE-92A557862020.htm |
| CollaborationCache | `...\Autodesk Revit <year>\CollaborationCache\<hub>\<project guid>\{<model guid>.rvt, <model guid>_backup\, CentralCache\, LinkedModels\}`; 1.6 GB in 38 files on one host | M (2023); D | field notes; https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/C4R-is-it-possible-to-move-the-collaboration-cache-to-a-different-drive.html |
| CollaborationCache location (2024+) | Options > Cloud Model > cache location; `Revit.ini` `[CloudModelCache] CacheLocation` | D (option); F (ini key) | https://stackoverflow.com/questions/78373576/revit-api-find-location-of-collaboration-cache-in-2024 |
| CollaborationCache safety | Clearing destroys saved-but-unsynchronized changes; move aside, do not delete | D | same C4R article |
| PacCache | `{LocalAppData}\Autodesk\Revit\PacCache`, `Logs\` inside; 240 MB on one host; self-limited by `Revit Personal Accelerator\config.json` `DiskCacheLimitGB` (default 10); "no need to manually clear" | M (2023); D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/FAQ-about-Revit-Personal-Accelerator.html |
| CefCache (through 2025) | `{LocalAppData}\Autodesk\Revit\Autodesk Revit <year>\CefCache`; delete contents with Revit closed. One 2026 install page says roaming (`{AppData}`) instead | D (conflicting) | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/How-to-clear-cached-data-for-Revit-Home.html |
| WebBrowserControl (2026+) | `{LocalAppData}\Autodesk\Revit\Autodesk Revit <year>\WebBrowserControl` replaces CefCache | D | same |
| Product key letters | P = 2024, Q = 2025, R = 2026 (e.g. `829R1` Revit 2026) | M | field notes |
| Years 2019 to 2022, 2024 to 2027 | Same path pattern assumed | C | to measure |

## 3. AutoCAD

| Item | Path / value | Grade | Source |
|---|---|---|---|
| GraphicsCache | `{LocalAppData}\Autodesk\AutoCAD <year>\R<n>\<lang>\GraphicsCache`; Civil 3D and toolsets `{LocalAppData}\Autodesk\C3D <year>\<lang>\GraphicsCache`; deleting cache files is Autodesk's fix for display issues | D | https://help.autodesk.com/cloudhelp/2027/ENU/AutoCAD-Core/files/GUID-7494F1CE-253B-42AC-BD26-10FB9E8FE77B.htm |
| R-numbers | 2019 R23.0, 2020 R23.1, 2021 R24.0, 2022 R24.1, 2023 R24.2, 2024 R24.3, 2025 R25.0, 2026 R25.1, 2027 R26.0 | D (2019, 2023 to 2027); F (2020 to 2022) | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Release-numbers-differ-from-version-year-numbers-in-AutoCAD-products.html |
| Autosave `*.sv$` | `SAVEFILEPATH`, default from `%TEMP%`; removed by AutoCAD on save/close/exit, so leftovers mean a crash; recovery data | D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Understanding-AutoCAD-backup-and-autosave-files.html |
| Temp `*.ac$` | Temp folder from Options; no recoverable drawing data; left behind only by crashes | D (behavior); F (location) | same |
| `*.bak` | Beside the drawing; prior version of the DWG; user data, never touched | D | same |
| `acad.err`, `acadstk.dmp` | `{LocalAppData}\CrashDumps` and `{Temp}` | D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Acad-err-and-acadstk-dmp-files.html |
| Plot and Publish log | `{LocalAppData}\Autodesk\AutoCAD <year>\R<n>\enu\PlotandPublishLog.CSV`; deletable with AutoCAD closed | D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Error-There-are-no-plot-or-publish-details-to-view-when-looking-at-plot-details-in-AutoCAD.html |
| Everything above | | none M yet | to measure |

## 4. Shared Autodesk components

| Item | Path / value | Grade | Source |
|---|---|---|---|
| CER crash reports (2025+) | `{LocalAppData}\Autodesk\CER\<hash>\<timestamp>\*.pb, *.dmp`; keeps 5 by default (`HKCU\Software\Autodesk\SendMiniDmp\Settings` `MaxRetainedCount`); contains user email, machine and drawing names | F | https://btl-blog.com/2026/03/30/the-new-autodesk-cer-v7-format-changes-and-how-to-read-it/ |
| CER `dumpdata.zip` | Copy in Windows Temp | D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Does-AutoCAD-store-error-logs-on-the-C-drive.html |
| ODIS install logs | `{LocalAppData}\Autodesk\ODIS\*.log`; product install logs in `{Temp}` | D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Location-of-the-log-files-generated-by-the-installation-of-an-Autodesk-product.html |
| `{ProgramData}\Autodesk\ODIS` | metadata, extract, `Install.db` | C | another cleanup tool's targets |
| `C:\Autodesk` | Installer extracts: `WI` classic, `IM` ODIS, `Access` updates; deletable after install except `Network License Manager`; keeping it recommended | D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Can-I-move-or-delete-C-Autodesk-folder.html |
| Desktop Connector workspace | v16+: `{UserProfile}\DC\{ACCDocs,Drive,Fusion}`; v15: `{UserProfile}\ACCDocs`; up to 15.8: `{UserProfile}\BIM 360`; override `WorkspaceLocation` under `HKLM`/`HKCU\SOFTWARE\Autodesk\Desktop Connector Advanced Settings`. Never delete directly | D | https://help.autodesk.com/cloudhelp/ENU/CONNECT-Admin-Guide/files/Administrator_Deploying_Change_Workspace.htm |
| Desktop Connector app data | `{LocalAppData}\Autodesk\Desktop Connector`, `{LocalAppData}\Autodesk\Web Services\DesktopConnector`, `{ProgramData}\Autodesk\Desktop Connector`; Reset Utility only | D | https://help.autodesk.com/cloudhelp/ENU/CONNECT-Install-And-Update/files/Uninstall_Desktop_Connector.htm |

## 5. Processes (guard list)

| Process | Grade | Source |
|---|---|---|
| `acad.exe` (AutoCAD and verticals incl. Civil 3D) | D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/AutoCAD-is-stuck-in-the-Task-Manager-after-exiting.html |
| `RevitWorker.exe` | D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/What-is-RevitWorker-exe-used-for.html |
| `RevitAccelerator.exe` (always on, not tied to Revit running; not guarded) | D | PAC FAQ above |
| `Roamer.exe` (Navisworks) | D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Names-of-Navisworks-Manage-Simulate-and-Freedom-executable-files.html |
| `DesktopConnector.Applications.Tray.exe` | D | Desktop Connector admin guide above |
| `AdskAccessService.exe`, `AdskAccessUIHost.exe` | D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Blank-Autodesk-Access-window-shows-up-when-starting-Windows.html |
| `AcCoreConsole.exe` | D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/AcCoreConsole-exe-CAD-component-spiking-memory.html |
| `Revit.exe`, `dwgviewr.exe` | C | no Autodesk source; measure |

## 6. Still to measure

1. Revit 2019 through 2027: journal, CefCache / WebBrowserControl, PacCache and
   CollaborationCache paths per year; `[CloudModelCache] CacheLocation` in practice; whether
   CefCache is under Local or Roaming for 2026.
2. Whether Revit's journal shelf (10 files / 10 days by default) is already pruning journals:
   compare journal count and oldest age per year against the shelf values (decides D18).
3. Worker log, `DUMP*.txt` and backup RVT/RFA name shapes in Journals.
4. AutoCAD: GraphicsCache size and age profile; where `*.sv$`, `*.ac$`, `acad.err` actually land;
   Plot and Publish log size.
5. CER under `{LocalAppData}\Autodesk\CER` and anywhere under `{ProgramData}\Autodesk`.
6. ODIS logs, `{ProgramData}\Autodesk\ODIS`, and `C:\Autodesk` sizes; which `C:\Autodesk`
   folders are referenced by an `InstallSource`.
7. Desktop Connector workspace location and whether any workspace sits under a cleaned root.
8. Process names: `Revit.exe`, `dwgviewr.exe`; owners as seen from SYSTEM.
9. Age distribution of `{Temp}` and `{WindowsTemp}` (sets the default numbers, D10).
10. `NtfsDisableLastAccessUpdate` across the fleet (decides how often last access is usable).
