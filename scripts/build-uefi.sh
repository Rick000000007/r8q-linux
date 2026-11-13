#!/usr/bin/env bash
#
# Embed our kernel-built DTB into Mu-Silicium and build the UEFI boot image.
# The DTB (with the display fix: dispcc protected-clocks + framebuffer MDSS_GDSC
# power-domain) lives INSIDE the firmware, so any DTB change needs a re-flash.
#
# Env: MUSIL=<Mu-Silicium checkout>  DTB=<out/.../sm8250-samsung-r8q.dtb>
set -euo pipefail
MUSIL="${MUSIL:?set MUSIL to your Mu-Silicium checkout}"
DTB="${DTB:?set DTB to out/arch/arm64/boot/dts/qcom/sm8250-samsung-r8q.dtb}"
VENV="${VENV:-$MUSIL/../.venv}"   # python venv with Mu-Silicium pip-requirements

if [[ "$DTB" != /* ]]; then
    DTB="$PWD/$DTB"
fi
if [[ "$MUSIL" != /* ]]; then
    MUSIL="$PWD/$MUSIL"
fi

if [[ ! -f "$DTB" ]]; then
    echo "[-] Error: DTB file not found: '$DTB'" >&2
    exit 1
fi
if [[ ! -s "$DTB" ]]; then
    echo "[-] Error: DTB file is empty: '$DTB'" >&2
    exit 1
fi

if [[ ! -d "$MUSIL" ]]; then
    echo "[-] Error: Mu-Silicium directory not found: '$MUSIL'" >&2
    exit 1
fi

PKG_DIR="$MUSIL/Platforms/Samsung/r8qPkg"
if [[ ! -d "$PKG_DIR" ]]; then
    echo "[-] Error: Mu-Silicium r8qPkg directory not found: '$PKG_DIR'" >&2
    exit 1
fi

FDF_FILE="$PKG_DIR/r8q.fdf"
if [[ ! -f "$FDF_FILE" ]]; then
    echo "[-] Error: Firmware configuration file not found: '$FDF_FILE'" >&2
    exit 1
fi

EXPECTED_FDF_REL="r8qPkg/FdtBlob/sm8250-samsung-r8q.dtb"
if ! grep -q "$EXPECTED_FDF_REL" "$FDF_FILE"; then
    echo "[-] Error: Firmware configuration '$FDF_FILE' does not reference '$EXPECTED_FDF_REL'." >&2
    exit 1
fi

FDT_DIR="$PKG_DIR/FdtBlob"
FDT_DEST="$FDT_DIR/sm8250-samsung-r8q.dtb"

mkdir -p "$FDT_DIR"
if [[ ! -d "$FDT_DIR" ]]; then
    echo "[-] Error: Failed to create DTB destination directory: '$FDT_DIR'" >&2
    exit 1
fi

cp "$DTB" "$FDT_DEST"
if [[ ! -s "$FDT_DEST" ]] || ! cmp -s "$DTB" "$FDT_DEST"; then
    echo "[-] Error: DTB destination file verification failed: '$FDT_DEST'" >&2
    exit 1
fi

( cd "$MUSIL" && "$VENV/bin/python" build_uefi.py -d r8q )

IMG_BASE="$MUSIL/Mu-r8q.img"
IMG_LEGACY="$MUSIL/Mu-r8q-0.img"

if [[ ! -f "$IMG_LEGACY" ]]; then
    if [[ -f "$IMG_BASE" && -s "$IMG_BASE" ]]; then
        cp "$IMG_BASE" "$IMG_LEGACY"
    fi
elif [[ ! -f "$IMG_BASE" ]]; then
    if [[ -f "$IMG_LEGACY" && -s "$IMG_LEGACY" ]]; then
        cp "$IMG_LEGACY" "$IMG_BASE"
    fi
fi

if [[ ! -f "$IMG_BASE" && ! -f "$IMG_LEGACY" ]]; then
    echo "[-] Error: UEFI build output not found (neither '$IMG_BASE' nor '$IMG_LEGACY' was created)." >&2
    exit 1
fi

if [[ ! -s "$IMG_BASE" || ! -s "$IMG_LEGACY" ]]; then
    echo "[-] Error: UEFI build output is empty (0 bytes)." >&2
    exit 1
fi

if ! cmp -s "$IMG_BASE" "$IMG_LEGACY"; then
    echo "[-] Error: Output verification failed: '$IMG_BASE' and '$IMG_LEGACY' differ." >&2
    exit 1
fi

echo "[+] $IMG_LEGACY built from $IMG_BASE (embeds the display-fix DTB). Flash with scripts/flash.sh"
