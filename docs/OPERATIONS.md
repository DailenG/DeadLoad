# DeadLoad operations

How to build, sign, install, upgrade, configure, monitor and remove DeadLoad. Design and
rationale: [ARCHITECTURE.md](ARCHITECTURE.md) sections 10 to 13. Requirements: PRD FR-21 to FR-23.

## 1. Build

```powershell
pwsh -NoProfile -File build\Build.ps1 [-Configuration Release] [-OutputPath out] [-NoSign] [-SkipTray] [-StageOnly]
```

| Step | What happens |
|---|---|
| Tray | `dotnet build src\tray\DeadLoadTray.csproj -c <Configuration>` into `out\tray`. Missing project or SDK fails the build unless `-SkipTray`. |
| Policy | `build\New-DeadLoadAdmx.ps1` writes the templates straight into the stage (the committed `policy\` copy is used only when the generator is absent). |
| Stage | `out\stage\engine\DeadLoad\`, `engine\Start-DeadLoad.ps1`, `engine\Invoke-DeadLoadUserAction.ps1`, `tray\DeadLoadTray.exe` (+ `.config`, any `.dll`), `policy\`. An entry script that does not exist yet is a warning and is named in the summary. `-StageOnly` stops here. |
| Pack copy | `out\pack` = the nuspec, `packaging\chocolatey\tools\` and the stage as `tools\payload\`. A `<name>.exe.ignore` marker is written beside every exe so Chocolatey does not put the tray on PATH. The repository is never modified. |
| Sign | Every `.ps1`, `.psm1`, `.psd1`, `.exe` and `.dll` under `out\pack\tools` (payload and Chocolatey scripts) is signed, then verified twice; see section 8. |
| Pack | `choco pack` into `out\` when `choco` is on PATH. |

The nuspec version must equal `ModuleVersion` in `src\engine\DeadLoad\DeadLoad.psd1`; the build
refuses a mismatch (bump both together). The build ends with a summary line (version, signed
yes/no, file count, package path) and returns the same facts as an object.

## 2. Install

```powershell
choco install deadload --source <folder or feed> -y [--params "'/NoTray /ReportOnly'"]
```

Chocolatey runs `tools\chocolateyInstall.ps1` elevated under Windows PowerShell 5.1 (64-bit; a
32-bit host is refused because it would write the wrong registry view and Program Files). In
order, every step idempotent:

1. Legacy retirement (FR-23): if the Get-FreeSpace MSI `{DCD33BCE-C996-4E9B-9044-B77CCCB33EAD}`
   has an uninstall entry (64-bit or WOW6432Node view), `msiexec.exe /x {GUID} /qn /norestart`
   runs with a verbose log in `%TEMP%\DeadLoad-legacy-msi-uninstall.log`. Exit 0 and 1605 are
   success; 3010 is success with a warning and no restart; anything else fails the install.
   `%ProgramFiles%\Get-FreeSpace` and `%ProgramFiles(x86)%\Get-FreeSpace` are removed when
   present, refused (and kept, with a warning) if the folder or any subfolder is a reparse
   point. Root-folder scheduled tasks whose name contains `FreeSpace` are removed only when an
   action runs a `Get-FreeSpace` script.
2. Program files: `engine`, `tray` and `policy` are copied to `%ProgramFiles%\DeadLoad` as
   `<folder>.new-<id>` siblings and swapped in by rename, so a task never sees a half-copied
   engine. A folder held open by a running tray is updated file by file instead; the in-use file
   is renamed `*.dlold-<id>` and removed by the next install. Nothing else in the folder is
   touched.
3. `%ProgramData%\DeadLoad` is created or re-secured: inheritance broken, SYSTEM and
   Administrators full control, Users read and execute, owner Administrators (by SID). Its
   content is never touched.
4. Event source `DeadLoad` in the Application log is registered if missing.
5. `HKLM\SOFTWARE\DeadLoad`: `Version` and `InstallPath` (REG_SZ); `ReportOnly` = 1 (REG_DWORD)
   with `/ReportOnly`.
6. Tray: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` value `DeadLoadTray` = the quoted
   exe path, unless `/NoTray` (which removes the value). A running tray is never stopped.
7. `/InstallAdmxLocally`: `DeadLoad.admx` and `en-US\DeadLoad.adml` into
   `%SystemRoot%\PolicyDefinitions`.
8. Tasks: the installed module's `Sync-DeadLoadSchedule -Register -InstallPath <dir>` creates or
   replaces `\DeadLoad\Maintenance`, `PressureCheck` and `OnDemand` (all SYSTEM).

No step restarts the machine or interrupts a signed-in user.

## 3. Package parameters

| Parameter | Install / upgrade | Uninstall |
|---|---|---|
| `/NoTray` | Do not start the tray at sign-in; removes an existing Run value. | - |
| `/ReportOnly` | Sets local `ReportOnly` = 1: scan, plan and report, delete nothing. Without it an existing value is left as it is (remove it by hand or set the policy). | - |
| `/InstallAdmxLocally` | Copies the templates into the local PolicyDefinitions folder. | - |
| `/PurgeData` | Ignored (a message says so). | Also removes `%ProgramData%\DeadLoad` and the whole `HKLM\SOFTWARE\DeadLoad` key. |

An unknown parameter is a warning, not a failure; a parameter with an unreadable value
(`/ReportOnly:maybe`) fails the run. Parameters are not remembered between runs: pass them again
on every upgrade (or use `choco feature enable -n useRememberedArgumentsForUpgrades`).

## 4. Upgrade

```powershell
choco upgrade deadload --source <folder or feed> -y [--params "'/NoTray'"]
```

The same install script runs again: the payload is swapped in, the ACL and registry values
re-applied and the tasks replaced from the effective schedule. Reports, logs and local settings
are kept.

## 5. Uninstall

```powershell
choco uninstall deadload -y [--params "'/PurgeData'"]
```

Removes the three tasks and the `\DeadLoad\` task folder (through the installed module), the
tray Run value, the event source and `%ProgramFiles%\DeadLoad`. `HKLM\SOFTWARE\DeadLoad` loses
`Version` and `InstallPath`; the key goes only when nothing else is in it, or with `/PurgeData`.
`%ProgramData%\DeadLoad` (reports and logs) is kept unless `/PurgeData`.
`HKLM\SOFTWARE\Policies\DeadLoad` belongs to Group Policy and is never touched. If a user still
has the tray running, its folder cannot be fully removed; the uninstall warns and the leftover can
be deleted after the user signs out.

## 6. Group Policy templates

The package carries the templates in `%ProgramFiles%\DeadLoad\policy\`. In a domain, copy them to
the central store once per version, from any machine with the package installed:

```powershell
$store = '\\<your domain>\SYSVOL\<your domain>\Policies\PolicyDefinitions'
Copy-Item -LiteralPath "$env:ProgramFiles\DeadLoad\policy\DeadLoad.admx" -Destination $store
Copy-Item -LiteralPath "$env:ProgramFiles\DeadLoad\policy\en-US\DeadLoad.adml" -Destination (Join-Path $store 'en-US')
```

The settings appear under Computer (and, for tray settings, User) Configuration, Administrative
Templates, DeadLoad. Policy values live in `HKLM\SOFTWARE\Policies\DeadLoad` (tray:
`HKCU\SOFTWARE\Policies\DeadLoad\Tray`) and win over local values, which win over the shipped
defaults. `Get-DeadLoadConfiguration -Trace` shows each effective value and its source. Without a
domain, use `/InstallAdmxLocally` and the Local Group Policy Editor.

## 7. Monitoring

Application log, source `DeadLoad`:

| ID | Level | Meaning |
|---|---|---|
| 1000 | Info | Run started (mode, version, report-only) |
| 1001 | Info / Warning / Error | Run summary; the message ends with the summary JSON |
| 1002 | Info | Category result |
| 1003 | Info | Effective configuration with sources |
| 2000 | Warning | Disk pressure entered (free, floor) |
| 2001 | Info | Pressure target reached |
| 2002 | Warning | Pressure target not reachable |
| 3000 | Error | Run error |
| 3001 | Warning | Items skipped (reparse, locked, process, changed) |
| 3002 | Warning | Configuration value or custom target rejected |
| 3003 | Error | Integrity check failed; run refused |
| 4000 | Info | OnDemand run requested |
| 4001 | Info | User temp cleanup (tray) |
| 4002 | Info | Support bundle created (tray) |

`%ProgramData%\DeadLoad\last-run.json` holds the latest summary (`Result` is Success, Partial,
Failed, Skipped or Disabled; `EndTime` is UTC); `runs\<runId>.json` keeps each run and
`logs\deadload-YYYYMMDD.log` the detail. An RMM monitor should alert on 1001 at Error, 2002,
3000 and 3003, and on a `last-run.json` older than the maintenance interval. `Get-DeadLoadStatus`
reads the same facts on the machine.

## 8. Signing

Every script, module, data file and binary in the package is Authenticode-signed (FR-22); a
signed engine refuses to run when a file changed after signing (event 3003).

- The build uses the `TrustedSigning` PowerShell module when it is installed and
  `Test-TrustedSigningConfiguration` returns nothing. Credentials come only from the environment
  variables that module reads; the build never reads, prints or passes one, and none belongs in
  this repository.
- Each file is signed with `Invoke-TrustedSigning -Path <file>`, then verified with
  `Test-TrustedSigningSignature` and `Get-AuthenticodeSignature` (Status `Valid`); every file must
  carry the same signer subject. Any failure fails the build.
- Without the module, without a complete configuration, or with `-NoSign`, the build prints
  `UNSIGNED development build` and carries on. An unsigned package is for a test VM only: it does
  not meet FR-22 and does not run under an `AllSigned` execution policy.
- `AllSigned` also requires the signing certificate in the machine's **Trusted Publishers**
  store; otherwise PowerShell asks whether to trust the publisher, which a scheduled task cannot
  answer, and module import fails with "AuthorizationManager check failed". Deploy the
  certificate to Trusted Publishers by Group Policy (Public Key Policies) before switching
  workstations to `AllSigned`. Under `RemoteSigned` or `Bypass` no store change is needed; the
  engine still refuses a signed module whose data files were changed (event 3003).
- Verify a built package by hand from PowerShell (not Git Bash, which mangles signtool flags):
  `Get-ChildItem out\pack\tools -Recurse -Include *.ps1,*.psm1,*.psd1,*.exe,*.dll | Get-AuthenticodeSignature`.

## 9. Install test procedure (disposable VM only)

Never on a production machine. Use a VM with a snapshot, Windows 10 or 11, 64-bit, Chocolatey
installed, a standard user account and an administrator account. Build with signing for the last
pass; unsigned builds are fine for the earlier ones. Record results in the pilot notes.

1. **Snapshot** the clean VM. Copy `out\deadload.<version>.nupkg` to a local folder.
2. **Legacy**: install the Get-FreeSpace 1.3.5.0 MSI, confirm its uninstall entry, folder and
   task exist.
3. **Install**: `choco install deadload --source <folder> -y`. Expect exit 0 and no restart
   prompt. Check:
   - the MSI entry, `%ProgramFiles%\Get-FreeSpace` and the legacy task are gone;
   - `%ProgramFiles%\DeadLoad\engine|tray|policy` exist and no `*.new-*`/`*.old-*` siblings;
   - `schtasks /Query /TN \DeadLoad\ /FO LIST /V` lists three tasks running as SYSTEM;
   - `icacls %ProgramData%\DeadLoad` shows exactly SYSTEM (F), Administrators (F), Users (RX),
     not inherited;
   - `[System.Diagnostics.EventLog]::SourceExists('DeadLoad')` is True;
   - `HKLM\SOFTWARE\DeadLoad` has `Version` and `InstallPath`; the Run value `DeadLoadTray` is
     the quoted exe path.
4. **Run**: `schtasks /Run /TN \DeadLoad\OnDemand`; events 1000 and 1001 appear;
   `last-run.json` exists.
5. **Standard user**: sign in as the standard user. The tray starts. `schtasks /Run /TN
   \DeadLoad\OnDemand` succeeds; `schtasks /Change /TN \DeadLoad\OnDemand /DISABLE` is denied;
   `last-run.json` is readable and writing to `%ProgramData%\DeadLoad` is denied.
6. **Upgrade with the tray running**: bump the version, rebuild, `choco upgrade deadload -y`
   while the standard user is signed in. Expect success, the tray not stopped, an
   `InPlace` line for `tray` and a `*.dlold-*` file that the next upgrade removes.
7. **Parameters**, one at a time, each from the snapshot or by re-running `choco upgrade
   deadload -y --force --params "'/X'"`:
   - `/NoTray`: the Run value is removed;
   - `/ReportOnly`: `ReportOnly` = 1 and a run deletes nothing (summary `ReportOnly` true);
   - `/InstallAdmxLocally`: the templates are in `%SystemRoot%\PolicyDefinitions` and open in
     `gpedit.msc`.
8. **Uninstall**: `choco uninstall deadload -y`. Tasks, the task folder, the Run value, the event
   source and `%ProgramFiles%\DeadLoad` are gone; `%ProgramData%\DeadLoad` remains; a policy key
   set beforehand under `HKLM\SOFTWARE\Policies\DeadLoad` remains.
9. **Purge**: reinstall, then `choco uninstall deadload -y --params "'/PurgeData'"`.
   `%ProgramData%\DeadLoad` and `HKLM\SOFTWARE\DeadLoad` are gone.
10. **Signed pass**: with a signed package, set `Set-ExecutionPolicy AllSigned -Scope
    LocalMachine`, repeat steps 3 to 5, then revert the snapshot.
