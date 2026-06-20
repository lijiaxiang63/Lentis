// ViewerModel+Nifti.swift
// Lentis
//
// NIfTI loading orchestration: reads a .nii/.nii.gz file off the main thread,
// detects modality, builds an Int16 VolumeData, and displays it as an axial
// view. 4D volumes default to the first timepoint with a selector.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

extension ViewerModel {

    /// True if the URL looks like a NIfTI file (.nii or .nii.gz).
    static func isNiftiURL(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".nii") || name.hasSuffix(".nii.gz")
    }

    /// Load a NIfTI file: parse + detect modality off the main thread, then
    /// display the first volume as an axial slice in a single panel.
    func loadNifti(url: URL) {
        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }

            do {
                let image = try NiftiImage.read(contentsOf: url)
                let seriesID = "nifti:\(url.lastPathComponent):\(UUID().uuidString)"
                let dataset = NiftiDataset(
                    image: image,
                    seriesID: seriesID,
                    displayName: url.deletingPathExtension().lastPathComponent
                )
                let volume = dataset.makeVolume(timepoint: 0)
                DispatchQueue.main.async {
                    self?.applyNiftiDataset(dataset, firstVolume: volume)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isLoading = false
                    self?.isScanning = false
                    self?.errorMessage = "Failed to open NIfTI: \(error)"
                }
            }
        }
    }

    /// Install a freshly-loaded dataset into the viewer (main thread).
    private func applyNiftiDataset(_ dataset: NiftiDataset, firstVolume volume: VolumeData) {
        niftiDataset = dataset
        currentTimepoint = 0
        modalityOverride = nil
        crosshairWorld = nil  // drop any crosshair from a previously-loaded volume

        // Cache under a stable key (the dataset id) so 4D timepoint switches
        // simply replace the cached volume without spawning new series.
        let idx = registerStandaloneVolume(volume, cacheKey: dataset.seriesID, description: dataset.displayName)
        niftiSeriesIndex = idx

        // Seed the modality default: CT → the Brain HU preset, MRI → percentile
        // auto-window. (initialWindow remains a defensive fallback.)
        let (ww, wc) = modalityDefaultWindow(forSeriesIndex: idx) ?? initialWindow(for: dataset)

        setLayout(.single)
        guard let panel = panels.first else { isLoading = false; return }
        panel.reset()
        panel.seriesIndex = idx
        panel.windowWidth = ww
        panel.windowCenter = wc
        panel.rescaleSlope = volume.rescaleSlope
        panel.rescaleIntercept = volume.rescaleIntercept
        panel.valueUnitLabel = (dataset.detectedModality == .ct ? "HU" : "Val")
        setPanelMode(panel, mode: .mprAxial)   // centers + renders axial via loadMPRSlice
        activePanelID = panel.id

        isLoading = false
        isScanning = false
    }

    /// Switch the displayed timepoint of a 4D NIfTI and re-render.
    func selectTimepoint(_ t: Int) {
        guard let dataset = niftiDataset, dataset.isMultiVolume else { return }
        let clamped = min(max(0, t), dataset.timepointCount - 1)
        guard clamped != currentTimepoint else { return }
        currentTimepoint = clamped

        let volume = dataset.makeVolume(timepoint: clamped)
        registerStandaloneVolume(volume, cacheKey: dataset.seriesID, description: dataset.displayName)

        for panel in panels where panel.seriesIndex == niftiSeriesIndex {
            panel.rescaleSlope = volume.rescaleSlope
            panel.rescaleIntercept = volume.rescaleIntercept
            if panel.panelMode.isMPR {
                loadMPRSlice(for: panel)
            }
        }
    }

    /// Set / clear the manual modality override and refresh dependent UI.
    func setModalityOverride(_ modality: ImagingModality?) {
        modalityOverride = modality
        let label = (effectiveModality == .ct ? "HU" : "Val")
        for panel in panels where panel.seriesIndex == niftiSeriesIndex {
            panel.valueUnitLabel = label
            // The appropriate window changes with the modality (CT preset vs MRI
            // percentile), so reseed to the new modality default and re-render.
            if let (ww, wc) = modalityDefaultWindow(forSeriesIndex: panel.seriesIndex) {
                setPanelWindow(panel, ww: ww, wc: wc)
            }
        }
        objectWillChange.send()
    }

    // MARK: - Modality-aware W/L seeding

    /// The modality default W/L in STORED units, ignoring any saved manual
    /// window: CT → the default HU preset (Brain); MRI → robust percentile
    /// auto-window. nil unless `idx` is the loaded NIfTI series.
    func modalityDefaultWindow(forSeriesIndex idx: Int) -> (ww: Double, wc: Double)? {
        guard idx == niftiSeriesIndex, let dataset = niftiDataset else { return nil }
        if effectiveModality == .ct {
            let vol = cachedVolume(forSeriesIndex: idx)
            let (w, c) = WindowPreset.defaultCT.storedWindow(
                slope: vol?.rescaleSlope ?? 1, intercept: vol?.rescaleIntercept ?? 0)
            return (w, c)
        }
        let (low, high) = dataset.suggestedWindow
        return (max(high - low, 1), (high + low) / 2)
    }

    /// W/L to seed a freshly-assigned NIfTI panel: a previously-saved manual
    /// window if present (so toggling layouts / timepoints keeps the user's
    /// window), else the modality default. nil unless `idx` is the NIfTI series.
    func seededWindow(forSeriesIndex idx: Int) -> (ww: Double, wc: Double)? {
        guard idx == niftiSeriesIndex, idx >= 0, idx < allSeries.count else { return nil }
        if let saved = seriesStates[allSeries[idx].id],
           let ww = saved.windowWidth, let wc = saved.windowCenter, ww > 0 {
            return (ww, wc)
        }
        return modalityDefaultWindow(forSeriesIndex: idx)
    }

    // MARK: - Modality-aware W/L application (UI)

    /// Apply a CT HU preset to every panel showing the NIfTI series, converting
    /// to stored units per the volume calibration. Re-renders + persists.
    func applyWindowPreset(_ preset: WindowPreset) {
        guard niftiSeriesIndex >= 0 else { return }
        let vol = cachedVolume(forSeriesIndex: niftiSeriesIndex)
        let (ww, wc) = preset.storedWindow(slope: vol?.rescaleSlope ?? 1,
                                           intercept: vol?.rescaleIntercept ?? 0)
        for panel in panels where panel.seriesIndex == niftiSeriesIndex {
            setPanelWindow(panel, ww: ww, wc: wc)
        }
    }

    /// Reset every panel showing the NIfTI series to the modality default window
    /// (CT → Brain preset, MRI → percentile auto-window). Re-renders + persists.
    func applyModalityAutoWindow() {
        guard let (ww, wc) = modalityDefaultWindow(forSeriesIndex: niftiSeriesIndex) else { return }
        for panel in panels where panel.seriesIndex == niftiSeriesIndex {
            setPanelWindow(panel, ww: ww, wc: wc)
        }
    }

    /// Auto-window a panel: the modality default for the NIfTI series (applied to
    /// all linked panels so the ortho views stay in sync), else the legacy
    /// per-slice min/max. Backs the "Auto" button and the `A` shortcut.
    func autoWindow(for panel: PanelState) {
        if niftiDataset != nil, panel.seriesIndex == niftiSeriesIndex {
            applyModalityAutoWindow()
        } else {
            autoWindowLevelForPanel(panel)
        }
    }

    /// Initial display window (width, center) in STORED units. Defensive
    /// fallback for `applyNiftiDataset`; normal seeding uses `modalityDefaultWindow`.
    private func initialWindow(for dataset: NiftiDataset) -> (Double, Double) {
        let (low, high) = dataset.suggestedWindow
        let ww = max(high - low, 1)
        let wc = (high + low) / 2
        return (ww, wc)
    }
}
