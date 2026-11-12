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

verify_zinitix_zt7650_implementation() {
    local zinitix_c="$KSRC/drivers/input/touchscreen/zinitix.c"
    local kconfig="$KSRC/drivers/input/touchscreen/Kconfig"
    local makefile="$KSRC/drivers/input/touchscreen/Makefile"
    local dt_binding="$KSRC/Documentation/devicetree/bindings/input/touchscreen/zinitix,bt400.yaml"

    [[ -f "$zinitix_c" && -f "$kconfig" && -f "$makefile" && -f "$dt_binding" ]] || return 1

    # 1. zinitix_zt7650_data exists in the correct driver definition
    awk '
        /static const struct zinitix_chip_data zinitix_zt7650_data = \{/,/^\};/ {
            if ($0 ~ /^[[:space:]]*\.point_status_reg[[:space:]]*=[[:space:]]*0x0200/ && !f1) f1=1;
            if ($0 ~ /^[[:space:]]*\.zt_events[[:space:]]*=[[:space:]]*true/ && !f2) f2=1;
        }
        END { exit !(f1 && f2) }
    ' "$zinitix_c" || return 1

    # 2. struct zinitix_zt_event has the expected 16-byte layout
    awk '
        /struct zinitix_zt_event \{/,/static_assert\(sizeof\(struct zinitix_zt_event\) == 16\);/ {
            if ($0 ~ /static_assert\(sizeof\(struct zinitix_zt_event\) == 16\);/) found=1
        }
        END { exit !found }
    ' "$zinitix_c" || return 1

    # 3. zinitix_check_presence() performs actual ZT7650 presence detection
    awk '
        /static int zinitix_check_presence\(/,/^}/ {
            if ($0 ~ /zinitix_write_cmd\(.*ZINITIX_CHIP_REVISION\)/) f1=1
        }
        /static int zinitix_ts_probe\(/,/^}/ {
            if ($0 ~ /zinitix_check_presence\(bt541\)/) f2=1
        }
        END { exit !(f1 && f2) }
    ' "$zinitix_c" || return 1

    # 4. zinitix_of_match[] maps zinitix,zt7650 to zinitix_zt7650_data
    awk '
        /static const struct of_device_id zinitix_of_match\[\]/,/^\};/ {
            if ($0 ~ /\{[[:space:]]*\.compatible[[:space:]]*=[[:space:]]*"zinitix,zt7650"[[:space:]]*,[[:space:]]*\.data[[:space:]]*=[[:space:]]*&zinitix_zt7650_data[[:space:]]*\}/) found=1
        }
        END { exit !found }
    ' "$zinitix_c" || return 1

    # 5. CONFIG_TOUCHSCREEN_ZINITIX exists in Kconfig
    awk '
        /^config TOUCHSCREEN_ZINITIX/ { in_zinitix=1; next }
        /^config / { if (in_zinitix) in_zinitix=0 }
        in_zinitix {
            if ($0 ~ /^[[:space:]]*tristate[[:space:]]+"Zinitix touchscreen support"/) f1=1;
            if ($0 ~ /^[[:space:]]*depends on I2C/) f2=1;
        }
        END { exit !(f1 && f2) }
    ' "$kconfig" || return 1

    # 6. Makefile enables zinitix.o through CONFIG_TOUCHSCREEN_ZINITIX
    grep -q '^[[:space:]]*obj-\$(CONFIG_TOUCHSCREEN_ZINITIX)[[:space:]]*+=[[:space:]]*zinitix\.o' "$makefile" || return 1

    # 7. Device Tree YAML binding includes zinitix,zt7650
    awk '
        /^[[:space:]]*compatible:/ { in_compat=1 }
        /^[[:space:]]*reg:/ { in_compat=0 }
        in_compat && /^[[:space:]]*-[[:space:]]*zinitix,zt7650/ { found=1 }
        END { exit !found }
    ' "$dt_binding" || return 1

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
    elif [[ "$patch_name" == "0007-r8q-input-zinitix-zt7650.patch" ]] && verify_zinitix_zt7650_implementation; then
        echo "Already satisfied: $patch_name (upstream kernel implements equivalent Zinitix ZT7650 touchscreen support)"
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
