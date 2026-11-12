#!/usr/bin/env bash
# Build the mainline kernel Image, modules, and r8q DTB.
# Usage: KSRC=/path/to/linux [OUT=/path/to/build] [BUSYBOX=/path/to/static-aarch64-busybox] ./scripts/build_kernel.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$REPO/out/kernel}"
JOBS="${JOBS:-$(nproc)}"
if [[ "$OUT" != /* ]]; then
    OUT="$PWD/$OUT"
fi

if [[ "${1:-}" == clean ]]; then
    rm -rf -- "$OUT"
    exit 0
fi

KSRC="${KSRC:-}"
if [[ -z "$KSRC" || ! -f "$KSRC/Makefile" ]]; then
    echo "Set KSRC to an existing mainline Linux source checkout." >&2
    exit 2
fi
KSRC="$(cd "$KSRC" && pwd)"

BUSYBOX="${BUSYBOX:-$REPO/initramfs/bin/busybox}"
if [[ ! -x "$BUSYBOX" ]]; then
    echo "Static AArch64 busybox is required at $BUSYBOX (or set BUSYBOX=/path/to/busybox)." >&2
    exit 2
fi

QCOM_DTS="$KSRC/arch/arm64/boot/dts/qcom"
MERGE_CONFIG="$KSRC/scripts/kconfig/merge_config.sh"
KCONFIG_SCRIPT="$KSRC/scripts/config"
for required in "$QCOM_DTS" "$MERGE_CONFIG" "$KCONFIG_SCRIPT"; do
    if [[ ! -e "$required" ]]; then
        echo "Kernel source is missing required build file: $required" >&2
        exit 2
    fi
done

mkdir -p "$OUT"
STAGED_INITRAMFS="$OUT/initramfs"
rm -rf -- "$STAGED_INITRAMFS"
mkdir -p "$STAGED_INITRAMFS/bin"
cp -a "$REPO/initramfs/." "$STAGED_INITRAMFS/"
install -m 0755 "$BUSYBOX" "$STAGED_INITRAMFS/bin/busybox"

install -m 0644 "$REPO/dts/sm8250-samsung-common.dtsi" "$QCOM_DTS/"
install -m 0644 "$REPO/dts/sm8250-samsung-r8q.dts" "$QCOM_DTS/"

verify_r8q_se_dma_implementation() {
    local geni_i2c="$KSRC/drivers/i2c/busses/i2c-qcom-geni.c"
    [[ -f "$geni_i2c" ]] || return 1

    # 1. Verify force_se_dma flag inside struct geni_i2c_dev (excluding comments)
    awk '
        /^struct geni_i2c_dev \{/,/^\};/ {
            if ($0 ~ /^[[:space:]]*bool[[:space:]]+force_se_dma;/) found=1
        }
        END { exit !found }
    ' "$geni_i2c" || return 1

    # 2. Verify r8q device-tree detection inside geni_i2c_probe() (excluding comments)
    awk '
        /static int geni_i2c_probe\(/,/^}/ {
            if ($0 ~ /^[[:space:]]*gi2c->force_se_dma[[:space:]]*=[[:space:]]*of_machine_is_compatible\("samsung,r8q"\);/) found=1
        }
        END { exit !found }
    ' "$geni_i2c" || return 1

    # 3. Verify DMA threshold routing in geni_i2c_rx_one_msg()
    awk '
        /static int geni_i2c_rx_one_msg\(/,/^}/ {
            if ($0 ~ /i2c_get_dma_safe_msg_buf\([^,]+,[[:space:]]*gi2c->force_se_dma[[:space:]]*\?[[:space:]]*1[[:space:]]*:[[:space:]]*32\)/) found=1
        }
        END { exit !found }
    ' "$geni_i2c" || return 1

    # 4. Verify DMA threshold routing in geni_i2c_tx_one_msg()
    awk '
        /static int geni_i2c_tx_one_msg\(/,/^}/ {
            if ($0 ~ /i2c_get_dma_safe_msg_buf\([^,]+,[[:space:]]*gi2c->force_se_dma[[:space:]]*\?[[:space:]]*1[[:space:]]*:[[:space:]]*32\)/) found=1
        }
        END { exit !found }
    ' "$geni_i2c" || return 1

    # 5. Verify FIFO detection logic in geni_i2c_probe()
    awk '
        /static int geni_i2c_probe\(/,/^}/ {
            if ($0 ~ /fifo_disable[[:space:]]*=[[:space:]]*!gi2c->force_se_dma/) found=1
        }
        END { exit !found }
    ' "$geni_i2c" || return 1

    return 0
}

cd "$KSRC"
for patch_file in "$REPO"/patches/*.patch; do
    patch_name="$(basename "$patch_file")"
    if patch --batch --forward --dry-run -p1 < "$patch_file" >/dev/null 2>&1; then
        echo "Applying $patch_name"
        patch --batch --forward -p1 < "$patch_file"
    elif patch --batch --reverse --dry-run -p1 < "$patch_file" >/dev/null 2>&1; then
        echo "Already applied: $patch_name"
    elif [[ "$patch_name" == "0003-r8q-i2c-qcom-geni-force-fifo-se-dma.patch" ]] && verify_r8q_se_dma_implementation; then
        echo "Already satisfied: $patch_name (upstream kernel implements equivalent Samsung r8q SE-DMA workaround)"
    else
        echo "Cannot apply or verify $patch_name; check the kernel version/source tree." >&2
        exit 1
    fi
done

make O="$OUT" ARCH=arm64 LLVM=1 defconfig
"$MERGE_CONFIG" -m -O "$OUT" "$OUT/.config" "$REPO/config/r8q_bringup.config"
"$KCONFIG_SCRIPT" --file "$OUT/.config" \
    --set-str CONFIG_CMDLINE "$(tr -d '\n' < "$REPO/config/cmdline.txt")" \
    --set-val CONFIG_CMDLINE_FORCE y \
    --set-str CONFIG_INITRAMFS_SOURCE "$STAGED_INITRAMFS $REPO/initramfs/irfs.devnodes"
make O="$OUT" ARCH=arm64 LLVM=1 olddefconfig

make O="$OUT" ARCH=arm64 LLVM=1 -j"$JOBS" Image dtbs modules

IMAGE="$OUT/arch/arm64/boot/Image"
DTB="$OUT/arch/arm64/boot/dts/qcom/sm8250-samsung-r8q.dtb"
for artifact in "$IMAGE" "$DTB"; do
    if [[ ! -s "$artifact" ]]; then
        echo "Expected kernel artifact was not produced: $artifact" >&2
        exit 1
    fi
done
echo "[+] Image: $IMAGE"
echo "[+] DTB:   $DTB"
echo "[+] Modules built; run make -C \"$KSRC\" O=\"$OUT\" ARCH=arm64 LLVM=1 INSTALL_MOD_PATH=... modules_install to install them."
