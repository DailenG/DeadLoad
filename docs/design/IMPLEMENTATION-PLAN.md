# Design system implementation plan

Inputs: `DEADLOAD_DESIGN_SYSTEM.md` (authoritative), `DEADLOAD_IMPLEMENTATION_PROMPT.md`,
`reference/DeadLoad_Engineering_Design_Reference.png` (art direction only). Precedence as both
documents state: safety and accessibility, then the design system's rules, then Windows
conventions, then the image.

## 1. What exists today (audit, 2026-11-04)

| Area | State | Gap against the design system |
|---|---|---|
| Engine (`src/engine/DeadLoad`) | Category-driven retention, report-only and what-if modes, `last-run.json`, `runs/<id>.json`, event log. Runs unattended as SYSTEM, or as the user (`-Mode User`) for the tray. | No per-item plan output a UI can review; no risk tier per category; no way to run only the categories a user selected. |
| Tray (`src/tray`, .NET Framework 4.8 WinForms, one exe, D5) | Notification icon, menu actions, balloons, a plain read-only report window (ListView plus raw JSON). Default exe icon. | No brand icon, no app shell, no Analyze, Review, Clean flow, no theming (dark, high contrast handled only by WinForms defaults). |
| Policy (`policy/*.admx`, generated) | Every setting manageable by Group Policy. | No recommended configuration; admins face the full catalog (owner feedback 2026-11-04). |
| Website | None. The repository has no remote yet, so there is no GitHub URL, release or Pages site to link to. | Whole landing page; policy generator. |
| README | Text only. | Header with mark and hero line, screenshot, safety note. |
| Brand assets | None besides the mood board. | Vector mark, one-color variant, lockups, PNG sizes, multi-size ICO, favicon. |

## 2. Decisions this plan makes (adapting the spec to the architecture)

1. **One desktop binary.** The design's app shell grows out of the existing tray exe
   (WinForms, net48): the report window becomes the DeadLoad window. No WinUI 3 or new runtime:
   D5 chose net48 so nothing has to be deployed beside the exe, and a managed workstation fleet
   is the target. WinForms gets the tokens through a small owner-drawn theme layer (Segoe UI
   Variable with Segoe UI fallback, 4 px spacing, 6 to 8 px radius, focus ring `#0078D4`), with
   the system high-contrast colors taking over whenever Windows high contrast is on.
2. **Who cleans what.** DeadLoad is administered by policy and cleans as SYSTEM. The interactive
   **Analyze, Review, Clean** flow covers what a standard user may clean: their own profile's
   user-action categories, without elevation. Machine-wide categories appear in the same view
   from the last SYSTEM report, read-only, with **Request a cleanup** (the SYSTEM task, policy
   governed). Nothing in the window elevates.
3. **Clean deletes only what was reviewed.** Analyze runs the engine report-only and keeps the
   item list; Clean passes that list back and the engine deletes the intersection of it and a
   fresh plan (so an item that became protected since Analyze, or is now in use, is skipped and
   shown as skipped). The result separates *estimated* (Analyze) from *recovered* (confirmed
   deletions), which the engine already reports.
4. **Risk tiers are data.** Each category in `Data/Defaults.psd1` gets `Risk = Routine | Review |
   Restricted`, mapped from the decisions already made (ARCHITECTURE section 7): temp files,
   CER crash reports and installer logs Routine; Revit web and PAC caches Review (they rebuild
   or re-download); journals, collaboration cache, old Revit versions and installers Restricted.
   Review and Restricted are unselected in the UI by default; Restricted needs an extra
   confirmation line. The ADMX explain text shows the tier.
5. **Presets are policy, not a user setting.** The design's "Presets" page becomes **Settings**:
   the effective configuration with its source (policy, local, default), read-only, from
   `Get-DeadLoadConfiguration -Trace`. Presets for administrators live in the website's policy
   generator (section 4).
6. **Claims.** The image's "Safe & Reversible", "No design files or project data are affected",
   "Clean Up (12.6 GB)" button and Civil 3D mention are not used: DeadLoad has no quarantine or
   rollback, the primary action is **Review Cleanup**, and Civil 3D was not measured (no
   installs). Copy says what is protected (section 4 of the PRD) and that deletion is permanent.
7. **Tokens live once.** `design/tokens.json` holds colors (light and dark), type, spacing,
   radius and focus; a build step writes `site/assets/tokens.css` and `src/tray/Theme.g.cs`.
8. **Icon geometry lives once.** `build/New-DeadLoadBrand.ps1` defines the stacked-slab mark as
   polygons, writes the SVGs (primary, one-color, lockups, favicon) and renders the PNG sizes
   (16, 20, 24, 32, 40, 48, 64, 256) and the multi-size ICO with System.Drawing from the same
   coordinates, so no image tool is added. 16 px gets its own simplified silhouette (pixel
   aligned), as the spec requires legibility at taskbar sizes.
9. **Website is static.** `site/` is plain HTML, CSS and a little JavaScript (no framework, no
   build dependency, Inter not bundled: system fallback), deployable to GitHub Pages by a
   workflow once the repository has a remote. Download links point only at real releases; until
   one exists the page shows build-from-source and Chocolatey instructions.
10. **ASCII rule.** AGENTS.md requires 7-bit ASCII. The two design documents contain typographic
    dashes and quotes; they are committed with those normalized to ASCII (content unchanged).

## 3. Component inventory (from spec section 7)

Desktop (WinForms, `src/tray/Ui/`): `ThemedButton` (primary, secondary), `CategoryRow`
(checkbox, icon, title, explanation, size, risk badge, expander), `RiskBadge`, `ResultMetric`
(Estimated or Recovered qualifier), `CapacityBar` (free versus used with its denominator stated,
not a decorative ring), `ProgressStrip` (determinate only when counts are known),
`ConfirmCleanupDialog`, `ItemTable` (path, size, age, reason; full path on demand, copy),
`NavRail` (Cleanup, Details, History, Settings, About). States: hover, focus, pressed,
disabled, loading, empty, error, high contrast.

Web (`site/`): top bar, hero, value row, three-step flow, "what it examines" with limitations,
safety section, screenshots (real, from the sandbox), install, footer, policy generator.

## 4. Recommended configuration and policy generator (owner request, 2026-11-04)

- `docs/RECOMMENDED-POLICY.md`: the shipped defaults *are* the recommendation (measured on seven
  workstations); an administrator normally sets only three things: the maintenance time, report
  only for the pilot week, and the support share for log bundles. Two presets: **Pilot**
  (report-only, notifications on) and **Recommended** (defaults, report-only off).
- `site/policy.html` (linked from the landing page): pick a preset, adjust the handful of common
  settings, optionally expand the full catalog; output a PowerShell script that writes the values
  into a named GPO with the GroupPolicy module (`Set-GPRegistryValue`), a `.reg` file for one test
  machine, and a table for doing it by hand in GPMC. Runs entirely in the browser; the catalog is
  `site/data/settings.json`, generated at build from `Data/Settings.psd1` and `Data/Defaults.psd1`
  so it cannot drift from the ADMX.

## 5. Slices, in order (each its own commits, tests green on 5.1 and 7)

| # | Slice | Proof |
|---|---|---|
| 1 | Brand mark and icon pipeline; tray and package use the ICO | Renders inspected at 16 to 256 px, light and dark; exe shows the icon |
| 2 | Tokens; static site with hero, features, flow, safety, install; policy generator and recommended presets | Browser screenshots at 1440, 1024, 390 px, light and dark, keyboard pass; generator output round-tripped against `Get-DeadLoadConfiguration -Trace` in the sandbox |
| 3 | Engine: `Risk` per category; plan output per item for user mode; `-Category` and reviewed-item intersection | Pester on both hosts; existing 1.x safety tests unchanged |
| 4 | DeadLoad window: Cleanup (Analyze, Review, Confirm, Clean, Complete), Details, History, Settings, About; dark and high contrast; DPI | Sandbox: standard user flow end to end, screenshots at 100 and 150 percent, keyboard-only pass |
| 5 | README header and real screenshots; docs (decisions, QA checklist) | Rendered on GitHub once a remote exists |

## 6. Open items for the owner

- Repository URL (no remote yet): needed for site links, Pages deployment and "View on GitHub".
- License (D3): the site footer and About page state it.
- Whether the policy generator should also emit a GPO backup that can be imported (more work,
  needs a GPMC machine to verify) or the PowerShell plus `.reg` outputs are enough.
