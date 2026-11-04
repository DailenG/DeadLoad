# DeadLoad window: implementation notes (design slice 4)

Status: 2026-11-04. The DeadLoad window lives in the existing tray exe (`src/tray`, .NET Framework
4.8 WinForms, one exe, no new package or runtime). It is built against
`docs/design/ENGINE-UI-CONTRACT.md` and `docs/design/DEADLOAD_DESIGN_SYSTEM.md` sections 3, 4, 6 and
7. This file records the decisions taken while building it, the contrast of every color pairing it
draws, the known limits and the QA checklist with its results.

## 1. Where things are

| File | What it holds |
|---|---|
| `src/tray/Ui/Theme.g.cs` | Generated tokens (`build/New-DeadLoadTokens.ps1` from `design/tokens.json`). |
| `src/tray/Ui/Theme.cs` | `Palette` (light, dark, high contrast), `ThemeManager` (theme detection, scale factor, fonts), native calls (dark title bar, dark scroll bars, focus cues). |
| `src/tray/Ui/Draw.cs` | Color mixing, rounded shapes, the focus ring, text measurement, the line glyphs. |
| `src/tray/Ui/Controls.cs` | `StackPanel`, `Card`, `ScrollHost`, `TextBlock`, `ThemedButton` (primary, secondary), `ButtonBar`, `Divider`, `RiskBadge`, `ResultMetric`, `CapacityBar`, `ProgressStrip`, `Notice`, `FactList`, `BrandMark`. |
| `src/tray/Ui/CategoryRow.cs`, `ItemTable.cs`, `NavRail.cs` | The category row with its expander, the sortable item table, the left navigation. |
| `src/tray/Ui/MainWindow.cs` | The window shell, the page base class, the shared view helpers. |
| `src/tray/Ui/CleanupPage.cs` | Analyze, Review, Clean and "This computer". |
| `src/tray/Ui/InfoPages.cs` | Details, History, Settings, About. |
| `src/tray/Ui/ConfirmCleanDialog.cs` | The confirmation before a cleanup. |
| `src/tray/Ui/Models.cs`, `Backend.cs` | Readers of `analysis.json`, `last-cleanup.json`, `configuration.json` and the run history; the live backend (user actions, reports, the on-demand task). |
| `src/tray/Ui/RenderHarness.cs`, `src/tray/Samples/*.json` | The hidden `--render-samples <outdir>` switch, its sample backend, the embedded samples. |
| `src/engine/Invoke-DeadLoadUserAction.ps1` | New `-Action Configuration` (contract section 10). |

`ReportForm.cs` is gone: "View last report" opens the window's Details page.

## 2. Decisions

1. **Shell.** Native title bar with the brand icon (the embedded multi-size ICO), a 200 px left rail
   (Cleanup, Details, History, Settings, About) and a status footer. One instance, owned by the
   tray: the bold top menu item "Open DeadLoad" and a double-click on the icon open Cleanup, "View
   last report" opens Details. Closing the window while Analyze or Clean runs only hides it (the
   tray shows the same window again with the result); exiting the tray disposes it.
2. **Rail.** Navy rail with a blue fill for the selected page, as the reference board shows (the
   design system allows the navy navigation variant). One tab stop: Up and Down (Home, End) change
   the page, Alt+1 to Alt+5 work anywhere in the window. The focus ring on the rail is the rail text
   color (white on navy): a blue ring would vanish into the blue selection.
3. **Theme.** Light or dark from `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`
   `AppsUseLightTheme` (absent means light), re-read on `SystemEvents.UserPreferenceChanged`; the
   view is rebuilt from page state, so nothing a user selected is lost. Dark mode sets
   `DwmSetWindowAttribute(20)` (19 on builds before 20H1) on the window and the dialog, and the
   `DarkMode_Explorer` theme on lists and text boxes (dark scroll bars). High contrast
   (`SystemInformation.HighContrast`) uses `SystemColors` only: buttons become standard system
   buttons, lists are drawn by Windows, the owner-drawn rows, badges and bars use the system window,
   text and highlight colors with outlines instead of tints.
4. **Scaling.** The window scales itself: every pixel metric goes through `ThemeManager.S()` and every
   font is created in pixels, from the window's DPI. `AutoScaleMode` is `None`, not `Dpi` as the
   slice brief suggested, on purpose: WinForms 4.8 does not auto-scale controls added after the form
   loaded (every category row and table is added after Analyze), and point-size fonts render at
   the system DPI, not the monitor's, under PerMonitorV2. `WM_DPICHANGED` is handled by the window
   (new factor, the suggested bounds, a rebuild). The manifest already declared PerMonitorV2.
5. **150 percent renders.** `Form.Scale(1.5)` scales bounds but not fonts or owner-drawn metrics, so
   it would not show what a 144 DPI monitor shows. The harness sets the same factor the window uses
   at 144 DPI (`ThemeManager.RenderScale = 1.5` at 96 DPI) and builds every view with it.
6. **Fonts.** Segoe UI Variable Text for text and Segoe UI Variable Display for headings when
   installed, else Segoe UI; Cascadia Code, else Consolas, for paths and raw JSON. Semibold uses the
   installed semibold family (GDI truncates names to 31 characters: `Segoe UI Variable Display
   Semib`), else bold. **Tabular figures:** measured with GDI at 14 px, ten "1" digits are 59 px
   in Segoe UI Variable and 89 px like every other digit in Segoe UI, so size and count columns use
   Segoe UI (every digit one width) and are right aligned; the large metric number keeps the display
   face.
7. **Text measurement.** `TextRenderer.MeasureText` without a device context kept GDI's side padding
   despite `NoPadding` (measured: "8.0" at 28 px semibold, 56 px without a Graphics, 39 px with one);
   all measurement goes through one bitmap Graphics, as all drawing does.
8. **Focus.** Every focusable control shows a 2 px ring in `focusRing`, 2 px outside its body, and
   focus cues are on from the start (`WM_CHANGEUISTATE`). Buttons reserve the ring's room on every
   side; button bars "bleed" out by that room so the button bodies line up with the text (a negative
   margin did not move the bar in the first renders, so `StackPanel` applies the bleed itself).
9. **Category rows.** One tab stop per row: Space toggles the checkbox, Enter (or Right and Left)
   shows and hides the items, Up and Down move between rows. Routine rows with items start checked,
   Review rows unchecked; a row with nothing to clean shows a disabled box and "Nothing to clean here
   right now."; an unavailable row (Restricted, machine-wide, not deleting) has a lock in the
   checkbox column and no checkbox, with "Managed by your administrator; not cleaned from here." for
   Restricted and the engine's `unavailableText` otherwise. Order: offered rows with items (Routine,
   then Review), then empty offered rows, then unavailable rows. Only checked, offered ids are sent
   to Clean; an id outside `[A-Za-z0-9._-]` is refused before any process starts.
10. **Review and Clean.** "Review Cleanup" is the only way to the Clean button and is disabled with
    nothing selected or in report-only mode. The confirmation text is the brief's sentence with
    plural handling ("1 selected file across 1 category"); a folder item counts as its measured
    files. Cancel has the focus and is the Escape key; the dialog has no AcceptButton, so Enter
    never cleans unless the Clean button itself has the focus.
11. **Cancel.** Analyze can be canceled (the process is killed: Analyze is report-only and
    `analysis.json` is replaced atomically or not at all). Clean cannot: stopping partway would
    leave no `last-cleanup.json`; the view says so.
12. **Estimated and recovered.** The metric before Clean carries "Estimated" (analysis bytes); the
    Complete view carries "Recovered" (`freedBytes`) and says "of an estimated X". Volume free space
    is shown only as capacity, never as recovered.
13. **Skip reasons.** `Locked` is shown with the design system's copy "File in use; skipped."; other
    reasons show the engine's `reasonText`.
14. **Refusals and errors.** A refusal shows "Nothing was deleted." with the engine's reason (its
    "Nothing was deleted:" lead-in removed) and offers Analyze Again. A failure shows the message and
    stderr under "Technical details". Disabled (policy or engine off) shows "Cleanup is turned off
    by your administrator." and no Analyze button; the window re-reads `Tray.AllowCleanTemp` each
    time Cleanup is shown and before Analyze and Clean (the script re-checks it anyway).
15. **This computer.** Last machine maintenance from `last-run.json` (result, time, recovered,
    skipped) and "Request a cleanup" when `Tray.AllowRequestCleanup` allows it. It shares the tray's
    requested-run watch (30 s polls for up to 90 minutes); the card updates when the new report
    lands, and the tray still shows its "Cleanup finished" notification.
16. **Configuration.** The Settings page runs `-Action Configuration`. The trace has 315 rows on a
    default install (measured, 26 KB of JSON), so the script writes
    `%LOCALAPPDATA%\DeadLoad\configuration.json` and prints only its path (contract section 10).
    It is not gated by any tray policy. The page shows section, setting, value and source (Policy,
    User policy, Local, Default; "Ignored (Policy: reason)" for a rejected value), read-only.
17. **Details and History.** Details lists the machine run per category (outcome, items found,
    recovered, skipped) with display names from the analysis or the installed engine's
    `Data\Defaults.psd1` (read as text with a pattern, never executed; the id when neither has it)
    and the user's last cleanup (deleted and skipped items), each with "Show raw report". History
    reads the newest 200 files of `%ProgramData%\DeadLoad\runs` and of `%LOCALAPPDATA%\DeadLoad\runs`
    plus `last-cleanup.json`, off the UI thread; unreadable files are counted and named as such.
18. **About.** Icon, name, version (assembly, and the engine's `ModuleVersion` read from the
    installed manifest), the design system's short description, GPL-3.0, the repository link
    (opened in the browser only on click) and "No telemetry is collected." Verified: a search of
    `src/` for `http`, `WebClient`, `HttpClient`, `WebRequest`, `Invoke-WebRequest`,
    `Invoke-RestMethod`, `TcpClient`, `System.Net.` and `telemetry` finds only XML namespaces, the
    module's license URI, the About link and the About sentence.
19. **Tokens and derived colors.** One token was added: `font.sizePx.appPageTitle` = 24 (page
    titles; the design system allows 20 to 28). Derived, not tokens (all in `Theme.cs`): button hover
    and pressed (blue 12 and 24 percent toward black in light; 14 percent toward white and black in
    dark), the tone tints (token mixed into the card, 10 percent light, 14 percent dark), the tone
    text on tints (token 15 percent deeper in light, brighter in dark: the plain tokens on their tints
    measured 3.86 to 4.27:1), the secondary button outline (border mixed 55 percent toward slate in
    light, 35 percent toward secondary text in dark, for 3:1).
20. **Motion.** The only animation is the indeterminate progress segment (a 33 ms timer). With
    Windows animations off (`SystemInformation.UIEffectsEnabled` false) it is a row of static marks
    instead, never a partial fill that would read as a percentage. No transitions.

## 3. Contrast

WCAG 2.x ratios of every pairing the window draws in light and dark (computed from the token hex
values with the same mixing as `Draw.Blend`). Text needs 4.5:1 (all app text is 12 to 16 px, so no
large-text allowance is used); focus rings, outlines, checkboxes and the capacity bar need 3:1.

| Theme | Pairing | Foreground | Background | Ratio | Needed | Pass |
|---|---|---|---|---|---|---|
| Light | Body text on card | `#0F172A` | `#FFFFFF` | 17.85 | 4.5 | yes |
| Light | Body text on canvas | `#0F172A` | `#F8FAFC` | 17.06 | 4.5 | yes |
| Light | Secondary text on card | `#475569` | `#FFFFFF` | 7.58 | 4.5 | yes |
| Light | Secondary text on canvas | `#475569` | `#F8FAFC` | 7.24 | 4.5 | yes |
| Light | Muted text (legend, version) on card | `#64748B` | `#FFFFFF` | 4.76 | 4.5 | yes |
| Light | Muted text on canvas (footer) | `#64748B` | `#F8FAFC` | 4.55 | 4.5 | yes |
| Light | Page title (navy) on canvas | `#0B3B6F` | `#F8FAFC` | 10.74 | 4.5 | yes |
| Light | Primary button text on blue | `#FFFFFF` | `#0078D4` | 4.53 | 4.5 | yes |
| Light | Primary button text, hover | `#FFFFFF` | `#006ABB` | 5.56 | 4.5 | yes |
| Light | Primary button text, pressed | `#FFFFFF` | `#005BA1` | 6.97 | 4.5 | yes |
| Light | Secondary button text (navy) on card | `#0B3B6F` | `#FFFFFF` | 11.23 | 4.5 | yes |
| Light | Secondary button text, hover | `#0B3B6F` | `#F3F4F5` | 10.20 | 4.5 | yes |
| Light | Secondary button outline on card | `#838C98` | `#FFFFFF` | 3.40 | 3.0 | yes |
| Light | Rail text on navy | `#FFFFFF` | `#0B3B6F` | 11.23 | 4.5 | yes |
| Light | Rail text on hover | `#FFFFFF` | `#234F7D` | 8.45 | 4.5 | yes |
| Light | Rail selected text on blue | `#FFFFFF` | `#0078D4` | 4.53 | 4.5 | yes |
| Light | Rail focus ring (white) on navy | `#FFFFFF` | `#0B3B6F` | 11.23 | 3.0 | yes |
| Light | Badge Routine text | `#126D34` | `#E8F2EC` | 5.62 | 4.5 | yes |
| Light | Badge Review text | `#994708` | `#F8EEE6` | 5.63 | 4.5 | yes |
| Light | Badge Restricted text | `#9D1818` | `#F8E8E8` | 6.87 | 4.5 | yes |
| Light | Qualifier Estimated (blue) | `#0066B4` | `#E6F2FB` | 5.19 | 4.5 | yes |
| Light | Notice text on warning tint | `#0F172A` | `#F8EEE6` | 15.61 | 4.5 | yes |
| Light | Notice text on danger tint | `#0F172A` | `#F8E8E8` | 15.05 | 4.5 | yes |
| Light | Guarded line (warning) on card | `#994708` | `#FFFFFF` | 6.44 | 4.5 | yes |
| Light | Link on card | `#0078D4` | `#FFFFFF` | 4.53 | 4.5 | yes |
| Light | Focus ring on card | `#0078D4` | `#FFFFFF` | 4.53 | 3.0 | yes |
| Light | Focus ring on canvas | `#0078D4` | `#F8FAFC` | 4.33 | 3.0 | yes |
| Light | Checkbox outline on card | `#64748B` | `#FFFFFF` | 4.76 | 3.0 | yes |
| Light | Checked box (blue) on card | `#0078D4` | `#FFFFFF` | 4.53 | 3.0 | yes |
| Light | Capacity used (navy) on track | `#0B3B6F` | `#E5E7EB` | 9.07 | 3.0 | yes |
| Light | Table header text on canvas | `#475569` | `#F8FAFC` | 7.24 | 4.5 | yes |
| Light | Row text on selected row | `#0F172A` | `#DBECF9` | 14.77 | 4.5 | yes |
| Light | Disabled button text | `#64748B` | `#E5E7EB` | 3.84 | exempt | - |
| Dark | Body text on card | `#F1F5F9` | `#1E293B` | 13.35 | 4.5 | yes |
| Dark | Body text on canvas | `#F1F5F9` | `#0F172A` | 16.30 | 4.5 | yes |
| Dark | Secondary text on card | `#CBD5E1` | `#1E293B` | 9.85 | 4.5 | yes |
| Dark | Secondary text on canvas | `#CBD5E1` | `#0F172A` | 12.02 | 4.5 | yes |
| Dark | Muted text on card | `#94A3B8` | `#1E293B` | 5.71 | 4.5 | yes |
| Dark | Muted text on canvas | `#94A3B8` | `#0F172A` | 6.96 | 4.5 | yes |
| Dark | Primary button text on blue | `#0F172A` | `#60A5FA` | 7.02 | 4.5 | yes |
| Dark | Primary button text, hover | `#0F172A` | `#76B2FB` | 8.10 | 4.5 | yes |
| Dark | Primary button text, pressed | `#0F172A` | `#538ED7` | 5.29 | 4.5 | yes |
| Dark | Secondary button text on raised | `#F1F5F9` | `#263449` | 11.48 | 4.5 | yes |
| Dark | Secondary button outline on card | `#758293` | `#1E293B` | 3.74 | 3.0 | yes |
| Dark | Rail text on navy | `#F1F5F9` | `#0B3B6F` | 10.25 | 4.5 | yes |
| Dark | Rail text on hover | `#F1F5F9` | `#234F7D` | 7.71 | 4.5 | yes |
| Dark | Rail selected text on blue | `#0F172A` | `#60A5FA` | 7.02 | 4.5 | yes |
| Dark | Rail focus ring on navy | `#F1F5F9` | `#0B3B6F` | 10.25 | 3.0 | yes |
| Dark | Badge Routine text | `#65E393` | `#244245` | 6.68 | 4.5 | yes |
| Dark | Badge Review text | `#FCC945` | `#3D3E38` | 6.98 | 4.5 | yes |
| Dark | Badge Restricted text | `#F98686` | `#3D3343` | 5.01 | 4.5 | yes |
| Dark | Qualifier Estimated (blue) | `#78B2FB` | `#273A56` | 5.24 | 4.5 | yes |
| Dark | Notice text on warning tint | `#F1F5F9` | `#3D3E38` | 9.86 | 4.5 | yes |
| Dark | Notice text on danger tint | `#F1F5F9` | `#3D3343` | 10.93 | 4.5 | yes |
| Dark | Guarded line (warning) on card | `#FCC945` | `#1E293B` | 9.46 | 4.5 | yes |
| Dark | Link on card | `#60A5FA` | `#1E293B` | 5.75 | 4.5 | yes |
| Dark | Focus ring on card | `#60A5FA` | `#1E293B` | 5.75 | 3.0 | yes |
| Dark | Focus ring on canvas | `#60A5FA` | `#0F172A` | 7.02 | 3.0 | yes |
| Dark | Checkbox outline on card | `#94A3B8` | `#1E293B` | 5.71 | 3.0 | yes |
| Dark | Capacity used (blue) on track | `#60A5FA` | `#334155` | 4.07 | 3.0 | yes |
| Dark | Table header text on raised | `#CBD5E1` | `#263449` | 8.47 | 4.5 | yes |
| Dark | Row text on selected row | `#F1F5F9` | `#2D4465` | 9.02 | 4.5 | yes |

Before the fix in decision 19 five pairings failed: the light Routine (4.27), Review (4.25) and
Estimated (3.86) badges, and the dark Restricted (4.18) and Estimated (4.33) badges; the secondary
button outline was 2.06 (light) and 1.93 (dark). High contrast uses the user's system colors, whose
contrast the user's theme decides.

## 4. Render harness

`DeadLoadTray.exe --render-samples <outdir>` (hidden; not in any menu or help) renders every view
and state from the embedded samples (`src/tray/Samples`: copies of the contract's examples, plus
an invented `last-run.json` and `configuration.json`, each marked `SAMPLE DATA` inside) in light
and dark at 100 and 150 percent, plus the high contrast code path at 100 percent, and writes
`index.txt` with each image's size and layout check (page preferred height against actual, scroll
bars). Its backend throws on any attempt to run a user action, read a real file or start the task.
The clock is fixed (2026-11-04 17:00 UTC) and motion is off, so renders repeat exactly. Two sample
variants are made in code and named as such: "partial, guarded" (result `Partial` and a guarded
message on Temporary files) and "empty" (no items). The last renders are in `out/ui-render/` (81
PNGs; `out/` is not committed).

## 5. Known limits

- **Not run live here.** Analyze and Clean were not run against a real profile on the build
  workstation (by instruction); the window's flow was exercised with the samples, the parsers by the
  self-test, and the script by `tests/UserAction.Tests.ps1`. The end-to-end standard-user pass
  (implementation plan slice 4 proof) still has to happen in the Windows Sandbox.
- **Monitor DPI changes** are handled in code (`WM_DPICHANGED`, rebuild at the new factor) but were
  not tried on a second monitor; 150 percent is proven by the render scale only.
- **High contrast** was rendered through its code path with high contrast off, so the images show
  standard controls with ordinary system colors, not a contrast theme.
- **Renders** are full-length composites drawn with `DrawToBitmap`: the window's own title bar and
  scroll bar are not in them (a long page shows a 17 px empty strip where the scroll bar is); the
  dialog render draws its non-client area in the classic style, unlike the real DWM title bar.
- **Category names** in the machine report come from the installed `Defaults.psd1`; next to a
  development build (and in the renders) machine-only categories show their id (`windows.temp`).
- **Dark mode leftovers:** the list context menu ("Copy path", "Select all") and the tooltip are
  drawn by Windows in light colors.
- **High contrast lists** use the standard end ellipsis for paths, not the middle (path) ellipsis.
- **No cross-gate with the tray menu:** "Clean my temp files" from the menu can run while the window
  analyzes; the engine's own re-checks keep that safe (a removed item is reported `Missing`).
- **Screen readers** get names, roles, states and descriptions (rows are check buttons with value
  and expanded state, the rail is a page tab list); not yet tried with Narrator.
- **Link inset:** the About page link sits 4 px right of the text column (LinkLabel's own padding).

## 6. QA checklist

Results of this slice. "Render" means verified in `out/ui-render`; "code" means verified by reading
the implementation, not by running it interactively.

- [x] One primary action per view: Analyze Storage, Review Cleanup, Clean Selected Items (render).
- [x] No Clean action outside Review and the confirmation dialog; no "Clean Up (X GB)" button (code, render 03 and 07).
- [x] Estimated before Clean, Recovered after it, never one number for both (render 03, 07, 10).
- [x] Confirmation text and title as specified; Cancel focused; Escape cancels; Enter on Cancel cancels (render 08, code).
- [x] "Deleted files are not moved to the Recycle Bin and cannot be restored by DeadLoad." on Review (render 07).
- [x] No reversibility, "100% safe" or Civil 3D claim anywhere in the window (search of `src/tray`).
- [x] Restricted rows: lock, no checkbox, "Managed by your administrator; not cleaned from here." (render 03).
- [x] Review rows start unchecked, Routine rows checked (render 03).
- [x] Guarded and partial analyses explained (render 05); empty state copy (render 06).
- [x] Skipped items listed with plain reasons, "File in use; skipped." for a locked file (render 10).
- [x] Refused and Disabled shown as clear messages (render 11, 12).
- [x] Risk shown as glyph plus text, never color alone (render 03; also in high contrast, render 03-highcontrast).
- [x] Capacity bar states its denominator ("41.0 GB free of 476.0 GB") (render 01).
- [x] Light and dark complete, dark title bar on window and dialog (render, code).
- [x] Contrast: 61 of 61 checked pairings pass (section 3).
- [x] 150 percent: no clipped or overlapping text, tables without needless scroll bars, no horizontal scroll bar (render *-150, `index.txt`).
- [x] Narrow window (760 px): summary stacks, rows switch to the compact layout (render 17).
- [x] Visible focus ring on buttons, rows, rail, tables (render: rail and dialog; code: all).
- [x] Keyboard: Tab order follows the visual order (button bars set TabIndex); rail Up/Down and Alt+1..5; rows Space/Enter/arrows; tables Ctrl+C, Ctrl+A, column click sort (code).
- [x] Reduced motion: no animation with Windows animations off (code; renders use it).
- [x] No telemetry (search, decision 18).
- [x] Sources 7-bit ASCII (`[^\x00-\x7F]` search of `src/tray`, the script, the tests, the tokens).
- [x] Build with 0 warnings (TreatWarningsAsErrors); `--self-test` exit 0 with the new parser checks.
- [x] `tests/UserAction.Tests.ps1`: 29 passed on Windows PowerShell 5.1 and on PowerShell 7.
- [ ] Narrator pass (not done).
- [ ] Real high contrast theme and a second monitor at another DPI (not available here).
- [ ] Standard-user end-to-end run in the Windows Sandbox (not run here; next step of slice 4).
