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

- ☐ **B1 — Inline "Add Layer…" action in the empty state.** The +/- live in the window
  toolbar (far from the list); the empty state says "add or drop here" with no button in the pane.
- ☐ **B2 — Single empty state.** Today both the list overlay AND the details pane show an
  empty state (same icon) when there are no layers — collapse to one.
- ☐ **B4 — Clarify z-order hint** ("Top renders last" → plainer wording).
- ⤬ **B3 — Tighten the sparse Mask detail pane.** Low value; documented, not done.

## Phase C — Segment tab (`SegmentInspectorView.swift`)

- ☐ **C1 — De-emphasize the (optional, slow) Brain Mask.** It is the top section and its
  Generate button is the only `.glassProminent` hero, competing with the real primary action
  (Add Region). Collapse the no-mask cluster into an opt-in disclosure so drawing a region is
  the first-glance path.
- ☐ **C2 — Move advanced params into a disclosure.** Min size / Connectivity / Constrain are
  always visible in the active-region editor; fold them into a collapsed "Advanced".
- ☐ **C4 — Clarify Mask vs Atlas export.** Add `.help`/captions so the user knows which to pick
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
