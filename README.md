<p align="center">
  <img src="docs/icon.png" alt="Lentis app icon" width="128">
</p>

<h1 align="center">Lentis</h1>

<p align="center">
  <strong>A native macOS NIfTI brain viewer for CT and MRI.</strong><br>
  Affine-correct neurological orientation, linked multiplanar views, interactive Metal volume rendering,
  mask/atlas overlays, and manual segmentation in one focused desktop app.
</p>

<p align="center">
  <a href="../../releases">Releases</a> &middot;
  <a href="../../issues">Issues</a> &middot;
  <a href="LICENSE">MIT License</a>
</p>

![Lentis showing linked axial, sagittal, coronal, and 3D brain views with mask and atlas layers](screenshot.png)

## Overview

Lentis is a SwiftUI + Metal viewer for 3D and 4D brain NIfTI files (`.nii` and `.nii.gz`). It supports both CT and MRI, displays anatomy in neurological orientation (patient-left is screen-left), and uses the image affine as the source of spatial truth.

The app began as a fork of [OpenDicomViewer](https://github.com/jnheo-md/open-dicom-viewer) and has since been rebuilt around a dependency-free NIfTI pipeline. DICOM, DCMTK, and OpenJPEG are not part of Lentis.

## Features

- **NIfTI-1 and NIfTI-2** — reads uncompressed and gzip-compressed 3D/4D volumes across common integer and floating-point data types.
- **Correct spatial orientation** — uses sform/qform affines, canonicalizes volumes to RAS, and renders axial, sagittal, and coronal planes in neurological orientation.
- **Linked brain quad** — one command creates axial, sagittal, coronal, and 3D views with a draggable crosshair connecting the orthogonal planes.
- **Interactive 3D rendering** — Metal compute ray marching with drag rotation, density control, physical-spacing-aware geometry, lighting, and full-quality settling after interaction.
- **CT- and MRI-aware display** — CT HU presets (Brain, Subdural, Stroke, Bone, and Soft Tissue), robust MRI auto-windowing, manual window/level, invert, zoom, pan, rotate, and flip.
- **Mask and atlas layers** — add 3D NIfTI overlays in the native Layers Inspector; Lentis performs affine-aware nearest-neighbour alignment and supports ordering, opacity, mask colors, FreeSurfer/custom LUTs, and per-label visibility.
- **Manual segmentation** — draw a resizable 3D ROI box and segment by threshold or grow-from-seed; manage multiple labeled regions, optionally constrain to a brain mask, and export the result as a mask or multi-label atlas NIfTI with a FreeSurfer LUT.
- **FreeSurfer SynthSeg integration** — generate a brain mask and anatomical parcellation in-app (`mri_synthseg`), automatically naming segmented regions by anatomy.
- **BIDS datasets** — open a BIDS or loose-folder dataset, browse subjects and sessions in the sidebar navigator, and write outputs into a `derivatives/lentis/` tree.
- **4D timepoints** — switch volumes without changing the shared spatial view or quantization scale.
- **Measurement tools** — ruler, angle, ROI statistics, and ROI-based window/level.
- **Spatial readout** — live voxel coordinates, RAS millimetres, and calibrated HU/intensity values in the status bar.
- **Responsive large-volume interaction** — slice extraction, windowing, overlay compositing, and GPU readback run asynchronously with stale-render coalescing.
- **Native and self-contained** — pure Swift + SwiftUI + AppKit + Metal, with no native or system-library dependencies.

## Requirements

- macOS 26 Tahoe or later (required for the native Liquid Glass UI)
- Apple Silicon Mac (`arm64`)
- Xcode 26 / a Swift 6.2+ toolchain for source builds

## Download

Prebuilt, ad-hoc-signed DMGs are published on the [Releases](../../releases) page. Because the app is not notarized, the first launch needs **right-click → Open** (or an approval under **System Settings → Privacy & Security**).

## Build and Run

```bash
git clone https://github.com/lijiaxiang63/Lentis.git
cd Lentis

# Build the Swift package
swift build

# Build, stage dist/Lentis.app, and launch it
./scripts/build_and_run.sh
```

To create a release app and DMG:

```bash
./scripts/package_app.sh
```

This produces `Lentis.app` and `Lentis.dmg` with ad-hoc signing by default. Developer ID signing and notarization require your own Apple credentials and packaging configuration. Pushing a `v*` tag builds and publishes the DMG to Releases automatically via GitHub Actions.

## Open Images and Layers

- Press `Cmd+O`, use **File → Open**, click **Open** in the sidebar, or drop a `.nii` / `.nii.gz` file onto the viewer.
- Press `Opt+Cmd+O` or use **File → Open Folder** to open a folder or BIDS dataset, then pick images from the sidebar navigator.
- Press `Cmd+Shift+O`, use **File → Add Layer**, or drop a 3D NIfTI mask/atlas into the Layers Inspector.
- Click the brain-quad button or press `Cmd+Shift+M` to create linked axial, sagittal, coronal, and 3D panels.
- Click or drag in an MPR panel with the Select tool to reposition the shared crosshair.
- Drag inside the 3D panel to rotate the volume.

External layers are session-scoped. Label `0` is transparent, categorical labels are never linearly interpolated, and the top row in the Inspector is composited last.

## Controls

### Navigation and Layout

| Input | Action |
|---|---|
| `Cmd+1` … `Cmd+4` | Single, side-by-side, stacked, or quad layout |
| `Cmd+Shift+M` | Axial/sagittal/coronal/3D brain layout |
| `Tab` | Cycle the active panel |
| Scroll wheel or `Up` / `Down` | Navigate slices |
| `Page Up` / `Page Down` | Jump 10 slices |
| `Home` / `End` | First / last slice |
| Double-click | Toggle the active panel fullscreen |
| `A` | Modality-aware auto window/level |
| `F` | Fit image to panel |
| `R` | Reset view |
| `I` | Invert image |
| `H` | Flip horizontally |
| `[` / `]` | Rotate 90° counter-clockwise / clockwise |

### Tools

| Key | Tool |
|---|---|
| `V` | Select / move crosshair |
| `P` | Pan |
| `W` | Window/Level |
| `Z` | Zoom |
| `O` | ROI Window/Level |
| `S` | ROI Statistics |
| `D` | Ruler |
| `N` | Angle |
| `E` | Eraser |
| `B` | Calcification ROI box |
| `K` | Calcification brush |

Right-drag adjusts window/level from any tool. Hold `Option` or `Control` while left-dragging to pan, or while scrolling to zoom.

## Architecture

```text
Sources/Lentis/
├── NIfTI.swift                 # NIfTI-1/2 parsing and pure-Swift gzip/DEFLATE
├── Orientation.swift           # Affine interpretation and canonical RAS reorientation
├── NiftiVolumeLoader.swift     # Modality detection, quantization, and volume creation
├── VolumeData.swift            # Int16 volume, affine transforms, and mask seam
├── ViewerModel.swift           # Panel, rendering, navigation, and interaction state
├── ViewerModel+Nifti.swift     # NIfTI loading, timepoints, modality, and W/L policy
├── MPREngine.swift             # Oriented CPU slice extraction and layer compositing
├── MetalVolumeRenderer.swift   # Metal 3D ray marcher and projection rendering
├── OverlayLayerLoader.swift    # Mask/atlas classification and affine-aware alignment
├── CalcificationSegmenter.swift # Threshold/grow segmentation engine and ROI-box geometry
├── NiftiWriter.swift           # NIfTI-1 writer for mask/atlas export and brain-mask write-back
├── LayerInspectorView.swift    # Native layer, segmentation, and LUT management UI
└── MultiPanelContainer.swift   # Panel grid, gestures, annotations, and overlays
```

The 2D MPR path is CPU-rendered; the fourth panel uses a cached Metal 3D texture. Both paths run expensive work off the main thread and discard stale results during rapid interaction. Orientation and display flips are centralized so grayscale slices, overlays, crosshairs, labels, and coordinate readouts remain aligned.

## Tests

```bash
# Full XCTest + swift-testing suite
swift test

# NIfTI and dataset coverage
swift test --filter nifti --filter dataset

# Segmentation/mask alignment seam
swift test --filter SegmentationSeam
```

The repository also includes release-mode NIfTI load and 3D rendering benchmark harnesses under `scripts/`.

## Research Use

Lentis is research and visualization software. It is not a medical device and has not been reviewed or approved for clinical diagnosis. Always validate orientation, calibration, and derived results for your own workflow, and do not publish screenshots containing identifying patient information.

## Contributing

Issues and pull requests are welcome. Please keep orientation logic centralized, preserve nearest-neighbour handling for categorical overlays, and include focused tests for spatial or rendering changes.

## License

Lentis is distributed under the [MIT License](LICENSE) and retains attribution to the original OpenDicomViewer project. The bundled FreeSurfer color lookup table is distributed under separate MGH terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
