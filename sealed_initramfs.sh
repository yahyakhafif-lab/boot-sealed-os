#!/bin/bash
# Install the attestation + LUKS-unlock initramfs into a target root filesystem.
#
#   attested_initramfs.sh <target-root-dir>
#
# Reads SSH_KEY and ATTEST_PORT from .env. Drops in:
#   - snpguest (static) + initramfs networking + dropbear authorized_keys
#   - init-top/00attestkey    : generate an EPHEMERAL ssh host key in RAM
#   - init-premount/zzattest  : bind SHA-512(host key) into a SEV-SNP report, serve it
#   - local-bottom/zzswaproot : swap the decoy /boot root for /dev/mapper/cryptroot
#   - hooks/zzattest          : pull snpguest + tools + sev-guest module into the initrd
# After this, the caller runs `update-initramfs` (with cryptsetup-initramfs +
# dropbear-initramfs installed) to bake it.
set -e

ROOT="${1:?usage: $0 <target-root-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/.env"
SNPGUEST="${SNPGUEST_BIN:-$HERE/snpguest}"
: "${SSH_KEY:?set SSH_KEY in .env}"
: "${ATTEST_PORT:=9000}"

# snpguest + client-login key + initramfs networking + force-include cryptsetup
install -m755 "$SNPGUEST" "$ROOT/usr/local/bin/snpguest"
install -d -m700 "$ROOT/etc/dropbear/initramfs"
printf '%s\n' "$SSH_KEY" > "$ROOT/etc/dropbear/initramfs/authorized_keys"
chmod 600 "$ROOT/etc/dropbear/initramfs/authorized_keys"
grep -q '^DEVICE=' "$ROOT/etc/initramfs-tools/initramfs.conf" || echo 'DEVICE=eth0' >> "$ROOT/etc/initramfs-tools/initramfs.conf"
grep -q '^IP='     "$ROOT/etc/initramfs-tools/initramfs.conf" || echo 'IP=dhcp'    >> "$ROOT/etc/initramfs-tools/initramfs.conf"
mkdir -p "$ROOT/etc/initramfs-tools/conf.d"
echo CRYPTSETUP=y > "$ROOT/etc/initramfs-tools/conf.d/cryptsetup"

cat > "$ROOT/etc/initramfs-tools/hooks/zzattest" <<'HOOK'
#!/bin/sh
PREREQ=""; case "$1" in prereqs) echo "$PREREQ"; exit 0;; esac
. /usr/share/initramfs-tools/hook-functions
copy_exec /usr/local/bin/snpguest /usr/local/bin/snpguest
copy_exec /usr/bin/dropbearkey /usr/bin/dropbearkey
copy_exec /usr/bin/xxd /usr/bin/xxd
copy_exec /usr/bin/sha512sum /usr/bin/sha512sum
copy_exec /usr/bin/busybox /usr/local/bin/busybox
manual_add_modules sev-guest
HOOK

cat > "$ROOT/etc/initramfs-tools/scripts/init-top/00attestkey" <<'ITOP'
#!/bin/sh
PREREQ=""; case "$1" in prereqs) echo "$PREREQ"; exit 0;; esac
mkdir -p /etc/dropbear
rm -f /etc/dropbear/dropbear_*_host_key
/usr/bin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null 2>&1
ITOP

cat > "$ROOT/etc/initramfs-tools/scripts/init-premount/zzattest" <<IPRE
#!/bin/sh
PREREQ="dropbear"; case "\$1" in prereqs) echo "\$PREREQ"; exit 0;; esac
. /scripts/functions
modprobe sev-guest 2>/dev/null || true
mkdir -p /run/attest
/usr/bin/dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null \\
  | grep -m1 '^ssh-ed25519 ' | cut -d' ' -f1,2 > /run/attest/hostkey.pub
tr -d '\\n' < /run/attest/hostkey.pub | /usr/bin/sha512sum | cut -d' ' -f1 \\
  | /usr/bin/xxd -r -p > /run/attest/report_data.bin
/usr/local/bin/snpguest report /run/attest/report.bin /run/attest/report_data.bin \\
  > /run/attest/snpguest.log 2>&1 || true
/usr/local/bin/busybox httpd -p 0.0.0.0:$ATTEST_PORT -h /run/attest 2>/dev/null || true
IPRE

cat > "$ROOT/etc/initramfs-tools/scripts/local-bottom/zzswaproot" <<'LBOT'
#!/bin/sh
PREREQ=""; case "$1" in prereqs) echo "$PREREQ"; exit 0;; esac
. /scripts/functions
[ -b /dev/mapper/cryptroot ] || exit 0
# stop the attestation httpd so it cannot survive switch_root holding a mount ns
for p in $(pidof busybox 2>/dev/null); do
    grep -aq httpd "/proc/$p/cmdline" 2>/dev/null && kill "$p" 2>/dev/null
done
# replace the decoy /boot root (mounted by mountroot) with the decrypted LUKS root.
# Do NOT use `mountpoint` (absent from busybox-initramfs) or cryptroot gets stacked.
umount "$rootmnt" 2>/dev/null || umount -l "$rootmnt" 2>/dev/null || true
mount /dev/mapper/cryptroot "$rootmnt"
log_success_msg "swapped rootmnt -> /dev/mapper/cryptroot"
LBOT

chmod +x "$ROOT"/etc/initramfs-tools/hooks/zzattest \
         "$ROOT"/etc/initramfs-tools/scripts/init-top/00attestkey \
         "$ROOT"/etc/initramfs-tools/scripts/init-premount/zzattest \
         "$ROOT"/etc/initramfs-tools/scripts/local-bottom/zzswaproot
echo "==> attested-initramfs hooks installed into $ROOT"
