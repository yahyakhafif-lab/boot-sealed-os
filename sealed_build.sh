#!/bin/bash
# sealed_build.sh — build a minimal, reproducible, sealed confidential-inference image.
# ---------------------------------------------------------------------------
# Builds a confidential-inference appliance image that is, in one read-only volume:
#   - LUKS2 ENCRYPTED        (confidentiality at rest; key released only by attestation)
#   - dm-verity MEASURED     (integrity; root hash folded into the launch measurement)
#   - attest-then-unlock     (initramfs binds a per-boot key into an SNP report; a
#                             remote verifier checks the measurement and releases the
#                             LUKS passphrase; nothing is decrypted until that passes)
#
# The base is a CLEAN public Ubuntu cloud image — NOT a snapshot of any running box —
# so the measurement is reproducible from documented inputs. The GPU driver, the
# inference engine and the model weights are NOT hardcoded: they are OPTIONAL inputs
# you reference from .env, exactly as a customer would (see README). With none set you
# get the minimal sealed OS + the daemonless-engine scaffolding, ready to fill in.
#
# Layering at rest:  partition -> LUKS2 -> (decrypted) ext4 -> dm-verity over it.
# Boot:  measured direct kernel boot -> initramfs attests -> verifier releases the LUKS
#        passphrase -> luksOpen -> veritysetup open -> read-only root -> switch_root.
#
# Optional inputs (set in .env; leave unset for the minimal base):
#   ENGINE_SRC   dir baked to /opt/engine (store/ cdi/ storage.conf run.sh); enables
#                inference.service. See sealed_engine_prepare.sh for a daemonless payload.
#   WEIGHTS_SRC  dir baked to /opt/weights (the model). Bound into the engine read-only.
#   DRIVER_INSTALL_CMD  a shell command run inside the image's chroot to install the GPU
#                driver (e.g. the NVIDIA open driver matching your CC GPU). Reproducible.
#
# Requires: source .env. Run as root. Needs: wget qemu-img veritysetup cryptsetup
#           sgdisk rsync mkfs.ext4 mkfs.vfat chroot.
# ---------------------------------------------------------------------------
set -e
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"
: "${SSH_KEY:?set SSH_KEY}"; : "${LUKS_PASS:?set LUKS_PASS}"
: "${BUILD_DIR:?set BUILD_DIR (staging; on a volume with room for the base, e.g. the attached volume)}"
: "${BOOT_FS_UUID:?set BOOT_FS_UUID}"; : "${ESP_VOLID:?set ESP_VOLID}"; : "${CMDLINE:?set CMDLINE}"
for c in veritysetup cryptsetup sgdisk rsync mkfs.ext4 mkfs.vfat; do
  command -v "$c" &>/dev/null || { echo "missing: $c" >&2; exit 1; }
done
# wget + qemu-img are only needed to fetch/convert the cloud image; if the raw is already
# cached (e.g. an in-place rebuild) they are not required.

CODENAME="${CODENAME:-resolute}"                      # Ubuntu 26.04 LTS (matches the CC base)
IMAGENAME="$BUILD_DIR/${CODENAME}-server-cloudimg-amd64.img"
RAWNAME="$BUILD_DIR/server-raw.img"
APPNAME="${APPNAME:-$BUILD_DIR/sealed-image.img}"     # the output image (can be on another volume)
DATA_MB=${DATA_MB:-12288}    # LUKS data partition. Minimal base fits in ~12G; raise it
                             # when you bake an engine + weights (see README sizing note).
VHASH_MB=${VHASH_MB:-256}    # dm-verity hash tree (~1% of DATA)
BIOS_MB=4; ESP_MB=128; BOOT_MB=1024
MODEL_MOUNT="${MODEL_MOUNT:-/opt/weights}"
SNPGUEST="$SCRIPT_DIR/snpguest"
STAGE="$BUILD_DIR/stage"
VER="$BUILD_DIR/verify"
CBM="${CB_MNT:-/mnt}"   # base for scratch mount points; set CB_MNT=/run for a read-only build host

SLOOP=""; TLOOP=""
cleanup(){ set +e
  for m in ${CBM}/cb_app ${CBM}/cb_src ${CBM}/cb_crypt; do umount -R "$m" 2>/dev/null; done
  [ -n "$STAGE" ] && for d in proc sys dev/pts dev run; do umount -lR "$STAGE/$d" 2>/dev/null; done
  veritysetup close cb_verity 2>/dev/null
  cryptsetup close cb_crypt 2>/dev/null
  [ -n "$TLOOP" ] && losetup -d "$TLOOP" 2>/dev/null
  [ -n "$SLOOP" ] && losetup -d "$SLOOP" 2>/dev/null; }
trap cleanup EXIT
modprobe dm-verity 2>/dev/null || true; modprobe dm-crypt 2>/dev/null || true
mkdir -p ${CBM}/cb_app ${CBM}/cb_src ${CBM}/cb_crypt "$BUILD_DIR"
[ -x "$SNPGUEST" ] || { curl -fsSL https://github.com/virtee/snpguest/releases/download/v0.10.0/snpguest -o "$SNPGUEST"; chmod +x "$SNPGUEST"; }

# run a command inside the staged rootfs with /proc /sys /dev /run bound + DNS
chroot_run(){
  for d in proc sys dev dev/pts run; do mkdir -p "$STAGE/$d"; mount --bind "/$d" "$STAGE/$d"; done
  cp -f /etc/resolv.conf "$STAGE/etc/resolv.conf" 2>/dev/null || true
  chroot "$STAGE" env KVER="$KVER" DEBIAN_FRONTEND=noninteractive /bin/bash -eu -c "$1"
  umount -R "$STAGE/proc" "$STAGE/sys" "$STAGE/dev" "$STAGE/run" 2>/dev/null || true
}

# Copy the GPU driver that is ALREADY installed on this build host into the image,
# matching the baked kernel ($KVER). This is the reproducible path for a customer whose
# base image already ships the driver (e.g. Verda's CC image): no DKMS build in a chroot.
# Takes the exact file set from the nvidia dpkg packages + the DKMS-built kernel modules.
copy_driver_from_host(){
  echo "[driver] copying host NVIDIA driver into the image (kernel $KVER)"
  local md="/lib/modules/$KVER/updates/dkms"
  if ls "$md"/nvidia*.ko* >/dev/null 2>&1; then
    install -d "$STAGE$md"; cp -a "$md"/nvidia*.ko* "$STAGE$md"/
  else
    echo "  WARN: no nvidia DKMS modules for $KVER on the build host" >&2
  fi
  local pkgs; pkgs=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E 'nvidia|cuda-drivers' || true)
  if [ -n "$pkgs" ]; then
    echo "  driver packages (dpkg): $(echo "$pkgs" | wc -l)"
    dpkg -L $pkgs 2>/dev/null | sort -u | while read -r f; do
      if [ -f "$f" ] || [ -L "$f" ]; then install -d "$STAGE$(dirname "$f")" 2>/dev/null; cp -a "$f" "$STAGE$f" 2>/dev/null || true; fi
    done
  else
    # fallback (host has the driver as COPIED FILES, not apt packages — e.g. a prior sealed
    # rootfs): copy the known NVIDIA + container-toolkit footprint by glob.
    echo "  driver packages: none in dpkg -> copying by file globs"
    for g in \
      /usr/bin/nvidia-* \
      /usr/lib/x86_64-linux-gnu/libnvidia-*.so* \
      /usr/lib/x86_64-linux-gnu/libcuda.so* /usr/lib/x86_64-linux-gnu/libnvcuvid.so* \
      /usr/lib/x86_64-linux-gnu/libnvoptix.so* /usr/lib/x86_64-linux-gnu/libnvrtc*.so* \
      /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so* /usr/lib/x86_64-linux-gnu/libEGL_nvidia.so* \
      /usr/lib/x86_64-linux-gnu/libGLESv1_CM_nvidia.so* /usr/lib/x86_64-linux-gnu/libGLESv2_nvidia.so* \
      /usr/lib/x86_64-linux-gnu/vdpau/libvdpau_nvidia.so* \
      /usr/lib/x86_64-linux-gnu/gbm/nvidia-drm_gbm.so \
      /usr/lib/x86_64-linux-gnu/nvidia/xorg/* \
      /etc/nvidia-container-runtime /etc/cdi \
      /etc/vulkan/icd.d/nvidia_icd.json /usr/share/vulkan/icd.d/nvidia_icd.json \
      /usr/share/egl /usr/share/glvnd \
      /lib/udev/rules.d/*nvidia* /usr/lib/udev/rules.d/*nvidia* ; do
      for f in $g; do [ -e "$f" ] && { install -d "$STAGE$(dirname "$f")" 2>/dev/null; cp -a "$f" "$STAGE$f" 2>/dev/null || true; }; done
    done
  fi
  # authoritative: copy EVERY file the CDI spec references (its mount sources must exist in
  # the image or podman fails to start the container). This closes any glob gaps.
  if [ -f "${ENGINE_SRC:-/nonexistent}/cdi/nvidia.yaml" ]; then
    local cdi="$ENGINE_SRC/cdi/nvidia.yaml"
    grep -oE '/usr/[^ "]*|/lib/[^ "]*|/etc/[^ "]*' "$cdi" | sort -u | while read -r f; do
      [ -e "$f" ] && { install -d "$STAGE$(dirname "$f")" 2>/dev/null; cp -a "$f" "$STAGE$f" 2>/dev/null || true; }
    done
    # any CDI *mount* source still absent (e.g. optional vulkan/graphics configs this platform
    # does not ship) -> empty placeholder so the bind-mount cannot fail at container start
    grep -oE 'hostPath: [^ ]+' "$cdi" | awk '{print $2}' | sort -u | while read -r f; do
      [ -e "$STAGE$f" ] || { install -d "$STAGE$(dirname "$f")" 2>/dev/null; : > "$STAGE$f" 2>/dev/null || true; }
    done
  fi
  [ -d /lib/firmware/nvidia ] && { install -d "$STAGE/lib/firmware"; cp -a /lib/firmware/nvidia "$STAGE/lib/firmware/"; }  # GSP firmware (open driver)
  install -d "$STAGE/etc/modules-load.d"
  printf 'nvidia\nnvidia_uvm\nnvidia_modeset\n' > "$STAGE/etc/modules-load.d/nvidia.conf"
  chroot_run "depmod -a $KVER || true"
}

# Generate SSH host keys into tmpfs (/run) at every boot, so sshd works on the measured
# READ-ONLY root without baking any secret into the measurement. A oneshot creates the
# keys before sshd; a drop-in points sshd at them. Keys are fresh per boot (the endpoint's
# authenticity comes from attestation, not a pinned host key).
setup_tmpfs_sshd_keys(){
  echo "[sshd] tmpfs host-key generator + drop-in"
  cat > "$STAGE/etc/systemd/system/sealed-sshd-keys.service" <<'U'
[Unit]
Description=Generate ephemeral SSH host keys on tmpfs (sealed read-only root)
DefaultDependencies=no
After=local-fs.target systemd-tmpfiles-setup.service
Before=ssh.service ssh.socket
ConditionPathExists=!/run/sshd-keys/ssh_host_ed25519_key
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mkdir -p /run/sshd-keys
ExecStart=/usr/bin/ssh-keygen -q -t ed25519 -f /run/sshd-keys/ssh_host_ed25519_key -N ""
ExecStart=/usr/bin/ssh-keygen -q -t rsa -b 3072 -f /run/sshd-keys/ssh_host_rsa_key -N ""
[Install]
WantedBy=multi-user.target
U
  install -d "$STAGE/etc/ssh/sshd_config.d" "$STAGE/etc/systemd/system/ssh.service.d"
  cat > "$STAGE/etc/ssh/sshd_config.d/10-sealed.conf" <<'C'
HostKey /run/sshd-keys/ssh_host_ed25519_key
HostKey /run/sshd-keys/ssh_host_rsa_key
PermitRootLogin prohibit-password
C
  cat > "$STAGE/etc/systemd/system/ssh.service.d/10-sealed.conf" <<'C'
[Unit]
After=sealed-sshd-keys.service
Requires=sealed-sshd-keys.service
C
  # prefer the traditional daemon over socket activation (avoids a key-before-connect race)
  install -d "$STAGE/etc/systemd/system/multi-user.target.wants"
  ln -sf ../sealed-sshd-keys.service "$STAGE/etc/systemd/system/multi-user.target.wants/sealed-sshd-keys.service"
  ln -sf /lib/systemd/system/ssh.service "$STAGE/etc/systemd/system/multi-user.target.wants/ssh.service"
  rm -f "$STAGE/etc/systemd/system/sockets.target.wants/ssh.socket"
}

# Networking + boot hardening for a sealed single-disk READ-ONLY root:
#   - DHCP on eth0 via systemd-networkd directly (no netplan generate-at-boot on RO root)
#   - mask multipathd (hangs scanning the dm-crypt/dm-verity stack; no multipath here)
#   - cap unit start timeout so NO stray job can ever hang the boot
setup_networking_and_harden(){
  echo "[net] systemd-networkd DHCP on eth0 + mask multipathd + bounded timeouts"
  install -d "$STAGE/etc/systemd/network" "$STAGE/etc/systemd/system/multi-user.target.wants" \
            "$STAGE/etc/systemd/system/sockets.target.wants" "$STAGE/etc/systemd/system.conf.d"
  cat > "$STAGE/etc/systemd/network/10-eth0.network" <<'N'
[Match]
Name=eth0
[Network]
DHCP=yes
N
  rm -f "$STAGE"/etc/netplan/*.yaml 2>/dev/null || true
  ln -sf /lib/systemd/system/systemd-networkd.service "$STAGE/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
  ln -sf /lib/systemd/system/systemd-networkd.socket  "$STAGE/etc/systemd/system/sockets.target.wants/systemd-networkd.socket"
  rm -f "$STAGE/etc/resolv.conf"; printf 'nameserver 1.1.1.1\n' > "$STAGE/etc/resolv.conf"
  # mask services that hang or spam failures on a sealed single-disk READ-ONLY appliance
  for u in multipathd.service multipathd.socket \
           snapd.service snapd.socket snapd.seeded.service \
           unattended-upgrades.service chrony.service sysstat.service \
           nvidia-persistenced.service systemd-networkd-persistent-storage.service \
           e2scrub_reap.service; do
    ln -sf /dev/null "$STAGE/etc/systemd/system/$u"
  done
  printf '[Manager]\nDefaultTimeoutStartSec=30s\nDefaultTimeoutStopSec=15s\n' > "$STAGE/etc/systemd/system.conf.d/10-sealed-timeouts.conf"
}

# --- 1. clean cloud image -> raw -> loop-mount -> minimal customize -> stage rootfs ---
[ -f "$IMAGENAME" ] || wget -q -O "$IMAGENAME" "https://cloud-images.ubuntu.com/${CODENAME}/current/${CODENAME}-server-cloudimg-amd64.img"
[ -f "$RAWNAME" ]   || qemu-img convert -f qcow2 -O raw "$IMAGENAME" "$RAWNAME"
SLOOP=$(losetup --find --show -P "$RAWNAME"); udevadm settle 2>/dev/null || sleep 1
SRC_ROOT=""
for p in ${SLOOP}p*; do
  [ "$(blkid -o value -s TYPE "$p" 2>/dev/null)" = ext4 ] || continue
  mount "$p" ${CBM}/cb_src || continue
  if [ -e ${CBM}/cb_src/etc/os-release ] && [ -d ${CBM}/cb_src/etc/ssh ]; then SRC_ROOT="$p"; break; fi
  umount ${CBM}/cb_src
done
: "${SRC_ROOT:?no cloud root}"
install -d -m700 ${CBM}/cb_src/root/.ssh
printf '%s\n' "$SSH_KEY" > ${CBM}/cb_src/root/.ssh/authorized_keys; chmod 600 ${CBM}/cb_src/root/.ssh/authorized_keys
sed -i 's/#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' ${CBM}/cb_src/etc/ssh/sshd_config || true
mkdir -p ${CBM}/cb_src/etc/netplan
printf 'network:\n  version: 2\n  ethernets:\n    eth0: {dhcp4: true, critical: true}\n' > ${CBM}/cb_src/etc/netplan/01-netcfg.yaml
touch ${CBM}/cb_src/etc/cloud/cloud-init.disabled 2>/dev/null || true
: > ${CBM}/cb_src/etc/machine-id
rm -rf "$STAGE"; mkdir -p "$STAGE"
rsync -aHAX ${CBM}/cb_src/ "$STAGE"/
umount ${CBM}/cb_src; losetup -d "$SLOOP"; SLOOP=""
KVER=$(ls "$STAGE/lib/modules" | sort -V | tail -1); : "${KVER:?no kernel modules}"

# --- 2. sealing tooling the attest+unlock initramfs needs (minimal, documented) ---
INSTALL_PKGS="cryptsetup-initramfs dropbear-initramfs busybox xxd podman crun"
echo "[pkgs] $INSTALL_PKGS"
chroot_run "apt-get update -q && apt-get install -y -q $INSTALL_PKGS"

# optional GPU driver (customer input; NOT hardcoded). Two reproducible ways:
#   DRIVER_INSTALL_CMD="..."  run your pinned install command inside the image chroot, or
#   DRIVER_COPY=1             copy the driver already on this build host (matching $KVER).
if [ -n "${DRIVER_INSTALL_CMD:-}" ]; then
  echo "[driver] running DRIVER_INSTALL_CMD in the image chroot"
  chroot_run "$DRIVER_INSTALL_CMD"
fi
[ "${DRIVER_COPY:-0}" = 1 ] && copy_driver_from_host

# networking (systemd-networkd DHCP) + boot hardening (mask multipathd, bound timeouts)
setup_networking_and_harden

# --- 3. attest-unlock initramfs (proven), then overlay dm-verity hook + root swap ---
SNPGUEST_BIN="$SNPGUEST" bash "$SCRIPT_DIR/sealed_initramfs.sh" "$STAGE"
install -d "$STAGE/etc/verity" "$STAGE/etc/initramfs-tools/hooks"
cat > "$STAGE/etc/initramfs-tools/hooks/verity" <<'HK'
#!/bin/sh
PREREQ=""; case "$1" in prereqs) echo "$PREREQ"; exit 0;; esac
. /usr/share/initramfs-tools/hook-functions
copy_exec /usr/sbin/veritysetup /sbin
manual_add_modules dm_verity
mkdir -p "${DESTDIR}/etc/verity"; cp /etc/verity/root_hash "${DESTDIR}/etc/verity/root_hash"
HK
chmod +x "$STAGE/etc/initramfs-tools/hooks/verity"
# overwrite the proven zzswaproot to add verity ON TOP of the opened LUKS mapper
cat > "$STAGE/etc/initramfs-tools/scripts/local-bottom/zzswaproot" <<'LB'
#!/bin/sh
PREREQ=""; case "$1" in prereqs) echo "$PREREQ"; exit 0;; esac
. /scripts/functions
[ -b /dev/mapper/cryptroot ] || exit 0
for p in $(pidof busybox 2>/dev/null); do grep -aq httpd "/proc/$p/cmdline" 2>/dev/null && kill "$p" 2>/dev/null; done
modprobe dm_verity 2>/dev/null || true
RH="$(cat /etc/verity/root_hash)"
HASH="/dev/disk/by-partlabel/verityhash"
for i in $(seq 1 30); do [ -b "$HASH" ] && break; sleep 0.5; done
veritysetup open /dev/mapper/cryptroot verityroot "$HASH" "$RH" \
  || panic "dm-verity verification FAILED — refusing to boot"
umount "$rootmnt" 2>/dev/null || umount -l "$rootmnt" 2>/dev/null || true
mount -o ro /dev/mapper/verityroot "$rootmnt"
log_success_msg "swapped rootmnt -> verityroot (encrypted + measured)"
LB
chmod +x "$STAGE/etc/initramfs-tools/scripts/local-bottom/zzswaproot"

# read-only root fstab (passno 0 on the verity root — it is RO + integrity-checked, no fsck)
ESP_UUID=$(printf '%s' "$ESP_VOLID" | tr 'a-f' 'A-F'); ESP_UUID="${ESP_UUID:0:4}-${ESP_UUID:4:4}"
cat > "$STAGE/etc/fstab" <<F
/dev/mapper/verityroot / ext4 ro 0 0
F

# sshd that works on the measured read-only root (ephemeral host keys on tmpfs at boot)
[ "${ENABLE_SSHD:-1}" = 1 ] && setup_tmpfs_sshd_keys

# --- 4. daemonless-engine scaffolding (always present) + optional engine/weights ---
# The scaffolding is inert until an engine + weights are baked and the unit is enabled,
# so the minimal base boots clean. See README to fill these in as a customer.
install -d "$STAGE/opt/engine/cdi" "$STAGE/opt/engine/store" "$STAGE$MODEL_MOUNT"
if [ ! -f "$STAGE/opt/engine/run.sh" ]; then
  cat > "$STAGE/opt/engine/run.sh" <<'RUN'
#!/bin/sh
# Placeholder daemonless engine launcher. Replace by baking ENGINE_SRC (see README),
# which provides a run.sh that launches your engine read-only from /opt/engine/store
# with the GPU via CDI and weights bound from /opt/weights.
echo "no engine baked; set ENGINE_SRC at build time (README)"; exit 1
RUN
  chmod +x "$STAGE/opt/engine/run.sh"
fi
cat > "$STAGE/etc/systemd/system/inference.service" <<U
[Unit]
Description=Sealed daemonless inference engine
After=network-online.target
[Service]
ExecStartPre=-/usr/bin/nvidia-smi conf-compute -srs 1
Environment=WEIGHTS=$MODEL_MOUNT
ExecStart=/opt/engine/run.sh
Restart=on-failure
TemporaryFileSystem=/run/engine:rw,nosuid,nodev
[Install]
WantedBy=multi-user.target
U
# BAKE the engine into the measured volume when ENGINE_SRC is given; AUTO-START it at boot
# only when ENABLE_ENGINE_SERVICE=1. For a hands-on test you bake it but launch podman
# yourself over SSH, so leave the service disabled (default).
ENABLE_ENGINE=0
if [ -n "${ENGINE_SRC:-}" ] && [ -d "${ENGINE_SRC:-/nonexistent}" ]; then ENABLE_ENGINE=1; fi
ENABLE_ENGINE_SERVICE="${ENABLE_ENGINE_SERVICE:-0}"

# --- 5. partition the image ---
TOTAL=$(( BIOS_MB+ESP_MB+BOOT_MB+DATA_MB+VHASH_MB+64 ))
rm -f "$APPNAME"; truncate -s "${TOTAL}M" "$APPNAME"
sgdisk --clear \
  --new=1:0:+${BIOS_MB}M  --typecode=1:ef02 --change-name=1:bios \
  --new=2:0:+${ESP_MB}M   --typecode=2:ef00 --change-name=2:esp \
  --new=3:0:+${BOOT_MB}M  --typecode=3:8300 --change-name=3:boot \
  --new=4:0:+${DATA_MB}M  --typecode=4:8300 --change-name=4:cryptdata \
  --new=5:0:0             --typecode=5:8300 --change-name=5:verityhash "$APPNAME" >/dev/null
TLOOP=$(losetup --find --show -P "$APPNAME"); udevadm settle 2>/dev/null || sleep 1
mkfs.vfat -i "$ESP_VOLID" -n ESP "${TLOOP}p2" >/dev/null
mkfs.ext4 -q -F -U "$BOOT_FS_UUID" -L boot "${TLOOP}p3"

# --- 6. LUKS2 on p4, open, ext4, fill: staged root (+ optional engine/weights) ---
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --pbkdf argon2id "${TLOOP}p4" -
LUKS_UUID=$(cryptsetup luksUUID "${TLOOP}p4")
printf '%s' "$LUKS_PASS" | cryptsetup open "${TLOOP}p4" cb_crypt -
mkfs.ext4 -q -F -L root /dev/mapper/cb_crypt
mount /dev/mapper/cb_crypt ${CBM}/cb_crypt
echo "cryptroot UUID=$LUKS_UUID none luks,initramfs,discard" > "$STAGE/etc/crypttab"
if [ "$ENABLE_ENGINE_SERVICE" = 1 ]; then
  mkdir -p "$STAGE/etc/systemd/system/multi-user.target.wants"
  ln -sf ../inference.service "$STAGE/etc/systemd/system/multi-user.target.wants/inference.service"
fi
rsync -aHAX "$STAGE"/ ${CBM}/cb_crypt/
# large customer inputs go STRAIGHT into the measured volume (never duplicated in STAGE)
if [ "$ENABLE_ENGINE" = 1 ]; then
  echo "[bake] engine $ENGINE_SRC -> /opt/engine"
  rsync -aHAX "$ENGINE_SRC"/ ${CBM}/cb_crypt/opt/engine/
fi
if [ -n "${WEIGHTS_SRC:-}" ] && [ -d "${WEIGHTS_SRC:-/nonexistent}" ]; then
  echo "[bake] weights $WEIGHTS_SRC -> $MODEL_MOUNT"
  rsync -aHAX "$WEIGHTS_SRC"/ "${CBM}/cb_crypt$MODEL_MOUNT"/
fi
sync; umount ${CBM}/cb_crypt

# --- 7. dm-verity over the decrypted root -> root hash ---
ROOT_RH=$(veritysetup format /dev/mapper/cb_crypt "${TLOOP}p5" | awk '/Root hash/{print $3}')
echo "[verity] root hash $ROOT_RH"

# --- 8. build the measured initrd FROM staging (carries the root hash), onto /boot ---
printf '%s\n' "$ROOT_RH" > "$STAGE/etc/verity/root_hash"
chroot_run "rm -f /etc/dropbear/initramfs/dropbear_*_host_key 2>/dev/null || true
            update-initramfs -u -k \$KVER
            [ -e /boot/vmlinuz-\$KVER ] || { apt-get update -q; apt-get install -y -q --reinstall linux-image-\$KVER || true; }"
KIMG=""; for c in "$STAGE/boot/vmlinuz-$KVER" "$STAGE/usr/lib/modules/$KVER/vmlinuz" "${HOST_KERNEL:-}"; do [ -n "$c" ] && [ -e "$c" ] && { KIMG="$c"; break; }; done
: "${KIMG:?no kernel image for $KVER}"
mount "${TLOOP}p3" ${CBM}/cb_app
cp "$KIMG" ${CBM}/cb_app/vmlinuz; cp "$KIMG" ${CBM}/cb_app/vmlinuz-"$KVER"
cp "$STAGE/boot/initrd.img-$KVER" ${CBM}/cb_app/initrd.img; cp "$STAGE/boot/initrd.img-$KVER" ${CBM}/cb_app/initrd.img-"$KVER"
mkdir -p ${CBM}/cb_app/lib/systemd   # Verda marker: direct-boot /boot
sync; umount ${CBM}/cb_app

# --- 9. export verify/ for measurement + unlock ---
mkdir -p "$VER"
cp "$KIMG" "$VER/vmlinuz"; cp "$STAGE/boot/initrd.img-$KVER" "$VER/initrd.img"
echo "$KVER" > "$VER/kver"; echo "$LUKS_UUID" > "$VER/luks_uuid"; echo "$ROOT_RH" > "$VER/rootfs_roothash"
printf '%s\n' "$CMDLINE" > "$VER/cmdline.txt"

cryptsetup close cb_crypt; losetup -d "$TLOOP"; TLOOP=""
rm -rf "$STAGE"
trap - EXIT
echo
echo "Sealed image ready: $APPNAME ($(du -h "$APPNAME" | cut -f1))"
echo "  LUKS UUID: $LUKS_UUID   verity root hash: $ROOT_RH   KVER: $KVER"
echo "  engine baked: $([ "$ENABLE_ENGINE" = 1 ] && echo yes || echo 'no (scaffolding only)')   weights: $([ -n "${WEIGHTS_SRC:-}" ] && echo yes || echo no)"
echo "Next: sealed_01_measure.sh (expected measurement), then flash + console Start + attest-unlock."
