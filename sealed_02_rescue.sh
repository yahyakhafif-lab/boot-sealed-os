#!/bin/bash
# Runs LOCALLY. Installs dropbear + a pause hook on the running VM so the next
# boot holds in a RAM-only initramfs (dropbear on :22, /dev/vda unmounted), then
# powers the VM off. CC VMs cannot reboot from inside, so you Start it from the
# Verda console. Same flow as boot_custom_os/01_setup_initramfs_ssh.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"
: "${REMOTE:?Edit .env and set REMOTE}"

echo "==> Installing dropbear-initramfs on $REMOTE"
ssh $SSH_OPTS "$REMOTE" "DEBIAN_FRONTEND=noninteractive apt-get install -y -q dropbear-initramfs"

echo "==> Configuring dropbear + networking"
ssh $SSH_OPTS "$REMOTE" "
  set -e
  mkdir -p /etc/dropbear/initramfs
  cp /root/.ssh/authorized_keys /etc/dropbear/initramfs/authorized_keys
  chmod 600 /etc/dropbear/initramfs/authorized_keys
  grep -q '^DEVICE=' /etc/initramfs-tools/initramfs.conf || echo 'DEVICE=eth0' >> /etc/initramfs-tools/initramfs.conf
  grep -q '^IP=' /etc/initramfs-tools/initramfs.conf     || echo 'IP=dhcp'    >> /etc/initramfs-tools/initramfs.conf"

echo "==> Installing init-premount/99-pause hook"
ssh $SSH_OPTS "$REMOTE" 'cat > /etc/initramfs-tools/scripts/init-premount/99-pause <<'"'"'HOOK'"'"'
#!/bin/sh
case "$1" in prereqs) echo "dropbear"; exit 0 ;; esac
log_begin_msg "RESCUE initramfs SSH active: port 22 open, /dev/vda not mounted"
while true; do sleep 3600; done
HOOK
chmod +x /etc/initramfs-tools/scripts/init-premount/99-pause'

echo "==> Rebuilding initrd with dropbear + pause hook"
ssh $SSH_OPTS "$REMOTE" "update-initramfs -u -k \$(uname -r) 2>&1 | tail -1"

echo "==> Powering off $REMOTE (sysrq)..."
echo "    CC VMs cannot reboot from inside, so a manual Start from Verda is required."
ssh $SSH_OPTS "$REMOTE" "nohup sh -c 'sleep 2 && echo o > /proc/sysrq-trigger' >/dev/null 2>&1 &" || true

cat <<'EOF'

>>> In the Verda console: once the VM is offline, Start it.
    Note: if the VM is already running, Shutdown it first, then Start it.

Waiting for rescue initramfs SSH (dropbear on port 22)...
EOF

for i in $(seq 1 120); do
  sleep 5
  if ssh -o ConnectTimeout=4 -o BatchMode=yes $SSH_OPTS "$REMOTE" true 2>/dev/null; then
    pid1=$(ssh -o ConnectTimeout=4 -o BatchMode=yes $SSH_OPTS "$REMOTE" "cat /proc/1/comm" 2>/dev/null || echo unknown)
    if [ "$pid1" = systemd ]; then
      echo "  ... PID 1 is 'systemd' (regular OS boot): Shutdown the VM from Verda and Start it again."
    else
      echo ""
      echo "==> $REMOTE is up in rescue initramfs mode (PID 1: $pid1)."
      echo "Next step:  ./sealed_03_flash.sh"
      exit 0
    fi
  else
    echo "  ... still waiting ($((i * 5))s), did you Start the VM from Verda?"
  fi
done

echo "ERROR: rescue SSH did not come up within 600 s." >&2
exit 1
