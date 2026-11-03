# DeadLoad: Contributor and Agent Notes

Read [PRD.md](PRD.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[docs/MEASUREMENTS.md](docs/MEASUREMENTS.md) and [docs/PLAN.md](docs/PLAN.md) before changing
anything. ARCHITECTURE section 2 is the decision record; change a decision there, with its
rationale, before changing code that depends on it.

## Hard rules

- **Open source, vendor-neutral.** No company, client or person-specific names, hosts, URLs,
  feed addresses, share paths or GPO values in code, docs, tests, fixtures or commit messages.
  Everything is named plain `DeadLoad` (no vendor parent folder or registry key).
- **Safety as SYSTEM** (ARCHITECTURE section 8): never traverse or delete a reparse point; never
  use `Remove-Item -Recurse` or `Get-ChildItem -Recurse` on a target; delete files by full path
  after re-checking; remove directories only when empty. Never touch user data.
- **No network during a run.** No HTTP anywhere in the engine. Only a configured Copy/Move
  destination may be a UNC path.
- **Targets ship in the signed package.** Nothing is downloaded at runtime.
- **Paths must be graded** in MEASUREMENTS.md. Only M (measured) paths ship enabled.
- **Read-only on production machines.** Measurement with `tools/Measure-AutodeskFootprint.ps1`
  is fine where access is granted; installing, piloting or changing settings on a production
  workstation needs separate, explicit approval.
- **Probe output is private.** Raw JSON goes in `measurements/raw/` (gitignored). Record results
  in MEASUREMENTS.md by anonymous host label.
- **Secrets** (signing credentials) stay in the environment. Never print or commit one.

## PowerShell conventions

- Windows PowerShell 5.1 and PowerShell 7 compatible.
- 7-bit ASCII only: no em or en dashes, curly quotes, non-breaking spaces or ellipsis glyphs.
- No `&&` or `||`. Run scripts with `-File`, never inline `-Command`.
- Advanced functions with `[CmdletBinding()]`; state changes behind `SupportsShouldProcess`.
- Prose goes to `Write-Verbose` / `Write-Information` / the log file; the output stream carries
  only the result object.
- Comments explain why, not what.

## Tests

- Pester 5+ on both hosts; every test builds its own sandbox under `%TEMP%` and removes it.
- Profiles, running processes and free space come from private functions so tests can mock them.
- The safety tests in docs/PLAN.md phase 1 are mandatory and must never be skipped or weakened.

## Language

American English spelling in code, docs and UI text.

## Commits

- Atomic, one concern per commit.
- Imperative subject; the body explains why.
- No co-author lines.
