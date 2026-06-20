// DICOMModel+Nifti.swift
// Lentis
//
// NIfTI loading orchestration: reads a .nii/.nii.gz file off the main thread,
// detects modality, builds an Int16 VolumeData, and displays it as an axial
// view. 4D volumes default to the first timepoint with a selector.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

extension DICOMModel {

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

        // Cache under a stable key (the dataset id) so 4D timepoint switches
        // simply replace the cached volume without spawning new series.
        let idx = registerStandaloneVolume(volume, cacheKey: dataset.seriesID, description: dataset.displayName)
        niftiSeriesIndex = idx

        let (ww, wc) = initialWindow(for: dataset)

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
        }
        objectWillChange.send()
    }

    /// Initial display window (width, center) in STORED units. Uses a robust
    /// 1–99% percentile of the data; modality-specific HU presets arrive later.
    private func initialWindow(for dataset: NiftiDataset) -> (Double, Double) {
        let (low, high) = dataset.suggestedWindow
        let ww = max(high - low, 1)
        let wc = (high + low) / 2
        return (ww, wc)
    }
}
