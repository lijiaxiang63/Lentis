// MultiPanelContainer.swift
// Lentis
//
// The main viewer area that arranges panels in a grid (1x1 to 2x2).
// Each panel shows an image plus only the overlays that are bound to the
// pixels — orientation labels, the 3D crosshair, ROI / ruler / angle
// annotations, the group-selection chrome, and the right-edge slice scroller.
// All control toolbars and textual readouts now live OFF the image in the
// docked ViewerControlBar (top) and ViewerStatusBar (bottom).
//
// Mouse handling per panel: right-drag for W/L, scroll for navigation,
// pinch-to-zoom, two-finger pan, click to activate, Select-tool click/drag to
// move the crosshair; drag-and-drop assigns a series from the sidebar.
//
// Key types:
//   MultiPanelContainer      — Grid layout that creates PanelView per slot
//   PanelView                — Single panel: image + pixel-bound overlays + gestures
//   ModalityBadge            — CT/MRI capsule toggle (reused by ViewerControlBar)
//   PanelHistogramView       — Miniature histogram with W/L window indicator
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import QuartzCore

// MARK: - Multi-Panel Container

/// Arranges panels in a grid based on the current ViewerLayout.
struct MultiPanelContainer: View {
    @ObservedObject var model: ViewerModel
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        let layout = model.layout

        // Fullscreen mode: show only the fullscreen panel (edge-to-edge, square).
        if let fsID = model.fullscreenPanelID,
           let fsPanel = model.panels.first(where: { $0.id == fsID }) {
            PanelView(
                model: model,
                panel: fsPanel,
                isActive: true,
                isFocused: $isFocused,
                cornerRadius: 0
            )
            .id(fsPanel.id)
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.toggleFullscreen(for: fsPanel)
                }
            }
            .onTapGesture(count: 1) {
                isFocused = true
            }
        } else {
            // Grid mode — pin every cell to the available geometry. A panel's
            // image/W-L changes must not make the outer stacks ask all sibling
            // panels for their ideal size again. Rounded inset cards float on the
            // viewport backdrop, separated (and inset) by a consistent gap.
            let rows = layout.rows
            let cols = layout.columns
            let gap = Spacing.s

            GeometryReader { geometry in
                let horizontalGaps = CGFloat(max(0, cols - 1)) * gap
                let verticalGaps = CGFloat(max(0, rows - 1)) * gap
                let cellWidth = max(0, (geometry.size.width - horizontalGaps) / CGFloat(cols))
                let cellHeight = max(0, (geometry.size.height - verticalGaps) / CGFloat(rows))

                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<cols, id: \.self) { col in
                                let index = row * cols + col
                                if index < model.panels.count {
                                    let panel = model.panels[index]
                                    PanelView(
                                        model: model,
                                        panel: panel,
                                        isActive: panel.id == model.activePanelID,
                                        isFocused: $isFocused
                                    )
                                    .frame(width: cellWidth, height: cellHeight)
                                    .id(panel.id)
                                    .onTapGesture(count: 2) {
                                        // Fullscreen is disallowed in the MPR tri-planar
                                        // layout — it would break the coordinated crosshair
                                        // linkage the layout depends on.
                                        guard !model.isMPRLayout else { return }
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            model.toggleFullscreen(for: panel)
                                        }
                                    }
                                    .onTapGesture(count: 1) {
                                        model.activePanelID = panel.id
                                        isFocused = true
                                    }
                                } else {
                                    EmptyPanelView()
                                        .frame(width: cellWidth, height: cellHeight)
                                }
                            }
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height,
                       alignment: .topLeading)
            }
            .padding(gap)
            .background(Color.lentisViewport)
        }
    }
}

// MARK: - Empty Panel View

struct EmptyPanelView: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: Spacing.s) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("Drag a series here, or drop a NIfTI file")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.panel)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        }
    }
}

// MARK: - Panel View

/// Individual panel — refactored from the original DetailView.
/// Each panel has its own image, histogram, scrollbar, W/L, zoom/pan state.
struct PanelView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var panel: PanelState
    let isActive: Bool
    @FocusState.Binding var isFocused: Bool
    var cornerRadius: CGFloat = Radius.panel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Image View
            if let image = panel.image {
                PanelInteractiveImageView(model: model, panel: panel, image: image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(0)
            } else if panel.errorMessage == nil && !panel.isLoading {
                if panel.seriesIndex >= 0 {
                    // Series assigned but no image yet
                    ProgressView()
                        .controlSize(.large)
                } else {
                    EmptyPanelView()
                }
            }

            // (Per-panel control toolbars — plane/3D/modality/window/transform/4D —
            // moved off the image into the docked ViewerControlBar at the top.)

            // Shift-overlay for group selection (multi-panel only)
            if model.isShiftHeld && model.panels.count > 1 {
                ZStack {
                    if panel.isGroupSelected {
                        Color.orange.opacity(0.25)
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.orange)
                            Text("Linked")
                                .font(.headline)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Color.black.opacity(0.5)
                        VStack(spacing: 8) {
                            Image(systemName: "hand.tap")
                                .font(.system(size: 36))
                                .foregroundStyle(.white.opacity(0.7))
                            Text("Click to link\nfor group scrolling")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .allowsHitTesting(false)
                .zIndex(500)
            }

            // Cross-reference lines overlay. Observes the decoupled CrosshairState
            // (not the model) so crosshair drags don't re-lay-out this whole panel.
            if panel.image != nil && panel.panelMode.isMPR && model.panels.count > 1 && model.showCrossReference {
                CrossReferenceOverlay(panel: panel, crosshair: model.crosshair)
                    .zIndex(10)
            }

            // Calcification ROI box overlay: the draft region's 3D box drawn as
            // its cross-section + corner markers on every MPR plane.
            if panel.image != nil, panel.panelMode.isMPR, let draft = model.draftRegion,
               let vol = model.cachedVolume(forSeriesIndex: panel.seriesIndex) {
                SegmentationBoxOverlay(panel: panel, region: draft, volume: vol)
                    .zIndex(11)
            }

            // Touch-up brush footprint: a ring on the current slice showing the
            // brush size (calcBrushRadius voxels) at the cursor, so the inspector
            // slider's numeric radius reads against the image. Brush-only.
            if panel.image != nil, panel.panelMode.isMPR, model.activeTool == .calcBrush,
               let vol = model.cachedVolume(forSeriesIndex: panel.seriesIndex) {
                BrushFootprintOverlay(panel: panel, model: model, volume: vol)
                    .zIndex(12)
            }

            // ROI rectangle overlay
            if panel.image != nil, panel.panelMode != .volume3D, let roiRect = panel.roiRect {
                ROIOverlay(panel: panel, roiRect: roiRect)
                    .zIndex(12)
            }

            // Annotation overlay (rulers, angles, ROI stats)
            if panel.image != nil && panel.panelMode != .volume3D {
                AnnotationOverlay(panel: panel)
                    .zIndex(13)
            }

            // Orientation labels (A/P/R/L/S/I)
            if panel.image != nil && panel.panelMode != .volume3D {
                OrientationLabelsOverlay(orientation: panel.imageOrientationPatient,
                                         rotationSteps: panel.rotationSteps,
                                         isFlippedH: panel.isFlippedH,
                                         isFlippedV: panel.isFlippedV)
                    .zIndex(15)
            }

            // (Cursor HU/RAS/pixel readout moved off the image into the docked
            // ViewerStatusBar at the bottom; it follows the hovered panel.)

            // Error Overlay
            if let error = panel.errorMessage {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error).font(.caption)
                }
                .background(Color.black.opacity(0.8))
                .zIndex(200)
            }

            // (File name + slice position + W/L readout, and the histogram +
            // preset/Auto adjustment toolbar, moved off the image: readouts into
            // the docked ViewerStatusBar, controls into the docked ViewerControlBar.)

            // Right Side Scroller (always visible when series assigned)
            if panel.seriesIndex >= 0 && panel.panelMode != .volume3D {
                HStack {
                    Spacer()
                    PanelSliceScroller(model: model, panel: panel)
                        .frame(width: 40)
                        .padding(.trailing, 4)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)
                .zIndex(70)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        // Active-panel + group-selection borders, tracking the rounded shape. An
        // inactive panel keeps a faint hairline so its edge reads against the
        // viewport backdrop; the active panel gets the accent + a soft glow.
        .overlay {
            ZStack {
                if panel.isGroupSelected {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.lentisGroup, lineWidth: 2.5)
                }
                RoundedRectangle(cornerRadius: max(0, cornerRadius - (panel.isGroupSelected ? 3 : 0)))
                    .strokeBorder(isActive ? Color.lentisAccent : Color.white.opacity(0.07),
                                  lineWidth: isActive ? 2 : 1)
                    .padding(panel.isGroupSelected ? 3 : 0)
                    .shadow(color: isActive ? Color.lentisAccent.opacity(0.5) : .clear,
                            radius: isActive ? 5 : 0)
            }
        }
    }
}

// MARK: - Panel Interactive Image View (NSViewRepresentable)

struct PanelInteractiveImageView: NSViewRepresentable {
    @ObservedObject var model: ViewerModel
    @ObservedObject var panel: PanelState
    var image: NSImage

    func makeNSView(context: Context) -> PanelImageInteractView {
        let view = PanelImageInteractView()
        view.model = model
        view.panel = panel
        return view
    }

    func updateNSView(_ nsView: PanelImageInteractView, context: Context) {
        nsView.model = model
        nsView.panel = panel
        nsView.setImage(image)
        nsView.applyFilters()
        nsView.updateTransform()
        nsView.updateROICursor()
    }

    class PanelImageInteractView: NSView {
        weak var model: ViewerModel?
        var panel: PanelState?
        private var imageView = NSImageView()
        private var lastDragLocation: NSPoint?
        private var scrollAccumulator: CGFloat = 0.0
        private var roiStartPixel: CGPoint?  // ROI drag start in pixel coords
        // When a roiBox drag began on a resize handle, which in-plane bounds it
        // moves (nil = the drag is drawing a new box, the legacy behavior).
        private var roiResizeGrip: (BoxGrip, BoxGrip)?

        // Cursor stack state machine. The NSCursor stack is one layer deep at
        // most: either a tool cursor (pushed by updateROICursor) or a handle
        // cursor (pushed over the tool cursor while hovering a resize handle).
        // `.none` = arrow default (no custom cursor pushed); `.tool` = the
        // active-tool cursor is on top; `.handle` = a resize-handle cursor has
        // been swapped onto the tool cursor's slot. Tracking which one is live
        // (instead of a single bool) lets mouseMoved overlay a handle cursor
        // and mouseExited/updateROICursor pop exactly one layer without ever
        // under/over-popping the NSCursor stack.
        private enum CursorStackState: Equatable { case none, tool, handle }
        private var cursorStackState: CursorStackState = .none
        private var cursorTool: ActiveTool = .select
        private var wlPendingDeltaWidth: Double = 0
        private var wlPendingDeltaCenter: Double = 0
        private var wlLastRenderTime: CFTimeInterval = 0
        private let wlRenderInterval: CFTimeInterval = 1.0 / 60.0
        private var volumePendingYaw: Double = 0
        private var volumePendingPitch: Double = 0
        private var volumeLastRenderTime: CFTimeInterval = 0
        // The 192² interactive render fits inside 16.7 ms on the 721 MB
        // MPRAGE, so drive camera updates at display-rate instead of the visibly
        // stepped 30 Hz used by the first 3D implementation.
        private let volumeRenderInterval: CFTimeInterval = 1.0 / 60.0
        private var volumeDidRotate = false

        // In-progress annotation state
        private var rulerStartPixel: CGPoint?
        private var anglePoints: [CGPoint] = []

        // Prevent image dimensions from influencing SwiftUI layout
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        override func layout() {
            super.layout()
            if let layer = imageView.layer {
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                let midX = self.bounds.width / 2.0
                let midY = self.bounds.height / 2.0
                layer.position = CGPoint(x: midX, y: midY)
            }
        }

        private func setup() {
            self.wantsLayer = true
            self.layer?.backgroundColor = NSColor.black.cgColor
            self.layer?.masksToBounds = true

            imageView.imageScaling = .scaleProportionallyUpOrDown
            // Prevent NSImageView from wanting to grow to its image's natural size
            imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
            imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            self.addSubview(imageView)

            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: self.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                imageView.widthAnchor.constraint(equalTo: self.widthAnchor),
                imageView.heightAnchor.constraint(equalTo: self.heightAnchor)
            ])

            imageView.wantsLayer = true
            imageView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)

            // Register for drag & drop: series from sidebar (.string) + files/folders from Finder (.fileURL)
            registerForDraggedTypes([.string, .fileURL])
        }

        // MARK: - Drag & Drop (NSDraggingDestination)

        private func hasDraggableContent(_ sender: NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard
            // Check for series index string (from sidebar)
            if let strs = pb.readObjects(forClasses: [NSString.self]) as? [String],
               let first = strs.first, Int(first) != nil {
                return true
            }
            // Check for file URLs (from Finder)
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
               !urls.isEmpty {
                return true
            }
            return false
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            hasDraggableContent(sender) ? .copy : []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            hasDraggableContent(sender) ? .copy : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard

            // 1. Series index from sidebar
            if let strs = pb.readObjects(forClasses: [NSString.self]) as? [String],
               let first = strs.first,
               let seriesIndex = Int(first),
               let model = model, let panel = panel {
                DispatchQueue.main.async {
                    model.assignSeriesToPanel(panel, seriesIndex: seriesIndex)
                }
                return true
            }

            // 2. File/folder URL from Finder
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               let url = urls.first,
               let model = model {
                DispatchQueue.main.async {
                    model.load(url: url)
                }
                return true
            }

            return false
        }

        func setImage(_ img: NSImage) {
            if imageView.image != img {
                imageView.image = img
                DispatchQueue.main.async {
                    self.restoreState()
                }
            }
        }

        func updateTransform() { restoreState() }

        private func restoreState() {
            guard let panel = panel, let layer = imageView.layer else { return }

            // Build transform: flip → rotate → scale → translate
            var t = CATransform3DIdentity

            // Apply flip
            let flipX: CGFloat = panel.isFlippedH ? -1.0 : 1.0
            let flipY: CGFloat = panel.isFlippedV ? -1.0 : 1.0
            t = CATransform3DScale(t, flipX, flipY, 1.0)

            // Apply rotation (90° steps around Z axis)
            let angle = CGFloat(panel.rotationSteps) * .pi / 2.0
            t = CATransform3DRotate(t, angle, 0, 0, 1)

            // Apply zoom
            t = CATransform3DScale(t, panel.scale, panel.scale, 1.0)

            // Apply pan
            t = CATransform3DTranslate(t, panel.translation.x / panel.scale, panel.translation.y / panel.scale, 0)

            layer.transform = t
        }

        func applyFilters() {
            guard let panel = panel else { return }

            var filters: [CIFilter] = []

            if !panel.isRawDataAvailable {
                let currentWW = panel.windowWidth
                let currentWC = panel.windowCenter
                let initialWW = panel.initialWindowWidth
                let initialWC = panel.initialWindowCenter

                if initialWW != 0 {
                    let safeWW = currentWW == 0 ? 1 : currentWW
                    let contrast = CGFloat(initialWW / safeWW)
                    let brightness = CGFloat((initialWC - currentWC) / 255.0)

                    if let filter = CIFilter(name: "CIColorControls") {
                        filter.setDefaults()
                        filter.setValue(contrast, forKey: "inputContrast")
                        filter.setValue(brightness, forKey: "inputBrightness")
                        filters.append(filter)
                    }
                }
            }

            // Invert filter
            if panel.isInverted {
                if let invertFilter = CIFilter(name: "CIColorInvert") {
                    invertFilter.setDefaults()
                    filters.append(invertFilter)
                }
            }

            imageView.contentFilters = filters
        }

        private func saveState() {
            guard let panel = panel, let model = model, let layer = imageView.layer else { return }
            // Don't extract scale from m11 — after rotation, m11 ≠ scale.
            // panel.scale is maintained directly by zoom handlers.
            let tx = layer.transform.m41
            let ty = layer.transform.m42

            panel.translation = CGPoint(x: tx, y: ty)
            model.saveViewStateForPanel(panel, scale: panel.scale, translation: CGPoint(x: tx, y: ty))
            model.syncZoomFromPanel(panel)
        }

        override var acceptsFirstResponder: Bool { true }

        // performKeyEquivalent fires BEFORE the Input Method (Korean/Japanese/Chinese IME)
        // processes the event. This is the only reliable way to handle single-letter shortcuts
        // when a CJK input method is active. Returns true to consume the event.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard let model = model, let panel = panel else { return super.performKeyEquivalent(with: event) }
            // Only handle if this is the active panel (avoid duplicate handling across panels)
            guard panel.id == model.activePanelID else { return super.performKeyEquivalent(with: event) }
            // Only handle unmodified keys
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            guard flags.isEmpty else { return super.performKeyEquivalent(with: event) }
            guard let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }

            switch key {
            case "1":
                DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.single) } }
                return true
            case "2":
                DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoHorizontal) } }
                return true
            case "3":
                DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoVertical) } }
                return true
            case "4":
                DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.quad) } }
                return true
            case "r":
                model.resetViewForPanel(model.activePanel)
                return true
            case "l":
                // Sync scrolling is not used in MPR layout (crosshair tracks scrolls).
                if !model.isMPRLayout { model.synchronizedScrolling.toggle() }
                return true
            case "x":
                model.showCrossReference.toggle()
                return true
            case "i":
                model.invertForPanel(model.activePanel)
                return true
            case "f":
                model.fitToWindowForPanel(model.activePanel)
                return true
            case "a":
                if let p = model.activePanel {
                    // Modality-aware auto-window — same path as the Auto button.
                    model.autoWindow(for: p)
                }
                return true
            case "o":
                model.activateTool(.roiWL)
                return true
            case "s":
                model.activateTool(.roiStats)
                return true
            case "d":
                model.activateTool(.ruler)
                return true
            case "n":
                model.activateTool(.angle)
                return true
            case "e":
                model.activateTool(.eraser)
                return true
            case "b":
                // Context-gated via `activateTool` — arming ROI Box needs a loaded
                // volume, matching the palette (a no-volume `b` press is ignored).
                model.activateTool(.roiBox)
                return true
            case "k":
                // The touch-up brush edits a committed region; `activateTool` only
                // arms it when a segmentation exists and no draft is in progress
                // (the same gate the palette + Segment tab enforce).
                model.activateTool(.calcBrush)
                return true
            case "-", "_":
                // Brush size down — only while the Brush is active (otherwise
                // plain `-` typing must pass through). `[`/`]` are rotation.
                guard model.activeTool == .calcBrush else { return super.performKeyEquivalent(with: event) }
                model.adjustBrushRadius(by: -1)
                return true
            case "=", "+":
                // Brush size up — only while the Brush is active.
                guard model.activeTool == .calcBrush else { return super.performKeyEquivalent(with: event) }
                model.adjustBrushRadius(by: 1)
                return true
            case "]", ".":
                model.rotateClockwiseForPanel(model.activePanel)
                return true
            case "[", ",":
                model.rotateCounterClockwiseForPanel(model.activePanel)
                return true
            case "w":
                model.activateTool(.windowLevel)
                return true
            case "v":
                model.activateTool(.select)
                return true
            case "p":
                model.activateTool(.pan)
                return true
            case "z":
                model.activateTool(.zoom)
                return true
            case "h":
                model.flipHorizontalForPanel(model.activePanel)
                return true
            default:
                return super.performKeyEquivalent(with: event)
            }
        }

        func updateROICursor() {
            let tool = model?.activeTool ?? .select

            let desiredCursor: NSCursor
            switch tool {
            case .select:
                desiredCursor = panel?.panelMode == .volume3D ? .openHand : .arrow
            case .pan:
                desiredCursor = .openHand
            case .windowLevel:
                desiredCursor = .resizeUpDown
            case .zoom:
                desiredCursor = .crosshair
            case .roiWL, .roiStats, .ruler, .angle, .roiBox, .calcBrush:
                desiredCursor = .crosshair
            case .eraser:
                desiredCursor = .disappearingItem
            }

            // .select on an MPR panel = the system arrow (no custom cursor on
            // the stack). Pop whatever is live so the default returns.
            if tool == .select && panel?.panelMode != .volume3D {
                if cursorStackState != .none {
                    NSCursor.pop()
                    cursorStackState = .none
                }
                cursorTool = tool
                return
            }

            // Preserve an active handle-hover cursor when the tool hasn't
            // changed — SwiftUI re-evaluates (updateNSView) on W/L / slice /
            // panel mutations, and re-pushing the tool cursor here would
            // flicker away the resize hint the user is seeing.
            if cursorStackState == .handle && cursorTool == tool {
                return
            }

            // Tool changed (or first push). If a handle cursor is on top,
            // pop it first so the stack returns to the pre-handle depth before
            // we swap the tool cursor.
            if cursorStackState == .handle {
                NSCursor.pop()
                cursorStackState = .tool
            }
            if cursorStackState == .none {
                desiredCursor.push()
                cursorStackState = .tool
            } else { // .tool
                NSCursor.pop()
                desiredCursor.push()
            }
            cursorTool = tool
        }

        /// Push (or swap in) a resize-handle cursor over the tool cursor. Idempotent
        /// for the same handle cursor; called from mouseMoved while hovering a
        /// draft-box handle in the .roiBox tool.
        private func pushHandleCursor(_ cursor: NSCursor) {
            switch cursorStackState {
            case .none:
                cursor.push()
                cursorStackState = .handle
            case .tool:
                cursor.push()
                cursorStackState = .handle
            case .handle:
                NSCursor.pop()
                cursor.push()
            }
        }

        /// Pop the handle cursor (if active) and restore the active-tool cursor.
        /// Called when the cursor leaves all handles, and on mouseUp/mouseDown
        /// away from a handle, so the resize hint never outstays its welcome.
        private func clearHandleCursor() {
            guard cursorStackState == .handle else { return }
            NSCursor.pop()
            cursorStackState = .tool
            updateROICursor()
        }

        /// Show a directional resize cursor when the pointer is over a draft-box
        /// handle in the .roiBox tool; otherwise restore the tool cursor. Driven
        /// from mouseMoved, so the hint tracks the pointer at full tracking-area
        /// rate. Only the .roiBox tool can actually start a resize drag (mouseDown
        /// .roiBox → roiHandleGrip), so the hint is never shown when dragging
        /// wouldn't work — it never "lies".
        private func updateHandleHoverCursor(with event: NSEvent) {
            guard let model = model, let panel = panel,
                  model.activeTool == .roiBox,
                  let handle = roiHandleGrip(at: event),
                  let g = panel.displayedPlaneGeometry,
                  let vol = model.segmentationVolume,
                  let axes = VoxelBox.inPlaneAxes(forPlane: panel.panelMode) else {
                clearHandleCursor()
                return
            }
            let dirA = screenAxisDelta(axis: axes.0, at: handle.voxel, geometry: g, volume: vol, viewSize: bounds.size)
            let dirB = screenAxisDelta(axis: axes.1, at: handle.voxel, geometry: g, volume: vol, viewSize: bounds.size)
            pushHandleCursor(Self.resizeCursor(for: handle, dirA: dirA, dirB: dirB).nsCursor)
        }

        /// Convert a window-space NSEvent location to image pixel coordinates.
        /// Returns nil if the position is outside the image bounds.
        private func screenToPixel(_ event: NSEvent) -> CGPoint? {
            guard let panel = panel, let image = imageView.image else { return nil }

            let loc = convert(event.locationInWindow, from: nil)

            let viewW = bounds.width
            let viewH = bounds.height
            let imgW = image.size.width
            let imgH = image.size.height

            let fitScale = min(viewW / imgW, viewH / imgH)
            let displayW = imgW * fitScale
            let displayH = imgH * fitScale
            let offsetX = (viewW - displayW) / 2
            let offsetY = (viewH - displayH) / 2

            let cx = viewW / 2
            let cy = viewH / 2

            // Convert NSView Y-up to image Y-down
            var x = loc.x
            var y = viewH - loc.y

            // Undo pan (translation is screen-space; Y was inverted in pixelToScreen)
            x -= panel.translation.x
            y += panel.translation.y

            // Undo zoom (center-relative)
            x = (x - cx) / panel.scale + cx
            y = (y - cy) / panel.scale + cy

            // Undo rotation (center-relative, negative angle to reverse)
            let angle = -CGFloat(panel.rotationSteps) * .pi / 2.0
            let dx = x - cx
            let dy = y - cy
            let cosA = cos(angle)
            let sinA = sin(angle)
            x = dx * cosA - dy * sinA + cx
            y = dx * sinA + dy * cosA + cy

            // Undo flip (center-relative)
            if panel.isFlippedH { x = 2 * cx - x }
            if panel.isFlippedV { y = 2 * cy - y }

            // Convert from view space to pixel space
            let pixelX = (x - offsetX) / fitScale
            let pixelY = (y - offsetY) / fitScale

            guard pixelX.isFinite, pixelY.isFinite else { return nil }
            return CGPoint(x: pixelX, y: pixelY)
        }

        /// Convert aspect-corrected display-image coordinates back to the raw
        /// slice pixel grid used by `rawPixelData` and `PlaneGeometry`.
        private func rawPixel(fromDisplayPixel pixel: CGPoint, panel: PanelState) -> CGPoint {
            let iw = CGFloat(max(1, panel.imageWidth))
            let ih = CGFloat(max(1, panel.imageHeight))
            let dw = panel.displayImageWidth > 0 ? panel.displayImageWidth : iw
            let dh = panel.displayImageHeight > 0 ? panel.displayImageHeight : ih
            return CGPoint(x: pixel.x * iw / dw, y: pixel.y * ih / dh)
        }

        /// World coordinate (RAS mm) under the cursor, on this panel's displayed
        /// slice plane. screenToPixel yields aspect-corrected display-space
        /// coords; convert back to raw pixels (inverse of the overlay's
        /// rawToDisplay) and run through the panel's plane geometry. nil unless
        /// this is an MPR panel with valid geometry under the cursor.
        private func crosshairWorld(at event: NSEvent) -> SIMD3<Double>? {
            guard let panel = panel, panel.panelMode.isMPR,
                  let g = panel.displayedPlaneGeometry,
                  let disp = screenToPixel(event), disp.x.isFinite, disp.y.isFinite
            else { return nil }
            let raw = rawPixel(fromDisplayPixel: disp, panel: panel)
            return g.world(col: Double(raw.x), row: Double(raw.y))
        }

        /// In multi-panel MPR with the crosshair enabled, place the shared 3D
        /// crosshair at the click and relocate the other panels. No-op otherwise
        /// (so a plain Select click just activates the panel, as before).
        private func setCrosshairFromEvent(_ event: NSEvent) {
            guard let model = model, let panel = panel,
                  model.showCrossReference, model.panels.count > 1,
                  let world = crosshairWorld(at: event) else { return }
            model.setCrosshair(world, from: panel)
        }

        /// Canonical voxel under the cursor on this MPR plane — for the
        /// calcification touch-up brush. nil off an MPR panel / with no volume.
        private func brushVoxel(at event: NSEvent) -> (Int, Int, Int)? {
            guard let model = model, let world = crosshairWorld(at: event),
                  let vol = model.segmentationVolume else { return nil }
            let v = vol.worldToVoxel(world)
            guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { return nil }
            return (Int(v.x.rounded()), Int(v.y.rounded()), Int(v.z.rounded()))
        }

        /// If `event` is within grab distance of one of the draft box's resize
        /// handles on this plane, return that handle (its in-plane grip pair +
        /// voxel coordinate). Returns nil when there is no draft, the plane is
        /// not MPR, the box is empty, or the cursor isn't near any handle.
        /// Shared by mouseDown (to start a resize drag) and mouseMoved (to show
        /// a directional resize cursor on hover), so the grab target can never
        /// drift from the drawn dots (`panel.viewPoint(forRawPixel:)` is the
        /// SAME forward transform the overlay draws with).
        private func roiHandleGrip(at event: NSEvent) -> BoxHandle? {
            guard let model = model, let panel = panel, panel.panelMode.isMPR,
                  let draft = model.draftRegion, !draft.box.isEmpty,
                  let g = panel.displayedPlaneGeometry,
                  let vol = model.segmentationVolume else { return nil }
            let handles = draft.box.handles(plane: panel.panelMode, sliceIndex: panel.mprSliceIndex)
            guard !handles.isEmpty else { return nil }
            let loc = convert(event.locationInWindow, from: nil)
            // viewPoint returns top-left/y-down coords; NSView is y-up.
            let cursor = CGPoint(x: loc.x, y: bounds.height - loc.y)
            let threshold: CGFloat = 12
            var best: BoxHandle?
            var bestDist = threshold
            for h in handles {
                let raw = g.pixel(of: vol.voxelToWorld(h.voxel))
                let pt = panel.viewPoint(forRawPixel: raw, viewSize: bounds.size)
                let d = hypot(pt.x - cursor.x, pt.y - cursor.y)
                if d < bestDist { bestDist = d; best = h }
            }
            return best
        }

        /// Screen-space direction (y-down, view coords) of one step along voxel
        /// `axis` starting at `voxel`, via the ONE shared forward transform
        /// (`voxelToWorld` → `PlaneGeometry.pixel` → `viewPoint`). Mirrors how
        /// `SegmentationBoxOverlay` and `roiHandleGrip` project, so the resize
        /// cursor's on-screen orientation stays correct under zoom/pan/flip and
        /// a 90° panel rotation (where in-plane axis A may map to vertical).
        private func screenAxisDelta(axis: Int, at voxel: SIMD3<Double>,
                                     geometry: PlaneGeometry, volume: VolumeData,
                                     viewSize: CGSize) -> CGPoint {
            var next = voxel
            next[axis] += 1
            let p0 = panel?.viewPoint(forRawPixel: geometry.pixel(of: volume.voxelToWorld(voxel)), viewSize: viewSize) ?? .zero
            let p1 = panel?.viewPoint(forRawPixel: geometry.pixel(of: volume.voxelToWorld(next)), viewSize: viewSize) ?? .zero
            return CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
        }

        /// Which directional resize cursor a handle should show. AppKit provides
        /// only the two cardinal resize cursors (`resizeLeftRight`/`resizeUpDown`),
        /// so the two diagonals are rendered from SF Symbols (lazily, once).
        enum ResizeCursorKind: Equatable {
            case leftRight, upDown, diagUpLeftDownRight, diagUpRightDownLeft

            /// The `NSCursor` for this kind. Cardinal kinds use the built-in
            /// cursors; diagonals are built once from SF Symbols and cached.
            var nsCursor: NSCursor {
                switch self {
                case .leftRight: return .resizeLeftRight
                case .upDown: return .resizeUpDown
                case .diagUpLeftDownRight:
                    if let c = Self.diagUpLeftDownRightCursor { return c }
                    let c = Self.makeDiagonalCursor(symbol: "arrow.up.left.and.arrow.down.right")
                    Self.diagUpLeftDownRightCursor = c
                    return c
                case .diagUpRightDownLeft:
                    if let c = Self.diagUpRightDownLeftCursor { return c }
                    let c = Self.makeDiagonalCursor(symbol: "arrow.up.right.and.arrow.down.left")
                    Self.diagUpRightDownLeftCursor = c
                    return c
                }
            }

            private static var diagUpLeftDownRightCursor: NSCursor?
            private static var diagUpRightDownLeftCursor: NSCursor?

            /// Build a centered-hot-spot cursor from an SF Symbol name.
            private static func makeDiagonalCursor(symbol: String) -> NSCursor {
                guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Diagonal resize") else {
                    return .crosshair
                }
                // Render at a fixed point size so the cursor isn't tiny.
                let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                let rendered = img.withSymbolConfiguration(cfg) ?? img
                let size = rendered.size
                return NSCursor(image: rendered, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
            }
        }

        /// Pick a directional resize cursor for a handle given the screen
        /// directions of the plane's two in-plane voxel axes (each as returned
        /// by `screenAxisDelta`). Corners move both axes → diagonal cursor;
        /// edge midpoints move one axis → that axis's cursor. The cursor is
        /// direction-agnostic about which end of the handle is grabbed, so the
        /// two opposing diagonal cursors collapse to the same choice by sign.
        static func resizeCursor(for handle: BoxHandle, dirA: CGPoint, dirB: CGPoint) -> ResizeCursorKind {
            let movesA = handle.gripA != .fixed
            let movesB = handle.gripB != .fixed
            let dx: CGFloat
            let dy: CGFloat
            if movesA && movesB {
                // Corner — both axes move; the drag direction is the sum.
                dx = dirA.x + dirB.x
                dy = dirA.y + dirB.y
            } else if movesA {
                dx = dirA.x; dy = dirA.y
            } else if movesB {
                dx = dirB.x; dy = dirB.y
            } else {
                return .leftRight
            }
            return directionalResizeCursor(dx: dx, dy: dy)
        }

        /// Map an unnormalized screen-space drag direction (y-down) to one of
        /// the four directional resize cursor kinds. The 2.5× ratio distinguishes
        /// "mostly horizontal/vertical" from diagonal; for the diagonal case
        /// the cursor only cares about which diagonal, so `(dx,dy)` and
        /// `(-dx,-dy)` (same handle, opposite end) map to the same kind.
        /// Pure — unit-tested without an NSView.
        static func directionalResizeCursor(dx: CGFloat, dy: CGFloat) -> ResizeCursorKind {
            let ax = abs(dx), ay = abs(dy)
            // Guard against a degenerate (zero) direction.
            if ax < 1e-6 && ay < 1e-6 { return .leftRight }
            if ax > 2.5 * ay { return .leftRight }
            if ay > 2.5 * ax { return .upDown }
            // Diagonal. In y-down screen space, (dx>0, dy>0) points down-right
            // ↔ the ↖↘ cursor; (dx>0, dy<0) points up-right ↔ the ↗↙ cursor.
            let sameSign = (dx >= 0) == (dy >= 0)
            return sameSign ? .diagUpLeftDownRight : .diagUpRightDownLeft
        }

        override func mouseDown(with event: NSEvent) {
            // Shift+click: toggle group selection via overlay
            if event.modifierFlags.contains(.shift), let panel = panel, let model = model, model.panels.count > 1 {
                DispatchQueue.main.async {
                    panel.isGroupSelected.toggle()
                }
                return
            }

            // Activate this panel on click and become first responder
            // (first responder is needed so keyDown: reaches this view, not the SwiftUI host)
            if let panel = panel, let model = model {
                window?.makeFirstResponder(self)
                DispatchQueue.main.async {
                    model.activePanelID = panel.id
                }
            }

            guard let model = model, let panel = panel else { return }

            // Modifier overrides: Option/Control + left-click starts pan
            let mods = event.modifierFlags.intersection([.option, .control])
            if !mods.isEmpty {
                lastDragLocation = event.locationInWindow
                return
            }

            switch model.activeTool {
            case .select:
                if panel.panelMode == .volume3D {
                    // The default pointer directly manipulates the 3D camera.
                    lastDragLocation = event.locationInWindow
                    volumePendingYaw = 0
                    volumePendingPitch = 0
                    volumeDidRotate = false
                } else {
                    // On MPR, Select doubles as the crosshair localizer.
                    setCrosshairFromEvent(event)
                }

            case .pan:
                // Record the drag anchor. The Pan tool (and the Opt/Ctrl
                // modifier pan) derives motion from absolute locationInWindow
                // differences, not NSEvent.deltaX/deltaY (coalesced/synthetic
                // events can report zero deltas — the same root cause as the
                // 3D rotation "stuck then jump" bug). On the 3D panel, pan is
                // gated off via canActivate, but if it's already active when
                // the 3D panel is clicked this anchor also seeds the rotation
                // drag (rotatesVolumeOnPrimaryDrag == true for .pan).
                lastDragLocation = event.locationInWindow

            case .windowLevel:
                lastDragLocation = event.locationInWindow
                wlPendingDeltaWidth = 0
                wlPendingDeltaCenter = 0

            case .zoom:
                lastDragLocation = event.locationInWindow

            case .roiWL, .roiStats:
                if let px = screenToPixel(event) {
                    roiStartPixel = px
                    panel.roiRect = CGRect(x: px.x, y: px.y, width: 0, height: 0)
                }

            case .ruler:
                if let px = screenToPixel(event) {
                    if rulerStartPixel == nil {
                        // First click: record start
                        rulerStartPixel = px
                        panel.rulerPreviewStart = px
                        panel.rulerPreviewEnd = px
                    } else {
                        // Second click: finalize ruler
                        let start = rulerStartPixel!
                        let dx = Double(px.x - start.x)
                        let dy = Double(px.y - start.y)
                        var distance: Double
                        if let ps = panel.pixelSpacing {
                            distance = sqrt(pow(dx * ps.1, 2) + pow(dy * ps.0, 2))
                        } else {
                            distance = sqrt(dx * dx + dy * dy)
                        }
                        let annotation = Annotation(type: .ruler(start: start, end: px, distanceMM: distance))
                        panel.annotations.append(annotation)
                        // Clear preview
                        rulerStartPixel = nil
                        panel.rulerPreviewStart = nil
                        panel.rulerPreviewEnd = nil
                    }
                }

            case .angle:
                if let px = screenToPixel(event) {
                    anglePoints.append(px)
                    panel.anglePreviewPoints = anglePoints
                    if anglePoints.count == 3 {
                        // Compute angle using dot product
                        let vertex = anglePoints[1]
                        let arm1 = anglePoints[0]
                        let arm2 = anglePoints[2]
                        let v1 = CGPoint(x: arm1.x - vertex.x, y: arm1.y - vertex.y)
                        let v2 = CGPoint(x: arm2.x - vertex.x, y: arm2.y - vertex.y)
                        let dot = Double(v1.x * v2.x + v1.y * v2.y)
                        let mag1 = sqrt(Double(v1.x * v1.x + v1.y * v1.y))
                        let mag2 = sqrt(Double(v2.x * v2.x + v2.y * v2.y))
                        var degrees = 0.0
                        if mag1 > 0 && mag2 > 0 {
                            let cosAngle = max(-1, min(1, dot / (mag1 * mag2)))
                            degrees = acos(cosAngle) * 180.0 / .pi
                        }
                        let annotation = Annotation(type: .angle(vertex: vertex, arm1: arm1, arm2: arm2, degrees: degrees))
                        panel.annotations.append(annotation)
                        // Clear preview
                        anglePoints = []
                        panel.anglePreviewPoints = []
                    }
                }

            case .eraser:
                // SEAM (Phase 7 segmentation): the Eraser/ROI tools are retained
                // as the editing surface for a future intracranial-calcification
                // mask. A "paint mask" sub-mode would map this click to a voxel
                // exactly as the crosshair does — screenToPixel → raw pixel via
                // panel.displayedPlaneGeometry → PlaneGeometry.world → volume
                // worldToVoxel — then `volume.ensureLabelMask().setLabel(_:x:y:z:)`
                // (or 0 to erase) and re-render through loadMPRSlice (which already
                // composites volume.labelMask). The annotation-erase below is the
                // current, unchanged behavior.
                if let px = screenToPixel(event) {
                    // Find nearest annotation and remove it
                    let threshold: CGFloat = 15.0
                    var bestIdx: Int? = nil
                    var bestDist: CGFloat = .infinity
                    for (i, ann) in panel.annotations.enumerated() {
                        let dist = distanceToAnnotation(ann, from: px)
                        if dist < bestDist {
                            bestDist = dist
                            bestIdx = i
                        }
                    }
                    if let idx = bestIdx, bestDist < threshold {
                        panel.annotations.remove(at: idx)
                    }
                }

            case .roiBox:
                // If the click grabbed a resize handle of the existing draft box,
                // begin a resize drag; otherwise start a new in-plane rect
                // (finalized into a 3D slab box on mouseUp; drawn by ROIOverlay).
                roiResizeGrip = nil
                if panel.panelMode.isMPR {
                    if let handle = roiHandleGrip(at: event) {
                        roiResizeGrip = (handle.gripA, handle.gripB)
                    } else if let px = screenToPixel(event) {
                        roiStartPixel = px
                        panel.roiRect = CGRect(x: px.x, y: px.y, width: 0, height: 0)
                        // Drawing a new box replaces the old one; drop the resize
                        // hint until the pointer returns over a handle.
                        clearHandleCursor()
                    }
                }

            case .calcBrush:
                // Start a new brush stroke so every paintBrush call between now
                // and mouseUp records into one undo backup (one stroke = one ⌘Z).
                model.beginBrushStroke()
                if let v = brushVoxel(at: event) {
                    model.paintBrush(atVoxel: v, radius: model.calcBrushRadius, erase: model.calcBrushErase)
                }
            }
        }

        /// Compute minimum distance from a point to an annotation
        private func distanceToAnnotation(_ annotation: Annotation, from point: CGPoint) -> CGFloat {
            switch annotation.type {
            case .ruler(let start, let end, _):
                return pointToSegmentDistance(point, start, end)
            case .angle(let vertex, let arm1, let arm2, _):
                let d1 = pointToSegmentDistance(point, arm1, vertex)
                let d2 = pointToSegmentDistance(point, vertex, arm2)
                return min(d1, d2)
            case .roiStats(let rect, _, _, _, _, _):
                // Distance to rectangle edges
                let closest = CGPoint(
                    x: max(rect.minX, min(point.x, rect.maxX)),
                    y: max(rect.minY, min(point.y, rect.maxY))
                )
                return hypot(point.x - closest.x, point.y - closest.y)
            }
        }

        /// Distance from a point to a line segment
        private func pointToSegmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lenSq = dx * dx + dy * dy
            if lenSq == 0 { return hypot(p.x - a.x, p.y - a.y) }
            var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
            t = max(0, min(1, t))
            let projX = a.x + t * dx
            let projY = a.y + t * dy
            return hypot(p.x - projX, p.y - projY)
        }

        override func keyDown(with event: NSEvent) {
            guard let model = model, let panel = panel else {
                super.keyDown(with: event)
                return
            }

            // Arrow keys by keyCode (not affected by IME)
            let code = event.keyCode
            switch code {
            case 123: model.navigatePanel(panel, direction: .prevSeries); return
            case 124: model.navigatePanel(panel, direction: .nextSeries); return
            case 126: model.navigatePanelWithGroup(panel, direction: .prevImage); return
            case 125: model.navigatePanelWithGroup(panel, direction: .nextImage); return
            case 53: // Escape
                if model.draftRegion != nil || model.activeTool == .roiBox {
                    model.cancelActiveRegion()
                    model.activeTool = .select
                    return
                }
                if !model.groupSelectedPanels.isEmpty {
                    model.clearGroupSelection(); return
                }
            default: break
            }

            // Handle letter/symbol shortcuts using charactersIgnoringModifiers
            // This returns the physical key regardless of IME (Korean, Japanese, Chinese)
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            if flags.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() {
                switch key {
                case "1":
                    DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.single) } }
                    return
                case "2":
                    DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoHorizontal) } }
                    return
                case "3":
                    DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoVertical) } }
                    return
                case "4":
                    DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.quad) } }
                    return
                case "r": model.resetViewForPanel(model.activePanel); return
                case "l":
                    // Sync scrolling is not used in MPR layout (crosshair tracks scrolls).
                    if !model.isMPRLayout { model.synchronizedScrolling.toggle() }
                    return
                case "x": model.showCrossReference.toggle(); return
                case "i": model.invertForPanel(model.activePanel); return
                case "f": model.fitToWindowForPanel(model.activePanel); return
                case "a":
                    if let p = model.activePanel { model.autoWindow(for: p) }
                    return
                case "o": model.activateTool(.roiWL); return
                case "s": model.activateTool(.roiStats); return
                case "d": model.activateTool(.ruler); return
                case "n": model.activateTool(.angle); return
                case "e": model.activateTool(.eraser); return
                case "]", ".": model.rotateClockwiseForPanel(model.activePanel); return
                case "[", ",": model.rotateCounterClockwiseForPanel(model.activePanel); return
                case "w": model.activateTool(.windowLevel); return
                case "v": model.activateTool(.select); return
                case "p": model.activateTool(.pan); return
                case "z": model.activateTool(.zoom); return
                case "h": model.flipHorizontalForPanel(model.activePanel); return
                default: break
                }
            }

            // Not handled — pass to default (including IME)
            super.keyDown(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            // Option/Control+Scroll or Zoom tool active = Zoom
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control) || model?.activeTool == .zoom {
                guard let panel = panel else { return }
                let dy = event.deltaY
                if dy == 0 { return }
                let zoomSpeed: CGFloat = 0.05
                let delta = dy * zoomSpeed
                var newScale = panel.scale + CGFloat(delta)
                newScale = max(0.1, min(10.0, newScale))
                panel.scale = newScale
                restoreState()
                return
            }

            // Ignore momentum (inertial) scroll events — they fight direction changes
            if event.momentumPhase.rawValue != 0 {
                return
            }

            // Reset accumulator when gesture ends
            if event.phase == .ended || event.phase == .cancelled {
                scrollAccumulator = 0
                return
            }

            guard let model = model, let panel = panel else { return }

            if event.hasPreciseScrollingDeltas {
                // Trackpad: accumulate pixel-level deltas
                let delta = event.scrollingDeltaY
                if delta == 0 { return }

                // Reset accumulator on direction change for immediate responsiveness
                if scrollAccumulator != 0 && ((scrollAccumulator > 0) != (delta > 0)) {
                    scrollAccumulator = 0
                }
                scrollAccumulator += delta

                let threshold: CGFloat = 25.0
                if abs(scrollAccumulator) >= threshold {
                    if scrollAccumulator > 0 {
                        model.navigatePanelWithGroup(panel, direction: .prevImage)
                    } else {
                        model.navigatePanelWithGroup(panel, direction: .nextImage)
                    }
                    scrollAccumulator = 0
                }
            } else {
                // Mouse wheel: navigate immediately per click
                let dy = event.deltaY
                if dy == 0 { return }
                if dy > 0 {
                    model.navigatePanelWithGroup(panel, direction: .prevImage)
                } else {
                    model.navigatePanelWithGroup(panel, direction: .nextImage)
                }
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            // Activate panel on right-click too
            if let panel = panel, let model = model {
                DispatchQueue.main.async {
                    model.activePanelID = panel.id
                }
            }
            wlPendingDeltaWidth = 0
            wlPendingDeltaCenter = 0
            lastDragLocation = event.locationInWindow
        }

        override func rightMouseDragged(with event: NSEvent) {
            guard let start = lastDragLocation, let panel = panel else { return }
            let current = event.locationInWindow

            let dx = Double(current.x - start.x)
            let dy = Double(current.y - start.y)

            let currentWW = panel.windowWidth
            let dynamicFactor = max(0.1, currentWW / 500.0)
            let sensitivity: Double = 1.0 * dynamicFactor

            wlPendingDeltaWidth += dx * sensitivity
            wlPendingDeltaCenter += dy * sensitivity
            flushPendingWindowLevelIfNeeded(force: false)
            lastDragLocation = current
        }

        override func rightMouseUp(with event: NSEvent) {
            flushPendingWindowLevelIfNeeded(force: true)
            lastDragLocation = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let panel = panel, let model = model else { return }

            // Modifier overrides: Option/Control + left-drag = pan. Like the Pan
            // tool, motion comes from absolute locationInWindow deltas (the
            // mouseDown handler seeded lastDragLocation), not the unreliable
            // NSEvent.deltaX/deltaY — coalesced/synthetic events can report
            // zero deltas even when the cursor moved (the 3D rotation bug's
            // root cause). The sign convention is preserved via PanelPanDelta.
            let mods = event.modifierFlags.intersection([.option, .control])
            if !mods.isEmpty {
                guard let layer = imageView.layer else { return }
                let current = event.locationInWindow
                if let previous = lastDragLocation {
                    let d = PanelPanInteraction.panDelta(from: previous, to: current)
                    layer.transform.m41 += d.dx
                    layer.transform.m42 += d.dy
                    saveState()
                }
                lastDragLocation = current
                return
            }

            if panel.panelMode == .volume3D && model.activeTool.rotatesVolumeOnPrimaryDrag {
                // Trackball-style camera: horizontal drag = yaw, vertical = pitch.
                // Use absolute locations instead of NSEvent.deltaX/deltaY:
                // coalesced and synthetic macOS drag events may report zero
                // deltas even though their cursor location moved, producing
                // the intermittent "stuck then jump" horizontal rotation.
                let current = event.locationInWindow
                guard let previous = lastDragLocation else {
                    lastDragLocation = current
                    return
                }
                let delta = VolumeRotationInteraction.rotationDelta(
                    from: previous,
                    to: current
                )
                volumePendingYaw += delta.yaw
                volumePendingPitch += delta.pitch
                lastDragLocation = current
                volumeDidRotate = true
                flushPendingVolumeRotationIfNeeded(force: false)
                return
            }

            switch model.activeTool {
            case .select:
                if panel.panelMode != .volume3D {
                    // Drag the crosshair (continuous localizer) in multi-panel MPR.
                    setCrosshairFromEvent(event)
                }

            case .pan:
                // Left-click drag = pan (MPR; the 3D panel routes .pan through
                // the rotation branch above via rotatesVolumeOnPrimaryDrag).
                // Absolute-coordinate delta — NSEvent.deltaX/deltaY are
                // unreliable on coalesced/synthetic drag events, so the Pan
                // tool was effectively dead on trackpads until this matched
                // the 3D rotation fix's absolute-coordinate approach.
                guard let layer = imageView.layer else { return }
                let current = event.locationInWindow
                if let previous = lastDragLocation {
                    let d = PanelPanInteraction.panDelta(from: previous, to: current)
                    layer.transform.m41 += d.dx
                    layer.transform.m42 += d.dy
                    saveState()
                }
                lastDragLocation = current

            case .windowLevel:
                // W/L adjustment (same as right-drag)
                guard let start = lastDragLocation else { return }
                let current = event.locationInWindow
                let dx = Double(current.x - start.x)
                let dy = Double(current.y - start.y)
                let currentWW = panel.windowWidth
                let dynamicFactor = max(0.1, currentWW / 500.0)
                let sensitivity: Double = 1.0 * dynamicFactor
                wlPendingDeltaWidth += dx * sensitivity
                wlPendingDeltaCenter += dy * sensitivity
                flushPendingWindowLevelIfNeeded(force: false)
                lastDragLocation = current

            case .zoom:
                // Drag up = zoom in, drag down = zoom out
                guard let start = lastDragLocation else { return }
                let current = event.locationInWindow
                let dy = current.y - start.y
                let zoomSpeed: CGFloat = 0.005
                var newScale = panel.scale + dy * zoomSpeed
                newScale = max(0.1, min(10.0, newScale))
                panel.scale = newScale
                restoreState()
                lastDragLocation = current

            case .roiWL, .roiStats:
                // Update ROI rectangle
                if let start = roiStartPixel, let current = screenToPixel(event) {
                    let x = min(start.x, current.x)
                    let y = min(start.y, current.y)
                    let w = abs(current.x - start.x)
                    let h = abs(current.y - start.y)
                    panel.roiRect = CGRect(x: x, y: y, width: w, height: h)
                }

            case .ruler:
                // Update preview line endpoint
                if rulerStartPixel != nil, let current = screenToPixel(event) {
                    panel.rulerPreviewEnd = current
                }

            case .angle:
                // Update preview line endpoint
                if !anglePoints.isEmpty, let current = screenToPixel(event) {
                    var preview = anglePoints
                    preview.append(current)
                    panel.anglePreviewPoints = preview
                }

            case .roiBox:
                if let grip = roiResizeGrip {
                    // Live-resize the draft box by the grabbed handle.
                    if let disp = screenToPixel(event) {
                        let raw = rawPixel(fromDisplayPixel: disp, panel: panel)
                        model.resizeActiveRegionBox(gripA: grip.0, gripB: grip.1, rawPixel: raw, panel: panel)
                    }
                } else if let start = roiStartPixel, let current = screenToPixel(event) {
                    let x = min(start.x, current.x)
                    let y = min(start.y, current.y)
                    let w = abs(current.x - start.x)
                    let h = abs(current.y - start.y)
                    panel.roiRect = CGRect(x: x, y: y, width: w, height: h)
                }

            case .calcBrush:
                if let v = brushVoxel(at: event) {
                    model.paintBrush(atVoxel: v, radius: model.calcBrushRadius, erase: model.calcBrushErase)
                }

            case .eraser:
                break
            }
        }

        override func mouseUp(with event: NSEvent) {
            guard let panel = panel, let model = model else { return }

            switch model.activeTool {
            case .select:
                if panel.panelMode == .volume3D {
                    flushPendingVolumeRotationIfNeeded(force: true)
                    lastDragLocation = nil
                }

            case .pan:
                if panel.panelMode == .volume3D {
                    flushPendingVolumeRotationIfNeeded(force: true)
                }
                // Clear the drag anchor on both MPR and 3D (the MPR pan path
                // uses lastDragLocation too now, so leaving it set would let a
                // later non-pan drag jump from the stale anchor).
                lastDragLocation = nil

            case .roiWL:
                if let rect = panel.roiRect, rect.width > 1 && rect.height > 1 {
                    model.autoWindowLevelForPanelROI(panel, rect: rect)
                }
                roiStartPixel = nil
                panel.roiRect = nil

            case .roiStats:
                if let rect = panel.roiRect, rect.width > 1 && rect.height > 1 {
                    if let stats = model.computeROIStats(panel: panel, rect: rect) {
                        let annotation = Annotation(type: .roiStats(
                            rect: rect,
                            mean: stats.mean, max: stats.max, min: stats.min,
                            stdDev: stats.stdDev, count: stats.count
                        ))
                        panel.annotations.append(annotation)
                    }
                }
                roiStartPixel = nil
                panel.roiRect = nil

            case .windowLevel:
                flushPendingWindowLevelIfNeeded(force: true)
                lastDragLocation = nil

            case .roiBox:
                if roiResizeGrip != nil {
                    // The box was updated live during the drag; nothing to finalize.
                    roiResizeGrip = nil
                } else if let start = roiStartPixel {
                    // Finalize the in-plane rect into a 3D slab box (raw pixels →
                    // plane geometry → voxel) and drive the segmentation preview.
                    let endDisplay = screenToPixel(event) ?? start
                    let rawA = rawPixel(fromDisplayPixel: start, panel: panel)
                    let rawB = rawPixel(fromDisplayPixel: endDisplay, panel: panel)
                    if abs(rawA.x - rawB.x) > 1 || abs(rawA.y - rawB.y) > 1 {
                        model.setActiveRegionBox(fromRawCornerA: rawA, cornerB: rawB, panel: panel)
                    }
                }
                roiStartPixel = nil
                panel.roiRect = nil
                // Release may land away from the handle; restore the tool cursor
                // (mouseMoved will re-show the resize hint if still over a handle).
                clearHandleCursor()

            case .calcBrush:
                // Reconcile per-region counts after a brush stroke.
                model.recomputeRegionVoxelCounts()
                // Register the single undo for the whole stroke (mouseDown→up).
                model.endBrushStroke(undoManager: self.undoManager)

            default:
                break
            }
        }

        private func flushPendingWindowLevelIfNeeded(force: Bool) {
            guard let model = model, let panel = panel else { return }

            let now = CACurrentMediaTime()
            let hasPending = wlPendingDeltaWidth != 0 || wlPendingDeltaCenter != 0
            if hasPending && (force || (now - wlLastRenderTime) >= wlRenderInterval) {
                // Per-flush: panel-local only (persist: false) — so a W/L drag does
                // NOT write the model's @Published seriesStates and thus does not
                // fire model.objectWillChange → does not re-lay-out the whole quad.
                model.adjustWindowLevelForPanel(panel, deltaWidth: wlPendingDeltaWidth,
                                                deltaCenter: wlPendingDeltaCenter, persist: false)
                applyFilters()
                wlPendingDeltaWidth = 0
                wlPendingDeltaCenter = 0
                wlLastRenderTime = now
            }
            // Drag END: commit the final window to the model exactly once.
            if force {
                model.persistWindowToSeriesStates(panel)
            }
        }

        private func flushPendingVolumeRotationIfNeeded(force: Bool) {
            guard let model, let panel, panel.panelMode == .volume3D else { return }
            let now = CACurrentMediaTime()
            let hasPending = volumePendingYaw != 0 || volumePendingPitch != 0
            if hasPending && (force || (now - volumeLastRenderTime) >= volumeRenderInterval) {
                model.rotateVolumeRendering(
                    panel,
                    deltaYaw: volumePendingYaw,
                    deltaPitch: volumePendingPitch,
                    interactive: !force
                )
                volumePendingYaw = 0
                volumePendingPitch = 0
                volumeLastRenderTime = now
            } else if force && volumeDidRotate {
                // Even if the last delta was already flushed, settle at full quality.
                model.loadVolumeRendering(for: panel)
            }
            if force { volumeDidRotate = false }
        }

        // MARK: - Mouse Tracking for HU Readout

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas {
                removeTrackingArea(area)
            }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            updateROICursor()
        }

        override func mouseExited(with event: NSEvent) {
            panel?.showCursorInfo = false
            if cursorStackState != .none {
                NSCursor.pop()
                cursorStackState = .none
            }
        }

        override func mouseMoved(with event: NSEvent) {
            guard let panel = panel, imageView.image != nil else {
                panel?.showCursorInfo = false
                return
            }
            guard panel.panelMode != .volume3D else {
                panel.showCursorInfo = false
                return
            }

            // Show a directional resize cursor when hovering a draft-box handle
            // in the .roiBox tool (restores the tool cursor when not). Placed
            // before the screenToPixel guard so the hint still works when a
            // handle sits just outside the image bounds.
            updateHandleHoverCursor(with: event)

            // Update ruler/angle preview line to follow mouse
            if let model = model, let currentPixel = screenToPixel(event) {
                switch model.activeTool {
                case .ruler:
                    if rulerStartPixel != nil {
                        panel.rulerPreviewEnd = currentPixel
                    }
                case .angle:
                    if !anglePoints.isEmpty, anglePoints.count < 3 {
                        panel.anglePreviewPoints = anglePoints + [currentPixel]
                    }
                default:
                    break
                }
            }

            // Use raw slice pixels for the status readout and value lookup.
            guard let displayPixelPoint = screenToPixel(event) else {
                panel.showCursorInfo = false
                return
            }
            let rawPixelPoint = rawPixel(fromDisplayPixel: displayPixelPoint, panel: panel)
            let pixelX = rawPixelPoint.x
            let pixelY = rawPixelPoint.y

            // Safe Double→Int conversion (pixelX/Y can be NaN/Inf with degenerate transforms)
            guard pixelX.isFinite, pixelY.isFinite else {
                panel.showCursorInfo = false
                return
            }
            let px = Int(max(-1, min(Double(Int.max / 2), pixelX)))
            let py = Int(max(-1, min(Double(Int.max / 2), pixelY)))

            guard px >= 0, px < panel.imageWidth, py >= 0, py < panel.imageHeight else {
                panel.showCursorInfo = false
                return
            }

            // Only update if position changed (throttle view updates)
            guard px != panel.cursorPixelX || py != panel.cursorPixelY || !panel.showCursorInfo else { return }

            // Look up raw pixel value
            var huValue: Double = 0
            if let data = panel.rawPixelData {
                let index = py * panel.imageWidth + px
                if panel.bitDepth > 8 {
                    let byteIndex = index * 2
                    if byteIndex + 1 < data.count {
                        data.withUnsafeBytes { raw in
                            if let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt16.self) {
                                if panel.isSigned {
                                    huValue = Double(Int16(bitPattern: ptr[index]))
                                } else {
                                    huValue = Double(ptr[index])
                                }
                            }
                        }
                    }
                } else if index < data.count {
                    huValue = Double(data[index])
                }
            }

            panel.cursorPixelX = px
            panel.cursorPixelY = py
            // Apply intensity calibration: stored → HU (CT) / native intensity (MRI).
            panel.cursorHU = huValue * panel.rescaleSlope + panel.rescaleIntercept
            panel.showCursorInfo = true

            if let geometry = panel.displayedPlaneGeometry {
                let patPos = geometry.world(col: Double(px), row: Double(py))
                panel.cursorPatientX = patPos.x
                panel.cursorPatientY = patPos.y
                panel.cursorPatientZ = patPos.z
                panel.hasCursorPatientPosition = true

                if let volume = model?.cachedVolume(forSeriesIndex: panel.seriesIndex) {
                    let voxel = volume.worldToVoxel(patPos)
                    if voxel.x.isFinite, voxel.y.isFinite, voxel.z.isFinite {
                        panel.cursorVoxelX = min(max(0, Int(voxel.x.rounded())), volume.width - 1)
                        panel.cursorVoxelY = min(max(0, Int(voxel.y.rounded())), volume.height - 1)
                        panel.cursorVoxelZ = min(max(0, Int(voxel.z.rounded())), volume.depth - 1)
                        panel.hasCursorVoxelPosition = true
                    } else {
                        panel.hasCursorVoxelPosition = false
                    }
                } else {
                    panel.hasCursorVoxelPosition = false
                }
            } else {
                panel.hasCursorPatientPosition = false
                panel.hasCursorVoxelPosition = false
            }
        }
    }
}

// MARK: - ROI Overlay

/// Draws the ROI selection rectangle during drag.
struct ROIOverlay: View {
    @ObservedObject var panel: PanelState
    let roiRect: CGRect

    var body: some View {
        GeometryReader { geo in
            let screenRect = pixelRectToScreen(roiRect, viewSize: geo.size)
            Rectangle()
                .stroke(Color.yellow, lineWidth: 2)
                .background(Color.yellow.opacity(0.1))
                .frame(width: screenRect.width, height: screenRect.height)
                .position(x: screenRect.midX, y: screenRect.midY)
        }
        .allowsHitTesting(false)
    }

    /// Convert a pixel-space rectangle to SwiftUI overlay screen coordinates.
    /// Uses the same transform logic as CrossReferenceOverlay's pixelToScreen.
    private func pixelRectToScreen(_ rect: CGRect, viewSize: CGSize) -> CGRect {
        let topLeft = pixelToScreen(CGPoint(x: rect.minX, y: rect.minY), viewSize: viewSize)
        let bottomRight = pixelToScreen(CGPoint(x: rect.maxX, y: rect.maxY), viewSize: viewSize)
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    private func pixelToScreen(_ pixel: CGPoint, viewSize: CGSize) -> CGPoint {
        let imgW = max(1, panel.displayImageWidth)
        let imgH = max(1, panel.displayImageHeight)
        let vw = viewSize.width
        let vh = viewSize.height

        let fitScale = min(vw / imgW, vh / imgH)
        let offsetX = (vw - imgW * fitScale) / 2
        let offsetY = (vh - imgH * fitScale) / 2

        var x = pixel.x * fitScale + offsetX
        var y = pixel.y * fitScale + offsetY

        let cx = vw / 2
        let cy = vh / 2
        x -= cx
        y -= cy

        if panel.isFlippedH { x = -x }
        if panel.isFlippedV { y = -y }

        let steps = panel.rotationSteps % 4
        if steps > 0 {
            let angle = -CGFloat(steps) * .pi / 2
            let cosA = cos(angle)
            let sinA = sin(angle)
            let rx = x * cosA - y * sinA
            let ry = x * sinA + y * cosA
            x = rx
            y = ry
        }

        x *= panel.scale
        y *= panel.scale

        // Pan (same as fixed CrossReferenceOverlay)
        x += panel.translation.x
        y -= panel.translation.y

        x += cx
        y += cy
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Modality Badge

/// Color-coded modality control: CT = amber, MRI = teal. Click to switch the
/// modality (which reseeds the window to that modality's default). Reused by the
/// docked ViewerControlBar — this is the single CT/MRI control.
struct ModalityBadge: View {
    @ObservedObject var model: ViewerModel
    let modality: ImagingModality

    var body: some View {
        // Plain Button (not Menu) so the color-coded capsule renders — a
        // borderlessButton Menu strips the label background. Two modalities, so
        // a click simply toggles to the other; the swap glyph signals it's live.
        Button(action: {
            let next: ImagingModality = (model.effectiveModality == .ct) ? .mri : .ct
            model.setModalityOverride(next)
        }) {
            HStack(spacing: 3) {
                Text(modality.rawValue)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.85)
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
            .foregroundStyle(.white)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Modality: \(modality.rawValue) (auto-detected) — click to switch CT/MRI")
    }

    private var badgeColor: Color {
        switch modality {
        case .ct:  return .lentisCT   // amber
        case .mri: return .lentisMRI  // teal
        }
    }
}

// MARK: - Panel Histogram View

struct PanelHistogramView: View {
    let data: [Double]
    let minVal: Double
    let maxVal: Double
    let windowWidth: Double
    let windowCenter: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Path { path in
                    let width = geo.size.width
                    let height = geo.size.height
                    let step = width / CGFloat(data.count)

                    path.move(to: CGPoint(x: 0, y: height))
                    for (i, val) in data.enumerated() {
                        let x = CGFloat(i) * step
                        let y = height - (CGFloat(val) * height)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [.blue.opacity(0.6), .purple.opacity(0.6)], startPoint: .top, endPoint: .bottom))

                let totalRange = maxVal - minVal
                if totalRange > 0 {
                    let windowStart = (windowCenter - (windowWidth / 2.0))
                    let windowEnd = (windowCenter + (windowWidth / 2.0))

                    let startRatio = max(0.0, min(1.0, (windowStart - minVal) / totalRange))
                    let endRatio = max(0.0, min(1.0, (windowEnd - minVal) / totalRange))

                    let startX = CGFloat(startRatio) * geo.size.width
                    let widthPx = CGFloat(endRatio - startRatio) * geo.size.width

                    Rectangle()
                        .fill(Color.yellow.opacity(0.2))
                        .frame(width: max(2, widthPx), height: geo.size.height)
                        .position(x: startX + (widthPx / 2.0), y: geo.size.height / 2.0)

                    let centerRatio = max(0.0, min(1.0, (windowCenter - minVal) / totalRange))
                    let centerX = CGFloat(centerRatio) * geo.size.width
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 1, height: geo.size.height)
                        .position(x: centerX, y: geo.size.height / 2.0)
                }
            }
        }
    }
}

// MARK: - Panel Slice Scroller

struct PanelSliceScroller: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var panel: PanelState
    @State private var isHovering = false
    @State private var hoverLocation: CGPoint = .zero
    @State private var dragLocation: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            let total = model.totalSliceCount(for: panel)
            let currentIdx = model.currentSliceIndex(for: panel)

            ZStack(alignment: .top) {
                // Track
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 8, height: geo.size.height)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                // Handle
                if total > 0 {
                    let thumbHeight = max(20.0, geo.size.height / CGFloat(total) * 4.0)
                    let progress = Double(currentIdx) / Double(max(1, total - 1))
                    let availHeight = geo.size.height - thumbHeight
                    let offset = CGFloat(progress) * availHeight

                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 8, height: thumbHeight)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(y: offset)
                }
            }
            .contentShape(Rectangle())
            .overlay {
                PanelScrollerInteractionView(
                    onDrag: { loc in
                        dragLocation = loc
                        calculateIndex(y: loc.y, height: geo.size.height, total: total, commit: true)
                    },
                    onHover: { loc in
                        hoverLocation = loc
                    },
                    onEnter: { isHovering = true },
                    onExit: {
                        isHovering = false
                        dragLocation = nil
                    }
                )
            }
            .overlay(alignment: .topTrailing) {
                if total > 0, let pY = activeY() {
                    let idx = getIndex(y: pY, height: geo.size.height, total: total)
                    Text("\(idx + 1)/\(total)")
                        .font(.system(.caption2, design: .monospaced))
                        .padding(4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(4)
                        .offset(x: -20, y: min(max(0, pY - 12), geo.size.height - 24))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func activeY() -> CGFloat? {
        if let d = dragLocation { return d.y }
        if isHovering { return hoverLocation.y }
        return nil
    }

    func calculateIndex(y: CGFloat, height: CGFloat, total: Int, commit: Bool) {
        if total <= 1 { return }
        let idx = getIndex(y: y, height: height, total: total)
        if commit {
            model.navigatePanelToSlice(panel, index: idx)
        }
    }

    func getIndex(y: CGFloat, height: CGFloat, total: Int) -> Int {
        let pct = max(0, min(1, y / height))
        return Int(pct * Double(total - 1))
    }
}

// MARK: - Panel Scroller Interaction View

struct PanelScrollerInteractionView: NSViewRepresentable {
    var onDrag: (CGPoint) -> Void
    var onHover: (CGPoint) -> Void
    var onEnter: () -> Void
    var onExit: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = InteractionView()
        v.onDrag = onDrag
        v.onHover = onHover
        v.onEnter = onEnter
        v.onExit = onExit
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let v = nsView as? InteractionView {
            v.onDrag = onDrag
            v.onHover = onHover
            v.onEnter = onEnter
            v.onExit = onExit
        }
    }

    class InteractionView: NSView {
        var onDrag: ((CGPoint) -> Void)?
        var onHover: ((CGPoint) -> Void)?
        var onEnter: (() -> Void)?
        var onExit: (() -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .activeAlways], owner: self, userInfo: nil))
        }

        override func mouseDown(with event: NSEvent) { handleDrag(event) }
        override func mouseDragged(with event: NSEvent) { handleDrag(event) }

        private func handleDrag(_ event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let flippedY = bounds.height - loc.y
            onDrag?(CGPoint(x: loc.x, y: flippedY))
        }

        override func mouseEntered(with event: NSEvent) { onEnter?() }
        override func mouseExited(with event: NSEvent) { onExit?() }
        override func mouseMoved(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let flippedY = bounds.height - loc.y
            onHover?(CGPoint(x: loc.x, y: flippedY))
        }
    }
}

// MARK: - Orientation Labels Overlay

struct OrientationLabelsOverlay: View {
    let orientation: [Double]?
    var rotationSteps: Int = 0
    var isFlippedH: Bool = false
    var isFlippedV: Bool = false

    var body: some View {
        if let ori = orientation, ori.count == 6 {
            let row = SIMD3<Double>(ori[0], ori[1], ori[2])
            let col = SIMD3<Double>(ori[3], ori[4], ori[5])

            // Base labels: right, left, bottom, top
            let baseRight = dirLabel(row)
            let baseLeft = oppositeLabel(baseRight)
            let baseBottom = dirLabel(col)
            let baseTop = oppositeLabel(baseBottom)

            // Apply flip and rotation transforms to the 4 label slots.
            // Start with logical positions: right=0, top=1, left=2, bottom=3
            // then rotate and flip to get the final label for each screen position.
            let labels = transformedLabels(
                right: baseRight, top: baseTop, left: baseLeft, bottom: baseBottom,
                rotationSteps: rotationSteps, flipH: isFlippedH, flipV: isFlippedV)

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                Text(labels.right)
                    .position(x: w - 16, y: h / 2)
                Text(labels.left)
                    .position(x: 16, y: h / 2)
                Text(labels.bottom)
                    .position(x: w / 2, y: h - 16)
                Text(labels.top)
                    .position(x: w / 2, y: 16)
            }
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(.yellow)
            // Dark halo so the letters stay legible over bright slices.
            .shadow(color: .black.opacity(0.9), radius: 1.5)
            .allowsHitTesting(false)
        }
    }

    /// Apply flip and rotation to the four orientation labels.
    /// Rotation is CW in 90-degree steps; flips are applied before rotation
    /// (matching the image transform order in restoreState).
    private func transformedLabels(
        right: String, top: String, left: String, bottom: String,
        rotationSteps: Int, flipH: Bool, flipV: Bool
    ) -> (right: String, top: String, left: String, bottom: String) {
        // Put labels in array: [right, top, left, bottom] indexed 0-3
        var labels = [right, top, left, bottom]

        // Horizontal flip swaps left ↔ right
        if flipH { labels.swapAt(0, 2) }
        // Vertical flip swaps top ↔ bottom
        if flipV { labels.swapAt(1, 3) }

        // CW rotation by N steps: each 90° CW step moves
        // right→bottom, bottom→left, left→top, top→right
        // That's equivalent to rotating the array backward by N positions.
        let steps = ((rotationSteps % 4) + 4) % 4
        if steps > 0 {
            let rotated = (0..<4).map { labels[($0 + steps) % 4] }
            labels = rotated
        }

        return (right: labels[0], top: labels[1], left: labels[2], bottom: labels[3])
    }

    /// Map a direction vector to its dominant anatomical label.
    /// World space is NIfTI **RAS+**: +x=R, +y=A, +z=S (and negatives).
    private func dirLabel(_ v: SIMD3<Double>) -> String {
        anatomicalDirection(of: v).letter
    }

    private func oppositeLabel(_ l: String) -> String {
        AnatomicalDirection(rawValue: l)?.opposite.letter ?? ""
    }
}

// MARK: - Annotation Overlay

struct AnnotationOverlay: View {
    @ObservedObject var panel: PanelState

    var body: some View {
        GeometryReader { geo in
            // Finalized annotations
            ForEach(panel.annotations) { annotation in
                annotationView(for: annotation, viewSize: geo.size)
            }

            // Ruler preview (dashed line)
            if let start = panel.rulerPreviewStart, let end = panel.rulerPreviewEnd {
                let s = pixelToScreen(start, viewSize: geo.size)
                let e = pixelToScreen(end, viewSize: geo.size)
                Path { path in
                    path.move(to: s)
                    path.addLine(to: e)
                }
                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }

            // Angle preview (dashed lines)
            if panel.anglePreviewPoints.count >= 2 {
                let pts = panel.anglePreviewPoints.map { pixelToScreen($0, viewSize: geo.size) }
                Path { path in
                    path.move(to: pts[0])
                    for i in 1..<pts.count {
                        path.addLine(to: pts[i])
                    }
                }
                .stroke(Color.green, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func annotationView(for annotation: Annotation, viewSize: CGSize) -> some View {
        switch annotation.type {
        case .ruler(let start, let end, let distanceMM):
            let s = pixelToScreen(start, viewSize: viewSize)
            let e = pixelToScreen(end, viewSize: viewSize)
            ZStack {
                Path { path in
                    path.move(to: s)
                    path.addLine(to: e)
                }
                .stroke(Color.cyan, lineWidth: 1.5)

                // Distance label at midpoint
                let mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
                let label = panel.pixelSpacing != nil
                    ? String(format: "%.1f mm", distanceMM)
                    : String(format: "%.1f px", distanceMM)
                Text(label)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .padding(2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(2)
                    .position(x: mid.x, y: mid.y - 12)

                // Endpoint markers
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 6, height: 6)
                    .position(s)
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 6, height: 6)
                    .position(e)
            }

        case .angle(let vertex, let arm1, let arm2, let degrees):
            let v = pixelToScreen(vertex, viewSize: viewSize)
            let a1 = pixelToScreen(arm1, viewSize: viewSize)
            let a2 = pixelToScreen(arm2, viewSize: viewSize)
            ZStack {
                Path { path in
                    path.move(to: a1)
                    path.addLine(to: v)
                    path.addLine(to: a2)
                }
                .stroke(Color.green, lineWidth: 1.5)

                // Angle label near vertex
                Text(String(format: "%.1f°", degrees))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(2)
                    .position(x: v.x + 16, y: v.y - 12)

                // Endpoint markers
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .position(a1)
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .position(v)
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .position(a2)
            }

        case .roiStats(let rect, let mean, let maxV, let minV, let stdDev, let count):
            let topLeft = pixelToScreen(CGPoint(x: rect.minX, y: rect.minY), viewSize: viewSize)
            let bottomRight = pixelToScreen(CGPoint(x: rect.maxX, y: rect.maxY), viewSize: viewSize)
            let screenRect = CGRect(
                x: min(topLeft.x, bottomRight.x),
                y: min(topLeft.y, bottomRight.y),
                width: abs(bottomRight.x - topLeft.x),
                height: abs(bottomRight.y - topLeft.y)
            )
            ZStack {
                Rectangle()
                    .stroke(Color.orange, lineWidth: 1.5)
                    .frame(width: screenRect.width, height: screenRect.height)
                    .position(x: screenRect.midX, y: screenRect.midY)

                // Stats label below the rectangle
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "Mean: %.1f", mean))
                    Text(String(format: "SD: %.1f", stdDev))
                    Text(String(format: "Min: %.0f  Max: %.0f", minV, maxV))
                    Text("N: \(count)")
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.orange)
                .padding(3)
                .background(Color.black.opacity(0.7))
                .cornerRadius(3)
                .position(x: screenRect.midX, y: screenRect.maxY + 30)
            }
        }
    }

    private func pixelToScreen(_ pixel: CGPoint, viewSize: CGSize) -> CGPoint {
        let imgW = max(1, panel.displayImageWidth)
        let imgH = max(1, panel.displayImageHeight)
        let vw = viewSize.width
        let vh = viewSize.height

        let fitScale = min(vw / imgW, vh / imgH)
        let offsetX = (vw - imgW * fitScale) / 2
        let offsetY = (vh - imgH * fitScale) / 2

        var x = pixel.x * fitScale + offsetX
        var y = pixel.y * fitScale + offsetY

        let cx = vw / 2
        let cy = vh / 2
        x -= cx
        y -= cy

        if panel.isFlippedH { x = -x }
        if panel.isFlippedV { y = -y }

        let steps = panel.rotationSteps % 4
        if steps > 0 {
            let angle = -CGFloat(steps) * .pi / 2
            let cosA = cos(angle)
            let sinA = sin(angle)
            let rx = x * cosA - y * sinA
            let ry = x * sinA + y * cosA
            x = rx
            y = ry
        }

        x *= panel.scale
        y *= panel.scale

        x += panel.translation.x
        y -= panel.translation.y

        x += cx
        y += cy
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Tool Palette

/// Floating vertical Liquid Glass capsule of tools, overlaid on the viewport's
/// leading edge. The active tool tints with the signature accent; neighbouring
/// glass buttons blend within the GlassEffectContainer. A one-shot Reset View
/// button sits below a divider at the capsule's bottom — the most discoverable
/// place to "undo" zoom/pan/rotation/flip/invert in one click (R key mirrors it).
struct ToolPalette: View {
    @ObservedObject var model: ViewerModel

    private var hasVolume: Bool { model.activePanel?.image != nil }

    var body: some View {
        GlassEffectContainer(spacing: Spacing.xs) {
            VStack(spacing: Spacing.xs) {
                // Tools are partitioned into Navigate / Measure / Segment groups
                // (ActiveTool.group); a thin divider separates each group so the
                // eleven tools read as three intents rather than one long stack.
                ForEach(ToolGroup.allCases) { group in
                    if group != ToolGroup.allCases.first { groupDivider }
                    ForEach(ActiveTool.allCases.filter { $0.group == group }) { tool in
                        toolButton(tool)
                    }
                }

                // One-shot "Reset View" — restores all spatial transforms
                // (zoom, pan, 90° rotation, horizontal/vertical flip, invert)
                // in a single click. Kept visually distinct from the tools:
                // never accent-tinted, separated by a divider. W/L is preserved
                // (use A / the Auto button for an auto window). The R key and
                // the menu's "Reset View" route through the same model call.
                groupDivider

                GlassIconButton(
                    systemName: "arrow.counterclockwise",
                    isActive: false,
                    size: 34,
                    help: "Reset View (R) — restore zoom, pan, rotation, flips, invert (keeps Window/Level)"
                ) {
                    if let panel = model.activePanel {
                        model.resetViewForPanel(panel)
                    }
                }
                .disabled(!hasVolume)
                .opacity(hasVolume ? 1.0 : 0.4)
            }
        }
    }

    private var groupDivider: some View {
        Divider()
            .frame(width: 22)
            .opacity(0.5)
    }

    @ViewBuilder
    private func toolButton(_ tool: ActiveTool) -> some View {
        let enabled = isEnabled(tool)
        GlassIconButton(
            systemName: tool.icon,
            isActive: model.activeTool == tool,
            size: 34,
            help: "\(tool.displayName) (\(tool.shortcutHint)) — \(tool.description)"
        ) {
            model.activeTool = tool
        }
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.35)
    }

    /// Context-gating for the palette. No volume → every tool is greyed out;
    /// otherwise the per-tool logic is delegated to `model.canActivate(_:)`, the
    /// SAME gate the keyboard shortcuts route through (`activateTool`), so the
    /// palette and the shortcuts can never disagree about ROI Box / Brush.
    private func isEnabled(_ tool: ActiveTool) -> Bool {
        guard hasVolume else { return false }
        return model.canActivate(tool)
    }
}

// (CursorInfoOverlay removed — the HU/RAS/pixel readout now lives in the docked
// ViewerStatusBar at the bottom of the viewer, following the hovered panel.)
