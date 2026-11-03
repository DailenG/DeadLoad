# DeadLoad: Plan of Work

Phases run in order; each ends with its acceptance checks passing. Design references:
[../PRD.md](../PRD.md), [ARCHITECTURE.md](ARCHITECTURE.md), [MEASUREMENTS.md](MEASUREMENTS.md).

Rules for every phase:

- Windows PowerShell 5.1 and PowerShell 7; 7-bit ASCII; no `&&`/`||`; scripts run with `-File`.
- Pester 5+ suite green on both hosts (`tests/Invoke-Tests.ps1` runs both).
- Atomic commits, imperative subject, body explains why, no co-author lines.
- No change to any production workstation without a separate, explicit approval. Read-only
  measurement is allowed where the owner has granted access.

## Phase 0: Measure (read-only)

Work: run `tools/Measure-AutodeskFootprint.ps1` elevated or as SYSTEM on workstations that
together cover Revit 2019 to 2027, AutoCAD (plus a vertical such as Civil 3D if present),
Desktop Connector, and at least one heavy Revit user and one low-disk machine. Store raw JSON in
`measurements/raw/` (gitignored). Update MEASUREMENTS.md grades and the "Still to measure" list.

Acceptance:

- Every path in ARCHITECTURE section 7 marked enabled-by-default is graded M, or its category is
  switched to off by default with the reason recorded.
- D18 (Revit journal shelf) and D10 (default numbers) are resolved from data and recorded in
  ARCHITECTURE section 2.
- `Revit.exe` and `dwgviewr.exe` process names confirmed.

## Phase 1: Engine

Work: `src/engine/DeadLoad` module with `Invoke-DeadLoad`, `Get-DeadLoadStatus`,
`Export-DeadLoadSupportBundle`; `Data/Defaults.psd1` (categories from section 7); profile
enumeration from `ProfileList`; reparse-safe enumeration and deletion primitive; process guard;
retention planner (protect, routine, pressure); actions (Delete, Compress, Copy, Move); budgets;
report JSON; event log writer; text log. Reuse from Get-FreeSpace 2.0 with credit (ARCHITECTURE
section 15).

Acceptance tests (synthetic trees in a per-test sandbox; profiles, processes and free space are
injected through mockable private functions):

| # | Test |
|---|---|
| 1.1 | A junction planted inside a target, pointing to a canary folder outside the sandbox: canary and its files survive; junction survives; skip reported with reason `Reparse`. |
| 1.2 | A junction replacing a target root's ancestor (e.g. `Autodesk\Revit`): root disqualified, nothing under the link target touched. |
| 1.3 | A file held open with `FileShare.None`: survives; skip reason `Locked`; run result `Partial` or `Success` per policy, never `Failed`. |
| 1.4 | Profile whose owner runs `Revit` (mocked process list): every guarded category skipped for that profile, other profiles cleaned; `user.temp` still cleaned. |
| 1.5 | Age rule with each basis (Created, Modified, Accessed, Newest) on controlled timestamps; Accessed with tracking off falls back to Modified and logs it. |
| 1.6 | KeepNewest N per group; LimitScope Group vs User vs Machine. |
| 1.7 | MaxTotalMB: oldest removed first until under the cap. |
| 1.8 | MaxSharePercent of free and of disk size, with a simulated volume. |
| 1.9 | MinAgeHours and ProtectNewest override every other rule, including pressure. |
| 1.10 | Combination: age + count + size on one tree yields exactly the expected set (OR semantics). |
| 1.11 | Pressure: simulated volume below floor; tiers processed in order, oldest first; stops exactly when the target is reached; 2002 when eligible items run out. |
| 1.12 | ActivateBelow on a routine rule: inactive above, active below. |
| 1.13 | Journal ladder on a synthetic 60-day tree: exact files kept raw, exact entries in each monthly zip, originals removed only after verification; archive expiry by age. |
| 1.14 | Compress verification failure (corrupted entry injected): original kept, failure reported. |
| 1.15 | Copy and Move to a local destination: verified, idempotent, Move deletes the source. |
| 1.16 | Protected patterns: `*.rvt`, `*.dwg`, `*.bak` inside Journals and Temp survive any rule. |
| 1.17 | Budgets: item cap and byte cap stop cleanly with partial totals. |
| 1.18 | Report-only and `-WhatIf`: full plan, zero changes on disk (hash of the sandbox unchanged). |
| 1.19 | Output stream: `Invoke-DeadLoad` emits exactly one object of type `DeadLoad.RunSummary`. |
| 1.20 | No network: web cmdlets and .NET web clients mocked to fail the test if called, a sentinel proxy configured; a full run makes no call. |
| 1.21 | Freed bytes equal the bytes of confirmed deletions (locked file excluded). |
| 1.22 | Integrity: a signed module with a tampered `Defaults.psd1` refuses to run (3003). (Runs in the build after signing.) |

## Phase 2: Configuration and ADMX

Work: settings catalog; config reader (policy > local > defaults, with trace); custom targets
with allowlist; `Get-DeadLoadConfiguration`; `build/New-DeadLoadAdmx.ps1` generating
`policy/DeadLoad.admx` and `policy/en-US/DeadLoad.adml` from the catalog.

Acceptance:

- Every catalog setting appears in the ADMX; the generator is deterministic (re-run, no diff).
- Unit tests: each setting from each source wins in precedence order; out-of-range values
  rejected with 3002; custom target outside the allowlist rejected; `..` rejected.
- Engine reports the effective value and its source for every setting (1003 and `last-run.json`).
- ADMX loads without errors in `gpedit.msc` and GPMC on a test machine; setting a policy changes
  the engine's reported effective config.

## Phase 3: Scheduler, Chocolatey, signing

Work: `Start-DeadLoad.ps1`; `Sync-DeadLoadSchedule`; task XML templates; Chocolatey package
(`deadload.nuspec`, install, uninstall, parameters); legacy MSI retirement; `build/Build.ps1`
(stage, sign, verify, pack).

Acceptance (on a disposable VM, never a production machine):

- Install, upgrade, uninstall all succeed silently, no reboot.
- Three tasks exist in `\DeadLoad\`, run as SYSTEM; a standard user can start OnDemand and cannot
  modify it (`schtasks /Change` denied).
- Event source registered; 1000/1001 appear after a run; `last-run.json` readable by a standard
  user and not writable.
- A VM with the legacy 1.3.5.0 MSI installed ends with it removed.
- `/NoTray`, `/ReportOnly`, `/InstallAdmxLocally`, `/PurgeData` each verified.
- Every `.ps1`, `.psm1`, `.psd1`, `.exe` in the package verifies with `Test-TrustedSigningSignature`
  (signed builds) and the package runs under `AllSigned`.

## Phase 4: Tray

Work: `src/tray` C# WinForms .NET Framework 4.8 app; `Invoke-DeadLoadUserAction.ps1`.

Acceptance:

- A standard (non-admin) user can run every tray action; each action respects its policy switch.
- Request cleanup starts OnDemand (event 4000) without elevation.
- Clean my temp removes only the user's own eligible temp files (4001).
- Collect logs produces a zip with the last N days of journals, worker logs, dumps and AutoCAD
  error logs, readable while Revit runs (4002).
- Low-disk notification fires below the threshold, at most every 4 hours; completion
  notification respects `NotifyOnCompletion`.
- `ShowTray` off: the tray exits at start.

## Phase 5: Pilot (requires separate approval)

Work: three workstations (one heavy Revit user, one low-disk machine, one with several Revit
years). Two weeks report-only, review the decision logs, then two weeks live. Runbook in
`docs/PILOT.md` (written in this phase).

Acceptance: report-only plans reviewed and signed off; after go-live, journals present for the
configured retention, archives created, free space within target, zero protected items touched.

## Phase 6: Rollout

Work: fleet deployment through the organization's Chocolatey feed; GPO linked; RMM monitors
events 1001 (Error level), 2002, 3000, 3003. Optional central journal archive (D11) only after
its privacy decision.

Acceptance: every workstation reports a successful weekly run; RMM alerts only on failure events.
