// ViewerModel.swift
// Lentis
//
// Central model for the NIfTI viewer. This is the largest file in the project
// and serves as the single source of truth for all viewer state.
//
// Responsibilities:
//   - NIfTI loading, timepoint switching, and layer import coordination
//   - Multi-panel management: create, resize, assign series, navigate
//   - Window/level computation (auto, ROI-based, histogram generation)
//   - MPR slice extraction and layer compositing
//   - Metal direct-volume rendering with an interactive 3D camera
//   - Synchronized scrolling with spatial z-location matching
//   - Panel status/readout string formatting
//
// Threading model:
//   - NIfTI parsing and layer import run off the main thread
//   - MPR and 3D rendering use per-panel OperationQueues for cancellation/coalescing
//   - All @Published state updates dispatch to MainActor
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import Combine
import AppKit
import simd
import UniformTypeIdentifiers

// MARK: - Data Structures
struct ImageSeries: Identifiable, Equatable {
    let id: String
    let seriesNumber: Int
    let seriesDescription: String
}

// MARK: - Model
class ViewerModel: ObservableObject {
    // Current State
    @Published var image: NSImage?
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false

    // Active tool selection
    @Published var activeTool: ActiveTool = .select
    
    // Series Management
    @Published var allSeries: [ImageSeries] = []
    @Published var currentSeriesIndex: Int = -1 {
        didSet {
             if currentSeriesIndex != -1, let panel = activePanel {
                 panel.seriesIndex = currentSeriesIndex
             }
        }
    }
    @Published var currentImageIndex: Int = -1
    
    // Metadata State
    @Published var currentSeriesInfo: String = ""
    @Published var currentImageInfo: String = ""
    @Published var windowWidth: Double = 0
    @Published var windowCenter: Double = 0
    
    // Baseline W/L for Reference (Needed for Filter-based W/L on compressed images)
    var initialWindowWidth: Double = 0
    var initialWindowCenter: Double = 0
    
    // Raw Data for Re-rendering
    private var rawPixelData: Data?
    private var imageWidth: Int = 0
    private var imageHeight: Int = 0
    private var bitDepth: Int = 8
    private var samples: Int = 1
    private var isMonochrome1: Bool = false
    private var isSigned: Bool = false // PixelRepresentation (0028,0103)

    // State Persistence
    struct SeriesViewState {
        var windowWidth: Double?
        var windowCenter: Double?
        var scale: CGFloat = 1.0
        var translation: CGPoint = .zero
    }
    
    @Published var seriesStates: [String: SeriesViewState] = [:] // Key: SeriesUID
    
    // Histogram Data (Normalized 0-1 for 256 bins)
    @Published var histogramData: [Double] = []
    @Published var minPixelValue: Double = 0.0
    @Published var maxPixelValue: Double = 1.0

    // MARK: - Multi-Panel State
    @Published var layout: ViewerLayout = .single
    /// True only while the coordinated MPR tri-planar arrangement (Axial +
    /// Sagittal + Coronal + 3D, from `setupMPRLayout`) is active. In that mode
    /// the per-panel plane picker is locked so the panels keep their assigned
    /// roles; any plain `setLayout` (layout picker, ⌘1–4, context menu) clears
    /// it and re-enables per-panel plane switching.
    @Published var isMPRLayout: Bool = false
    @Published var panels: [PanelState] = []
    @Published var activePanelID: UUID = UUID()
    @Published var showCrossReference: Bool = false
    /// Shared 3D crosshair world coordinate (RAS mm). Set by click/drag in any
    /// MPR panel (Phase 6); all panels relocate to contain it and draw crosshair
    /// lines through its in-plane projection.
    ///
    /// Held in its OWN `ObservableObject` (NOT `@Published` on the model) so a
    /// crosshair drag — which rewrites it per mouse event — invalidates only the
    /// `CrossReferenceOverlay`s that observe it, not every view bound to the
    /// model. Writing it through `model.objectWillChange` re-ran the whole quad's
    /// SwiftUI layout each drag event, which (after the Slab-Slider fix) was the
    /// remaining crosshair-drag lag.
    let crosshair = CrosshairState()
    /// Back-compat accessor: existing call sites read/write `crosshairWorld`;
    /// it forwards to the decoupled `crosshair.world`. nil = no crosshair yet.
    var crosshairWorld: SIMD3<Double>? {
        get { crosshair.world }
        set { crosshair.world = newValue }
    }
    @Published var showHelp: Bool = false
    @Published var showLayerInspector: Bool = false

    /// Transient success/info banner (Liquid-Glass HUD). Set via `presentToast`;
    /// auto-clears after a delay. Drives the floating banner in ContentView.
    @Published var toast: ViewerToast? = nil
    private var toastDismissWorkItem: DispatchWorkItem?

    /// Show a banner and auto-dismiss it after `duration` seconds. A new banner
    /// supersedes any current one (its dismissal is rescheduled).
    func presentToast(_ toast: ViewerToast, duration: TimeInterval = 4) {
        self.toast = toast
        toastDismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.toast?.id == toast.id else { return }
            self.toast = nil
        }
        toastDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismissToast() {
        toastDismissWorkItem?.cancel()
        toast = nil
    }

    /// Reveal the current banner's file in Finder (e.g. the just-exported mask).
    func revealToastFile() {
        guard let url = toast?.fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @Published var isImportingLayers: Bool = false
    @Published var layerImportError: String? = nil
    /// WindowGroup can restore more than one window, so command-line startup
    /// arguments must be claimed once for the app-wide model.
    var didHandleCommandLineLaunch = false
    @Published var synchronizedScrolling: Bool = false {
        didSet {
            // Synchronized scrolling (proportional slice relocation) is only
            // meaningful in the legacy multi-series layouts. In the MPR
            // tri-planar layout the 3D crosshair tracks scrolls instead, so the
            // proportional relocation must never run there.
            guard synchronizedScrolling, !isMPRLayout, let source = activePanel else { return }

            // If single-panel, auto-expand to 2-panel and assign a same-axis series
            if layout == .single && allSeries.count > 1 {
                let sourceIdx = source.seriesIndex

                // Find a different series; NIfTI volumes do not carry legacy
                // per-slice orientation metadata, so there is no axis matching.
                var bestIdx: Int? = nil
                bestIdx = allSeries.indices.first(where: { $0 != sourceIdx })

                if let idx = bestIdx {
                    setLayout(.twoHorizontal)
                    if panels.count > 1 {
                        assignSeriesToPanel(panels[1], seriesIndex: idx)
                    }
                }
            }

            syncScrollFromPanel(source)
        }
    }

    /// The currently active panel (receives keyboard input, sidebar selections)
    var activePanel: PanelState? {
        panels.first(where: { $0.id == activePanelID })
    }

    /// When non-nil, the given panel fills the entire view (double-click toggle)
    @Published var fullscreenPanelID: UUID? = nil

    /// File name (last path component) of the currently loaded NIfTI file.
    /// Shown in the sidebar row and the per-panel info overlay in place of the
    /// vestigial "Series 1/1" label (a NIfTI is always a single series).
    @Published var loadedFileName: String = ""

    /// Full URL of the currently loaded NIfTI file. Drives the default output
    /// location ("next to the source file") for generated mask/label files.
    @Published var loadedFileURL: URL? = nil

    /// The open BIDS dataset / loose folder, when a folder (not a single file)
    /// was opened. Drives the sidebar dataset navigator and the BIDS-derivatives
    /// output location. nil for a single-file session.
    @Published var dataset: BIDSDataset? = nil

    /// The dataset record for the currently-loaded file (entities + datatype),
    /// used for BIDS-derivative output naming. nil when the loaded file isn't
    /// part of an open dataset.
    @Published var currentDatasetFile: BIDSImageFile? = nil

    /// True while a freshly-opened folder is being scanned into a dataset.
    @Published var isScanningFolder: Bool = false

    /// Toggle fullscreen for a panel (double-click behavior). Disabled in the
    /// MPR tri-planar layout, where fullscreen would break the coordinated
    /// crosshair linkage the layout depends on.
    func toggleFullscreen(for panel: PanelState) {
        guard !isMPRLayout || fullscreenPanelID == panel.id else { return }
        if fullscreenPanelID == panel.id {
            fullscreenPanelID = nil  // Exit fullscreen
        } else {
            fullscreenPanelID = panel.id
            activePanelID = panel.id
        }
    }

    // Track W/L params for cached images: [URL: (WW, WC)]
    private var imageCacheParams: [NSURL: (Double, Double)] = [:]
    private let imageCacheParamsLock = NSLock()
    // Track pixel metadata for cached images so cache-hit path can restore panel state
    private struct PixelMeta {
        let width: Int; let height: Int; let bitDepth: Int; let samples: Int
        let isSigned: Bool; let isMonochrome1: Bool
    }
    private var imagePixelMeta: [NSURL: PixelMeta] = [:]
    // Queue for Series Caching
    private let cachingQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 2 // Limit concurrency
        return q
    }()
    
    @Published var isScanning: Bool = false
    @Published var cacheProgress: Double = 0.0
    
    // Request Token to prevent stale background loads from overriding current view
    private var currentLoadRequestID: UUID = UUID()
    private var lastPrecachedSeriesIndex: Int = -1
    
    // Series Thumbnails
    @Published var seriesThumbnails: [String: NSImage] = [:]
    // Main Loading Queue (Serial) to allow cancellation of stale requests
    private let loadingQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated 
        return q
    }()
    
    var isRawDataAvailable: Bool { rawPixelData != nil }

    // MARK: - Volume / MPR
    /// Cached volumes keyed by series UID
    private var _volumeCache: [String: VolumeData] = [:]
    /// Lock protecting volumeCache
    private let volumeCacheLock = NSLock()
    /// Thread-safe read access to volumeCache
    private func volumeCacheGet(_ key: String) -> VolumeData? {
        volumeCacheLock.lock()
        let val = _volumeCache[key]
        volumeCacheLock.unlock()
        return val
    }
    /// Thread-safe write access to volumeCache
    private func volumeCacheSet(_ key: String, _ value: VolumeData) {
        volumeCacheLock.lock()
        _volumeCache[key] = value
        volumeCacheLock.unlock()
    }

    // MARK: - NIfTI state
    /// Currently loaded NIfTI dataset (drives 4D timepoint switching + modality).
    @Published var niftiDataset: NiftiDataset? = nil
    /// Selected timepoint for 4D NIfTI volumes.
    @Published var currentTimepoint: Int = 0
    /// Manual modality override (CT/MRI); nil ⇒ use the auto-detected value.
    @Published var modalityOverride: ImagingModality? = nil
    /// Series index of the loaded NIfTI volume (-1 if none).
    var niftiSeriesIndex: Int = -1

    /// Effective modality: manual override if set, else auto-detected.
    var effectiveModality: ImagingModality? { modalityOverride ?? niftiDataset?.detectedModality }

    // MARK: - Segmentation mask overlay (seam)
    /// Session-scoped external mask/atlas layers. This is a separate observable
    /// object so continuous opacity edits do not invalidate the whole viewer.
    let layerStore = LayerStore()

    /// Whether the MPR render path composites a panel volume's `labelMask` over
    /// the slice (Phase 7 seam). A future Eraser/ROI segmentation UI flips this;
    /// inert in normal runs because no volume carries a mask. Color defaults to
    /// calcification red.
    @Published var showMaskOverlay: Bool = true
    var maskOverlayColor: SIMD3<Double> = SIMD3<Double>(1.0, 0.23, 0.19)
    var maskOverlayAlpha: Double = 0.45

    // MARK: - Calcification segmentation (Phase 9)
    /// Which tab the trailing inspector shows.
    @Published var inspectorTab: InspectorTab = .layers
    /// Committed calcification regions (top-first, like the layer list). Each
    /// owns a distinct label value (1…254) in the base volume's `labelMask`.
    @Published var calcRegions: [CalcificationRegion] = []
    /// The region currently being created/edited (box + params + live preview,
    /// painted with the reserved preview label 255). nil when not segmenting.
    @Published var draftRegion: CalcificationRegion? = nil
    /// Selected committed region (drives recolor/rename/delete/re-edit + brush).
    @Published var activeRegionID: UUID? = nil
    /// Brain constraint layer (loaded mask or SynthSeg parcellation), if any.
    @Published var brainMaskLayer: OverlayLayer? = nil
    @Published var brainMaskStatus: String = ""
    @Published var isRunningSynthSeg: Bool = false
    @Published var synthSegProgress: Double = 0
    @Published var synthSegStatus: String = ""
    /// Touch-up brush state (manual voxel edit of the selected region).
    @Published var calcBrushRadius: Int = 2
    @Published var calcBrushErase: Bool = false
    /// Fixed initial through-plane thickness (slices) a freshly drawn ROI box
    /// gets along the plane it's drawn on. The user then refines the depth by
    /// dragging the box's handles on coronal/sagittal (there is no slab slider).
    let calcSlabDepth: Int = 5
    /// Bumped on every segmentation mask edit; `loadMPRSlice` drops in-flight
    /// renders that predate the latest edit (segmentation-edit sync contract,
    /// analogous to `LayerStore.revision`). All mask mutations happen on the
    /// main thread before this is bumped + a re-render enqueued.
    var segmentationRevision: UInt64 = 0
    /// Voxel values under the current draft preview, so clearing the preview
    /// restores committed labels instead of zeroing them.
    var segPreviewBackup: [(x: Int, y: Int, z: Int, prev: UInt8)] = []
    /// Touch-up brush stroke undo backup: the PRE-STROKE label of every voxel
    /// touched during the current mouse-down→up stroke, keyed by coordinate.
    /// Only the first touch per voxel is recorded, so a voxel painted then
    /// erased within one stroke restores to its original (pre-stroke) value on
    /// undo. `beginBrushStroke` clears it; `endBrushStroke` registers the undo.
    var brushStrokeBackup: [BrushVoxelKey: UInt8] = [:]
    /// True between the mouseDown and mouseUp of a brush stroke so `paintBrush`
    /// knows to record the backup (a programmatic paint call outside a stroke
    /// — there is none today, but defensively — won't accumulate undo state).
    var brushStrokeInProgress: Bool = false
    /// When a committed region is pulled into a draft for re-editing
    /// (`reEditRegion`), remember where it lived in `calcRegions` and the exact
    /// voxels it owned, so abandoning the edit (`cancelActiveRegion`) restores it
    /// instead of silently destroying it. nil unless a re-edit is in flight.
    var reEditingRegionIndex: Int? = nil
    var reEditingCommittedCoords: [(x: Int, y: Int, z: Int)] = []
    /// In-flight SynthSeg run (for cancel) + a user-chosen binary override.
    var synthSegRunner: SynthSegRunner?
    var synthSegBinaryOverride: URL?
    /// Files written by the most recent SynthSeg run (label file + optional brain
    /// mask), in the resolved output directory. Drives the "Show in Finder"
    /// affordance so the user can find the generated output.
    @Published var synthSegOutputFiles: [URL] = []
    /// The directory the last SynthSeg run wrote into (first output file's parent).
    var synthSegOutputDirectory: URL? { synthSegOutputFiles.first?.deletingLastPathComponent() }
    /// URLs of the most recent successful mask / atlas exports this session, used
    /// by the Segment panel's status indicator to show "Exported". Each is CLEARED
    /// whenever the segmentation's voxel content changes (commit / delete / re-edit
    /// / brush / reset), so the indicator never claims a stale on-disk file still
    /// matches the live regions.
    @Published var exportedMaskURL: URL? = nil
    @Published var exportedAtlasURL: URL? = nil
    /// True once a mask or atlas has been exported for the current segmentation.
    var hasExportedSegmentation: Bool { exportedMaskURL != nil || exportedAtlasURL != nil }
    /// Forget recorded exports because the segmentation's voxel content changed
    /// (both the mask and the atlas on-disk files would now be stale). Called
    /// from the voxel-mutation sites.
    func invalidateSegmentationExports() {
        if exportedMaskURL != nil { exportedMaskURL = nil }
        if exportedAtlasURL != nil { exportedAtlasURL = nil }
    }

    /// Forget only the recorded ATLAS export because a region's metadata
    /// (name / color) changed. The atlas's `_LUT.txt` / `_dseg.tsv` sidecar
    /// serializes those, so it's now stale; the binary mask carries no metadata,
    /// so `exportedMaskURL` stays valid. Called from the RegionRow rename/recolor
    /// bindings.
    func invalidateAtlasExport() {
        if exportedAtlasURL != nil { exportedAtlasURL = nil }
    }
    /// Live settings subscriptions (overlay opacity → re-render).
    var settingsCancellables = Set<AnyCancellable>()

    /// Register a pre-built NIfTI volume under `cacheKey` so panels can display
    /// it. Returns the series index.
    @discardableResult
    func registerStandaloneVolume(_ volume: VolumeData, cacheKey: String, description: String) -> Int {
        volumeCacheSet(cacheKey, volume)
        if let existing = allSeries.firstIndex(where: { $0.id == cacheKey }) {
            return existing
        }
        let series = ImageSeries(id: cacheKey, seriesNumber: allSeries.count + 1,
                                 seriesDescription: description)
        allSeries.append(series)
        return allSeries.count - 1
    }
    @Published var isVolumeBuildingInProgress: Bool = false
    @Published var volumeBuildProgress: Double = 0.0
    /// GPU direct-volume renderer (lazy init)
    lazy var metalRenderer: MetalVolumeRenderer? = MetalVolumeRenderer()


    // Shift-key state for group selection overlay
    @Published var isShiftHeld: Bool = false
    private var flagsMonitor: Any?

    // MARK: - Initialization
    init() {
        let firstPanel = PanelState()
        self.panels = [firstPanel]
        self.activePanelID = firstPanel.id

        layerStore.onRenderChange = { [weak self] in
            guard let self else { return }
            if Thread.isMainThread { self.refreshLayerRendering() }
            else { DispatchQueue.main.async { [weak self] in self?.refreshLayerRendering() } }
        }

        // Drive the segmentation overlay translucency from the shared settings.
        // Seed it now, then re-render whenever the user changes it in Settings.
        maskOverlayAlpha = AppSettings.shared.overlayOpacity
        AppSettings.shared.$overlayOpacity
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.maskOverlayAlpha = value
                self.refreshSegmentationRender()
            }
            .store(in: &settingsCancellables)

        // Monitor Shift key globally for group selection overlay
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return event }
            let shiftDown = event.modifierFlags.contains(.shift)
            self.isShiftHeld = shiftDown
            // When Shift is released, clear group if ≤1 panel selected
            if !shiftDown {
                let selectedCount = self.panels.filter(\.isGroupSelected).count
                if selectedCount <= 1 {
                    self.clearGroupSelection()
                }
            }
            return event
        }

    }

    deinit {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    // MARK: - Load Methods

    private func niftiContentTypes() -> [UTType] {
        ["nii", "gz"].compactMap { UTType(filenameExtension: $0) }
    }

    /// Show an Open panel and load the selected NIfTI file (clears any open
    /// dataset — a single-file session).
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a NIfTI file (.nii or .nii.gz)"
        let types = niftiContentTypes()
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    /// Show an Open panel and load a folder as a BIDS dataset (or a loose folder
    /// of NIfTI files), scanning it into the sidebar navigator.
    func openFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a BIDS dataset folder (or any folder of NIfTI files)"
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    /// Unified Open (File menu / sidebar primary action): one panel that accepts
    /// either a NIfTI file or a folder, routing to the right loader.
    func openFileOrFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose a NIfTI file (.nii / .nii.gz) or a folder / BIDS dataset"
        panel.prompt = "Open"
        let types = niftiContentTypes()
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    /// Load a file from the open dataset navigator, keeping the dataset visible.
    /// Re-selecting the already-loaded image is a no-op: load() would otherwise
    /// re-decode it AND wipe in-progress segmentation regions + external layers.
    func selectDatasetFile(_ file: BIDSImageFile) {
        guard file.url != loadedFileURL else { return }
        load(url: file.url, preserveDataset: true)
    }

    /// Scan a folder (off-main) into a BIDS dataset or a loose NIfTI list, then
    /// auto-load the first image. Replaces any previously open dataset.
    func loadFolder(url: URL) {
        isScanningFolder = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            let scanned = BIDSDataset.scan(at: url)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let scanned else {
                    self.isScanningFolder = false
                    self.errorMessage = "No NIfTI (.nii / .nii.gz) files found in “\(url.lastPathComponent)”."
                    return
                }
                self.dataset = scanned
                if let first = scanned.firstImage, first.url != self.loadedFileURL {
                    // A new image will load. Keep the loading overlay continuous
                    // across the scan→load hand-off: set isLoading before clearing
                    // isScanningFolder so `isLoading || isScanningFolder` never
                    // flickers false for a runloop turn (loadNifti sets isLoading
                    // on a later turn). Guard on the URL differing so re-opening
                    // the same folder (first image already shown) doesn't strand
                    // the overlay — selectDatasetFile would no-op and never clear it.
                    self.isLoading = true
                    self.isScanningFolder = false
                    self.selectDatasetFile(first)
                } else {
                    // The first image is already loaded (re-opening the same
                    // folder) — just refresh the navigator and re-tag the loaded
                    // file with the rebuilt dataset's entities.
                    self.isScanningFolder = false
                    if let loaded = self.loadedFileURL {
                        self.currentDatasetFile = scanned.file(for: loaded)
                    }
                }
            }
        }
    }

    /// Choose one or more 3D NIfTI mask/atlas files for the current volume.
    func openLayerFiles() {
        guard niftiSeriesIndex >= 0, cachedVolume(forSeriesIndex: niftiSeriesIndex) != nil else {
            layerImportError = "Open a base NIfTI image before adding layers."
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose 3D NIfTI mask or atlas label files"
        var types: [UTType] = []
        for ext in ["nii", "gz"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK { addLayerFiles(panel.urls) }
    }

    /// Load and affine-map layer files away from the main thread. Files are
    /// processed serially to avoid holding several decompressed NIfTI payloads
    /// at once; successful members of a multi-selection are still installed if
    /// another member fails.
    func addLayerFiles(_ urls: [URL]) {
        guard !urls.isEmpty,
              niftiSeriesIndex >= 0,
              let base = cachedVolume(forSeriesIndex: niftiSeriesIndex) else {
            layerImportError = "Open a base NIfTI image before adding layers."
            return
        }
        showLayerInspector = true
        isImportingLayers = true
        layerImportError = nil
        let startingColorIndex = layerStore.layers.count
        let palette: [SIMD3<Double>] = [
            SIMD3(1.00, 0.23, 0.19), SIMD3(0.20, 0.67, 0.96),
            SIMD3(0.30, 0.85, 0.39), SIMD3(1.00, 0.80, 0.18),
            SIMD3(0.75, 0.35, 0.95), SIMD3(1.00, 0.55, 0.18)
        ]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var loaded: [OverlayLayer] = []
            var failures: [String] = []
            for (index, url) in urls.enumerated() {
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                do {
                    let layer = try OverlayLayerLoader.load(url: url, matching: base)
                    layer.maskColor = palette[(startingColorIndex + index) % palette.count]
                    loaded.append(layer)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for layer in loaded { self.layerStore.add(layer) }
                self.isImportingLayers = false
                if !failures.isEmpty {
                    self.layerImportError = failures.joined(separator: "\n")
                }
            }
        }
    }

    /// Load a URL. A directory opens as a dataset/loose folder; a NIfTI file is
    /// displayed. `preserveDataset` keeps the open dataset navigator (set when the
    /// file was picked from it); the default clears it (a standalone single-file
    /// session).
    func load(url: URL, preserveDataset: Bool = false) {
        // A folder → scan it into the dataset navigator instead.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            DispatchQueue.main.async { self.loadFolder(url: url) }
            return
        }

        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }

        BenchmarkLogger.shared.start("load_total")
        BenchmarkLogger.shared.log(event: "load_start", dataset: url.lastPathComponent, detail: url.path)

        if ViewerModel.isNiftiURL(url) {
            cachingQueue.cancelAllOperations()
            DispatchQueue.main.async {
                self.errorMessage = nil
                self.image = nil
                self.rawPixelData = nil
                self.allSeries = []
                self.currentSeriesIndex = -1
                self.currentImageIndex = -1
                self.currentSeriesInfo = ""
                self.currentImageInfo = ""
                self.loadedFileName = url.lastPathComponent
                self.loadedFileURL = url
                if preserveDataset {
                    // Keep the navigator; tag the loaded file with its dataset
                    // entities (for BIDS-derivative output naming + highlight).
                    self.currentDatasetFile = self.dataset?.file(for: url)
                } else {
                    self.dataset = nil
                    self.currentDatasetFile = nil
                }
                self.layerStore.removeAll()
                self.resetSegmentation()
                self.resetAllPanels()
                self.loadNifti(url: url)
            }
            return
        }

        DispatchQueue.main.async {
            self.errorMessage = "Unsupported file type. Lentis opens NIfTI (.nii / .nii.gz) files."
        }
    }



    private func computeMinMax(data: Data, isSigned: Bool, bits: Int) -> (Double, Double) {
        var minVal: Double = Double.greatestFiniteMagnitude
        var maxVal: Double = -Double.greatestFiniteMagnitude
        
        if bits > 16 { // 32-bit
             data.withUnsafeBytes { rawBuffer in
                 if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt32.self) {
                     let count = data.count / 4
                     for i in 0..<count {
                         var v: Double = 0
                         if isSigned {
                             v = Double(Int32(bitPattern: ptr[i]))
                         } else {
                             v = Double(ptr[i])
                         }
                         
                         if v < minVal { minVal = v }
                         if v > maxVal { maxVal = v }
                     }
                 }
             }
        } else if bits > 8 { // 16-bit
             data.withUnsafeBytes { rawBuffer in
                 if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt16.self) {
                     let count = data.count / 2
                     for i in 0..<count {
                         var v: Double = 0
                         if isSigned {
                             v = Double(Int16(bitPattern: ptr[i]))
                         } else {
                             v = Double(ptr[i])
                         }
                         
                         if v < minVal { minVal = v }
                         if v > maxVal { maxVal = v }
                     }
                 }
             }
        } else {
             data.withUnsafeBytes { rawBuffer in
                 if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                     let count = data.count
                     for i in 0..<count {
                         let v = Double(ptr[i])
                         if v < minVal { minVal = v }
                         if v > maxVal { maxVal = v }
                     }
                 }
             }
        }
        
        if maxVal == minVal { maxVal = minVal + 1 }
        return (minVal, maxVal)
    }
    
    // MARK: - Navigation helpers
    
    // MARK: - Info Update

    // MARK: - Legacy-to-Panel Sync

    /// Assign a series to a specific panel and load its first image
    func assignSeriesToPanel(_ panel: PanelState, seriesIndex: Int) {
        guard seriesIndex >= 0, seriesIndex < allSeries.count else { return }
        panel.seriesIndex = seriesIndex
        panel.imageIndex = 0

        // Seed modality-aware W/L (CT preset / MRI percentile, or a saved manual
        // window) so MPR/3D panels don't fall back to a generic
        // 2000/500 window and render dark (e.g. the one-click quad MPR layout).
        // Non-NIfTI series (none currently) keep the legacy reset-to-0.
        if let (ww, wc) = seededWindow(forSeriesIndex: seriesIndex) {
            panel.windowWidth = ww
            panel.windowCenter = wc
        } else {
            panel.windowWidth = 0
            panel.windowCenter = 0
        }

        // NIfTI volumes display as an axial MPR reconstruction.
        setPanelMode(panel, mode: .mprAxial)
        updatePanelInfoStrings(panel)
    }

    // MARK: - W/L Helpers

    /// Navigate panel by an offset (positive = forward, negative = backward)
    func navigatePanelByOffset(_ panel: PanelState, offset: Int) {
        // If panel is group-selected, scroll all group members by the same offset
        if panel.isGroupSelected {
            let groupPanels = groupSelectedPanels
            if groupPanels.count > 1 {
                for p in groupPanels {
                    navigatePanelByOffsetDirect(p, offset: offset)
                }
                handleCrossPanelScroll(for: panel)
                return
            }
        }
        navigatePanelByOffsetDirect(panel, offset: offset)
        handleCrossPanelScroll(for: panel)
    }

    private func navigatePanelByOffsetDirect(_ panel: PanelState, offset: Int) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
        if panel.panelMode.isMPR {
            navigateMPRPanel(panel, delta: offset)
        }
    }

    /// Navigate panel to first or last image
    func navigatePanelToEdge(_ panel: PanelState, toFirst: Bool) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
        let total = totalSliceCount(for: panel)
        navigatePanelToSlice(panel, index: toFirst ? 0 : total - 1)
    }

    /// Reset view: restore ALL spatial transforms (zoom, pan, 90° rotation,
    /// horizontal/vertical flip, invert) to their defaults in one shot. Window/
    /// Level is deliberately preserved — use `A` / the Auto button for an
    /// auto window. For the 3D panel, the camera (yaw/pitch/opacity) is reset
    /// via `resetVolumeCamera` IN ADDITION to zoom/pan — the 3D image layer
    /// shares the same `restoreState()` transform as MPR, so Option/Control-drag
    /// pan and scroll/drag zoom still move `panel.scale`/`panel.translation` on
    /// a 3D panel, and those must be cleared too (not just the camera).
    ///
    /// Wired to the R key, the View menu's "Reset View" item, and the one-shot
    /// button at the bottom of the left tool palette. `F` (Fit to Window) is a
    /// lighter variant that resets only zoom/pan.
    func resetViewForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        // Zoom/pan apply to every panel (the image layer's `restoreState` uses
        // `panel.scale`/`panel.translation` for MPR and 3D alike; the scroll/drag
        // zoom + Option/Control-drag pan handlers are not 3D-guarded).
        panel.scale = 1.0
        panel.translation = .zero
        if panel.panelMode == .volume3D {
            // 3D has no rotation/flip/invert; reset the camera + density instead.
            resetVolumeCamera(panel)
            return
        }
        panel.rotationSteps = 0
        panel.isFlippedH = false
        panel.isFlippedV = false
        panel.isInverted = false
    }

    /// Fit image to window (reset zoom/pan only, keep W/L)
    func fitToWindowForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        panel.scale = 1.0
        panel.translation = .zero
    }

    /// Toggle image inversion
    func invertForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        panel.isInverted.toggle()
    }

    /// Rotate image 90° clockwise
    func rotateClockwiseForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        if panel.panelMode == .volume3D {
            rotateVolumeRendering(panel, deltaYaw: 90, deltaPitch: 0, interactive: false)
        } else {
            panel.rotationSteps = (panel.rotationSteps + 1) % 4
        }
    }

    /// Rotate image 90° counter-clockwise
    func rotateCounterClockwiseForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        if panel.panelMode == .volume3D {
            rotateVolumeRendering(panel, deltaYaw: -90, deltaPitch: 0, interactive: false)
        } else {
            panel.rotationSteps = (panel.rotationSteps + 3) % 4
        }
    }

    /// Flip image horizontally
    func flipHorizontalForPanel(_ panel: PanelState?) {
        guard let panel = panel, panel.panelMode != .volume3D else { return }
        panel.isFlippedH.toggle()
    }

    /// Flip image vertically
    func flipVerticalForPanel(_ panel: PanelState?) {
        guard let panel = panel, panel.panelMode != .volume3D else { return }
        panel.isFlippedV.toggle()
    }

    // MARK: - Multi-Panel Management

    /// Initialize panels array on first use
    func ensurePanelsInitialized() {
        if panels.isEmpty {
            let panel = PanelState()
            panels = [panel]
            activePanelID = panel.id
        }
    }

    /// Reset all panels to their default state (used when loading a new directory)
    func resetAllPanels() {
        for panel in panels {
            panel.reset()
        }
        // Clear per-image caches to prevent unbounded growth across directory loads
        imageCacheParamsLock.lock()
        imageCacheParams.removeAll()
        imagePixelMeta.removeAll()
        imageCacheParamsLock.unlock()
        seriesThumbnails.removeAll()
    }

    // MARK: - Close current file / replace-with-confirmation

    /// True when there is unsaved work the user might not want to discard: a
    /// committed calcification region, an in-flight draft, external mask/atlas
    /// layers, or a brain-mask/parcellation layer. Drives the close/replace
    /// confirmation gate (`requestClose` / `requestLoad`).
    var hasUnsavedWork: Bool {
        hasSegmentation || draftRegion != nil
            || !layerStore.layers.isEmpty || brainMaskLayer != nil
    }

    /// A deferred destructive action awaiting the user's confirmation. Set by
    /// `requestClose` / `requestLoad` when `hasUnsavedWork` and the
    /// `confirmReplaceOnDiscard` preference is on; the alert in `ContentView`
    /// either performs it (`performPendingConfirmation`) or cancels it
    /// (`cancelPendingConfirmation`). nil ⇒ no confirmation pending.
    struct PendingConfirmation: Identifiable {
        let id = UUID()
        /// The kind of destructive action — drives the alert's button label.
        let kind: Kind
        let message: String
        let action: () -> Void

        enum Kind { case close, replace }
        var title: String {
            kind == .close ? "Close current file?" : "Replace current file?"
        }
        /// Affirmative button label (role: .destructive).
        var actionLabel: String {
            kind == .close ? "Close" : "Replace"
        }
    }
    @Published var pendingConfirmation: PendingConfirmation? = nil

    /// Perform the pending destructive action (user confirmed the alert).
    func performPendingConfirmation() {
        let pending = pendingConfirmation
        pendingConfirmation = nil
        pending?.action()
    }

    /// Cancel the pending destructive action (user dismissed the alert).
    func cancelPendingConfirmation() {
        pendingConfirmation = nil
    }

    /// Whether a close/replace action needs to confirm with the user first:
    /// only when something is open, there's unsaved work, and the preference is
    /// on. Reads `AppSettings.shared` (the established viewer→settings pattern).
    /// `confirmReplaceOnDiscardOverride` (non-nil only in tests) substitutes for
    /// the shared preference so the gate can be exercised without mutating the
    /// process-wide singleton.
    var confirmReplaceOnDiscardOverride: Bool? = nil

    private var closeReplaceNeedsConfirmation: Bool {
        let pref = confirmReplaceOnDiscardOverride ?? AppSettings.shared.confirmReplaceOnDiscard
        return pref
            && (niftiDataset != nil || dataset != nil)
            && hasUnsavedWork
    }

    /// Close the current file (File → Close, ⌘W). Returns the viewer to the
    /// empty "No file open" state, mirroring a fresh launch. Segmentation
    /// regions, external layers, and caches are released. The window stays
    /// open — the user can then open another file.
    func closeCurrentFile() {
        cachingQueue.cancelAllOperations()
        for panel in panels { panel.loadingQueue.cancelAllOperations() }
        errorMessage = nil
        image = nil
        rawPixelData = nil
        allSeries = []
        currentSeriesIndex = -1
        currentImageIndex = -1
        currentSeriesInfo = ""
        currentImageInfo = ""
        loadedFileName = ""
        loadedFileURL = nil
        dataset = nil
        currentDatasetFile = nil
        niftiDataset = nil
        niftiSeriesIndex = -1
        currentTimepoint = 0
        modalityOverride = nil
        crosshairWorld = nil
        layerStore.removeAll()
        resetSegmentation()
        resetAllPanels()
        // `load` does not clear these (it overwrites per-series entries), so a
        // close must drop them to avoid a stale entry surviving into the next
        // session and seeding the wrong window.
        seriesStates.removeAll()
        volumeCacheLock.lock()
        _volumeCache.removeAll()
        volumeCacheLock.unlock()
        // Back to the launch layout: a single empty panel slot. MultiPanelContainer
        // renders EmptyPanelView for an unassigned slot; an empty `panels` array
        // likewise shows the empty state (and the sidebar's "No file open").
        layout = .single
        isMPRLayout = false
        fullscreenPanelID = nil
        panels = []
        showLayerInspector = false
        segmentationRevision &+= 1
    }

    /// File → Close, ⌘W. Confirms first if there is unsaved work and the
    /// preference is on; otherwise closes immediately.
    func requestClose() {
        if closeReplaceNeedsConfirmation {
            pendingConfirmation = PendingConfirmation(
                kind: .close,
                message: "Closing will discard unsaved segmentation regions, drafts, and layers.",
                action: { [weak self] in self?.closeCurrentFile() })
        } else {
            closeCurrentFile()
        }
    }

    /// Drop-to-replace entry point. A drop on the image viewport calls this
    /// instead of `load` directly so an unsaved segmentation/layers can be
    /// confirmed first (per the `confirmReplaceOnDiscard` preference). With no
    /// prior file open it just loads — same as the Open menu.
    func requestLoad(url: URL) {
        if closeReplaceNeedsConfirmation {
            pendingConfirmation = PendingConfirmation(
                kind: .replace,
                message: "Opening “\(url.lastPathComponent)” will discard unsaved segmentation regions, drafts, and layers.",
                action: { [weak self] in self?.load(url: url) })
        } else {
            load(url: url)
        }
    }

    /// Auto-assign series to panels (one series per panel, in order)
    func autoAssignSeriesToPanels() {
        for i in 0..<panels.count {
            guard i < allSeries.count else { break }
            // Skip panel[0] if it already has a valid series (set by fast-load path)
            if i == 0 && panels[0].seriesIndex >= 0 && panels[0].seriesIndex < allSeries.count {
                continue
            }
            assignSeriesToPanel(panels[i], seriesIndex: i)
        }
    }

    /// Set the viewer layout and resize the panels array accordingly
    func setLayout(_ newLayout: ViewerLayout) {
        let oldCount = panels.count
        let newCount = newLayout.panelCount
        layout = newLayout
        // Picking any explicit layout exits the coordinated MPR tri-planar mode,
        // so per-panel plane switching is allowed again. `setupMPRLayout` calls
        // this first, then re-sets the flag.
        isMPRLayout = false

        if newCount > oldCount {
            for i in oldCount..<newCount {
                let newPanel = PanelState()
                panels.append(newPanel)
                // Auto-assign series to newly created panels
                if i < allSeries.count {
                    assignSeriesToPanel(newPanel, seriesIndex: i)
                }
            }
        } else if newCount < oldCount {
            // Keep the first N panels, reset and remove the rest
            let removed = panels.suffix(from: newCount)
            for panel in removed {
                panel.reset()
            }
            panels = Array(panels.prefix(newCount))
        }

        // Ensure active panel is still valid
        if !panels.contains(where: { $0.id == activePanelID }) {
            activePanelID = panels.first?.id ?? UUID()
        }

        // Ensure fullscreen panel ID is still valid
        if let fsID = fullscreenPanelID, !panels.contains(where: { $0.id == fsID }) {
            fullscreenPanelID = nil
        }
    }

    /// One-click brain layout: Axial + Sagittal + Coronal + interactive 3D volume.
    /// Pass `seriesIndex` to pin a specific series (e.g. a freshly-loaded volume on
    /// open); otherwise it uses the active panel's series (or first available).
    func setupMPRLayout(seriesIndex: Int? = nil) {
        setLayout(.quad)

        // Determine series to use. An explicit index wins (the file-open path
        // passes the just-registered volume; registerStandaloneVolume *appends*
        // a series per load, so "active panel / first" can resolve to a stale
        // one on a second open). Otherwise fall back to active / first.
        let seriesIdx: Int
        if let s = seriesIndex, s >= 0, s < allSeries.count {
            seriesIdx = s
        } else if let active = activePanel, active.seriesIndex >= 0 {
            seriesIdx = active.seriesIndex
        } else if !allSeries.isEmpty {
            seriesIdx = 0
        } else {
            return
        }

        guard panels.count == 4 else { return }

        // Panel 0: Axial MPR
        assignSeriesToPanel(panels[0], seriesIndex: seriesIdx)
        setPanelMode(panels[0], mode: .mprAxial)

        // Panel 1: Sagittal MPR
        assignSeriesToPanel(panels[1], seriesIndex: seriesIdx)
        setPanelMode(panels[1], mode: .mprSagittal)

        // Panel 2: Coronal MPR
        assignSeriesToPanel(panels[2], seriesIndex: seriesIdx)
        setPanelMode(panels[2], mode: .mprCoronal)

        // Panel 3: direct volume rendering
        assignSeriesToPanel(panels[3], seriesIndex: seriesIdx)
        setPanelMode(panels[3], mode: .volume3D)

        // Set active panel to axial
        activePanelID = panels[0].id
        // Synchronized scrolling (proportional slice relocation) makes no sense
        // in the MPR tri-planar layout — scrolling one plane must NOT move the
        // orthogonal planes' slices. Instead, the 3D crosshair tracks the scroll
        // so the crosshair lines on the other planes follow the spatial position.
        synchronizedScrolling = false
        // Show the 3D crosshair out of the box for the tri-planar layout —
        // click/drag any plane to localize the others.
        showCrossReference = true
        // Lock per-panel plane switching: the four panels now have coordinated
        // roles (axial/sagittal/coronal/3D) that the crosshair linkage relies on.
        isMPRLayout = true
    }

    // MARK: - Panel Group Selection (simultaneous scrolling)

    /// Toggle group selection for a panel
    func toggleGroupSelection(for panel: PanelState) {
        panel.isGroupSelected.toggle()
    }

    /// Select all panels in a range (for drag-to-select across panels)
    func setGroupSelection(panelIDs: Set<UUID>) {
        for panel in panels {
            panel.isGroupSelected = panelIDs.contains(panel.id)
        }
    }

    /// Clear all group selections
    func clearGroupSelection() {
        for panel in panels {
            panel.isGroupSelected = false
        }
    }

    /// The set of panels currently group-selected
    var groupSelectedPanels: [PanelState] {
        panels.filter { $0.isGroupSelected }
    }

    /// Navigate a panel, and if it's group-selected, also scroll all other
    /// group-selected panels by the same relative offset (not spatial matching).
    func navigatePanelWithGroup(_ panel: PanelState, direction: NavigationDirection) {
        // Measures the synchronous main-thread cost of one scroll tick (active panel
        // navigate + sync-scroll of the others). With async MPR this should be
        // sub-millisecond even on the 721 MB MPRAGE quad layout (--benchmark only).
        BenchmarkLogger.shared.start("scroll_main")
        defer { BenchmarkLogger.shared.stop("scroll_main", detail: "\(panel.panelMode.rawValue) sync=\(synchronizedScrolling)") }

        // If the panel is group-selected, scroll all group members simultaneously
        if panel.isGroupSelected {
            let groupPanels = groupSelectedPanels
            if groupPanels.count > 1 {
                for p in groupPanels {
                    navigatePanelDirect(p, direction: direction)
                }
                // Still do spatial sync for linked mode on the source panel
                handleCrossPanelScroll(for: panel)
                return
            }
        }
        // Not in a group — use normal navigation (which handles sync)
        navigatePanel(panel, direction: direction)
    }

    /// Navigate a single panel without triggering sync or group logic (used by group scroll)
    private func navigatePanelDirect(_ panel: PanelState, direction: NavigationDirection) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }

        if panel.panelMode.isMPR {
            switch direction {
            case .nextImage: navigateMPRPanel(panel, delta: 1)
            case .prevImage: navigateMPRPanel(panel, delta: -1)
            default: break
            }
            return
        }

        // A 3D panel has no slice index. Arrow/scroll navigation is intentionally
        // a no-op; pointer drag controls its camera instead.
    }

    /// Navigate within a specific panel
    func navigatePanel(_ panel: PanelState, direction: NavigationDirection) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }

        // MPR mode: navigate slice index instead of image index
        if panel.panelMode.isMPR {
            switch direction {
            case .nextImage: navigateMPRPanel(panel, delta: 1)
            case .prevImage: navigateMPRPanel(panel, delta: -1)
            case .nextSeries, .prevSeries: break
            }
            if direction == .nextSeries || direction == .prevSeries {
            } else {
                handleCrossPanelScroll(for: panel)
                return
            }
        }

        // Series switching (NIfTI is usually a single series, so typically a no-op).
        switch direction {
        case .nextImage, .prevImage:
            break  // handled above for MPR; 3D has no slice navigation
        case .nextSeries:
            if panel.seriesIndex < allSeries.count - 1 {
                assignSeriesToPanel(panel, seriesIndex: panel.seriesIndex + 1)
            }
        case .prevSeries:
            if panel.seriesIndex > 0 {
                assignSeriesToPanel(panel, seriesIndex: panel.seriesIndex - 1)
            }
        }
    }

    // MARK: - Crosshair (3D linkage)

    /// Place the shared 3D crosshair at `world` (RAS mm) — typically from a
    /// click/drag in `source`. Every *other* orthogonal panel relocates so its
    /// slice passes through the point, reusing the async + coalesced MPR
    /// render path (so drag spam costs no more than fast scrolling). The source
    /// panel isn't moved: the click was on its displayed slice, so the point is
    /// already on its plane. All panels redraw their crosshair lines because the
    /// overlay observes `crosshairWorld` (@Published).
    ///
    /// This is the true 3D cross-panel link that replaces the old z-only
    /// `syncScrollFromPanel` proportional mapping: orthogonal planes correctly
    /// stay put unless the in-plane click actually moved their slice index.
    func setCrosshair(_ world: SIMD3<Double>, from source: PanelState) {
        BenchmarkLogger.shared.start("crosshair_set")
        var relocated = 0
        defer { BenchmarkLogger.shared.stop("crosshair_set", detail: "relocated=\(relocated)") }
        crosshairWorld = world

        for panel in panels where panel.id != source.id {
            guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count,
                  let vol = cachedVolume(forSeriesIndex: panel.seriesIndex) else { continue }
            let engine = MPREngine(volume: vol)
            switch panel.panelMode {
            case .mprAxial, .mprSagittal, .mprCoronal:
                guard let idx = engine.orthogonalSliceIndex(for: panel.panelMode, containing: world)
                else { continue }
                if idx != panel.mprSliceIndex {
                    relocated += 1
                    panel.mprSliceIndex = idx
                    updateMPRSpatialMetadata(panel, volume: vol)
                    loadMPRSlice(for: panel)
                }
            case .volume3D:
                continue
            }
        }
    }

    /// Synchronized scrolling: when one panel scrolls, sync others to the same spatial position.
    /// Uses z-location matching when available, falls back to proportional matching.
    private func syncScrollFromPanel(_ source: PanelState) {
        guard source.seriesIndex >= 0, source.seriesIndex < allSeries.count else { return }

        let sourceTotal = totalSliceCount(for: source)
        let sourceIndex = currentSliceIndex(for: source)

        for panel in panels where panel.id != source.id {
            guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { continue }
            let targetSeries = allSeries[panel.seriesIndex]

            switch panel.panelMode {
            case .volume3D:
                continue  // 3D has no slice position to sync.
            case .mprAxial:
                if let vol = volumeCacheGet(targetSeries.id), vol.depth > 1 {
                    let targetIdx = closestVolumeIndex(dimension: vol.depth, sourceIndex: sourceIndex, sourceTotal: sourceTotal)
                    if targetIdx != panel.mprSliceIndex {
                        panel.mprSliceIndex = targetIdx
                        updateMPRSpatialMetadata(panel, volume: vol)
                        loadMPRSlice(for: panel)
                    }
                }
            case .mprSagittal:
                if let vol = volumeCacheGet(targetSeries.id), vol.width > 1 {
                    let targetIdx = closestVolumeIndex(dimension: vol.width, sourceIndex: sourceIndex, sourceTotal: sourceTotal)
                    if targetIdx != panel.mprSliceIndex {
                        panel.mprSliceIndex = targetIdx
                        updateMPRSpatialMetadata(panel, volume: vol)
                        loadMPRSlice(for: panel)
                    }
                }
            case .mprCoronal:
                if let vol = volumeCacheGet(targetSeries.id), vol.height > 1 {
                    let targetIdx = closestVolumeIndex(dimension: vol.height, sourceIndex: sourceIndex, sourceTotal: sourceTotal)
                    if targetIdx != panel.mprSliceIndex {
                        panel.mprSliceIndex = targetIdx
                        updateMPRSpatialMetadata(panel, volume: vol)
                        loadMPRSlice(for: panel)
                    }
                }
            }
        }
    }

    /// Synchronized zoom/pan: when one panel zooms or pans, sync others to the same transform.
    func syncZoomFromPanel(_ source: PanelState) {
        guard synchronizedScrolling else { return }
        let targetScale = source.scale
        let targetTranslation = source.translation
        for panel in panels where panel.id != source.id {
            panel.scale = targetScale
            panel.translation = targetTranslation
        }
    }

    /// Cross-panel scroll dispatch. In the MPR tri-planar layout, scrolling one
    /// plane updates the 3D crosshair's perpendicular-axis world component so
    /// the crosshair lines on the *other* planes follow the new spatial position
    /// — but the other planes' slices are left untouched (the old proportional
    /// `syncScrollFromPanel` relocation is wrong for orthogonal MPR). In every
    /// other layout, falls back to the legacy proportional synchronized scroll.
    private func handleCrossPanelScroll(for source: PanelState) {
        if isMPRLayout {
            updateCrosshairOnScroll(of: source)
        } else if synchronizedScrolling {
            syncScrollFromPanel(source)
        }
    }

    /// Move the shared 3D crosshair to track a scroll on `panel`. The crosshair's
    /// in-plane voxel coordinates are preserved; only the scrolled panel's
    /// perpendicular voxel axis is updated to the new slice index, then mapped
    /// back to world. The other MPR panels are NOT relocated (their slices stay
    /// put) — only their crosshair lines move. Robust to any affine because it
    /// round-trips through `worldToVoxel` / `voxelToWorld`.
    private func updateCrosshairOnScroll(of panel: PanelState) {
        guard showCrossReference,
              let vol = cachedVolume(forSeriesIndex: panel.seriesIndex),
              panel.panelMode.isMPR else { return }
        let center = SIMD3<Double>(
            Double(vol.width - 1) / 2,
            Double(vol.height - 1) / 2,
            Double(vol.depth - 1) / 2)
        var v = crosshairWorld.map { vol.worldToVoxel($0) } ?? center
        switch panel.panelMode {
        case .mprAxial:    v.z = Double(panel.mprSliceIndex)
        case .mprSagittal: v.x = Double(panel.mprSliceIndex)
        case .mprCoronal:  v.y = Double(panel.mprSliceIndex)
        case .volume3D:    return
        }
        crosshairWorld = vol.voxelToWorld(v)
    }

    /// Find the closest volume slice index for MPR targets using proportional matching.
    private func closestVolumeIndex(dimension: Int, sourceIndex: Int, sourceTotal: Int) -> Int {
        guard dimension > 1 else { return 0 }

        // Current NIfTI synchronized scrolling is proportional. Cross-panel
        // anatomical linking is handled by the 3D crosshair path.
        guard sourceTotal > 1 else { return 0 }
        let pct = Double(sourceIndex) / Double(sourceTotal - 1)
        return max(0, min(dimension - 1, Int(pct * Double(dimension - 1))))
    }

    /// Set a panel's absolute W/L (stored units) and re-render. Routes through
    /// `adjustWindowLevelForPanel`, so it reuses the MPR/3D re-render path and
    /// persists to seriesStates. Used by preset / auto / modality-toggle seeding.
    func setPanelWindow(_ panel: PanelState, ww: Double, wc: Double) {
        adjustWindowLevelForPanel(panel,
                                  deltaWidth: ww - panel.windowWidth,
                                  deltaCenter: wc - panel.windowCenter)
    }

    /// Persist a panel's current window to the model's `seriesStates`, so other
    /// panels / precaching / 4D timepoints share it.
    ///
    /// ⚠️ This writes a `@Published` on the MODEL, so it fires
    /// `model.objectWillChange` → every model-observing view (the whole quad)
    /// re-evaluates and SwiftUI re-runs layout over the tree. That is fine for a
    /// **one-shot** (preset / auto / drag-END) but MUST NOT run per W/L-drag
    /// flush: doing so re-laid-out the entire quad on every mouse event (SwiftUI
    /// `LayoutEngineBox` recursion — found by `sample`, not by the `wl_drag`
    /// probe), which was the W/L-drag lag. Same class as the crosshair-drag lag,
    /// fixed the same way: keep per-event drag state on the PANEL; touch the
    /// model only at the end of the drag.
    func persistWindowToSeriesStates(_ panel: PanelState) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
        let uid = allSeries[panel.seriesIndex].id
        var state = seriesStates[uid] ?? SeriesViewState()
        state.windowWidth = panel.windowWidth
        state.windowCenter = panel.windowCenter
        seriesStates[uid] = state
    }

    /// Adjust W/L for a specific panel.
    ///
    /// The W/L *state* update stays synchronous on the main thread but mutates
    /// only PANEL `@Published` values (`windowWidth`/`windowCenter`) — the toolbar
    /// readout binds them, so it updates instantly while invalidating only this
    /// panel's subtree, never the whole model/quad. The *re-render* is pushed off
    /// the main thread by re-driving the panel's own async+coalesced loader with
    /// the just-updated window:
    ///   • MPR planes → `loadMPRSlice` (re-extracts the CURRENT slice fresh and
    ///     re-renders with the new W/L). Re-extraction is cheap and off-main, and
    ///     it makes this correct by construction — coalesced + drop-stale, and it
    ///     can't display a stale slice even if a scroll render was still in
    ///     flight when the drag began (a render-only path reading the cached
    ///     `rawPixelData` could).
    ///   • 3D → `loadVolumeRendering` (W/L drives the GPU transfer function).
    ///     The command-buffer wait and readback stay on `panel.loadingQueue`.
    /// Both loaders do only cheap setup on the main thread (cached-volume lookup
    /// is synchronous, then enqueue); extraction/projection + the now-Float
    /// parallel W/L render + NSImage build all run on `panel.loadingQueue`.
    /// `wl_drag` (--benchmark) measures the remaining synchronous main-thread
    /// cost of one flush; the off-main render shows as `mpr_render` / `volume_render`.
    ///
    /// Guarded on the panel already having a rendered view (`rawPixelData` for
    /// MPR / a cached volume for 3D) so seed-time W/L (presets/auto/modality,
    /// before the first render) stays a no-op exactly as the old synchronous path
    /// was — the normal first-render flow draws the initial slice.
    ///
    /// `persist` controls the write-back to the MODEL's `seriesStates`. A W/L
    /// **drag** passes `persist: false` for every throttled flush, so a drag never
    /// fires `model.objectWillChange` and never re-lays-out the whole quad (the
    /// W/L-drag-lag fix — see `persistWindowToSeriesStates`); it commits ONCE at
    /// drag-end. One-shot callers (presets / auto / seeding via `setPanelWindow`)
    /// keep the default `persist: true`.
    func adjustWindowLevelForPanel(_ panel: PanelState, deltaWidth: Double, deltaCenter: Double,
                                   persist: Bool = true) {
        BenchmarkLogger.shared.start("wl_drag")
        defer { BenchmarkLogger.shared.stop("wl_drag", detail: panel.panelMode.rawValue) }

        panel.windowWidth = max(1.0, panel.windowWidth + deltaWidth)
        panel.windowCenter += deltaCenter

        // Write the window back to the model only when asked — NEVER per drag
        // flush. `seriesStates` is @Published on the model, so this fires
        // model.objectWillChange → whole-quad SwiftUI relayout (LayoutEngineBox).
        // A drag passes persist:false (panel-local only) and commits once at end.
        if persist { persistWindowToSeriesStates(panel) }

        switch panel.panelMode {
        case .mprAxial, .mprSagittal, .mprCoronal:
            if panel.rawPixelData != nil { loadMPRSlice(for: panel) }
        case .volume3D:
            if let seriesID = allSeries[safe: panel.seriesIndex]?.id,
               volumeCacheGet(seriesID) != nil {
                loadVolumeRendering(for: panel)
            }
        }
    }

    /// Auto W/L for a specific panel
    func autoWindowLevelForPanel(_ panel: PanelState) {
        if let data = panel.rawPixelData {
            let (minVal, maxVal) = computeMinMax(data: data, isSigned: panel.isSigned, bits: panel.bitDepth)
            let newWW = maxVal - minVal
            let newWC = minVal + (newWW / 2.0)
            adjustWindowLevelForPanel(panel, deltaWidth: newWW - panel.windowWidth, deltaCenter: newWC - panel.windowCenter)
        }
    }

    /// Compute min/max pixel values within a rectangular subregion of the image data.
    private func computeMinMaxInRect(data: Data, width: Int, rect: CGRect, isSigned: Bool, bits: Int) -> (Double, Double) {
        guard width > 0 else { return (0, 0) }
        var minVal: Double = Double.greatestFiniteMagnitude
        var maxVal: Double = -Double.greatestFiniteMagnitude

        let startCol = max(0, Int(rect.minX))
        let endCol = min(width, Int(ceil(rect.maxX)))
        let startRow = max(0, Int(rect.minY))
        guard endCol > startCol else { return (0, 0) }

        if bits > 16 { // 32-bit
            let bytesPerPixel = 4
            let totalPixels = data.count / bytesPerPixel
            let height = totalPixels / max(1, width)
            let endRow = min(height, Int(ceil(rect.maxY)))
            guard endRow > startRow else { return (0, 0) }
            data.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
                for row in startRow..<endRow {
                    for col in startCol..<endCol {
                        let i = row * width + col
                        guard i >= 0, i < totalPixels else { continue }
                        let v: Double = isSigned ? Double(Int32(bitPattern: ptr[i])) : Double(ptr[i])
                        if v < minVal { minVal = v }
                        if v > maxVal { maxVal = v }
                    }
                }
            }
        } else if bits > 8 { // 16-bit
            let bytesPerPixel = 2
            let totalPixels = data.count / bytesPerPixel
            let height = totalPixels / max(1, width)
            let endRow = min(height, Int(ceil(rect.maxY)))
            guard endRow > startRow else { return (0, 0) }
            data.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt16.self) else { return }
                for row in startRow..<endRow {
                    for col in startCol..<endCol {
                        let i = row * width + col
                        guard i >= 0, i < totalPixels else { continue }
                        let v: Double = isSigned ? Double(Int16(bitPattern: ptr[i])) : Double(ptr[i])
                        if v < minVal { minVal = v }
                        if v > maxVal { maxVal = v }
                    }
                }
            }
        } else { // 8-bit
            let totalPixels = data.count
            let height = totalPixels / max(1, width)
            let endRow = min(height, Int(ceil(rect.maxY)))
            guard endRow > startRow else { return (0, 0) }
            data.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for row in startRow..<endRow {
                    for col in startCol..<endCol {
                        let i = row * width + col
                        guard i >= 0, i < totalPixels else { continue }
                        let v = Double(ptr[i])
                        if v < minVal { minVal = v }
                        if v > maxVal { maxVal = v }
                    }
                }
            }
        }

        if minVal > maxVal { return (0, 0) }
        return (minVal, maxVal)
    }

    /// Auto W/L from a rectangular ROI in pixel coordinates
    func autoWindowLevelForPanelROI(_ panel: PanelState, rect: CGRect) {
        guard let data = panel.rawPixelData, panel.imageWidth > 0 else { return }
        let scaleX = panel.displayImageWidth > 0 ? CGFloat(panel.imageWidth) / panel.displayImageWidth : 1.0
        let scaleY = panel.displayImageHeight > 0 ? CGFloat(panel.imageHeight) / panel.displayImageHeight : 1.0
        let rawRect = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY,
                             width: rect.width * scaleX, height: rect.height * scaleY)
        let (minVal, maxVal) = computeMinMaxInRect(data: data, width: panel.imageWidth, rect: rawRect, isSigned: panel.isSigned, bits: panel.bitDepth)
        let newWW = max(1.0, maxVal - minVal)
        let newWC = minVal + (newWW / 2.0)
        adjustWindowLevelForPanel(panel, deltaWidth: newWW - panel.windowWidth, deltaCenter: newWC - panel.windowCenter)
    }

    /// Compute HU statistics for a pixel-coordinate rectangle on a panel
    func computeROIStats(panel: PanelState, rect: CGRect) -> (mean: Double, max: Double, min: Double, stdDev: Double, count: Int)? {
        guard let data = panel.rawPixelData else { return nil }
        let w = panel.imageWidth
        let h = panel.imageHeight
        // Scale ROI rect from display-image space to raw-pixel space
        let scaleX = panel.displayImageWidth > 0 ? CGFloat(panel.imageWidth) / panel.displayImageWidth : 1.0
        let scaleY = panel.displayImageHeight > 0 ? CGFloat(panel.imageHeight) / panel.displayImageHeight : 1.0
        let rawRect = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY,
                             width: rect.width * scaleX, height: rect.height * scaleY)
        let minX = max(0, Int(rawRect.minX))
        let minY = max(0, Int(rawRect.minY))
        let maxX = min(w - 1, Int(rawRect.maxX))
        let maxY = min(h - 1, Int(rawRect.maxY))
        guard maxX > minX, maxY > minY else { return nil }

        var values: [Double] = []
        values.reserveCapacity((maxX - minX) * (maxY - minY))

        data.withUnsafeBytes { raw in
            for py in minY...maxY {
                for px in minX...maxX {
                    let index = py * w + px
                    var val: Double = 0
                    if panel.bitDepth > 8 {
                        let byteIndex = index * 2
                        if byteIndex + 1 < data.count {
                            if let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt16.self) {
                                if panel.isSigned {
                                    val = Double(Int16(bitPattern: ptr[index]))
                                } else {
                                    val = Double(ptr[index])
                                }
                            }
                        }
                    } else if index < data.count {
                        val = Double(raw[index])
                    }
                    values.append(val)
                }
            }
        }

        guard !values.isEmpty else { return nil }
        let count = values.count
        let sum = values.reduce(0, +)
        let mean = sum / Double(count)
        let maxVal = values.max() ?? 0
        let minVal = values.min() ?? 0
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(count)
        let stdDev = sqrt(variance)

        return (mean: mean, max: maxVal, min: minVal, stdDev: stdDev, count: count)
    }

    /// Save view state (zoom/pan) for a panel
    func saveViewStateForPanel(_ panel: PanelState, scale: CGFloat, translation: CGPoint) {
        panel.scale = scale
        panel.translation = translation
    }

    /// Update info strings for a specific panel
    func updatePanelInfoStrings(_ panel: PanelState) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else {
            panel.currentSeriesInfo = ""
            panel.currentImageInfo = ""
            return
        }
        let s = allSeries[panel.seriesIndex]
        // A NIfTI is always a single series, so "Series 1/1" is noise — show the
        // file name instead. Keep "Series N/M" only when there are multiple series.
        if panel.seriesIndex == niftiSeriesIndex, !loadedFileName.isEmpty {
            panel.currentSeriesInfo = loadedFileName
        } else if allSeries.count > 1 {
            panel.currentSeriesInfo = "Series \(panel.seriesIndex + 1)/\(allSeries.count)"
        } else {
            panel.currentSeriesInfo = ""
        }

        switch panel.panelMode {
        case .mprAxial:
            if let vol = volumeCacheGet(s.id) {
                panel.currentImageInfo = "Axial \(panel.mprSliceIndex + 1)/\(vol.depth)"
            }
        case .mprSagittal:
            if let vol = volumeCacheGet(s.id) {
                panel.currentImageInfo = "Sagittal \(panel.mprSliceIndex + 1)/\(vol.width)"
            }
        case .mprCoronal:
            if let vol = volumeCacheGet(s.id) {
                panel.currentImageInfo = "Coronal \(panel.mprSliceIndex + 1)/\(vol.height)"
            }
        case .volume3D:
            panel.currentImageInfo = String(
                format: "3D Volume  yaw %.0f°  pitch %.0f°",
                panel.volumeYawDegrees, panel.volumePitchDegrees
            )
        }
    }

    /// Get total slice count for current panel mode (for scroller)
    func totalSliceCount(for panel: PanelState) -> Int {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return 0 }
        let s = allSeries[panel.seriesIndex]
        switch panel.panelMode {
        case .mprAxial:
            return volumeCacheGet(s.id)?.depth ?? 0
        case .mprSagittal:
            return volumeCacheGet(s.id)?.width ?? 0
        case .mprCoronal:
            return volumeCacheGet(s.id)?.height ?? 0
        case .volume3D:
            return 0
        }
    }

    /// Get current slice index for panel mode (for scroller)
    func currentSliceIndex(for panel: PanelState) -> Int {
        switch panel.panelMode {
        case .mprAxial, .mprSagittal, .mprCoronal:
            return panel.mprSliceIndex
        case .volume3D:
            return 0
        }
    }

    /// Navigate to a specific slice index in any mode (for scroller drag)
    func navigatePanelToSlice(_ panel: PanelState, index: Int) {
        switch panel.panelMode {
        case .mprAxial, .mprSagittal, .mprCoronal:
            let total = totalSliceCount(for: panel)
            let idx = max(0, min(index, total - 1))
            if idx != panel.mprSliceIndex {
                panel.mprSliceIndex = idx
                if let seriesID = allSeries[safe: panel.seriesIndex]?.id,
                   let vol = volumeCacheGet(seriesID) {
                    updateMPRSpatialMetadata(panel, volume: vol)
                }
                loadMPRSlice(for: panel)
            }
        case .volume3D:
            return
        }
        handleCrossPanelScroll(for: panel)
    }

    /// Whether a series supports MPR/3D rendering, i.e. a volume with depth is
    /// available. NIfTI registers one volume per dataset via
    /// `registerStandaloneVolume`, so this is simply a cache lookup.
    func isSeriesVolumetric(seriesIndex: Int) -> Bool {
        guard seriesIndex >= 0, seriesIndex < allSeries.count else { return false }
        guard let volume = volumeCacheGet(allSeries[seriesIndex].id) else { return false }
        return volume.depth > 1
    }

    /// The cached volume for a series index, if present (synchronous lookup).
    /// Lets NIfTI seeding read a volume's calibration without the async
    /// `getVolume` path. (`volumeCacheGet` itself is file-private.)
    func cachedVolume(forSeriesIndex idx: Int) -> VolumeData? {
        guard idx >= 0, idx < allSeries.count else { return nil }
        return volumeCacheGet(allSeries[idx].id)
    }

    // MARK: - Volume Building & MPR

    /// Get or build a volume for the given series (returns cached if available)
    func getVolume(for seriesIndex: Int, completion: @escaping (VolumeData?, String?) -> Void) {
        guard seriesIndex >= 0, seriesIndex < allSeries.count else {
            completion(nil, nil)
            return
        }
        let series = allSeries[seriesIndex]

        // Return cached volume
        if let cached = volumeCacheGet(series.id) {
            completion(cached, nil)
            return
        }

        // NIfTI volumes are always pre-registered via registerStandaloneVolume,
        // so a miss here means the volume simply isn't available.
        completion(nil, "Volume not available")
    }

    /// Load an MPR slice for a panel (axial / sagittal / coronal reformat).
    ///
    /// The heavy work — slice extraction (a cache-hostile gather for sagittal /
    /// coronal), the per-pixel W/L render, and the NSImage allocation — runs on
    /// the panel's serial background queue, NOT the main thread. For a large
    /// volume (e.g. the 344×1024×1024 MPRAGE, whose long plane is a full
    /// 1024×1024 megapixel) doing this synchronously per scroll tick froze the
    /// UI. Renders are coalesced: each navigation cancels queued renders, and a
    /// finished render is dropped if the panel has since moved to another slice
    /// or mode — so fast scrubbing only pays for the in-flight render plus the
    /// latest target, and the main thread never blocks. The previously displayed
    /// slice stays on screen until the new one is ready (no spinner flicker).
    func loadMPRSlice(for panel: PanelState) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
        panel.isLoading = true
        panel.errorMessage = nil

        getVolume(for: panel.seriesIndex) { [weak self, weak panel] volume, errorMsg in
            guard let self = self, let panel = panel else { return }

            guard let volume = volume else {
                panel.isLoading = false
                if self.isScanning {
                    panel.errorMessage = "Volume build failed — directory is still scanning. Please wait for scanning to complete and try again."
                } else {
                    panel.errorMessage = "Volume build failed — \(errorMsg ?? "unknown error")"
                }
                return
            }

            // --- main thread: cheap setup only (pick & clamp index, capture params) ---
            panel.rescaleSlope = volume.rescaleSlope
            panel.rescaleIntercept = volume.rescaleIntercept

            let mode = panel.panelMode
            let maxIndex: Int
            switch mode {
            case .mprAxial:    maxIndex = volume.depth - 1
            case .mprSagittal: maxIndex = volume.width - 1
            case .mprCoronal:  maxIndex = volume.height - 1
            default:
                panel.isLoading = false
                return
            }
            // Center on first show (index not yet set).
            if panel.mprSliceIndex <= 0 || panel.mprSliceIndex > maxIndex {
                panel.mprSliceIndex = (maxIndex + 1) / 2
            }
            let targetIndex = min(max(0, panel.mprSliceIndex), maxIndex)

            // W/L: panel value, else the seeded initial, else a generic fallback.
            let ww = panel.windowWidth > 0 ? panel.windowWidth : (panel.initialWindowWidth > 0 ? panel.initialWindowWidth : 2000)
            let wc = panel.windowWidth > 0 ? panel.windowCenter : (panel.initialWindowWidth > 0 ? panel.initialWindowCenter : 500)
            let invert = panel.isInverted

            // Mask overlay (segmentation seam): captured on the main thread.
            // `engine.maskSlice` returns nil unless the volume carries a labelMask,
            // so renderSlice stays on the grayscale path in normal runs.
            let maskColor = self.maskOverlayColor
            let maskAlpha = self.maskOverlayAlpha
            // Per-label calcification colors, or nil to use the legacy flat mask.
            // When segmentation is active this is non-nil (possibly empty) so the
            // labelMask renders as a per-label ATLAS — a HIDDEN region is absent
            // from the table and draws nothing. (Routing it through the flat path
            // would paint EVERY label one color, defeating the visibility toggle.)
            let segAtlasColors = self.segmentationAtlasColors()
            // Nothing to composite when every region is hidden (empty atlas) → keep
            // the grayscale fast path. nil (no segmentation) leaves the flat Phase-7
            // demo mask gated only by showMaskOverlay.
            let showMask = self.showMaskOverlay && (segAtlasColors?.isEmpty != true)
            let segRevision = self.segmentationRevision
            let layerSnapshot = self.layerStore.renderSnapshot()

            // --- background: extract + render; coalesce via cancel + staleness check ---
            panel.loadingQueue.cancelAllOperations()
            let op = BlockOperation()
            op.addExecutionBlock { [weak op, weak panel] in
                guard let op = op, !op.isCancelled, let panel = panel else { return }
                BenchmarkLogger.shared.start("mpr_render")
                // Strong `volume` capture keeps the buffer alive through the render
                // even if a 4D timepoint switch replaces the cached volume meanwhile.
                let engine = MPREngine(volume: volume)
                let slice: MPRSlice?
                switch mode {
                case .mprAxial:    slice = engine.axialSlice(at: targetIndex)
                case .mprSagittal: slice = engine.sagittalSlice(at: targetIndex)
                case .mprCoronal:  slice = engine.coronalSlice(at: targetIndex)
                default:           slice = nil
                }
                let maskSlice = showMask ? engine.maskSlice(mode: mode, sliceIndex: targetIndex) : nil
                let layerSlices = layerSnapshot.layers.compactMap {
                    engine.layerSlice($0, mode: mode, sliceIndex: targetIndex)
                }
                guard !op.isCancelled,
                      let mprSlice = slice,
                      let image = MPREngine.renderSlice(mprSlice, ww: ww, wc: wc, invert: invert,
                                                        mask: maskSlice, maskColor: maskColor, maskAlpha: maskAlpha,
                                                        maskAtlasColors: segAtlasColors,
                                                        layers: layerSlices) else {
                    DispatchQueue.main.async { panel.isLoading = false }
                    return
                }
                BenchmarkLogger.shared.stop("mpr_render", detail: "\(mode.rawValue) \(mprSlice.width)x\(mprSlice.height)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Drop stale results: a newer scroll target or mode switch wins.
                    guard panel.panelMode == mode, panel.mprSliceIndex == targetIndex,
                          self.layerStore.revision == layerSnapshot.revision,
                          self.segmentationRevision == segRevision else {
                        panel.isLoading = false
                        return
                    }
                    panel.setDisplayImage(image)
                    panel.imageWidth = mprSlice.width
                    panel.imageHeight = mprSlice.height
                    panel.rawPixelData = mprSlice.pixelData
                    panel.bitDepth = 16
                    panel.isSigned = true
                    panel.samples = 1

                    // Spatial metadata straight from the rendered slice, so cross-
                    // reference lines + orientation labels match the displayed pixels.
                    panel.imagePositionPatient = (mprSlice.planeOrigin.x, mprSlice.planeOrigin.y, mprSlice.planeOrigin.z)
                    panel.imageOrientationPatient = [
                        mprSlice.planeRowDir.x, mprSlice.planeRowDir.y, mprSlice.planeRowDir.z,
                        mprSlice.planeColDir.x, mprSlice.planeColDir.y, mprSlice.planeColDir.z
                    ]
                    // PanelState.pixelSpacing is (row-step mm, col-step mm) per the
                    // cross-reference convention → (colDir spacing, rowDir spacing).
                    panel.pixelSpacing = (mprSlice.pixelSpacingY, mprSlice.pixelSpacingX)

                    panel.isLoading = false
                    // The panel @Published writes above already re-render this
                    // panel's view AND its crosshair overlay (overlays observe the
                    // panel + the decoupled CrosshairState, not the model). The
                    // old model-wide objectWillChange.send() here re-laid-out the
                    // ENTIRE quad on every settled render — a per-relocation hitch
                    // during a crosshair drag — and is now redundant.
                    self.updatePanelInfoStrings(panel)
                }
            }
            panel.loadingQueue.addOperation(op)
        }
    }

    /// Re-render only orthogonal MPR panels. Layer state itself lives outside
    /// ViewerModel, so this method doesn't publish a model-wide change.
    func refreshLayerRendering() {
        for panel in panels {
            switch panel.panelMode {
            case .mprAxial, .mprSagittal, .mprCoronal:
                if panel.seriesIndex == niftiSeriesIndex { loadMPRSlice(for: panel) }
            case .volume3D:
                break
            }
        }
    }

    /// Update spatial metadata synchronously for MPR panels (for cross-reference
    /// lines), before async MPR rendering. Uses the same MPREngine.planeGeometry
    /// source as the rendered slice so the two never diverge.
    private func updateMPRSpatialMetadata(_ panel: PanelState, volume: VolumeData) {
        guard let g = MPREngine(volume: volume).planeGeometry(panel.panelMode, sliceIndex: panel.mprSliceIndex) else { return }
        panel.imagePositionPatient = (g.origin.x, g.origin.y, g.origin.z)
        panel.imageOrientationPatient = [
            g.rowDir.x, g.rowDir.y, g.rowDir.z,
            g.colDir.x, g.colDir.y, g.colDir.z
        ]
        panel.pixelSpacing = (g.pixelSpacingY, g.pixelSpacingX)
    }

    /// Navigate MPR slice position for a panel
    func navigateMPRPanel(_ panel: PanelState, delta: Int) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }

        let series = allSeries[panel.seriesIndex]
        if let volume = volumeCacheGet(series.id) {
            let maxIndex: Int
            switch panel.panelMode {
            case .mprAxial: maxIndex = volume.depth - 1
            case .mprSagittal: maxIndex = volume.width - 1
            case .mprCoronal: maxIndex = volume.height - 1
            default: return
            }

            let newIndex = min(max(0, panel.mprSliceIndex + delta), maxIndex)
            if newIndex != panel.mprSliceIndex {
                panel.mprSliceIndex = newIndex
                updateMPRSpatialMetadata(panel, volume: volume)
                loadMPRSlice(for: panel)
            }
        }
    }

    /// Switch a panel's display mode (orthogonal MPR / 3D volume).
    func setPanelMode(_ panel: PanelState, mode: PanelMode) {
        panel.panelMode = mode

        // Prevent an older render from overwriting the newly selected mode.
        panel.loadingQueue.cancelAllOperations()

        switch mode {
        case .mprAxial, .mprSagittal, .mprCoronal:
            panel.mprSliceIndex = 0  // Reset; loadMPRSlice will center after volume is ready
            loadMPRSlice(for: panel)

        case .volume3D:
            loadVolumeRendering(for: panel)
        }
    }

    /// Rotate the 3D camera and enqueue a coalesced preview or final render.
    func rotateVolumeRendering(_ panel: PanelState, deltaYaw: Double, deltaPitch: Double,
                               interactive: Bool) {
        guard panel.panelMode == .volume3D else { return }
        panel.volumeYawDegrees = normalizedCameraAngle(panel.volumeYawDegrees + deltaYaw)
        panel.volumePitchDegrees = normalizedCameraAngle(panel.volumePitchDegrees + deltaPitch)
        updatePanelInfoStrings(panel)
        loadVolumeRendering(for: panel, interactive: interactive)
    }

    private func normalizedCameraAngle(_ degrees: Double) -> Double {
        var normalized = degrees.truncatingRemainder(dividingBy: 360)
        if normalized > 180 { normalized -= 360 }
        if normalized <= -180 { normalized += 360 }
        return normalized
    }

    func resetVolumeCamera(_ panel: PanelState) {
        guard panel.panelMode == .volume3D else { return }
        panel.volumeYawDegrees = -25
        panel.volumePitchDegrees = 18
        panel.volumeOpacity = 1.0
        loadVolumeRendering(for: panel)
    }

    /// Render the 3D brain with direct volume ray marching. GPU wait/readback and
    /// NSImage construction stay on the panel's serial background queue. Rapid
    /// camera/W-L changes cancel queued work and the revision guard drops any
    /// in-flight stale result. Interactive rotations use a smaller preview; the
    /// mouse-up render restores full quality.
    func loadVolumeRendering(for panel: PanelState, interactive: Bool = false) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
        panel.isLoading = true
        panel.errorMessage = nil
        panel.volumeRenderRevision &+= 1
        let revision = panel.volumeRenderRevision

        getVolume(for: panel.seriesIndex) { [weak self, weak panel] volume, errorMessage in
            guard let self, let panel else { return }
            guard let volume else {
                panel.isLoading = false
                panel.errorMessage = "Volume unavailable — \(errorMessage ?? "unknown error")"
                return
            }

            let ww = panel.windowWidth > 0
                ? panel.windowWidth
                : (panel.initialWindowWidth > 0 ? panel.initialWindowWidth : 2000)
            let wc = panel.windowWidth > 0
                ? panel.windowCenter
                : (panel.initialWindowWidth > 0 ? panel.initialWindowCenter : 500)
            let yaw = panel.volumeYawDegrees
            let pitch = panel.volumePitchDegrees
            let opacity = panel.volumeOpacity
            // 192² sustains a measured 60 Hz preview on the 344×1024×1024
            // MPRAGE (p95 ~9.5 ms); 320² only just sustained 30 Hz (~32.8 ms).
            // Mouse-up still settles to the full 512² image.
            let resolution = interactive ? 192 : 512
            let renderer = self.metalRenderer

            panel.loadingQueue.cancelAllOperations()
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak operation, weak panel] in
                guard let operation, !operation.isCancelled, let panel else { return }

                BenchmarkLogger.shared.start("volume_render")
                let camera = MetalVolumeRenderer.cameraToVolumeMatrix(
                    yawDegrees: Float(yaw), pitchDegrees: Float(pitch)
                )
                let image = renderer?.renderVolume(
                    volume: volume,
                    cameraToVolume: camera,
                    outputWidth: resolution,
                    outputHeight: resolution,
                    windowWidth: Float(ww),
                    windowCenter: Float(wc),
                    opacity: Float(opacity),
                    // PanelInteractiveImageView applies inversion as a display
                    // filter, so keep the generated volume image uninverted.
                    invert: false
                )
                BenchmarkLogger.shared.stop(
                    "volume_render",
                    detail: "\(resolution)x\(resolution) yaw=\(Int(yaw)) pitch=\(Int(pitch))"
                )
                guard !operation.isCancelled else { return }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard panel.panelMode == .volume3D,
                          panel.volumeRenderRevision == revision else { return }
                    guard let image else {
                        panel.isLoading = false
                        panel.errorMessage = "3D volume rendering failed — Metal is unavailable"
                        return
                    }

                    panel.setDisplayImage(image)
                    panel.imageWidth = resolution
                    panel.imageHeight = resolution
                    panel.rawPixelData = nil
                    panel.bitDepth = 16
                    panel.isSigned = true
                    panel.samples = 1
                    panel.pixelSpacing = nil
                    panel.imagePositionPatient = nil
                    panel.imageOrientationPatient = nil
                    panel.showCursorInfo = false
                    panel.hasCursorPatientPosition = false
                    panel.isLoading = false
                    self.updatePanelInfoStrings(panel)
                }
            }
            panel.loadingQueue.addOperation(operation)
        }
    }

    // MARK: - Multi-Frame / Cine Playback
}

// Force update
