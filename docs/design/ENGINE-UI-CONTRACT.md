# Engine to UI contract: the user's cleanup review (Analyze, Review, Clean)

Status: implemented in design slice 3 (2026-11-04). Decisions: ARCHITECTURE D22 (risk tiers),
D23 (Clean deletes only what was reviewed), D24 (review run semantics), D26 (where the files
live). The DeadLoad window (slice 4) is built against this file only.

The window never deletes anything itself and never elevates. It starts
`Invoke-DeadLoadUserAction.ps1` in the signed-in user's own context, reads one JSON line from
stdout, and reads the two JSON files that line points to.

## 1. Commands

Always Windows PowerShell 5.1, never a profile, never an inline `-Command`:

```
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<InstallRoot>\engine\Invoke-DeadLoadUserAction.ps1" -Action Analyze

%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<InstallRoot>\engine\Invoke-DeadLoadUserAction.ps1" -Action Clean -Categories user.temp,autodesk.cer -AnalysisId <analysisId>
```

| Argument | Action | Meaning |
|---|---|---|
| `-Action Analyze` | | Report-only scan of the current user's own profile; writes `analysis.json`. |
| `-Action Clean` | | Deletes the reviewed items of the named categories that a fresh plan still selects. |
| `-Categories <ids>` | Clean (required) | The category ids the user left checked, comma-separated, as **one** argument (`-File` passes `a,b` as one string; the script splits it). No spaces. |
| `-AnalysisId <id>` | Clean (recommended) | The `analysisId` the user reviewed. If `analysis.json` was replaced since (another Analyze), the Clean is refused instead of cleaning a list the user never saw. |
| `-AnalysisPath <file>` | both (optional) | Default `%LOCALAPPDATA%\DeadLoad\analysis.json`. Analyze writes there, Clean reads it; its folder also receives `last-cleanup.json` and the user run's report and log. The window passes nothing. |

`<InstallRoot>` is the tray's `TrayPaths.InstallRoot` (`%ProgramFiles%\DeadLoad`). Run one action at
a time; disable Analyze and Clean while either runs. Use a generous timeout (minutes: a large temp
folder takes a while to enumerate) and kill the process on timeout, as `UserActionRunner` does.

## 2. Output and exit codes

stdout carries exactly one compact JSON object on one line. Non-ASCII characters are escaped as
`\uXXXX`, so stdout is 7-bit ASCII whatever the code page. Read the last line that starts with `{`;
ignore anything else (a broken machine profile or a host banner could print before it). Verbose
prose goes nowhere unless `-Verbose` is passed; warnings are counted into `Message`.

| Exit code | Meaning | stdout |
|---|---|---|
| 0 | The action was handled. Look at `Result` (it may be `Disabled`, `Partial`, `ReportOnly`, even `Failed` when the engine itself reported a failed run). | One JSON object. |
| 1 | The script failed (module missing, exception). `Result` is `Failed`, `Message` is the error text. | One JSON object. |
| 2 | Clean was refused: nothing was deleted and no report was written. `Result` is `Refused`, `Message` says why. | One JSON object. |
| other, or no JSON | PowerShell itself failed before the script ran (for example a parameter that does not bind). Treat as `Failed`; show stderr in Details. | None. |

The object has a fixed set of properties per action; every property is always present.

| Action | Properties |
|---|---|
| Analyze | `Action`, `Result`, `Message`, `Path`, `AnalysisId`, `EstimatedBytes`, `ItemCount` |
| Clean | `Action`, `Result`, `Message`, `Path`, `FreedBytes`, `DeletedCount`, `SkippedCount` |

`Result` values:

| Result | Analyze | Clean | What the window does |
|---|---|---|---|
| `Success` | Scan complete. | Every reviewed item of the named categories was deleted (or there was nothing to delete). | Show results / Complete. |
| `Partial` | The scan stopped early (time or item budget); the list is what was found so far. | Some reviewed items were deleted, some skipped or failed; `last-cleanup.json` lists each with its reason. | Show Complete with the skipped list. |
| `ReportOnly` | n/a | Report-only mode is on by policy; nothing was deleted, every item is in `skipped` with reason `ReportOnly`. | Explain; Analyze already said so (`reportOnly: true`). |
| `Refused` | n/a | The request was refused as a whole (exit 2). | Show `Message`; offer Analyze again. |
| `Disabled` | Either policy turned the action off (`Tray.AllowCleanTemp` 0: `Path` null, nothing written), or the engine is off (`General.Enabled` 0: `analysis.json` written with `result: Disabled` and no items). | Same two cases; nothing deleted. | Show `Message`; hide Analyze and Clean while policy says off. |
| `Failed` | The engine run failed; `analysis.json` still describes the categories, with no items. | The run failed; `last-cleanup.json` lists what was deleted before it failed. | Show `Message`; offer Analyze again; Details shows the report. |

Policy: `Tray.AllowCleanTemp` gates Analyze and Clean, as it gates "Clean my temp files" (one
switch for every way a user cleans their own files). The window reads the same tray policy to
decide whether to show the actions, but the script re-reads it and answers `Disabled` regardless.

## 3. Analyze

Real output (section 9 says how it was captured):

Exit code 0:

```json
{"Action":"Analyze","Result":"Success","Message":"An estimated 8.0 MB in 5 item(s) can be cleaned.","Path":"C:\\Users\\alice\\AppData\\Local\\DeadLoad\\analysis.json","AnalysisId":"20261104T162738Z-8a94343b","EstimatedBytes":8396800,"ItemCount":5}
```

`EstimatedBytes` and `ItemCount` are the totals over every **available** category (Routine and
Review), not only the preselected ones; `analysis.json` has both.

### analysis.json

Written atomically (write then rename) to `Path`, UTF-8 without a byte order mark. Every Analyze
replaces it. Ignore properties you do not know: fields may be added; `schemaVersion` changes only
when a field changes meaning or is removed.

| Field | Type | Meaning |
|---|---|---|
| `schemaVersion` | int | 1. |
| `analysisId` | string | Pass it to Clean as `-AnalysisId`. Also the engine run id (`runs\<id>.json`). |
| `createdUtc` | string | ISO 8601 UTC end of the scan. |
| `result`, `reason` | string | As stdout `Result`; `reason` is the engine's reason text or null. |
| `reportOnly` | bool | Policy report-only mode: Clean will delete nothing. Disable Clean and say why. |
| `volume` | object or null | `drive`, `sizeBytes`, `freeBytes` of the system volume at scan time (for the capacity bar; state the denominator). |
| `totals` | object | `itemCount`, `estimatedBytes` (every available category), `selectedItemCount`, `selectedBytes` (the Routine categories, which start checked). |
| `categories` | array | One entry per enabled category of the user's own profile, in engine order. Machine-wide and disabled categories are not listed (machine-wide ones come from the last SYSTEM report, read-only). |

Category entry:

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Category id; what Clean takes. |
| `displayName`, `description` | string | User-facing title and explanation (from `Data\Defaults.psd1`, the same text the ADMX shows). |
| `risk` | string | `Routine`, `Review` or `Restricted` (risk badge: icon plus text label). |
| `riskText` | string | One sentence explaining the tier. |
| `available` | bool | False: show the row disabled, unchecked, with `unavailableText`; never send it to Clean. |
| `unavailableReason` | string or null | `Restricted`, `MachineScope` or `NotDelete` (an administrator's target that copies or moves instead of deleting). |
| `unavailableText` | string or null | Plain-language reason for an unavailable row. |
| `defaultSelected` | bool | Initial checkbox state: true only for available Routine categories. Review starts unchecked. |
| `ageDays`, `ageBasis` | number, string | The effective age rule (after the `Tray.CleanTempMinAgeDays` floor); null when not available. |
| `itemCount`, `estimatedBytes` | int, int | Items selected now and the sum of their sizes. |
| `guardedSkipped` | object or null | Files held back because Revit or AutoCAD is running in this session: `reason` (`Process`), `itemCount`, `bytes` (all such files, not only those the rule would pick), `message`. Show `message`; the items are not in `items`. |
| `items` | array | The reviewable items, largest first. Empty for unavailable rows. |

Item entry:

| Field | Type | Meaning |
|---|---|---|
| `path` | string | Full path (the user's own profile). Show shortened, full on demand, copyable. |
| `kind` | string | `File` or `Folder` (a folder judged as one unit, for example a crash report folder). |
| `bytes` | int | Size at scan time (a folder: the files inside). |
| `lastWriteUtc` | string | ISO 8601 UTC last write (a folder: newest inside). Show as age. |
| `reason`, `reasonText` | string | Why it is selected: rule ids joined by `+` (`AgeDays`, `KeepNewest`, `MaxTotalMB`, `MaxSharePercent`) and the sentence to show. |
| `fingerprint` | string | Opaque. Do not show, parse or change it. |
| `fileCount`, `files` | int, array | Folder items only: the files measured inside (`path`, `bytes`, `fingerprint`). Only these files can be deleted. |

Never edit or rewrite `analysis.json`. The window does not need to: Clean reads it itself.

Real `analysis.json` from the same run (whitespace reformatted, see section 9):

```json
{
  "schemaVersion": 1,
  "product": "DeadLoad",
  "version": "0.1.0",
  "analysisId": "20261104T162738Z-8a94343b",
  "createdUtc": "2026-11-04T16:27:40.9493410Z",
  "result": "Success",
  "reason": null,
  "reportOnly": false,
  "volume": {
    "drive": "C:\\",
    "sizeBytes": 511101235200,
    "freeBytes": 44023414784
  },
  "totals": {
    "itemCount": 5,
    "estimatedBytes": 8396800,
    "selectedItemCount": 4,
    "selectedBytes": 6299648
  },
  "categories": [
    {
      "id": "revit.journals",
      "displayName": "Revit journals",
      "description": "Session logs Revit writes every time it runs. Support uses them to diagnose problems, and Revit may save backup copies of models beside them.",
      "risk": "Restricted",
      "riskText": "Restricted: never offered in the user's cleanup review; only the scheduled runs act on it, as policy configures.",
      "available": false,
      "unavailableReason": "Restricted",
      "unavailableText": "Only the scheduled maintenance can clean this category.",
      "defaultSelected": false,
      "ageDays": null,
      "ageBasis": null,
      "itemCount": 0,
      "estimatedBytes": 0,
      "guardedSkipped": null,
      "items": []
    },
    {
      "id": "revit.journals.archive",
      "displayName": "Revit journal archives",
      "description": "Monthly zip archives of compressed Revit journals, kept as support records.",
      "risk": "Restricted",
      "riskText": "Restricted: never offered in the user's cleanup review; only the scheduled runs act on it, as policy configures.",
      "available": false,
      "unavailableReason": "Restricted",
      "unavailableText": "Only the scheduled maintenance can clean this category.",
      "defaultSelected": false,
      "ageDays": null,
      "ageBasis": null,
      "itemCount": 0,
      "estimatedBytes": 0,
      "guardedSkipped": null,
      "items": []
    },
    {
      "id": "revit.webcache",
      "displayName": "Revit web cache",
      "description": "Browser cache of the Revit sign-in, start and help pages. Revit rebuilds it, so pages may load slower the next time.",
      "risk": "Review",
      "riskText": "Review: offered but not selected in the user's cleanup review; removing them can cause reprocessing or a download.",
      "available": true,
      "unavailableReason": null,
      "unavailableText": null,
      "defaultSelected": false,
      "ageDays": 14,
      "ageBasis": "Newest",
      "itemCount": 1,
      "estimatedBytes": 2097152,
      "guardedSkipped": null,
      "items": [
        {
          "path": "C:\\Users\\alice\\AppData\\Local\\Autodesk\\Revit\\Autodesk Revit 2026\\WebBrowserControl\\EBWebView\\Default\\Cache\\Cache_Data\\data_1",
          "kind": "File",
          "bytes": 2097152,
          "lastWriteUtc": "2026-10-15T16:27:37.4523288Z",
          "reason": "AgeDays",
          "reasonText": "Not used in the last 14 days.",
          "fingerprint": "2097152:639276784574523288"
        }
      ]
    },
    {
      "id": "revit.paccache",
      "displayName": "Revit content cache",
      "description": "Content Revit downloaded and keeps locally (PacCache). Revit downloads it again when it is needed.",
      "risk": "Review",
      "riskText": "Review: offered but not selected in the user's cleanup review; removing them can cause reprocessing or a download.",
      "available": true,
      "unavailableReason": null,
      "unavailableText": null,
      "defaultSelected": false,
      "ageDays": 7,
      "ageBasis": "Newest",
      "itemCount": 0,
      "estimatedBytes": 0,
      "guardedSkipped": null,
      "items": []
    },
    {
      "id": "revit.ini.journalshelf",
      "displayName": "Revit journal retention setting",
      "description": "Raises how long Revit itself keeps journals (Revit.ini). A setting change, not a file cleanup.",
      "risk": "Restricted",
      "riskText": "Restricted: never offered in the user's cleanup review; only the scheduled runs act on it, as policy configures.",
      "available": false,
      "unavailableReason": "Restricted",
      "unavailableText": "Only the scheduled maintenance can clean this category.",
      "defaultSelected": false,
      "ageDays": null,
      "ageBasis": null,
      "itemCount": 0,
      "estimatedBytes": 0,
      "guardedSkipped": null,
      "items": []
    },
    {
      "id": "autodesk.cer",
      "displayName": "Autodesk crash reports",
      "description": "Reports the Autodesk crash reporter kept after a program closed unexpectedly. The newest reports are kept.",
      "risk": "Routine",
      "riskText": "Routine: offered and selected by default in the user's cleanup review; files that programs recreate or no longer need.",
      "available": true,
      "unavailableReason": null,
      "unavailableText": null,
      "defaultSelected": true,
      "ageDays": 30,
      "ageBasis": "Newest",
      "itemCount": 1,
      "estimatedBytes": 1581056,
      "guardedSkipped": null,
      "items": [
        {
          "path": "C:\\Users\\alice\\AppData\\Local\\Autodesk\\CER\\6e9a41c",
          "kind": "Folder",
          "bytes": 1581056,
          "lastWriteUtc": "2026-09-20T16:27:37.6092186Z",
          "reason": "AgeDays",
          "reasonText": "Not used in the last 30 days.",
          "fingerprint": "1581056:639255184576092186",
          "fileCount": 2,
          "files": [
            {
              "path": "C:\\Users\\alice\\AppData\\Local\\Autodesk\\CER\\6e9a41c\\cer.log",
              "bytes": 8192,
              "fingerprint": "8192:639255184576077036"
            },
            {
              "path": "C:\\Users\\alice\\AppData\\Local\\Autodesk\\CER\\6e9a41c\\report.dmp",
              "bytes": 1572864,
              "fingerprint": "1572864:639255184576040001"
            }
          ]
        }
      ]
    },
    {
      "id": "autodesk.installlogs",
      "displayName": "Autodesk installer logs",
      "description": "Logs written while Autodesk products were installed or updated. The newest logs are kept.",
      "risk": "Routine",
      "riskText": "Routine: offered and selected by default in the user's cleanup review; files that programs recreate or no longer need.",
      "available": true,
      "unavailableReason": null,
      "unavailableText": null,
      "defaultSelected": true,
      "ageDays": 90,
      "ageBasis": "Modified",
      "itemCount": 0,
      "estimatedBytes": 0,
      "guardedSkipped": null,
      "items": []
    },
    {
      "id": "user.temp",
      "displayName": "Temporary files",
      "description": "Files programs left in the temp folder. Files of a Revit or AutoCAD session that is still running are kept.",
      "risk": "Routine",
      "riskText": "Routine: offered and selected by default in the user's cleanup review; files that programs recreate or no longer need.",
      "available": true,
      "unavailableReason": null,
      "unavailableText": null,
      "defaultSelected": true,
      "ageDays": 7,
      "ageBasis": "Newest",
      "itemCount": 3,
      "estimatedBytes": 4718592,
      "guardedSkipped": null,
      "items": [
        {
          "path": "C:\\Users\\alice\\AppData\\Local\\Temp\\{4B1E}\\payload.cab",
          "kind": "File",
          "bytes": 3145728,
          "lastWriteUtc": "2026-10-05T16:27:37.4376994Z",
          "reason": "AgeDays",
          "reasonText": "Not used in the last 7 days.",
          "fingerprint": "3145728:639268144574376994"
        },
        {
          "path": "C:\\Users\\alice\\AppData\\Local\\Temp\\setup-7f3c.log",
          "kind": "File",
          "bytes": 1048576,
          "lastWriteUtc": "2026-10-14T16:27:37.4105749Z",
          "reason": "AgeDays",
          "reasonText": "Not used in the last 7 days.",
          "fingerprint": "1048576:639275920574105749"
        },
        {
          "path": "C:\\Users\\alice\\AppData\\Local\\Temp\\export-preview.tmp",
          "kind": "File",
          "bytes": 524288,
          "lastWriteUtc": "2026-10-23T16:27:37.4418833Z",
          "reason": "AgeDays",
          "reasonText": "Not used in the last 7 days.",
          "fingerprint": "524288:639283696574418833"
        }
      ]
    }
  ]
}
```

In this example `revit.paccache` and `autodesk.installlogs` are available with nothing to clean
(`itemCount` 0): show them as empty rows or hide them, but do not show them as errors.

## 4. Clean

Send the ids of the rows the user left checked, after the confirmation dialog. A Restricted or
unavailable id is a bug in the window: the engine refuses the whole request (nothing is deleted).

Real output of the Clean that followed the Analyze above. Between the two, one reviewed temp file
was opened again (`export-preview.tmp`, now newer than the age floor), one was held open by a
program (`setup-7f3c.log`) and a new old file appeared (`late.tmp`, not in the analysis, so not
deleted and not reported):

Exit code 0:

```json
{"Action":"Clean","Result":"Partial","Message":"Recovered 4.5 MB; 2 item(s) were skipped.","Path":"C:\\Users\\alice\\AppData\\Local\\DeadLoad\\last-cleanup.json","FreedBytes":4726784,"DeletedCount":2,"SkippedCount":2}
```

### last-cleanup.json

Written atomically beside `analysis.json` (`Path`) for every Clean that was not refused; a refusal
leaves the previous report in place and returns `Path` null.

| Field | Type | Meaning |
|---|---|---|
| `schemaVersion` | int | 1. |
| `cleanupId` | string or null | The engine run id (`runs\<id>.json`); null when the engine did not run (nothing to clean). |
| `analysisId` | string | The analysis it cleaned from. |
| `startUtc`, `endUtc` | string | ISO 8601 UTC. |
| `result`, `reason` | string | As stdout `Result`; `reason` is null or an explanation. |
| `categories` | array | The ids requested. |
| `estimatedBytes` | int | The analysis estimate for those categories ("Recovered X of an estimated Y"). |
| `freedBytes` | int | **Recovered**: bytes of the files actually deleted. |
| `deletedCount`, `skippedCount`, `failedCount` | int | Items deleted (fully or partly), items not (fully) deleted, of which failures. |
| `volume` | object or null | `drive`, `freeBytesBefore`, `freeBytesAfter` read by the run. |
| `deleted` | array | `category`, `path`, `kind`, `bytes` (bytes recovered from that item). |
| `skipped` | array | `category`, `path`, `kind`, `bytes` (bytes left), `reason`, `reasonText`. |

A folder item partly deleted (one file in use) appears in both lists: in `deleted` with the bytes
recovered, in `skipped` with the bytes left and the reason.

Real `last-cleanup.json` of that Clean (whitespace reformatted):

```json
{
  "schemaVersion": 1,
  "product": "DeadLoad",
  "version": "0.1.0",
  "cleanupId": "20261104T162741Z-e2ce4fba",
  "analysisId": "20261104T162738Z-8a94343b",
  "startUtc": "2026-11-04T16:27:41.5817790Z",
  "endUtc": "2026-11-04T16:27:42.6518816Z",
  "result": "Partial",
  "reason": null,
  "categories": [
    "user.temp",
    "autodesk.cer"
  ],
  "estimatedBytes": 6299648,
  "freedBytes": 4726784,
  "deletedCount": 2,
  "skippedCount": 2,
  "failedCount": 0,
  "volume": {
    "drive": "C:\\",
    "freeBytesBefore": 44023414784,
    "freeBytesAfter": 44023414784
  },
  "deleted": [
    {
      "category": "autodesk.cer",
      "path": "C:\\Users\\alice\\AppData\\Local\\Autodesk\\CER\\6e9a41c",
      "kind": "Folder",
      "bytes": 1581056
    },
    {
      "category": "user.temp",
      "path": "C:\\Users\\alice\\AppData\\Local\\Temp\\{4B1E}\\payload.cab",
      "kind": "File",
      "bytes": 3145728
    }
  ],
  "skipped": [
    {
      "category": "user.temp",
      "path": "C:\\Users\\alice\\AppData\\Local\\Temp\\export-preview.tmp",
      "kind": "File",
      "bytes": 524288,
      "reason": "MinAgeHours",
      "reasonText": "Used too recently."
    },
    {
      "category": "user.temp",
      "path": "C:\\Users\\alice\\AppData\\Local\\Temp\\setup-7f3c.log",
      "kind": "File",
      "bytes": 1048576,
      "reason": "Locked",
      "reasonText": "In use by a program."
    }
  ]
}
```

## 5. Estimated and recovered

| Number | Source | Label |
|---|---|---|
| Analyze `EstimatedBytes`, `totals.estimatedBytes`, category `estimatedBytes`, sum of checked rows | Sizes of the items selected at scan time | **Estimated** |
| Clean `FreedBytes`, `freedBytes`, `deleted[].bytes` | Bytes of files the engine confirmed deleted | **Recovered** |
| `volume.freeBytes*` | Free space readings of the volume | Capacity only; never shown as recovered (other programs write at the same time, and cluster rounding differs) |

The window shows "Estimated" before Clean and "Recovered" after it, never one number for both.
No claim of reversibility: deleted files are not in the Recycle Bin.

## 6. Reasons

`reason` ids of skipped items (`reasonText` carries the sentence to show):

| Id | Meaning |
|---|---|
| `Locked` | In use by a program (an exclusive open failed). |
| `MinAgeHours` | Used too recently (newer than the protection age, which includes `Tray.CleanTempMinAgeDays`). |
| `ChangedSinceAnalysis` | Its size or write time changed after it was reviewed. |
| `Changed` | Changed while the cleanup ran. |
| `Missing` | No longer found (deleted by someone else, or no longer part of the category). |
| `NotSelected` | No longer matches the cleanup rule. |
| `Process` | Revit or AutoCAD is running in this session. |
| `ProtectNewest` | One of the newest of its group, which are kept. |
| `ProtectedPattern` | A design or project file type, which is never removed. |
| `Reparse`, `OutsideAnchor` | A link, or a folder that moved: never followed. |
| `ReportOnly` | Report-only mode: nothing was deleted. |
| `Budget` | The run reached its time, item or size limit. |
| `Failed` | The delete failed. |

Other ids may appear; show `reasonText`.

## 7. Refusals and other edge cases

Real outputs:

Restricted category named (`-Categories revit.journals`). Exit code 2:

```json
{"Action":"Clean","Result":"Refused","Message":"Nothing was deleted: Category revit.journals cannot be cleaned here: Restricted.","Path":null,"FreedBytes":0,"DeletedCount":0,"SkippedCount":0}
```

Analysis replaced since review (`-AnalysisId` does not match). Exit code 2:

```json
{"Action":"Clean","Result":"Refused","Message":"Nothing was deleted: The analysis changed since it was reviewed; run Analyze again.","Path":null,"FreedBytes":0,"DeletedCount":0,"SkippedCount":0}
```

Turned off by policy (`Tray.AllowCleanTemp` 0), Analyze. Exit code 0:

```json
{"Action":"Analyze","Result":"Disabled","Message":"This action is turned off by your administrator.","Path":null,"AnalysisId":null,"EstimatedBytes":0,"ItemCount":0}
```

Turned off by policy, Clean. Exit code 0:

```json
{"Action":"Clean","Result":"Disabled","Message":"This action is turned off by your administrator.","Path":null,"FreedBytes":0,"DeletedCount":0,"SkippedCount":0}
```

Other refusals (exit 2, `Result` `Refused`): no `-Categories`; no `analysis.json`; an unreadable or
unknown-format analysis; a category that is unknown, turned off since the review, machine-wide,
not deleting, or not available in the analysis. Nothing is ever partly done on a refusal.

Nothing to clean (the named categories had no items): exit 0, `Result` `Success`, `FreedBytes` 0,
`last-cleanup.json` with `reason` "Nothing to clean in the selected categories."

## 8. Guarantees the window can rely on

- Only the current user's own profile is scanned or changed; other profiles are never read.
- Clean deletes only items that are both in the reviewed analysis (same size and write time) and
  selected by a fresh plan at clean time; a new file, including one added inside a reviewed folder,
  is never deleted. Editing `analysis.json` cannot widen a cleanup.
- Restricted and machine-wide categories are never cleaned through this path. Restricted ones are
  not cleaned by any user-started action either, "Clean my temp files" (`-Action CleanTemp`)
  included (ARCHITECTURE D25).
- Deletion uses the engine's own re-check and primitive (ARCHITECTURE section 8): locked, changed,
  linked and protected files are skipped and reported, never forced.
- `analysis.json` and `last-cleanup.json` hold full paths and stay in the user's own
  `%LOCALAPPDATA%\DeadLoad`; the run reports beside them (`last-user-action.json`, `runs\`) and the
  event log keep profile aliases only. Clean writes Application event 4003 when the event source is
  registered.

## 9. How the examples were captured

From a run of the real `Invoke-DeadLoadUserAction.ps1` and the real engine under Windows PowerShell
5.1 on 2026-11-04, against a test sandbox: a throwaway profile `alice` under `%TEMP%` with files
created at controlled ages, the profile, process list, free space and machine paths injected
through the module's test seams (as in `tests\Engine.UserFlow.Tests.ps1`), the tray policy through
`DEADLOAD_TEST_TRAYPOLICY`, and `-AnalysisPath` inside the sandbox. In the text above the sandbox
folder is shown as `C:\` and its data folder as `C:\Users\alice\AppData\Local\DeadLoad`; JSON
files were re-indented (Windows PowerShell writes the same content with wider indentation). Values,
field order and stdout lines are otherwise as produced.

## 10. Configuration (the window's Settings page)

Added in design slice 4. Read-only: it reports the effective configuration and changes nothing.

```
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<InstallRoot>\engine\Invoke-DeadLoadUserAction.ps1" -Action Configuration
```

| Argument | Meaning |
|---|---|
| `-OutputPath <file>` | Optional. Default `%LOCALAPPDATA%\DeadLoad\configuration.json`. The window passes nothing. |

No policy switch gates it (it only reads what policy says, `Tray.AllowCleanTemp` included). It runs
`Get-DeadLoadConfiguration -Trace`, writes the rows to the file (write then rename, UTF-8 without a
byte order mark) and prints one JSON line: the rows (about 300 on a default install) do not belong
on stdout. Exit codes as in section 2 (0 handled, 1 failed; never 2).

| Property | Meaning |
|---|---|
| `Action`, `Result`, `Message` | As section 2; `Result` is `Success` or `Failed`. |
| `Path` | The file written; null on failure (no file is written then). |
| `EngineVersion` | The loaded module's version. |
| `SettingCount`, `RejectedCount` | Rows in effect, and values ignored as invalid. |

`configuration.json`: `schemaVersion` (1), `product`, `engineVersion`, `createdUtc`, and `settings`,
one entry per trace row in engine order: `name` (the registry path below `DeadLoad`, for example
`Pressure\FloorGB` or `Categories\user.temp\AgeDays`; General settings have no prefix), `value`
(a string; lists joined with `; `), `source` (`Policy`, `UserPolicy`, `Local`, `Default`, or
`Rejected:<source>` for a value ignored as invalid) and `reason` (why a value was rejected, else null).

Real output of the real script and engine under Windows PowerShell 5.1 on 2026-11-04, on a machine
with no DeadLoad policy set. The run passed `-OutputPath` to a temporary folder; `Path` is shown here
as the default location with the profile folder as `alice`. Only the first rows of the file:

```json
{"Action":"Configuration","Result":"Success","Message":"315 setting(s) read; 0 value(s) ignored.","Path":"C:\\Users\\alice\\AppData\\Local\\DeadLoad\\configuration.json","EngineVersion":"0.1.0","SettingCount":315,"RejectedCount":0}
```

```json
[{"name":"Enabled","value":"1","source":"Default","reason":null},{"name":"ReportOnly","value":"0","source":"Default","reason":null},{"name":"TimeBudgetMinutes","value":"20","source":"Default","reason":null}]
```
