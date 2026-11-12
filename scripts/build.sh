#!/usr/bin/env bash
# Build the r8q kernel artifacts and, when MUSIL is set, the UEFI image.
# Usage: BUSYBOX=/path/to/static-aarch64-busybox [KSRC=/path/to/linux] [MUSIL=/path/to/Mu-Silicium] ./scripts/build.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/ben443/Linux-mainline-nethunter-pro.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-kali/master}"
if [[ -z "${KSRC:-}" ]]; then
    KSRC="$REPO/dl/Linux-mainline-nethunter-pro"
fi
if [[ "$KSRC" != /* ]]; then
    KSRC="$PWD/$KSRC"
fi

if [[ ! -f "$KSRC/Makefile" ]]; then
    if [[ "$KSRC" == "$REPO/dl/Linux-mainline-nethunter-pro" ]]; then
        if ! command -v git >/dev/null 2>&1; then
            echo "git is required to fetch the default kernel source; set KSRC to an existing kernel checkout." >&2
            exit 2
        fi
        mkdir -p "$(dirname "$KSRC")"
        git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KSRC"
    else
        echo "KSRC must point to an existing Linux source checkout containing Makefile." >&2
        exit 2
    fi
fi

KOUT="${KOUT:-$REPO/out/kernel}"
if [[ "$KOUT" != /* ]]; then
    KOUT="$PWD/$KOUT"
fi

KSRC="$KSRC" OUT="$KOUT" "${REPO}/scripts/build_kernel.sh"

if [[ -n "${MUSIL:-}" ]]; then
    MUSIL="$MUSIL" \
        DTB="$KOUT/arch/arm64/boot/dts/qcom/sm8250-samsung-r8q.dtb" \
        "${REPO}/scripts/build-uefi.sh"
else
    echo "[+] Kernel build complete. Set MUSIL=/path/to/Mu-Silicium to also build Mu-r8q-0.img."
fi
