# UI Polish — Tool Palette · Layers · Segment

Working branch: `worktree-ui-tool-layer-segment-polish`
Goal: address the UX review of the **left tool palette**, the **Layers** inspector tab,
and the **Segment** inspector tab. Pure UI/interaction polish — no orientation, render,
async, or segmentation-engine logic is touched. Build must stay clean; the 204-test suite
must stay green.

Status legend: ☐ todo · ◐ in progress · ☑ done · ⤬ deferred (with reason)

---

## Phase A — Left tool palette (`ToolPalette` in `MultiPanelContainer.swift`, `ActiveTool` in `PanelState.swift`)

- ☑ **A1 — Group the 11 tools into Navigate / Measure / Segment sections** with dividers
  (today they are one flat 11-icon column). Add a `ToolGroup` to `ActiveTool` (single source).
- ☑ **A2 — Context-gate the tools.** Disable the whole palette when no volume is loaded;
  additionally gate **ROI Box** on `segmentationVolume != nil` and **Brush** on
  `hasSegmentation && draftRegion == nil` (mirrors the K-shortcut + Segment-tab gating, which
  the palette currently ignores — clicking them is a silent no-op).
- ☑ **A3 — Clarify the annotation tools.** `Eraser` only deletes annotations, but in a
  segmentation app the name/icon reads as "erase mask". Tighten `displayName`/`description`
  so the Measure group is unambiguous (keep the enum `rawValue` — it's used widely).

## Phase B — Layers tab (`LayerInspectorView.swift`)

- ☑ **B1 — Inline "Add Layer…" action in the empty state.** The +/- live in the window
  toolbar (far from the list); the empty state says "add or drop here" with no button in the pane.
- ☑ **B2 — Single empty state.** Today both the list overlay AND the details pane show an
  empty state (same icon) when there are no layers — collapse to one.
- ☑ **B4 — Clarify z-order hint** ("Top renders last" → plainer wording).
- ⤬ **B3 — Tighten the sparse Mask detail pane.** Low value; documented, not done.

## Phase C — Segment tab (`SegmentInspectorView.swift`)

- ☑ **C1 — De-emphasize the (optional, slow) Brain Mask.** It is the top section and its
  Generate button is the only `.glassProminent` hero, competing with the real primary action
  (Add Region). Collapse the no-mask cluster into an opt-in disclosure so drawing a region is
  the first-glance path.
- ☑ **C2 — Move advanced params into a disclosure.** Min size / Connectivity / Constrain are
  always visible in the active-region editor; fold them into a collapsed "Advanced".
- ☑ **C4 — Clarify Mask vs Atlas export.** Add `.help`/captions so the user knows which to pick
  (single-value mask vs multi-value atlas + LUT).

## Deferred (evaluated — documented, not changed)

- ⤬ **C3 — Region-start has 3 entry points** (toolbar `+`, "New Region" buttons, palette ROI Box).
  Kept: they are distinct discovery surfaces; `beginRegion` already auto-switches the tool.
- ⤬ **C5 — Make status pills interactive.** Stretch; making only some pills tappable is itself
  inconsistent, and the actions are already reachable nearby.
- ⤬ **C6 — Duplicate draft warning** (status pill + export caption). Acceptable: glance vs detail.
- ⤬ **D1 — Unify Layers/Segment list interaction models.** Larger refactor; tracked separately.

---

## Log

### Phase A — left tool palette (done)
- `PanelState.swift`: added `enum ToolGroup { navigate, measure, segment }` + `ActiveTool.group`;
  `eraser.displayName` → "Delete Annotation" and its description now says "does not edit the mask".
- `MultiPanelContainer.swift` `ToolPalette`: renders by group with a divider between each; new
  `toolButton(_:)` + `isEnabled(_:)` gate — palette inert with no volume, ROI Box needs a volume,
  Brush needs a committed segmentation + no live draft (parity with the K key / Segment tab).
- `PanelStateTests.swift`: +2 tests (group partitions all 11 tools exactly once; spot assignments).
- Build clean; `PanelStateTests` 29/29 green.
- Commit `50adb55`.

### Phase B — Layers tab (done)
- `LayerInspectorView.swift`: the `.layers` tab now shows a single `emptyLayersState`
  (`ContentUnavailableView` with an inline **Add Layer…** `borderedProminent` action, gated on a
  loaded base image) when there are no layers, and only builds the list+details `VSplitView` once
  at least one layer exists — removing the old double placeholder (list overlay + details pane).
  Dropped the now-dead `layerList` empty overlay. z-order hint "Top renders last" → "Top draws on top".
- Pure view restructure (no logic) — no new tests. Build clean.
- Commit `8cac0f2`.

### Phase C — Segment tab (done)
- `SegmentInspectorView.swift`:
  - C1: the no-mask Brain Mask state is now a **collapsed `DisclosureGroup`** (`showBrainMaskSetup`,
    default false) with a compact `brainMaskDisclosureLabel` (tinted glyph + "Optional…" caption);
    the `.glassProminent` Generate hero only appears once the user opts in, so it no longer competes
    with Add Region. Running / mask-loaded states unchanged.
  - C2: Min size / Connectivity / Constrain wrapped in a collapsed **"Advanced" `DisclosureGroup`**
    (`showAdvanced`) inside `ActiveRegionEditor`.
  - C4: Export section gains a one-line Mask-vs-Atlas legend + a detailed `.help` tooltip on each
    Export button.
- Pure view changes (no model logic) — full suite green (XCTest 123 + swift-testing 86, 0 failures).
