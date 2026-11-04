# DeadLoad: Path Measurements

Every built-in category targets paths graded here. A category ships enabled only when its paths
are **M**.

| Grade | Meaning |
|---|---|
| **M** | Measured on a real installation; the row says which hosts, product build and when. |
| **D** | Stated in Autodesk documentation (URL given); not yet seen on a workstation. |
| **F** | Forum, blog or Autodesk staff answer outside official docs. |
| **C** | Candidate: inferred or taken from another tool; no source. |

Hosts are recorded by anonymous label (Host A, Host B, ...). Raw probe output contains computer
names, SIDs and journal file names and stays in `measurements/raw/` (gitignored).

## 1. How to measure

Run the read-only probe on a workstation with the products installed, elevated or as SYSTEM so
every profile is visible:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\Measure-AutodeskFootprint.ps1 -RootTimeBudgetSeconds 60 -OutFile C:\Windows\Temp\deadload-probe.json
```

It writes nothing else, never follows reparse points, and never enters Desktop Connector
workspaces or other user-data folders. Copy the JSON to `measurements/raw/<label>.json`, then
update the tables below: change the grade to M, add the host label, product build and date.

Probe 1.1.0 measured seven workstations on 2026-11-03 as SYSTEM through an RMM script runner
(32-bit Windows PowerShell host starting the 64-bit host for the probe). Every run ended with
exit 0 and no error output in 52 to 106 seconds against a 240-second whole-run budget; no root
was truncated; the output carried no profile folder name (the final redaction replaced 1 to 14
installer `InstallSource` paths per host that pointed into a user's profile). The first run of
1.0.0 wrote 4.7 MB of indented JSON for one host, which the RMM console cut at about 100 KB;
1.1.0 writes compact JSON and folds folders under 1 MB below depth 1, 411 to 618 KB per host.

## 2. Hosts (2026-11-03)

All Windows 11 Pro for Workstations (builds 26200 and 26300), Windows PowerShell 5.1, NTFS last
access updates system-managed and enabled (`NtfsDisableLastAccessUpdate` 0x80000002) on every
host. A weekly cleanup script emptied every user's Temp, Windows Temp and the Journals,
CefCache and PacCache folders of Revit years matching `*Revit*202*` until 2026-10-27, so ages in
those folders are capped at about a week; Revit 2019 and older folders were not matched and
show undisturbed history.

| Label | Role in the sample | Revit installed (build) | Other Autodesk | System drive |
|---|---|---|---|---|
| Host A | Heavy Revit user | 2023 (23.1.60), 2024 (24.3.40), 2025 (25.4.60), 2026 (26.4.10), 2027 (27.0.4) | AutoCAD 2019, 2022, 2025; Advance Steel 2022; Desktop Connector 17.1 | 475 GB, 109 GB free |
| Host B | Most Revit years; Revit running | 2020 (20.2.80) to 2027 (27.0.4) | AutoCAD 2018, 2019, 2024, 2025; Desktop Connector 17.1 | 930 GB, 277 GB free |
| Host C | Low disk; 9 profiles | 2023 (23.1.70) to 2026 (26.4.10) | AutoCAD 2022; Desktop Connector 16.8 | 465 GB, 49 GB free |
| Host D | Revit left open; AutoCAD 2027 | 2021 (21.1.90) to 2026 (26.2.0) | AutoCAD 2025, 2027; Desktop Connector 17.1 | 930 GB, 423 GB free |
| Host E | DWG TrueView 2027 | 2020 (20.2.50) to 2026 (26.2.0) | AutoCAD 2019, 2025; Desktop Connector 27.2 | 930 GB, 373 GB free |
| Host F | Navisworks Manage 2024; Revit running | 2020 (20.1.0) to 2026 (26.5.0) | AutoCAD 2019, 2025; Desktop Connector 16.8 | 930 GB, 459 GB free |
| Host G | Low disk; old journals | 2020 (20.2.50) to 2026 (26.2.0) | AutoCAD 2018 (+ Architecture, MEP), 2025; DWG TrueView 2018; Desktop Connector 17.1 | 475 GB, 30 GB free |

No sampled host has Revit 2019 or Civil 3D installed (a fleet inventory of 68 workstations found
none). Revit 2027 is installed on Hosts A and B but had not been started, so no 2027 user folder
exists yet.

## 3. Revit

| Item | Path / value | Grade | Source |
|---|---|---|---|
| Journals | `{LocalAppData}\Autodesk\Revit\Autodesk Revit <year>\Journals\journal.NNNN.txt`, one per session | M (2015 to 2026 folders, Hosts A to G, 2026-11-03); D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Location-of-journal-files.html |
| Journal sizes | median 0.05 MB (2015) to 20 MB (2026) per session, largest 47.5 MB; 10 journals of one user and year up to 184 MB | M (Hosts A to G) | probe |
| Worker logs | `...\Journals\journal.NNNN.workerN.log`, 0.03 to 0.1 MB each | M (Hosts A to G) | probe |
| Crash dumps | `...\Journals\journal.NNNN.NNNN.dmp` (265 files, up to 1.1 GB per year folder) and `dump.N.txt` (1197 files) | M (Hosts B, D to G) | probe |
| Backup RVT/RFA/RTE copies in Journals | `<model>_N-N-N.rvt` and `.rfa`, `.rte`; hundreds in Revit 2017 to 2019 folders | M (Hosts B, E, F, G); D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/How-to-prevent-Revit-from-creating-backup-files-in-the-journal-folder.html |
| Other journal files | `journal.NNNN.txt.abbrev`, `journal.NNNN.txt.copy.txt` | M (few files) | probe |
| Journal shelf | `Revit.ini` `[Backups]` `JournalShelfCapacity` (default 10), `JournalShelfLife` (default 10 days): "when number of journals exceeds N, delete journals older than D days" | D; behavior M (see D18) | https://help.autodesk.com/cloudhelp/2025/ENU/Revit-Customize/files/GUID-37D80997-3F1E-4C2C-9678-9B3F3EEC40FC.htm, https://help.autodesk.com/cloudhelp/2025/ENU/Revit-Customize/files/GUID-150AF853-2413-439F-B8FB-B3DBCB827EDD.htm |
| Journal shelf pruning | Every year folder with history holds 10 (once 11) journals whose session numbers are consecutive and far above 10 (for example 160 to 169, 444 to 453), oldest 32 days to 6 years: Revit keeps the newest 10 and deletes older ones | M (Hosts B, D, E, F, G) | probe (`JournalNumberMin/Max`) |
| Revit.ini | User: `{AppData}\Autodesk\Revit\Autodesk Revit <year>\Revit.ini`; seed: `{ProgramData}\Autodesk\RVT <year>\UserDataCache\Revit.ini`. No sampled user or seed file sets any Journal, Shelf or Cache key, so Revit defaults apply | M (Hosts A to G, years 2016 to 2027 seeds); D | https://help.autodesk.com/cloudhelp/2025/ENU/Revit-Customize/files/GUID-ECD1B2C6-7612-431E-ACDE-92A557862020.htm |
| CollaborationCache | `{LocalAppData}\Autodesk\Revit\Autodesk Revit <year>\CollaborationCache\<hub>\<project>\...`; 0.3 to 9.6 GB per user and year | M (2023 to 2026, Hosts A, B, D to G); D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/C4R-is-it-possible-to-move-the-collaboration-cache-to-a-different-drive.html |
| CollaborationCache location | `Revit.ini` `[CloudModelCache] CacheLocation`; set nowhere in the sample, every cache at the default path | M (absence, Hosts A to G); F (key name) | https://stackoverflow.com/questions/78373576/revit-api-find-location-of-collaboration-cache-in-2024 |
| CollaborationCache safety | Clearing destroys saved-but-unsynchronized changes; move aside, do not delete | D | same C4R article |
| PacCache | `{LocalAppData}\Autodesk\Revit\PacCache\<guid>\...` with `Logs\`; 1.0 to 7.5 GB per user, mostly under 7 days old; self-limited by `DiskCacheLimitGB` (default 10) | M (Hosts A, B, D to G); D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/FAQ-about-Revit-Personal-Accelerator.html |
| CefCache (through 2025) | `{LocalAppData}\Autodesk\Revit\Autodesk Revit <year>\CefCache`, 21 to 209 MB; never under `{AppData}` | M (2023 to 2025, Hosts A, B, D to G); D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/How-to-clear-cached-data-for-Revit-Home.html |
| WebBrowserControl (2026+) | `{LocalAppData}\Autodesk\Revit\Autodesk Revit 2026\WebBrowserControl`, 47 to 159 MB; no CefCache in any 2026 folder | M (2026, Hosts A, C to G); D | same |
| Folders of years not installed | `Autodesk Revit 2015` to `2019` folders holding only Journals (journals, dumps, model backups), up to 2.5 GB per profile | M (Hosts B, E, F, G) | probe |
| Product key letters | P = 2024, Q = 2025, R = 2026 | M | field notes |
| Revit 2027 user folders | Not created yet on any host | C | to measure after first use |

## 4. AutoCAD

| Item | Path / value | Grade | Source |
|---|---|---|---|
| User folder | `{LocalAppData}\Autodesk\AutoCAD <year>\R<n>\enu`; 0.5 to 117 MB per user and year | M (2017 to 2027, Hosts A to G) | probe |
| Graphics cache | `*.acdsgccache` files under `...\R<n>\enu` (the `GraphicsCache` folder is one level deeper than the probe lists); at most 34 MB per user and year | M (files and parent); D (folder name) | https://help.autodesk.com/cloudhelp/2027/ENU/AutoCAD-Core/files/GUID-7494F1CE-253B-42AC-BD26-10FB9E8FE77B.htm |
| R-numbers | 2017 R21.0, 2018 R22.0, 2019 R23.0, 2022 R24.1, 2024 R24.3, 2025 R25.0, 2027 R26.0 | M (`HKLM\SOFTWARE\Autodesk\AutoCAD`, Hosts A to G); D (2020, 2021, 2023, 2026) | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Release-numbers-differ-from-version-year-numbers-in-AutoCAD-products.html |
| Autosave `*.sv$` | `SAVEFILEPATH`, default from `%TEMP%`; recovery data | D; none found on any host | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Understanding-AutoCAD-backup-and-autosave-files.html |
| Temp `*.ac$` | Under `{Temp}`, 0 bytes each | M (Hosts A, B, D) | probe |
| `*.bak` | Beside the drawing; user data, never touched | D | same |
| `acad.err`, `acadstk.dmp` | `{LocalAppData}\CrashDumps` and `{Temp}` | D; none found on any host | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Acad-err-and-acadstk-dmp-files.html |
| Plot and Publish log | `...\R<n>\enu\PlotandPublishLog.CSV` | D; `.csv` of 1 KB seen | Error-There-are-no-plot-or-publish-details article |

## 5. Shared Autodesk components and Windows

| Item | Path / value | Grade | Source |
|---|---|---|---|
| CER crash reports | `{LocalAppData}\Autodesk\CER\<hash>\` holding logs (about 4.5 MB each, 3 to 4 per hash) and `<timestamp>\` folders with `.pb`, `.dmp`, `.zip`; up to 329 MB per profile across 20 hashes. `HKCU\Software\Autodesk\SendMiniDmp\Settings` exists without `MaxRetainedCount` | M (Hosts A to G) | probe; https://btl-blog.com/2026/03/30/the-new-autodesk-cer-v7-format-changes-and-how-to-read-it/ |
| ODIS user logs | `{LocalAppData}\Autodesk\ODIS\*.log` and rotated `*.log.N`, up to 365 MB and 1830 files per profile, mostly over 90 days old; `IHT\` subfolder of about 1500 small files | M (Hosts A to G); D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Location-of-the-log-files-generated-by-the-installation-of-an-Autodesk-product.html |
| `{ProgramData}\Autodesk\ODIS` | 427 to 733 MB per host | M (size); C (safety) | probe |
| `{ProgramData}\Autodesk` | 27 to 38 GB per host, nearly all installed content (RVT libraries, Steel Connections, Geospatial Coordinate Systems), over 90 days old | M; not a target | probe |
| `C:\Autodesk` | `WI` and `Access` installer extracts; empty on most hosts (wiped weekly until 2026-10-27), 10 GB on Host F; 1 to 3 installed products per host name a folder under it as `InstallSource` | M (Hosts A to G); D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Can-I-move-or-delete-C-Autodesk-folder.html |
| Desktop Connector workspace | `{UserProfile}\DC` on every host with Desktop Connector 16.8 to 27.2; no `WorkspaceLocation` override in `HKLM` or any loaded `HKCU`; no `ACCDocs` or `BIM 360` folders | M (Hosts A to G); D | https://help.autodesk.com/cloudhelp/ENU/CONNECT-Admin-Guide/files/Administrator_Deploying_Change_Workspace.htm |
| `{LocalAppData}\CrashDumps` | Windows Error Reporting dumps of any application, at most 10 per profile (WER's default cap), up to 715 MB; Revit dumps among them | M (Hosts A to G) | probe |
| User Temp | Up to 7.4 GB (Revit session temp of a running Revit, under 1 day old); `.tmp`, `.log`, installer and Office folders | M (Hosts A to G) | probe |
| Windows Temp | 139 MB to 3.5 GB; 1.2 GB over 90 days on two hosts (ODIS and Autodesk installer leftovers) | M (Hosts A to G) | probe |

## 6. Processes (guard list)

Owners resolve to the profile from SYSTEM through `Win32_Process.GetOwnerSid` on every host.

| Process | Grade | Source |
|---|---|---|
| `Revit.exe`, `RevitWorker.exe`, `RevitBrowserSubprocess.exe` (owner: the signed-in user) | M (Hosts B, D, F) | probe |
| `RevitAccelerator.exe` (always on, not tied to Revit running; not guarded) | M (Hosts A, B, D to G); D | PAC FAQ above |
| `DesktopConnector.Applications.Tray.exe` (user); `FileSystemMonitor.WindowsService.exe` (SYSTEM) | M (Hosts A to G); D | Desktop Connector admin guide above |
| `AdskAccessCore.exe`, `AdskAccessUIHost.exe`, `AdskAccessService.exe` (user), `AdskAccessServiceHost.exe` (SYSTEM) | M (Host A); D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Blank-Autodesk-Access-window-shows-up-when-starting-Windows.html |
| `acad.exe` (AutoCAD and verticals) | D; not running during the sample | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/AutoCAD-is-stuck-in-the-Task-Manager-after-exiting.html |
| `AcCoreConsole.exe` | D | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/AcCoreConsole-exe-CAD-component-spiking-memory.html |
| `Roamer.exe` (Navisworks) | D; installed on Host F, not running | https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Names-of-Navisworks-Manage-Simulate-and-Freedom-executable-files.html |
| `dwgviewr.exe` (DWG TrueView) | C; installed on Hosts E and G, not running | to measure |

## 7. Still to measure

1. Revit 2027 user folders (journals, WebBrowserControl, CollaborationCache) after first use.
2. AutoCAD `GraphicsCache` folder name one level below `R<n>\<lang>` (probe row depth 3), and
   whether `*.sv$` and `acad.err` appear on machines where AutoCAD crashes.
3. `dwgviewr.exe` and `acad.exe` while running, and their owner from SYSTEM.
4. Ages of user Temp and Windows Temp after several weeks without the weekly wipe (pilot
   report-only runs), to re-tune D10.
5. Whether Revit's journal cleanup ever touches `Journals\Archive\` (expected not: it manages
   `journal.*` files only) and a gap-free archive sequence after the pilot (D18).
6. Civil 3D and other verticals on a machine that has them.
