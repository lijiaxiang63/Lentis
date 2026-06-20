// ViewerModel.swift
// OpenDicomViewer
//
// Central model for the DICOM viewer. This is the largest file in the project
// and serves as the single source of truth for all viewer state.
//
// Responsibilities:
//   - Directory scanning with incremental UI updates (background thread)
//   - Series/image loading with multi-level caching (memory + disk)
//   - Multi-panel management: create, resize, assign series, navigate
//   - Window/level computation (auto, ROI-based, histogram generation)
//   - MPR volume building and slice extraction
//   - MIP rendering (CPU fallback + Metal GPU path)
//   - Synchronized scrolling with spatial z-location matching
//   - Series thumbnail generation
//   - DICOM tag extraction and panel info string formatting
//
// Threading model:
//   - Directory scanning runs on a background DispatchQueue
//   - Image loading uses an OperationQueue (serial, for cancellation)
//   - All @Published state updates dispatch to MainActor
//   - Volume building runs on a dedicated background queue
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import Combine
import AppKit
import simd
import UniformTypeIdentifiers

// MARK: - Data Structures
struct ImageContext: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let seriesUID: String
    let seriesDescription: String
    let instanceNumber: Int
    let seriesNumber: Int
    let zLocation: Double?

    // Spatial metadata for 3D/MPR/cross-reference
    let imagePosition: SIMD3<Double>?         // Full ImagePositionPatient (x,y,z)
    let imageOrientation: [Double]?           // 6 direction cosines from ImageOrientationPatient
    let pixelSpacing: SIMD2<Double>?          // Row, Column spacing in mm
    let sliceThickness: Double?               // (0018,0050)
    let spacingBetweenSlices: Double?          // (0018,0088)
    let frameOfReferenceUID: String?          // (0020,0052) - gates cross-referencing
    let studyInstanceUID: String?             // (0020,000D)
    let numberOfFrames: Int                   // (0028,0008) - 1 for single frame

    static func == (lhs: ImageContext, rhs: ImageContext) -> Bool {
        return lhs.url == rhs.url
    }

    /// Single-frame files group by SeriesInstanceUID; multi-frame files get a
    /// per-file key so each cine becomes its own sidebar series.
    var seriesGroupingKey: String {
        numberOfFrames > 1 ? "\(seriesUID)#mf#\(url.path)" : seriesUID
    }

    func displaySeriesDescription(baseDescription: String) -> String {
        guard numberOfFrames > 1 else { return baseDescription }
        let name = url.deletingPathExtension().lastPathComponent
        return "\(baseDescription) — \(name) (\(numberOfFrames)f)"
    }
}

struct ImageSeries: Identifiable, Equatable {
    let id: String // SeriesUID
    let seriesNumber: Int
    let seriesDescription: String
    var images: [ImageContext]

    /// Computed: dominant axis of this series (axial/sagittal/coronal) based on ImageOrientationPatient
    var dominantAxis: SliceAxis? {
        guard let orient = images.first?.imageOrientation, orient.count == 6 else { return nil }
        // The slice normal = cross product of row and column direction cosines
        let rowDir = SIMD3<Double>(orient[0], orient[1], orient[2])
        let colDir = SIMD3<Double>(orient[3], orient[4], orient[5])
        let normal = cross(rowDir, colDir)

        let absX = abs(normal.x)
        let absY = abs(normal.y)
        let absZ = abs(normal.z)

        if absZ >= absX && absZ >= absY { return .axial }
        if absY >= absX && absY >= absZ { return .coronal }
        return .sagittal
    }
}

enum SliceAxis: String, CaseIterable {
    case axial, sagittal, coronal
}

// SIMD3 cross product helper
func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    return SIMD3<Double>(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
    )
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
    @Published var panels: [PanelState] = []
    @Published var activePanelID: UUID = UUID()
    @Published var showCrossReference: Bool = false
    /// Shared 3D crosshair world coordinate (RAS mm). Set by click/drag in any
    /// MPR panel (Phase 6); all panels relocate to contain it and draw crosshair
    /// lines through its in-plane projection. nil = no crosshair placed yet.
    @Published var crosshairWorld: SIMD3<Double>? = nil
    @Published var showHelp: Bool = false
    @Published var synchronizedScrolling: Bool = false {
        didSet {
            guard synchronizedScrolling, let source = activePanel else { return }

            // If single-panel, auto-expand to 2-panel and assign a same-axis series
            if layout == .single && allSeries.count > 1 {
                let sourceIdx = source.seriesIndex
                let sourceAxis = sourceIdx >= 0 && sourceIdx < allSeries.count
                    ? allSeries[sourceIdx].dominantAxis : nil

                // Find a different series with the same dominant axis (or just the next series)
                var bestIdx: Int? = nil
                for (i, s) in allSeries.enumerated() where i != sourceIdx {
                    if sourceAxis != nil && s.dominantAxis == sourceAxis {
                        bestIdx = i
                        break
                    }
                }
                // Fallback: just pick the next available series
                if bestIdx == nil {
                    bestIdx = allSeries.indices.first(where: { $0 != sourceIdx })
                }

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

    /// Toggle fullscreen for a panel (double-click behavior)
    func toggleFullscreen(for panel: PanelState) {
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

    /// Register a pre-built volume (e.g. from a NIfTI file) under `cacheKey` so
    /// panels can display it without any DICOM files. Returns the series index.
    @discardableResult
    func registerStandaloneVolume(_ volume: VolumeData, cacheKey: String, description: String) -> Int {
        volumeCacheSet(cacheKey, volume)
        if let existing = allSeries.firstIndex(where: { $0.id == cacheKey }) {
            return existing
        }
        let series = ImageSeries(id: cacheKey, seriesNumber: allSeries.count + 1,
                                 seriesDescription: description, images: [])
        allSeries.append(series)
        return allSeries.count - 1
    }
    @Published var isVolumeBuildingInProgress: Bool = false
    @Published var volumeBuildProgress: Double = 0.0
    /// GPU renderer for MIP and volume rendering (lazy init)
    lazy var metalRenderer: MetalVolumeRenderer? = MetalVolumeRenderer()


    // Shift-key state for group selection overlay
    @Published var isShiftHeld: Bool = false
    private var flagsMonitor: Any?

    // MARK: - Initialization
    init() {
        let firstPanel = PanelState()
        self.panels = [firstPanel]
        self.activePanelID = firstPanel.id

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

    /// Show an Open panel and load the selected DICOM file or folder.
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a NIfTI file (.nii or .nii.gz)"
        var types: [UTType] = []
        for ext in ["nii", "gz"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func load(url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }

        BenchmarkLogger.shared.start("load_total")
        BenchmarkLogger.shared.log(event: "load_start", dataset: url.lastPathComponent, detail: url.path)

        // NIfTI files bypass the DICOM directory-scan path entirely.
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
                self.resetAllPanels()
                self.loadNifti(url: url)
            }
            return
        }

        DispatchQueue.main.async {
            self.errorMessage = "Unsupported file type. Lentis opens NIfTI (.nii / .nii.gz) files."
        }
    }



    // MARK: - Image Loading

    // ...

    // MARK: - Python/External Logic (REPLACED)

    // Legacy fallbackToExternalConverter removed

    
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
    
    // Track currently caching series to avoid redundant cancellations
    private var currentCachingSeriesUID: String? = nil

    // MARK: - Caching Logic
    
    // Synchronous version of fallbackToExternalConverter for background queue usage
    // Legacy runExternalConverterSynchronous removed


    // MARK: - Directory
    
    // MARK: - Navigation helpers
    
    // MARK: - Info Update

    // MARK: - Legacy-to-Panel Sync

    /// Assign a series to a specific panel and load its first image
    func assignSeriesToPanel(_ panel: PanelState, seriesIndex: Int) {
        guard seriesIndex >= 0, seriesIndex < allSeries.count else { return }
        panel.seriesIndex = seriesIndex
        panel.imageIndex = 0

        // Seed modality-aware W/L (CT preset / MRI percentile, or a saved manual
        // window) so MPR/MIP panels don't fall back to loadMPRSlice's generic
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
                if synchronizedScrolling { syncScrollFromPanel(panel) }
                return
            }
        }
        navigatePanelByOffsetDirect(panel, offset: offset)
        if synchronizedScrolling { syncScrollFromPanel(panel) }
    }

    private func navigatePanelByOffsetDirect(_ panel: PanelState, offset: Int) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
        if panel.panelMode.isMPR {
            navigateMPRPanel(panel, delta: offset)
        } else if panel.panelMode == .mip {
            navigatePanelToSlice(panel, index: panel.mipSlabPosition + offset)
        }
    }

    /// Navigate panel to first or last image
    func navigatePanelToEdge(_ panel: PanelState, toFirst: Bool) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
        let total = totalSliceCount(for: panel)
        navigatePanelToSlice(panel, index: toFirst ? 0 : total - 1)
    }

    /// Reset view: zoom/pan to default and auto W/L
    func resetViewForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        panel.scale = 1.0
        panel.translation = .zero
        autoWindowLevelForPanel(panel)
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
        panel.rotationSteps = (panel.rotationSteps + 1) % 4
    }

    /// Rotate image 90° counter-clockwise
    func rotateCounterClockwiseForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        panel.rotationSteps = (panel.rotationSteps + 3) % 4
    }

    /// Flip image horizontally
    func flipHorizontalForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        panel.isFlippedH.toggle()
    }

    /// Flip image vertically
    func flipVerticalForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
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

    /// One-click MPR layout: switches to 2x2 and configures panels as Axial + Sagittal + Coronal + MIP.
    /// Uses the active panel's series (or first available series) for all four panels.
    func setupMPRLayout() {
        setLayout(.quad)

        // Determine series to use (active panel's series or first available)
        let seriesIdx: Int
        if let active = activePanel, active.seriesIndex >= 0 {
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

        // Panel 3: MIP
        assignSeriesToPanel(panels[3], seriesIndex: seriesIdx)
        setPanelMode(panels[3], mode: .mip)

        // Set active panel to axial
        activePanelID = panels[0].id
        synchronizedScrolling = true
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
        // navigate + sync-scroll of the others). With async MPR + MIP this should be
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
                if synchronizedScrolling {
                    syncScrollFromPanel(panel)
                }
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

        if panel.panelMode == .mip {
            if let seriesID = allSeries[safe: panel.seriesIndex]?.id,
               let vol = volumeCacheGet(seriesID) {
                switch direction {
                case .nextImage:
                    if panel.mipSlabPosition < vol.depth - 1 {
                        panel.mipSlabPosition += 1
                        loadMIPForPanel(panel)
                    }
                case .prevImage:
                    if panel.mipSlabPosition > 0 {
                        panel.mipSlabPosition -= 1
                        loadMIPForPanel(panel)
                    }
                default: break
                }
            }
        }
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
                if synchronizedScrolling { syncScrollFromPanel(panel) }
                return
            }
        }

        // MIP mode: scroll moves slab position through volume
        if panel.panelMode == .mip {
            if let seriesID = allSeries[safe: panel.seriesIndex]?.id,
               let vol = volumeCacheGet(seriesID) {
                switch direction {
                case .nextImage:
                    if panel.mipSlabPosition < vol.depth - 1 {
                        panel.mipSlabPosition += 1
                        loadMIPForPanel(panel)
                    }
                case .prevImage:
                    if panel.mipSlabPosition > 0 {
                        panel.mipSlabPosition -= 1
                        loadMIPForPanel(panel)
                    }
                case .nextSeries, .prevSeries: break
                }
            }
            if direction == .nextSeries || direction == .prevSeries {
            } else {
                if synchronizedScrolling { syncScrollFromPanel(panel) }
                return
            }
        }

        // Series switching (NIfTI is usually a single series, so typically a no-op).
        switch direction {
        case .nextImage, .prevImage:
            break  // handled above for MPR/MIP
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
    /// click/drag in `source`. Every *other* panel relocates so its slice (or
    /// MIP slab) passes through the point, reusing the async + coalesced MPR/MIP
    /// render path (so drag spam costs no more than fast scrolling). The source
    /// panel isn't moved: the click was on its displayed slice, so the point is
    /// already on its plane. All panels redraw their crosshair lines because the
    /// overlay observes `crosshairWorld` (@Published).
    ///
    /// This is the true 3D cross-panel link that replaces the old z-only
    /// `syncScrollFromPanel` proportional mapping: orthogonal planes correctly
    /// stay put unless the in-plane click actually moved their slice index.
    func setCrosshair(_ world: SIMD3<Double>, from source: PanelState) {
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
                    panel.mprSliceIndex = idx
                    updateMPRSpatialMetadata(panel, volume: vol)
                    loadMPRSlice(for: panel)
                }
            case .mip:
                // MIP is an axial slab; track the crosshair's superior (z) level.
                guard vol.depth > 1 else { continue }
                let z = min(max(0, Int(vol.worldToVoxel(world).z.rounded())), vol.depth - 1)
                if z != panel.mipSlabPosition {
                    panel.mipSlabPosition = z
                    loadMIPForPanel(panel)
                }
            case .slice2D:
                continue
            }
        }
    }

    /// Synchronized scrolling: when one panel scrolls, sync others to the same spatial position.
    /// Uses z-location matching when available, falls back to proportional matching.
    private func syncScrollFromPanel(_ source: PanelState) {
        guard source.seriesIndex >= 0, source.seriesIndex < allSeries.count else { return }
        let sourceSeries = allSeries[source.seriesIndex]

        // Determine the source z-location for spatial matching
        let sourceZ: Double? = {
            switch source.panelMode {
            case .slice2D:
                guard source.imageIndex >= 0, source.imageIndex < sourceSeries.images.count else { return nil }
                return sourceSeries.images[source.imageIndex].zLocation
            case .mprAxial, .mprSagittal, .mprCoronal, .mip:
                // For MPR/MIP, use imagePositionPatient z if available
                return source.imagePositionPatient?.2
            }
        }()

        for panel in panels where panel.id != source.id {
            guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { continue }
            let targetSeries = allSeries[panel.seriesIndex]

            switch panel.panelMode {
            case .slice2D:
                continue  // 2D DICOM path removed; NIFTI uses MPR/MIP
            case .mip:
                if let vol = volumeCacheGet(targetSeries.id), vol.depth > 1 {
                    let targetIdx = closestVolumeIndex(dimension: vol.depth, targetSeries: targetSeries, sourceZ: sourceZ, fallbackSource: source, sourceSeries: sourceSeries)
                    if targetIdx != panel.mipSlabPosition {
                        panel.mipSlabPosition = targetIdx
                        loadMIPForPanel(panel)
                    }
                }
            case .mprAxial:
                if let vol = volumeCacheGet(targetSeries.id), vol.depth > 1 {
                    let targetIdx = closestVolumeIndex(dimension: vol.depth, targetSeries: targetSeries, sourceZ: sourceZ, fallbackSource: source, sourceSeries: sourceSeries)
                    if targetIdx != panel.mprSliceIndex {
                        panel.mprSliceIndex = targetIdx
                        updateMPRSpatialMetadata(panel, volume: vol)
                        loadMPRSlice(for: panel)
                    }
                }
            case .mprSagittal:
                if let vol = volumeCacheGet(targetSeries.id), vol.width > 1 {
                    let targetIdx = closestVolumeIndex(dimension: vol.width, targetSeries: targetSeries, sourceZ: sourceZ, fallbackSource: source, sourceSeries: sourceSeries)
                    if targetIdx != panel.mprSliceIndex {
                        panel.mprSliceIndex = targetIdx
                        updateMPRSpatialMetadata(panel, volume: vol)
                        loadMPRSlice(for: panel)
                    }
                }
            case .mprCoronal:
                if let vol = volumeCacheGet(targetSeries.id), vol.height > 1 {
                    let targetIdx = closestVolumeIndex(dimension: vol.height, targetSeries: targetSeries, sourceZ: sourceZ, fallbackSource: source, sourceSeries: sourceSeries)
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

    /// Find the closest volume slice index for MPR/MIP targets using spatial or proportional matching.
    private func closestVolumeIndex(dimension: Int, targetSeries: ImageSeries, sourceZ: Double?, fallbackSource source: PanelState, sourceSeries: ImageSeries) -> Int {
        guard dimension > 1 else { return 0 }

        // Spatial matching using target series z-range
        if let z = sourceZ {
            let zValues = targetSeries.images.compactMap { $0.zLocation }
            if zValues.count >= 2 {
                let minZ = zValues.min()!
                let maxZ = zValues.max()!
                let range = maxZ - minZ
                if range > 0 {
                    let fraction = (z - minZ) / range
                    return max(0, min(dimension - 1, Int(fraction * Double(dimension - 1))))
                }
            }
        }

        // Fallback: proportional
        let sourceTotal = sourceSeries.images.count
        guard sourceTotal > 1 else { return 0 }
        let pct = Double(source.imageIndex) / Double(sourceTotal - 1)
        return max(0, min(dimension - 1, Int(pct * Double(dimension - 1))))
    }

    /// Set a panel's absolute W/L (stored units) and re-render. Routes through
    /// `adjustWindowLevelForPanel`, so it reuses the MPR/MIP re-render path and
    /// persists to seriesStates. Used by preset / auto / modality-toggle seeding.
    func setPanelWindow(_ panel: PanelState, ww: Double, wc: Double) {
        adjustWindowLevelForPanel(panel,
                                  deltaWidth: ww - panel.windowWidth,
                                  deltaCenter: wc - panel.windowCenter)
    }

    /// Adjust W/L for a specific panel
    func adjustWindowLevelForPanel(_ panel: PanelState, deltaWidth: Double, deltaCenter: Double) {
        panel.windowWidth = max(1.0, panel.windowWidth + deltaWidth)
        panel.windowCenter += deltaCenter

        // Persist to seriesStates so precaching & other images use the same W/L
        if panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count {
            let uid = allSeries[panel.seriesIndex].id
            var state = seriesStates[uid] ?? SeriesViewState()
            state.windowWidth = panel.windowWidth
            state.windowCenter = panel.windowCenter
            seriesStates[uid] = state
        }

        switch panel.panelMode {
        case .slice2D:
            break  // 2D DICOM slice path removed; NIFTI uses MPR/MIP
        case .mprAxial, .mprSagittal, .mprCoronal, .mip:
            // Re-render MPR/MIP slice with updated W/L
            if panel.panelMode == .mip, panel.rawPixelData == nil,
               let renderer = self.metalRenderer,
               let seriesID = allSeries[safe: panel.seriesIndex]?.id,
               let volume = volumeCacheGet(seriesID) {
                // GPU re-render with updated W/L (volume already on GPU)
                let slabMM = Float(panel.mipSlabThickness) * Float(volume.spacingZ)
                let center = SIMD3<Float>(Float(volume.width) / 2.0, Float(volume.height) / 2.0, Float(panel.mipSlabPosition))
                if let newImg = renderer.renderProjection(
                    volume: volume, mode: .mip,
                    viewMatrix: matrix_identity_float4x4,
                    outputWidth: volume.width, outputHeight: volume.height,
                    windowWidth: Float(panel.windowWidth), windowCenter: Float(panel.windowCenter),
                    slabThickness: slabMM, slabCenterVoxel: center, invert: panel.isInverted
                ) {
                    let physW = Double(volume.width) * volume.spacingX
                    let physH = Double(volume.height) * volume.spacingY
                    newImg.size = NSSize(width: CGFloat(volume.width), height: CGFloat(Double(volume.width) * physH / physW))
                    panel.setDisplayImage(newImg)
                }
            } else if let data = panel.rawPixelData {
                // CPU fallback: re-render from raw pixel data
                // panel.pixelSpacing stores (row_spacing, col_spacing) per DICOM convention,
                // but MPRSlice expects (horizontal=X, vertical=Y), so swap .0↔.1
                let slice = MPRSlice(
                    pixelData: data, width: panel.imageWidth, height: panel.imageHeight,
                    planeOrigin: .zero,
                    planeRowDir: SIMD3<Double>(1, 0, 0),
                    planeColDir: SIMD3<Double>(0, 1, 0),
                    pixelSpacingX: panel.pixelSpacing?.1 ?? 1,
                    pixelSpacingY: panel.pixelSpacing?.0 ?? 1
                )
                if let newImg = MPREngine.renderSlice(slice, ww: panel.windowWidth, wc: panel.windowCenter, invert: panel.isInverted) {
                    panel.setDisplayImage(newImg)
                }
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
        panel.currentSeriesInfo = "Series \(panel.seriesIndex + 1)/\(allSeries.count)"

        switch panel.panelMode {
        case .slice2D:
            if panel.isMultiFrame && panel.numberOfFrames > 1 {
                panel.currentImageInfo = "Frame \(panel.currentFrameIndex + 1)/\(panel.numberOfFrames)"
            } else if panel.imageIndex >= 0, panel.imageIndex < s.images.count {
                let img = s.images[panel.imageIndex]
                panel.currentImageInfo = "Image \(img.instanceNumber) (\(panel.imageIndex + 1)/\(s.images.count))"
            }
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
        case .mip:
            if let vol = volumeCacheGet(s.id) {
                let halfSlab = panel.mipSlabThickness / 2
                let zStart = max(0, panel.mipSlabPosition - halfSlab) + 1
                let zEnd = min(vol.depth, panel.mipSlabPosition + halfSlab)
                panel.currentImageInfo = "MIP \(zStart)-\(zEnd)/\(vol.depth) (\(panel.mipSlabThickness) slices)"
            } else {
                panel.currentImageInfo = "MIP"
            }
        }
    }

    /// Get total slice count for current panel mode (for scroller)
    func totalSliceCount(for panel: PanelState) -> Int {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return 0 }
        let s = allSeries[panel.seriesIndex]
        switch panel.panelMode {
        case .slice2D:
            if panel.isMultiFrame && panel.numberOfFrames > 1 {
                return panel.numberOfFrames
            }
            return s.images.count
        case .mprAxial:
            return volumeCacheGet(s.id)?.depth ?? 0
        case .mprSagittal:
            return volumeCacheGet(s.id)?.width ?? 0
        case .mprCoronal:
            return volumeCacheGet(s.id)?.height ?? 0
        case .mip:
            guard let seriesID = allSeries[safe: panel.seriesIndex]?.id else { return 0 }
            return volumeCacheGet(seriesID)?.depth ?? 0
        }
    }

    /// Get current slice index for panel mode (for scroller)
    func currentSliceIndex(for panel: PanelState) -> Int {
        switch panel.panelMode {
        case .slice2D:
            if panel.isMultiFrame && panel.numberOfFrames > 1 {
                return panel.currentFrameIndex
            }
            return panel.imageIndex
        case .mprAxial, .mprSagittal, .mprCoronal:
            return panel.mprSliceIndex
        case .mip:
            return panel.mipSlabPosition
        }
    }

    /// Navigate to a specific slice index in any mode (for scroller drag)
    func navigatePanelToSlice(_ panel: PanelState, index: Int) {
        switch panel.panelMode {
        case .slice2D:
            break  // 2D DICOM path removed; NIFTI uses MPR/MIP
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
        case .mip:
            guard let seriesID = allSeries[safe: panel.seriesIndex]?.id,
                  let vol = volumeCacheGet(seriesID) else { return }
            let idx = max(0, min(index, vol.depth - 1))
            if idx != panel.mipSlabPosition {
                panel.mipSlabPosition = idx
                loadMIPForPanel(panel)
            }
        }
        if synchronizedScrolling { syncScrollFromPanel(panel) }
    }

    /// Whether a series supports MPR/MIP, i.e. a 3D volume with depth is
    /// available. NIfTI registers one volume per dataset via
    /// `registerStandaloneVolume`, so this is simply a cache lookup. (Replaces
    /// the old per-slice DICOM heuristic, which always failed on NIfTI's empty
    /// `images` stub.)
    func isSeriesVolumetric(seriesIndex: Int) -> Bool {
        guard seriesIndex >= 0, seriesIndex < allSeries.count else { return false }
        guard let volume = volumeCacheGet(allSeries[seriesIndex].id) else { return false }
        return volume.depth > 1
    }

    /// Total slice count of the cached volume (for slab thickness slider max)
    func volumeSliceCount(seriesIndex: Int) -> Int {
        guard seriesIndex >= 0, seriesIndex < allSeries.count else { return 1 }
        let seriesID = allSeries[seriesIndex].id
        return volumeCacheGet(seriesID)?.depth ?? 1
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

        // No cached volume. DICOM volume-building has been removed; NIFTI
        // volumes are always pre-registered via registerStandaloneVolume, so a
        // miss here means the volume simply isn't available.
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
                guard !op.isCancelled,
                      let mprSlice = slice,
                      let image = MPREngine.renderSlice(mprSlice, ww: ww, wc: wc, invert: invert) else {
                    DispatchQueue.main.async { panel.isLoading = false }
                    return
                }
                BenchmarkLogger.shared.stop("mpr_render", detail: "\(mode.rawValue) \(mprSlice.width)x\(mprSlice.height)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Drop stale results: a newer scroll target or mode switch wins.
                    guard panel.panelMode == mode, panel.mprSliceIndex == targetIndex else {
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
                    // Trigger cross-reference overlay updates on all panels.
                    self.objectWillChange.send()
                    self.updatePanelInfoStrings(panel)
                }
            }
            panel.loadingQueue.addOperation(op)
        }
    }

    /// Update spatial metadata synchronously from series image data (for cross-reference lines).
    /// Called immediately when imageIndex changes, before async image loading,
    /// so cross-reference overlays update without waiting for the loading queue.
    private func updateSpatialMetadataFromSeries(_ panel: PanelState) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
        let images = allSeries[panel.seriesIndex].images
        guard panel.imageIndex >= 0, panel.imageIndex < images.count else { return }
        let img = images[panel.imageIndex]
        if let pos = img.imagePosition {
            panel.imagePositionPatient = (pos.x, pos.y, pos.z)
        }
        panel.imageOrientationPatient = img.imageOrientation
        if let ps = img.pixelSpacing {
            panel.pixelSpacing = (ps.x, ps.y)
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

    /// Switch a panel's display mode (slice2D / sagittal / coronal / MIP)
    func setPanelMode(_ panel: PanelState, mode: PanelMode) {
        panel.panelMode = mode

        // Cancel any pending 2D loads to prevent them from overwriting MPR/MIP panel state
        panel.loadingQueue.cancelAllOperations()

        switch mode {
        case .slice2D:
            break  // 2D DICOM path removed; NIFTI uses MPR/MIP

        case .mprAxial, .mprSagittal, .mprCoronal:
            panel.mprSliceIndex = 0  // Reset; loadMPRSlice will center after volume is ready
            loadMPRSlice(for: panel)

        case .mip:
            if let seriesID = allSeries[safe: panel.seriesIndex]?.id,
               let vol = volumeCacheGet(seriesID) {
                panel.mipSlabPosition = vol.depth / 2
                panel.mipSlabThickness = min(10, vol.depth)
            }
            loadMIPForPanel(panel)
        }
    }

    /// Generate a clinical axial slab-MIP for a panel.
    /// Projects N consecutive axial slices via max intensity, scroll moves the slab.
    func loadMIPForPanel(_ panel: PanelState, mode: ProjectionMode = .mip) {
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

            // --- main thread: cheap setup only (clamp slab, capture params) ---
            if panel.mipSlabPosition <= 0 || panel.mipSlabPosition >= volume.depth {
                panel.mipSlabPosition = volume.depth / 2
            }
            if panel.mipSlabThickness < 1 { panel.mipSlabThickness = 10 }
            if panel.mipSlabThickness > volume.depth { panel.mipSlabThickness = volume.depth }

            let ww = panel.windowWidth > 0 ? panel.windowWidth : (panel.initialWindowWidth > 0 ? panel.initialWindowWidth : 2000)
            let wc = panel.windowWidth > 0 ? panel.windowCenter : (panel.initialWindowWidth > 0 ? panel.initialWindowCenter : 500)
            let invert = panel.isInverted
            let slabPosition = panel.mipSlabPosition
            let slabThickness = panel.mipSlabThickness
            let renderer = self.metalRenderer

            // --- background: GPU MIP (the waitUntilCompleted GPU sync, the readback,
            // and the NSImage build all run off the main thread) + CPU fallback.
            // Coalesced exactly like loadMPRSlice — this was the per-tick main-thread
            // block (~15–20 ms steady, ~170–290 ms on first GPU texture upload) that
            // made the quad-MPR + sync-scroll layout lag on the 721 MB MPRAGE. ---
            panel.loadingQueue.cancelAllOperations()
            let op = BlockOperation()
            op.addExecutionBlock { [weak op, weak panel] in
                guard let op = op, !op.isCancelled, let panel = panel else { return }
                let slabThicknessMM = Float(slabThickness) * Float(volume.spacingZ)
                let slabCenter = SIMD3<Float>(Float(volume.width) / 2.0, Float(volume.height) / 2.0, Float(slabPosition))

                BenchmarkLogger.shared.start("mip_render")
                var metalImage: NSImage? = nil
                if let renderer = renderer {
                    metalImage = renderer.renderProjection(
                        volume: volume, mode: mode, viewMatrix: matrix_identity_float4x4,
                        outputWidth: volume.width, outputHeight: volume.height,
                        windowWidth: Float(ww), windowCenter: Float(wc),
                        slabThickness: slabThicknessMM, slabCenterVoxel: slabCenter, invert: invert)
                }

                // Resolve the image (GPU, else CPU fallback) + raw data for W/L re-render.
                let resultImage: NSImage?
                var rawData: Data? = nil
                var imgW = volume.width, imgH = volume.height
                if let image = metalImage {
                    let physW = Double(volume.width) * volume.spacingX
                    let physH = Double(volume.height) * volume.spacingY
                    image.size = NSSize(width: CGFloat(volume.width), height: CGFloat(Double(volume.width) * physH / physW))
                    BenchmarkLogger.shared.stop("mip_render", detail: "GPU slab=\(slabThickness), mode=\(mode)")
                    resultImage = image
                } else {
                    let engine = MPREngine(volume: volume)
                    if let slice = engine.axialSlabProjection(mode: mode, slabCenter: slabPosition, slabThickness: slabThickness),
                       let image = MPREngine.renderSlice(slice, ww: ww, wc: wc, invert: invert) {
                        BenchmarkLogger.shared.stop("mip_render", detail: "CPU slab=\(slabThickness), mode=\(mode)")
                        rawData = slice.pixelData
                        imgW = slice.width; imgH = slice.height
                        resultImage = image
                    } else {
                        resultImage = nil
                    }
                }
                guard !op.isCancelled else { return }

                let origin = volume.voxelToWorld(SIMD3<Double>(0, 0, Double(slabPosition)))
                let rowDir = volume.rowDirection, colDir = volume.colDirection

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Drop stale results: a newer slab position or mode switch wins.
                    guard panel.panelMode == .mip, panel.mipSlabPosition == slabPosition else {
                        panel.isLoading = false
                        return
                    }
                    guard let image = resultImage else {
                        panel.isLoading = false
                        panel.errorMessage = "Slab MIP rendering failed"
                        return
                    }
                    panel.setDisplayImage(image)
                    panel.imageWidth = imgW
                    panel.imageHeight = imgH
                    panel.rawPixelData = rawData
                    panel.bitDepth = 16
                    panel.isSigned = true
                    panel.samples = 1
                    panel.pixelSpacing = (volume.spacingY, volume.spacingX)
                    // Spatial metadata for cross-reference (axial plane at slab center).
                    panel.imagePositionPatient = (origin.x, origin.y, origin.z)
                    panel.imageOrientationPatient = [rowDir.x, rowDir.y, rowDir.z, colDir.x, colDir.y, colDir.z]
                    panel.isLoading = false
                    self.objectWillChange.send()
                    self.updatePanelInfoStrings(panel)
                }
            }
            panel.loadingQueue.addOperation(op)
        }
    }

    // MARK: - Multi-Frame / Cine Playback
}

// Force update
