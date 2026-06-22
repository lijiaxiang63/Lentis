import gzip
import os
import struct
from pathlib import Path

import numpy as np

OUT = Path(__file__).resolve().parents[1] / "TestData"
OUT.mkdir(exist_ok=True)

def write_nifti(path, data, dtype_code, bitpix, affine, slope=1.0, inter=0.0):
    # data: numpy array shape (nz,ny,nx) or (nt,nz,ny,nx); C-order => i fastest (NIFTI order)
    if data.ndim == 3:
        nz, ny, nx = data.shape; nt = 1; dim0 = 3
    else:
        nt, nz, ny, nx = data.shape; dim0 = 4
    hdr = bytearray(352)
    struct.pack_into('<i', hdr, 0, 348)
    struct.pack_into('<8h', hdr, 40, dim0, nx, ny, nz, nt, 1, 1, 1)
    struct.pack_into('<h', hdr, 70, dtype_code)
    struct.pack_into('<h', hdr, 72, bitpix)
    struct.pack_into('<8f', hdr, 76, 1.0, 1.0, 1.0, 1.0, 1.0, 0,0,0)  # pixdim
    struct.pack_into('<f', hdr, 108, 352.0)  # vox_offset
    struct.pack_into('<f', hdr, 112, slope)
    struct.pack_into('<f', hdr, 116, inter)
    struct.pack_into('<h', hdr, 252, 0)   # qform_code
    struct.pack_into('<h', hdr, 254, 1)   # sform_code
    for r in range(3):
        struct.pack_into('<4f', hdr, 280 + r*16, *affine[r])
    hdr[344:348] = b'n+1\x00'
    raw = bytes(hdr) + np.ascontiguousarray(data).tobytes()
    with gzip.open(path, 'wb') as f:
        f.write(raw)
    print("wrote", path, "dims", (nx,ny,nz,nt), "bytes(gz)", os.path.getsize(path))

nx,ny,nz = 64,64,48
# RAS affine, 1mm iso, origin at volume center (neurological convention)
aff = [[1,0,0,-nx/2],[0,1,0,-ny/2],[0,0,1,-nz/2]]

zz,yy,xx = np.mgrid[0:nz,0:ny,0:nx].astype(np.float32)
cx,cy,cz = nx/2, ny/2, nz/2
# head ellipsoid mask
ell = ((xx-cx)/26)**2 + ((yy-cy)/30)**2 + ((zz-cz)/20)**2 <= 1.0

# ---- CT: air -1000, soft tissue ~40 HU, a calcification blob ~420 HU on the patient RIGHT (x<cx) ----
ct = np.full((nz,ny,nx), -1000, np.int16)
ct[ell] = 40
skull = (((xx-cx)/26)**2+((yy-cy)/30)**2+((zz-cz)/20)**2 <= 1.0) & (((xx-cx)/23)**2+((yy-cy)/27)**2+((zz-cz)/17)**2 >= 1.0)
ct[skull] = 1200  # bone
calc = ((xx-(cx-12))**2 + (yy-cy)**2 + (zz-cz)**2) <= 9    # small dense blob, left-of-center in array
ct[calc] = 420
write_nifti(OUT / "synthetic_ct.nii.gz", ct, 4, 16, aff)

# ---- MRI: float32, non-negative, intensity gradient inside head ----
mri = np.zeros((nz,ny,nx), np.float32)
mri[ell] = 300 + 200*np.sin(xx[ell]/6.0) + 1.5*yy[ell]
mri[mri<0] = 0
write_nifti(OUT / "synthetic_mri.nii.gz", mri, 16, 32, aff)

# ---- 4D MRI: 5 timepoints, brightness varies per timepoint ----
nt=5
m4 = np.zeros((nt,nz,ny,nx), np.float32)
for t in range(nt):
    vol = np.zeros((nz,ny,nx), np.float32)
    vol[ell] = 200 + 60*t + 100*np.cos((xx[ell]+t*4)/7.0)
    vol[vol<0]=0
    m4[t]=vol
write_nifti(OUT / "synthetic_mri_4d.nii.gz", m4, 16, 32, aff)

# ---- Orientation markers: distinct intensities per octant (for Phase 4 checks) ----
om = np.zeros((nz,ny,nx), np.int16)
om[zz<cz] += 0;     om[zz>=cz]+=4
om[yy>=cy]+=2;      om[xx>=cx]+=1
om = (om.astype(np.int16))*100 - 1000  # spread into HU-ish range with negatives (reads as CT)
write_nifti(OUT / "synthetic_orient.nii.gz", om, 4, 16, aff)
print("DONE")
