# Lentis Help

Lentis is a native macOS NIfTI brain viewer for CT and MRI. It opens 3D/4D `.nii` and `.nii.gz` files, displays affine-correct neurological MPR views, and includes an interactive Metal 3D volume panel plus Mask/Atlas overlays.

## Opening Data

- Press `Cmd+O`, use **File → Open**, click **Open** in the sidebar, or drop a `.nii` / `.nii.gz` file onto the viewer.
- Press `Cmd+Shift+O`, use **File → Add Layer**, or drop a 3D NIfTI mask/atlas into the Layers Inspector.
- External layers are session-scoped and aligned to the current base image with nearest-neighbour sampling.

## Navigation

| Input | Action |
|---|---|
| `Cmd+1` … `Cmd+4` | Single, side-by-side, stacked, or quad layout |
| `Cmd+Shift+M` | Axial / sagittal / coronal / 3D brain layout |
| `Tab` | Cycle the active panel |
| Scroll wheel or `Up` / `Down` | Navigate slices |
| `Page Up` / `Page Down` | Jump 10 slices |
| `Home` / `End` | First / last slice |
| Double-click | Toggle active panel fullscreen |
| Drag in the 3D panel | Rotate the volume |

## Tools

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
| `E` | Eraser seam for future mask editing |

Right-drag adjusts window/level from any tool. Hold `Option` or `Control` while dragging/scrolling to pan or zoom.

## Display

- NIfTI affines are canonicalized to RAS and MPR panels display in neurological orientation: patient-left is screen-left.
- CT defaults to the Brain HU preset and exposes HU window presets.
- MRI uses robust auto-windowing.
- The bottom status bar shows file, slice, W/L, cursor RAS coordinates, voxel coordinates, and HU/intensity.
- The 3D panel uses Metal volume rendering and intentionally hides 2D slice overlays.

## Layers

Open the Layers Inspector to add Mask/Atlas NIfTI overlays. Label 0 is transparent, masks use a selectable color/opacity, and atlases use the bundled FreeSurfer LUT or a custom FreeSurfer-format LUT.

## Research Use

Lentis is research and visualization software. It is not a medical device and has not been reviewed or approved for clinical diagnosis.

