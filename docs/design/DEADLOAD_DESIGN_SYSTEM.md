# DeadLoad - Brand & Interface Design System

**Version:** 1.0 | Engineering Edition  
**Product:** DeadLoad - Windows workstation storage cleanup utility  
**Primary audience:** Professional structural engineers and engineering firms  
**Secondary audience:** AEC professionals, technical workstation users, IT administrators  
**Companion visual:** `DeadLoad_Engineering_Design_Reference.png` (the supplied concept board)

> **DeadLoad**  
> **Remove the Digital Dead Load.**  
> Less overhead. More capacity.

## 1. Design intent

DeadLoad is a practical Windows utility for finding and removing unnecessary storage consumption: temporary files, disposable caches, obsolete logs, and other accumulated system/application data. The name is an understated nod to **dead load**, a familiar structural engineering term: permanent weight that a structure must support. DeadLoad removes the *digital* equivalent.

The product should feel like a **reliable engineering instrument**, not a novelty cleaner or aggressive "PC optimizer." Communicate precision, predictability, measured impact, and control. A little dry wit is welcome in the name and headline; routine actions, warnings, and destructive operations must remain plainspoken.

### Brand personality

- **Precise:** measured quantities, clear units, explicit scope.
- **Competent:** modern native-Windows quality, not a flashy dashboard.
- **Trustworthy:** visibility before cleanup; conservative defaults; clear exclusions.
- **Efficient:** dense enough for professionals, without visual clutter.
- **Subtly witty:** engineering double entendre, never cartoonish or meme-like.

### What it is not

No neon accents, cartoon mascot, skulls, dumpsters, hazard-stripe branding, gradients used as decoration, excessive glassmorphism, glowing elements, gamer styling, cyberpunk aesthetics, or aggressive "boost your PC" claims. No stock photos of engineers in hard hats as the product identity. Engineering drawings and structural frames are **contextual accents**, not full-screen wallpaper.

## 2. Reference image and precedence

The accompanying PNG establishes the overall direction: white/light surfaces, navy-and-blue accents, a stacked structural-layer symbol, restrained typography, a professional Windows dashboard, and technical linework in the marketing hero.

**Treat the PNG as art direction, not pixel-perfect source code.** Text, numeric values, proportions, shadows, and layout may be illustrative. Resolve ambiguity in this order:

1. Product safety, truthful behavior, and accessibility.
2. The explicit rules and design tokens in this document.
3. Platform conventions (Windows 11 / WinUI 3 styling or an equivalent accessible system).
4. The PNG's visual direction.

Where the image suggests overly promotional claims (e.g., "safe and reversible"), do not assert functionality that has not been implemented and tested.

## 3. Identity and copy

### Name / lockup

- Product spelling: **DeadLoad** (capital D and L; no space in the brand name).
- Primary lockup: abstract layered structural mark to the left of a clean **DeadLoad** wordmark.
- Optional descriptor below or beside the wordmark: **SYSTEM SPACE CLEANUP** in restrained uppercase with deliberate tracking, for larger marketing placements only.
- Avoid heavy italics in everyday UI. A slight italic treatment may be explored for the *marketing wordmark only* if readability and professional tone remain strong; a clean upright version is preferred at small sizes.

### Approved messaging

| Role | Copy |
|---|---|
| Primary hero | **Remove the Digital Dead Load.** |
| Supporting line | Reclaim storage, reduce system clutter, and keep your engineering workstation running efficiently. |
| Short product description | A transparent Windows cleanup utility that helps identify and remove unnecessary files without putting engineering work at risk. |
| Alternate headline | Less overhead. More capacity. |
| CTA | Download for Windows |
| Secondary CTA | View on GitHub |
| UI headline | System Cleanup |
| Scan CTA | Analyze Storage |
| Post-scan CTA | Review Cleanup |
| Confirm CTA | Clean Selected Items |
| Empty state | No unnecessary files found in the selected locations. |
| Success | Cleanup complete. **X GB reclaimed.** |
| Locked item | File in use; skipped. |

Use **Analyze -> Review -> Clean** as the interaction model. Avoid "One-click magic," "Turbocharge," "100% safe," "guaranteed reversible," and "no files can be affected."

### Voice

Concise, factual, measured, calm. Dry engineering wordplay belongs in page headings and optional secondary copy, not error messages or safety confirmations. Always distinguish **estimated reclaimable** space from **space actually recovered**.

## 4. Design tokens

### Colors - light (primary)

| Token | Hex | Usage |
|---|---|---|
| `brand.navy` | `#0B3B6F` | Brand anchors, strong headings, selected navigation backgrounds |
| `brand.blue` | `#0078D4` | Primary actions, active states, links, charts |
| `neutral.slate` | `#334155` | Secondary headings, technical labels, icons |
| `neutral.concrete` | `#E5E7EB` | Dividers, borders, chart tracks |
| `surface.canvas` | `#F8FAFC` | Overall page background |
| `surface.card` | `#FFFFFF` | App/content surfaces |
| `text.primary` | `#0F172A` | Main text |
| `text.secondary` | `#475569` | Explanatory copy |
| `text.muted` | `#64748B` | Metadata and noncritical captions |
| `state.success` | `#15803D` | Completed cleanup, verified operation |
| `state.warning` | `#B45309` | User review / potentially consequential operations |
| `state.danger` | `#B91C1C` | Destructive warnings and errors |
| `focus.ring` | `#0078D4` | Visible keyboard focus treatment |

**Suggested light surfaces:** app shell `#F8FAFC`; elevated cards `#FFFFFF`; navigation panel may use `#0B3B6F` with white text, but a light navigation variant is valid if it better matches native Windows. Use flat, subtle shadows only where needed to show layering.

### Colors - dark (secondary)

Provide a complete dark mode rather than simply inverting colors:

| Token | Hex |
|---|---|
| `surface.canvas.dark` | `#0F172A` |
| `surface.card.dark` | `#1E293B` |
| `surface.raised.dark` | `#263449` |
| `border.dark` | `#475569` |
| `text.primary.dark` | `#F1F5F9` |
| `text.secondary.dark` | `#CBD5E1` |
| `brand.blue.dark` | `#60A5FA` |

Check contrast per component; especially avoid light-blue text on white and muted gray text on dark slate. Chart colors must be distinguishable without hue alone.

### Typography

- **Windows application:** `Segoe UI Variable`, fallback `Segoe UI`, system sans-serif.
- **Website and documentation:** `Inter` if available, fallback `Segoe UI Variable`, `Segoe UI`, system sans-serif. Avoid dependence on a downloaded font in offline app builds.
- **Monospaced data:** `Cascadia Code`, fallback `Consolas`, for paths, sizes where appropriate, logs, and technical diagnostics.
- Body: 14-15 px app; 16 px website. Captions: 12-13 px minimum where practical. Headers: 20-28 px app, 36-56 px website hero on desktop.
- Weights: 400 regular, 600 semibold, 700 bold. Avoid excessive uppercase or wide letterspacing outside the optional descriptor.
- Use tabular numerals for drive capacities, file counts, percentages, and comparisons.

### Spacing, shape, depth

- Base spacing: **4 px**; standard steps: 4, 8, 12, 16, 24, 32, 48, 64.
- App control height: 32-40 px; primary CTAs 36-44 px; pointer targets should remain usable.
- Corner radius: 6-8 px controls; 10-12 px cards. Avoid pill-shaped controls everywhere.
- Borders: 1 px `#E5E7EB` or semantic equivalent; use hierarchy rather than heavy outlines.
- Shadows: subtle and rare. No ornamental blur/glow.
- Motion: 120-200 ms for small transitions, respect reduced-motion settings; do not animate critical state changes solely for flourish.

### Iconography and graphics

- Simple 1.5-2 px line icons, consistent stroke/optical weight. Use Windows/Fluent or similar clean geometric style; keep UI iconography distinct from the brand mark.
- Favor icons for: storage, file, layers, list, check shield, analysis, settings, history, and information.
- Structural linework: thin strokes, reference grids, beam/column framing, simplified axonometric structures. Reserved for hero, README header, or very quiet empty states.

## 5. App icon and logo system

### Symbol direction

Use an **abstract, geometric stack of structural slabs/plates or beam layers**, with aligned edges and one negative-space opening, suggesting both structure and the removal of unnecessary load. The reference PNG uses navy-and-blue stacked layers. Refine this into a legible **single silhouette** for small sizes.

Requirements:

1. Recognizable at 16, 24, 32, 48, 64, and 256 px.
2. Works on light and dark backgrounds.
3. Has a one-color variant, not dependent on gradients.
4. Avoids representing an actual structural certification or engineering authority.
5. Legible when displayed as a Windows taskbar icon.
6. Do not put a tiny wordmark inside the app icon.

**Deliverables:** primary SVG; one-color SVG; horizontal lockup; icon-only PNGs at common Windows sizes; multi-resolution `.ico`; favicon SVG/PNG if website requires it. For production use, create vector geometry, not a crop from the mood board. Provide clear-space equal to roughly 1/4 of symbol height; minimum wordmark size should be tested, not assumed.

## 6. Windows app information architecture

**Recommended primary navigation:**

1. **Cleanup** - analyze, review, select, confirm.
2. **Details** - per-location file inventory and size breakdown.
3. **Presets** - conservative cleanup profiles / saved selection rules.
4. **History** - what was analyzed, skipped, removed, when, and how much storage was recovered.
5. **Settings** - exclusions, elevation, behavior, theme, telemetry privacy if implemented.
6. **About** - version, links, licenses.

Keep navigation simple: a compact left rail or sidebar in a desktop app. Selected state uses blue, not overly saturated fills. Preserve Windows-native title bar, window controls, keyboard navigation, high-DPI scaling, and focus indicators.

### Cleanup dashboard

- Clear header: **System Cleanup** with short explanatory line.
- Top result: **X GB potentially reclaimable**, accompanied by file count and scan timestamp.
- Prefer a compact ring or horizontal capacity graphic that explains its denominator; don't draw an arbitrary progress ring implying a false percentage.
- Show category rows with checkbox, category name, exact or estimated size, item count, and risk label.
- Actions: **Analyze Again** (secondary) and **Review Cleanup** (primary). Avoid an immediate "Clean Up 12.6 GB" action that bypasses review.
- Footer/status: scan status, selected item count, latest completed cleanup, actual space recovered, and platform/build information if useful.

### Category row pattern

`[checkbox] [icon] Category title / explanation [size] [risk] [expand]`

Examples: Windows temporary files; application caches; obsolete logs; installation leftovers. A category's display name is not permission to delete everything that happens to share that name.

### Engineering application awareness

Support application-specific rules only when verified per product/version, with explanatory descriptions and safe exclusions. Potential future integrations include Revit, Civil 3D, AutoCAD, and other AEC tools, but **do not imply they are implemented** in marketing or UI before they are.

Treat active model caches, local worksharing data, journals needed for troubleshooting, autosave and recovery data, licensing data, configuration, and anything resembling project content as **protected or manual-review-only by default**. Never presume that a folder named "cache" is safe to remove. Clearly state application closure requirements and possible re-download/rebuild costs before an applicable cleanup.

### Safety UX: non-negotiable

- Scan first; show paths, counts, sizes, purpose, and risk.
- Default to conservative, verified rules and deselect ambiguous or consequential items.
- Explicit user confirmation with a concrete scope summary before deletion.
- Skips for locked/in-use files; useful error messages rather than silent failure.
- Clearly labeled exclusions and per-category details.
- Never claim deletion is reversible unless a tested rollback/quarantine mechanism exists.
- Log operations, display actual outcomes, and make failed/skipped items visible.
- Require elevation only where necessary; explain why.
- No ungrounded performance improvement promises. Reclaiming storage does not automatically speed up a workstation.

### Risk taxonomy

| Level | Label | Default | Example handling |
|---|---|---|---|
| 1 | Routine | Selected only if verified safe | Old system temp files not in use |
| 2 | Review | Off by default | Caches that may cause reprocessing or re-download |
| 3 | Restricted | Explicit opt-in, detailed warning, or excluded | Engineering recovery/worksharing/project-adjacent locations |

Use icons + text labels, not red/green coloring alone.

## 7. Component patterns

| Component | Visual behavior | UX behavior |
|---|---|---|
| Primary button | Solid `#0078D4`, white text | Only one dominant action per view |
| Secondary button | White/neutral, subtle border, navy/slate text | Re-scan, cancel, open details |
| Checkbox | Standard Windows-like checked/unchecked/mixed states | Keyboard accessible; clear grouped-selection behavior |
| Category card | White surface, 1 px border, compact data alignment | Expand to expose items, locations, exclusions |
| Risk badge | Low-emphasis semantic background and label | Includes plain-language classification |
| Result metric | Large numeric value, smaller unit and qualifier | "Estimated" before cleanup, "Recovered" afterward |
| Progress | Calm blue horizontal indicator; determinate only if measurable | File/location count and cancellability where possible |
| Confirmation dialog | Explicit action, selected count/size, irreversible warning when relevant | Cancel is easily available; focus placed deliberately |
| Empty state | Minimal structural iconography or none | Plain, helpful text and scan action |
| Toast/status | Short text, subtle icon, no celebratory confetti | Never replaces operation log or confirmation |
| Data table | Aligned size/count columns, truncation with full-path access | Sort, filter, accessible labels, export if supported |

Provide hover, focused, active, disabled, loading, empty, error, and high-contrast states for the components used. Ensure WCAG 2.2 AA contrast and keyboard operability in the website; follow equivalent Windows accessibility practices in the app.

## 8. Single-page GitHub Pages site

**Purpose:** Clearly explain the tool, establish trust, show the interface, and link to real downloads/source. It must feel appropriate to an engineering office.

Suggested sections:

1. **Top bar:** mark + DeadLoad, Features, How It Works, Safety, Screenshots, GitHub.
2. **Hero:** "Remove the Digital Dead Load." Short description, Download for Windows, View on GitHub. Product screenshot as focal point, quiet structural-frame linework behind/alongside it.
3. **Value proposition:** Reclaim storage, Clear visibility, Configurable cleanup, Measurable results.
4. **How it works:** Analyze -> Review -> Clean, three concise illustrated steps.
5. **What it examines:** categories with clearly stated limitations; call engineering-specific support "planned" unless real.
6. **Safety and transparency:** review before delete, protections/exclusions, operational logging, open-source inspectability if true.
7. **Screenshots:** real app screenshots where available, labeled mockups otherwise.
8. **Install:** link to genuine releases and system requirements; don't invent version numbers, endorsements, downloads, benchmark claims, or security guarantees.
9. **Footer:** source repository, docs, issues, license, attribution, privacy as applicable.

### Web layout

- Content max width: 1120-1200 px.
- Hero: two columns on desktop, stacked at narrower widths; copy left, screenshot/technical frame right.
- White or nearly white background; generous vertical rhythm; technical grid in small areas only.
- Blue primary CTA, navy headings, slate body text.
- Responsive layout at mobile widths without relying on hover.
- Respect reduced motion and standard browser accessibility.

### GitHub README

README header should use the icon/wordmark and succinct hero statement, then an actual screenshot, feature overview, safety note, install instructions, and links to docs. Prefer Markdown and standard GitHub rendering over elaborate HTML/CSS hacks. Do not treat the README as a separate visual brand.

## 9. Example structured content

**Hero**

> # Remove the Digital Dead Load.
> Reclaim storage, reduce system clutter, and keep your engineering workstation running efficiently.
>
> **Download for Windows** | **View on GitHub**

**Cleanup landing view**

> **System Cleanup**  
> Find and review unnecessary files before removing them.  
> **12.6 GB potentially reclaimable** *(illustrative)*  
> Temporary files | Application caches | Logs and journals  
> **Analyze Again** | **Review Cleanup**

**Confirmation**

> **Clean selected items?**  
> You're about to remove 1,284 selected files across 3 categories (estimated 4.2 GB). Review the included paths before continuing. Some deletions may not be reversible.  
> **Cancel** | **Clean Selected Items**

## 10. Design deliverables and handoff

For a complete implementation-ready system, create:

- Brand assets: icon SVG and export sizes, horizontal/stacked lockups, light/dark/monochrome variants.
- Design tokens: machine-readable color, type, spacing, radius, border, and focus definitions.
- UI components: button/checkbox/category row/risk badge/metric/progress/dialog/data table with all interaction states.
- Desktop app screens: first-run, scanning, results, expanded category details, review confirmation, cleaning, completion, history/settings.
- GitHub Pages implementation: responsive single page using actual assets and screenshots.
- README header and screenshot conventions.
- Accessibility and safety QA checklist.

### Acceptance checklist

- [ ] Feels professional and recognizable to structural engineers, without being an engineering-themed parody.
- [ ] Works at native Windows desktop sizes, high DPI, and light/dark/high-contrast modes.
- [ ] Visuals, copy, and claims are consistent between app, website, and README.
- [ ] Cleanup outcomes are specific and truthful; no unsupported guarantees.
- [ ] Every destructive action has clear scope and a meaningful review path.
- [ ] Project and recovery data are protected by conservative defaults.
- [ ] Icon is recognizable at 16 px and doesn't depend on embedded text.
- [ ] Engineering drawings remain secondary to the product content.

---

**North star:** *DeadLoad should look like a thoughtful tool an engineer would be comfortable installing on a production workstation - and one an IT administrator would be comfortable recommending.*
