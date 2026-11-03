# DeadLoad: Product Requirements

Status: draft 0.1, 2026-11-03. Maintainer: Dailen Gunter.

> In structural engineering the dead load is the permanent weight a structure carries.
> DeadLoad removes the dead load Autodesk products leave on engineering workstations,
> and keeps the records worth keeping.

## 1. Problem

Revit and AutoCAD accumulate gigabytes of per-user journals, crash dumps, web and graphics
caches, autosave leftovers, installer extracts and crash reports. The previous answer was a
weekly script run by an RMM that deleted the entire contents of each target folder with no
age check, fetched its deletion list at runtime from an unauthenticated URL, ran as SYSTEM
without reparse-point protection, and destroyed Revit journals that were later needed to
answer a model-integrity question. Its code review is summarized in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), section "Inherited defects".

## 2. Users

| User | Needs |
|---|---|
| Engineer / designer (standard user, no admin) | Enough free disk for Revit and AutoCAD; never lose models, drawings, or unsynchronized cloud work; a way to free space and send logs to support without calling IT |
| IT / MSP technician | One package to deploy; Group Policy to tune; an RMM-readable status; no scripts to babysit |
| Support / BIM manager | Revit journals kept long enough to answer "who did what to this model" |

The first deployment is a structural engineering firm. Its specific values (feed URL, GPO
values, share paths) live only in its GPO and its Chocolatey feed, never in this repository.

## 3. Goals

1. Reclaim disk space used by Autodesk Revit and AutoCAD data on Windows workstations, safely,
   unattended, as SYSTEM.
2. Treat Revit journals as records: keep, compress, and sacrifice only under disk pressure.
3. Retention modeled on log-management systems (logrotate, Windows event log retention,
   Elastic/Graylog index lifecycle): age, count, size, share-of-free-space, free-space floor and
   target, protected minimums, and per-rule actions.
4. No RMM dependency: own scheduled tasks; RMM only deploys and monitors.
5. Every setting manageable by Group Policy, with local configuration and shipped defaults as
   fallbacks, and the effective value and its source always visible.
6. A per-user tray app for self-service, with no admin rights.
7. Distributed through Chocolatey, all code Authenticode-signed.

## 4. Non-goals

- A general-purpose disk cleaner (Windows Storage Sense covers Windows itself).
- Cleaning network shares, or touching models, drawings, families, project files, Revit local
  copies and backups, `.bak` drawing backups, or Desktop Connector workspaces.
- Downloading deletion lists or anything else at runtime.
- Uploading anything off the machine, except an explicitly configured copy/move destination
  (for example the optional central journal archive).
- macOS, Linux, or non-Autodesk applications (custom targets aside).

## 5. Functional requirements

### 5.1 Engine

| ID | Requirement |
|---|---|
| FR-1 | Category-driven cleanup. Built-in categories with stable IDs ship in the signed package (initial set in ARCHITECTURE section 7). |
| FR-2 | Policy may add custom targets only under an allowlist of roots; anything else is rejected and logged. |
| FR-3 | Per-category retention, any combination of: age with basis (created, modified, accessed, newest of); keep newest N; max total size; max share of free space or of disk size; a free-space floor that activates the rule and a target that stops it. |
| FR-4 | Protection that no other rule overrides: minimum age, protected newest K, protected file patterns, protected paths. |
| FR-5 | Actions per rule: delete, compress into an archive, copy, or move to a destination. |
| FR-6 | Disk pressure: below a floor, process pressure tiers in order, oldest first, until a target is reached; report when the target is not reachable. |
| FR-7 | Every decision is logged with the rule that caused it. |
| FR-8 | Report-only mode and `-WhatIf` produce the full plan and change nothing. |
| FR-9 | Revit journals: compress after N days into monthly archives, verify the archive entry before deleting the original, keep a protected minimum, expire archives by age, give up archives and then journals only under pressure. |
| FR-10 | Optional management of Revit's own journal cleanup (`Revit.ini` `[Backups]` `JournalShelfCapacity` / `JournalShelfLife`) so Revit does not delete what DeadLoad is told to keep. |

### 5.2 Safety (as SYSTEM)

| ID | Requirement |
|---|---|
| SR-1 | Never traverse or delete a reparse point (junction, symlink, mount point, cloud placeholder), at any depth, including every ancestor of a target root. |
| SR-2 | Skip a profile's Autodesk categories while that user runs Revit, AutoCAD, Desktop Connector, Navisworks or another guarded process. |
| SR-3 | Skip locked files; re-check existence, attributes, activity and locks at action time. |
| SR-4 | Per-run budgets: time, bytes, item count. Stop cleanly and report partial results. |
| SR-5 | Never touch user data (section 4). Protected patterns apply in every category except where a category is explicitly a cache of those types (collaboration cache). |
| SR-6 | No network access during a run, except to a configured copy/move destination. No HTTP at all. |
| SR-7 | Refuse to run with a shipped defaults file whose signature does not match the module's signer. |
| SR-8 | Configuration and state are read only from locations standard users cannot write. |

### 5.3 Scheduling and monitoring

| ID | Requirement |
|---|---|
| FR-11 | Scheduled tasks: weekly Maintenance, daily PressureCheck (also triggered by low-disk events), and OnDemand that users may start but not edit. |
| FR-12 | Schedule days and times are policy-controlled. |
| FR-13 | Windows event log source with stable event IDs (ARCHITECTURE section 10). |
| FR-14 | JSON last-run report readable by standard users and by an RMM without running the engine. |

### 5.4 Tray app (per user, no admin)

| ID | Requirement |
|---|---|
| FR-15 | Shows free space, last run time and result, and pressure state. |
| FR-16 | Actions: clean my temp files; request a cleanup (starts OnDemand); collect my Revit/AutoCAD logs for support; open my journals folder; view last report. |
| FR-17 | Low-disk and cleanup-completed notifications, policy-controlled. |
| FR-18 | Every action can be hidden or disabled by user or machine policy. |

### 5.5 Configuration

| ID | Requirement |
|---|---|
| FR-19 | ADMX/ADML covering every setting: machine policy for the engine and tray, user policy for the tray. |
| FR-20 | Precedence: policy > local configuration > shipped defaults. The effective value and its source are logged every run and available on demand. |

### 5.6 Packaging

| ID | Requirement |
|---|---|
| FR-21 | Chocolatey package: install, upgrade, uninstall, package parameters. |
| FR-22 | All scripts, modules, data files and binaries Authenticode-signed. |
| FR-23 | Retire the legacy Get-FreeSpace 1.3.5.0 MSI and its remnants. |

## 6. Non-functional requirements

| ID | Requirement |
|---|---|
| NFR-1 | Windows 10 21H2+ and Windows 11; Windows PowerShell 5.1 and PowerShell 7 for the engine; .NET Framework 4.8 for the tray. |
| NFR-2 | A routine run finishes within its time budget (default 20 minutes) on a heavy workstation. |
| NFR-3 | The engine's output stream is exactly one summary object. |
| NFR-4 | 7-bit ASCII source, American English in code, docs and UI. |
| NFR-5 | Pester suite green on 5.1 and 7, including the safety tests listed in [docs/PLAN.md](docs/PLAN.md). |
| NFR-6 | Install and uninstall need no reboot. |

## 7. Success measures

- Pilot: after two weeks report-only and two weeks live, journals exist for the configured
  retention on every pilot machine, archives are created, free space stays above the target,
  and no protected item was touched (verified from the decision log).
- Fleet: every workstation reports a successful weekly run; RMM alerts on failure events only.

## 8. Decisions

Resolved and proposed decisions, with rationale, are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), section 2. Open items needing the owner are
listed there under "Open".
