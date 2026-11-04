# Prompt - Implement the DeadLoad Design System

You are a senior product designer, Windows desktop UX engineer, and frontend implementation specialist. Your assignment is to translate the attached **DeadLoad engineering-edition design reference PNG** and the accompanying **`DEADLOAD_DESIGN_SYSTEM.md`** into a consistent, production-quality identity and UI.

## Context

DeadLoad is a Windows utility for identifying and removing unnecessarily consumed storage (temporary files, unused caches, stale logs, and other verified cleanup candidates). Its initial audience is **professional structural engineers** working on engineering workstations, with future use across AEC and IT. "Dead load" is a real structural engineering term; use the double meaning intelligently and sparingly.

The visual direction should be **precision engineering, not edgy system-cleaner marketing**: structural navy, Windows blue, slate, white surfaces, clean linework, abstract structural layers as a brand mark, typography grounded in Segoe UI Variable, subtle blueprint-inspired accents on the website. Avoid mascots, neon, cyberpunk, gamer aesthetics, decorative gradients, oversized shadows, and flashy animations.

## Inputs and precedence

1. Read `DEADLOAD_DESIGN_SYSTEM.md` fully. It is the canonical specification for design tokens, voice, behavior, layout, and safety UX.
2. Inspect the supplied PNG. Use it as a **visual direction reference** for the overall mood, logo concept, app-shell hierarchy, palette, and GitHub page composition, **not** as an exact screenshot to duplicate.
3. Inspect the existing repository/tech stack before modifying code. Match the project's framework, build system, component conventions, and Windows-native patterns.
4. When conflicts arise: **safety and accessibility > Markdown rules > platform conventions > illustrative PNG**.

## Your work

- Create or refine reusable design tokens and UI components, not disconnected mockups.
- Create a scalable vector logo/app icon system featuring abstract structural layers or beams. Ensure it works at Windows taskbar sizes. Export required raster/ICO variants using available tooling; do not simply crop the mood board.
- Build a clean Windows app shell with a compact navigation area and views/states for **Analyze -> Review -> Clean**, including per-category sizes, risk labels, transparent item details, conservative selections, and meaningful confirmation before deletion.
- Build or update a responsive single-page GitHub Pages landing page with a clear hero, product screenshot, features, workflow, safety, downloads/source, and restrained blueprint/structural linework.
- Keep branding, iconography, component behavior, and wording consistent across app, site, and README.
- Ensure dark mode, keyboard navigation, clear focus, high contrast, reduced motion, and DPI-aware layout are appropriately handled for the stack.

## Essential product constraints

**Do not implement aggressive file deletion based on guessed paths.** Never suggest that a cache, journal, autosave, worksharing file, local model, recovery artifact, or project file is safe merely because of its location or name. For engineering applications such as Revit and Civil 3D, treat unknown/application-specific files as protected or manual-review-only until rules are researched and validated.

Never claim cleanup is reversible unless an actual tested recovery mechanism exists. Clearly separate estimated reclaimable space from actual space recovered. If the repository lacks a cleanup engine, implement the UI against clearly marked representative/demo data rather than pretending that cleanup works. Do not invent release links, endorsements, benchmarks, or compatibility claims.

## Execution approach

1. Audit repo, frameworks, design files, existing UI, and asset pipeline. Briefly document what exists and what is missing.
2. Extract reusable tokens and a component inventory from the spec.
3. Implement an initial polished vertical slice: brand/icon, desktop cleanup overview, review state, and web hero/feature sections. Adapt to the repo instead of needlessly rewriting it.
4. Complete responsive states, accessibility, light/dark styling, and copy consistency.
5. Validate builds/tests and visually inspect at relevant Windows desktop and website/mobile sizes where tools permit.
6. Record implementation decisions, assumptions, known limitations, and next steps in repo documentation.

Use GitHub-native project hygiene: focused commits, descriptive issues or TODOs for deferred work, and documentation kept beside the implementation. Avoid creating unnecessary dependencies. Do not introduce arbitrary design changes that diverge from the design system without documenting the rationale.

## Definition of done

- A coherent DeadLoad identity recognizable at 16 px, with reproducible vector and raster outputs.
- Reusable tokens/components rather than screenshot-specific CSS.
- A trustworthy, readable Windows UI and matching responsive GitHub Pages design.
- The Analyze -> Review -> Clean flow is visually and behaviorally explicit.
- Safe defaults, clearly labeled demo data where applicable, and no unsupported deletion claims.
- Practical documentation and successful build/test results, or precise explanations of any environment blockers.

**Final design test:** Would a professional structural engineer trust this UI on a production workstation, and would an IT administrator feel comfortable deploying it? If not, simplify, clarify, and make the behavior more transparent.
