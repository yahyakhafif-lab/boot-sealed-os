#!/bin/bash
# sealed_01_measure.sh
# ---------------------------------------------------------------------------
# Compute the EXPECTED launch measurement for the sealed image, host-side, so you
# can pin it in the verifier's allow-list BEFORE the VM is trusted. Identical
# recipe to measure_boot.sh (OVMF + kernel + initrd + cmdline), but run from the
# build host against the exported verify/ artifacts. Because the rootfs root hash
# is inside the measured initrd and the weights root hash is inside the
# verity-measured rootfs, this one number pins OS + engine + weights.
#
# Grab Verda's fixed OVMF off any running CC instance once:
#   scp root@<cc-instance>:/boot/OVMF.amdsev.fd verify/OVMF.amdsev.fd
#
# Requires: source .env ; sev-snp-measure (pipx install sev-snp-measure)
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"
export PATH="$PATH:$HOME/.local/bin"
command -v sev-snp-measure >/dev/null || { echo "install sev-snp-measure (pipx install sev-snp-measure)" >&2; exit 1; }

OVMF="${OVMF_PATH:-./verify/OVMF.amdsev.fd}"
KERNEL="${KERNEL:-./verify/vmlinuz}"
INITRD="${INITRD:-./verify/initrd.img}"
APPEND="${APPEND:-$CMDLINE}"
# GUEST-visible vCPU signature for QEMU's virtual EPYC-Turin (see .env).
VCPUS="${VCPUS:?set VCPUS to the instance vCPU count}"
VCPU_FAMILY="${VCPU_FAMILY:-26}"; VCPU_MODEL="${VCPU_MODEL:-0}"; VCPU_STEPPING="${VCPU_STEPPING:-0}"
[ -f "$OVMF" ] || { echo "missing $OVMF — scp it off a running CC instance (see header)" >&2; exit 1; }

MEAS=$(sev-snp-measure --mode snp \
  --vcpus "$VCPUS" --vcpu-family "$VCPU_FAMILY" --vcpu-model "$VCPU_MODEL" --vcpu-stepping "$VCPU_STEPPING" \
  --ovmf "$OVMF" --kernel "$KERNEL" --initrd "$INITRD" --append "$APPEND" --output-format hex)
MEAS="${MEAS^^}"

mkdir -p verify
ROOTFS_RH=$(cat verify/rootfs_roothash)
# Combined design bakes the weights INSIDE the single verity rootfs, so there is no
# separate weights verity volume; weights_roothash is only present in the old two-volume
# flow. Treat it as optional — the one rootfs root hash already covers OS+engine+weights.
WEIGHTS_RH=$(cat verify/weights_roothash 2>/dev/null || echo "")
OVMF_SHA=$(sha256sum "$OVMF"   | awk '{print $1}')
KERNEL_SHA=$(sha256sum "$KERNEL" | awk '{print $1}')
INITRD_SHA=$(sha256sum "$INITRD" | awk '{print $1}')
cat > verify/allow-list.json <<JSON
{
  "image": "sealed-image",
  "instance_vcpus": $VCPUS,
  "expected_measurement": "$MEAS",
  "rootfs_roothash": "$ROOTFS_RH",
  "weights_roothash": "$WEIGHTS_RH",
  "cmdline": "$APPEND",
  "ovmf_sha256": "$OVMF_SHA",
  "kernel_sha256": "$KERNEL_SHA",
  "initrd_sha256": "$INITRD_SHA"
}
JSON

echo "Expected measurement : $MEAS"
echo "  vCPUs $VCPUS  family $VCPU_FAMILY model $VCPU_MODEL stepping $VCPU_STEPPING"
echo "  rootfs  root hash  : $(cat verify/rootfs_roothash)"
[ -n "$WEIGHTS_RH" ] && echo "  weights root hash  : $WEIGHTS_RH" || echo "  weights            : baked inside the rootfs (covered by the rootfs root hash)"
echo
echo "Pinned to verify/allow-list.json — load this into the verifier."
echo "Re-run after ANY change to the OS, engine, weights, kernel or firmware:"
echo "the measurement changes and the old one must be retired."
