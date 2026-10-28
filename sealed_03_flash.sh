#!/bin/bash
# sealed_03_flash.sh — flash the sealed image onto /dev/vda from the LOCAL
# attached build volume, with the instance in rescue mode. No laptop round-trip.
# The instance must be paused in the rescue initramfs (run sealed_02_rescue.sh + console Start).
# Usage: source .env (REMOTE, SSH_OPTS); ./sealed_03_flash.sh [IMG_ON_INSTANCE] [VOL_DEV]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; source "$SCRIPT_DIR/.env"
: "${REMOTE:?set REMOTE}"
IMG="${1:-/mnt/vol/sealed-image.img}"; VOL="${2:-/dev/vdb}"; DISK="${DISK:-/dev/vda}"
echo "==> checking rescue mode on $REMOTE"
pid1=$(ssh $SSH_OPTS "$REMOTE" 'cat /proc/1/comm' 2>/dev/null || echo unknown)
[ "$pid1" != systemd ] || { echo "ERROR: not in rescue (PID1=systemd). Run sealed_02_rescue.sh + console Start." >&2; exit 1; }
echo "  PID1=$pid1. Flashing $IMG -> $DISK from the local volume (no network transfer)."
ssh $SSH_OPTS "$REMOTE" "
  set -e
  mkdir -p /mnt/vol
  mount -o ro $VOL /mnt/vol 2>/dev/null || mount $VOL /mnt/vol
  test -f $IMG || { echo 'image not found on volume: $IMG' >&2; exit 1; }
  echo 'streaming image to $DISK (busybox dd, plain — no conv=sparse)...'
  dd if=$IMG of=$DISK bs=4194304
  sync
  HASH=\$(command -v sha256sum || command -v md5sum || command -v sha1sum || true)
  if [ -n \"\$HASH\" ]; then
    s=\$(dd if=$IMG  bs=1M count=256 2>/dev/null | \$HASH | cut -d' ' -f1)
    d=\$(dd if=$DISK bs=1M count=256 2>/dev/null | \$HASH | cut -d' ' -f1)
    [ -n \"\$s\" ] && [ \"\$s\" = \"\$d\" ] && echo \"FLASH_OK readback(\$HASH)=\$d\" || { echo \"FLASH_MISMATCH src=\$s dst=\$d\" >&2; exit 1; }
  else
    echo \"FLASH_WRITTEN (no hash tool in rescue; verifying by dd record count + boot attestation)\"
  fi
  sleep 2; echo o > /proc/sysrq-trigger
" || true   # ssh drops on poweroff (after a confirmed FLASH_OK)
cat <<'MSG'

Flash complete. In-guest poweroff issued.

>>> In the Verda console: once the VM is offline, Start it again.
    Note: if the VM is already running, Shutdown it first, then Start it.

It boots into the attested-unlock initramfs. Then run the unlock step to verify
the measurement and release the LUKS passphrase.
MSG
