# Sealed confidential-inference image

A minimal, **reproducible** image that boots a confidential VM (AMD SEV-SNP) whose root
filesystem is **encrypted at rest (LUKS2)**, **integrity-measured (dm-verity)**, and
**decrypted only after remote attestation**. It is built from a clean public Ubuntu cloud
image — not a snapshot — so the launch measurement can be reconstructed from documented
inputs. The GPU driver, inference engine and model weights are **optional inputs you
supply** (see `.env_sample`); with none set you get the minimal sealed OS.

## How it is sealed

```
launch measurement = OVMF + kernel + initrd + cmdline      (signed by the AMD PSP)
                                    └─ the initrd carries the dm-verity ROOT HASH
                                         └─ which covers the whole read-only rootfs
                                            (OS + driver + engine + weights)
```

Boot flow: measured direct-kernel boot → the initramfs generates a **per-boot** SSH host
key, binds its hash into a SEV-SNP report (`REPORT_DATA`) and serves that report → a remote
**verifier** checks the measurement against a pinned allow-list *and* that the report binds
the key it is talking to, then releases the LUKS passphrase → `luksOpen` → `veritysetup
open` → read-only root → the OS boots. One altered block fails dm-verity; a wrong
measurement never receives the key.

## Files

| File | Runs on | Purpose |
|---|---|---|
| `.env_sample` | — | configuration template — `cp .env_sample .env` and edit |
| `sealed_build.sh` | build host (root) | builds `sealed-image.img` and exports `verify/` (kernel, initrd, cmdline, root hash, luks uuid) |
| `sealed_initramfs.sh` | helper | installs the attest-then-unlock initramfs into the rootfs; **called by `sealed_build.sh`** |
| `sealed_01_measure.sh` | build host | computes the expected SNP measurement from `verify/` + the pinned OVMF → `verify/allow-list.json` (the pin) |
| `sealed_02_rescue.sh` | control host | arms a rescue initramfs on the target instance so its boot disk can be overwritten |
| `sealed_03_flash.sh` | control host | streams the image onto the instance's disk from an attached volume (no network transfer) |
| `sealed_04_verify.sh` | inside the VM | post-boot check: SNP report vs the pin + live dm-verity status |

## Build host

`sealed_build.sh` must run on a **Linux x86_64 machine with root**, it uses loop devices,
dm-crypt, dm-verity and chroot (none of which exist on macOS) and produces an amd64 image,
so an Apple-Silicon Mac cannot build it. You also need **two disks**: the flash **target**
(the instance's OS disk) and a **second volume** that holds the build inputs and the output
image — you can't flash the disk the image itself lives on. Size the volume ~60G for a
minimal image, ~200G with engine + weights baked.

**Trust boundary.** The build is the only moment the model weights exist in plaintext.
Build somewhere you trust that: either your own environment (then ship only the sealed
image), or a Verda **CC instance**, where the plaintext lives in SEV-SNP-encrypted RAM —
keep `WEIGHTS_SRC` in `tmpfs` so only the LUKS-encrypted image ever touches the volume.

**Building on a CC CPU instance.** The build needs CPU/RAM/disk, **not a GPU**, so a cheaper
CPU-only CC instance is an ideal builder and still gives the encrypted-RAM trust boundary:
- Bake the driver with `DRIVER_INSTALL_CMD` (apt-install the matching NVIDIA open driver in
  the image chroot — building the module needs no GPU), since `DRIVER_COPY` has nothing to
  copy on a GPU-less host.
- Set `VCPUS` and `CMDLINE` to the **GPU target's** values — that is what the image will
  boot with, and what the measurement must be computed against — not the builder's.
- Flow: build on the CC CPU instance → move the volume (or copy the image) to the GPU CC
  instance → `sealed_02_rescue` + `sealed_03_flash` there → boot + attest-unlock.

## Steps

```bash
# 0. configure
cp .env_sample .env && $EDITOR .env          # keys, sizes, UUIDs, optional driver/engine/weights

# 1. build the sealed image            [build host, root — needs spare disk]
sudo ./sealed_build.sh
#    -> sealed-image.img  + verify/{vmlinuz,initrd.img,cmdline.txt,rootfs_roothash,luks_uuid}

# 2. pin the expected measurement      [build host — needs sev-snp-measure + the pinned OVMF]
OVMF_PATH=/path/to/OVMF.amdsev.fd VCPUS=<n> ./sealed_01_measure.sh
#    -> verify/allow-list.json  (load this into your verifier)

# 3. arm rescue on the target          [control host]
./sealed_02_rescue.sh
#    then, in the cloud console: Shutdown -> Start  (CC VMs cannot reboot from inside)
#    -> the instance pauses in a rescue initramfs

# 4. flash                             [control host, instance in rescue]
./sealed_03_flash.sh
#    then, in the console: Start
#    -> boots into the attest-unlock initramfs (dropbear + SNP report on :ATTEST_PORT)

# 5. attest & release the key   [control host / verifier — MANUAL: run these by hand]
#    This step is NOT scripted. In production your key broker / Vault automates exactly
#    these checks and holds the passphrase. Run them yourself:
curl -s http://<instance>:9000/report.bin  -o report.bin
curl -s http://<instance>:9000/hostkey.pub -o hostkey.pub
#    check the report against the pin — BOTH lines must print MATCH:
python3 - report.bin hostkey.pub verify/allow-list.json <<'EOF'
import sys, json, hashlib
rpt = open(sys.argv[1], 'rb').read()
hk  = open(sys.argv[2], 'rb').read().replace(b'\n', b'')
exp = json.load(open(sys.argv[3]))['expected_measurement'].upper()
print('measurement', 'MATCH' if rpt[0x90:0x90+48].hex().upper() == exp else 'MISMATCH')
print('endpoint   ', 'MATCH' if rpt[0x50:0x50+64].hex().upper() == hashlib.sha512(hk).hexdigest().upper() else 'MISMATCH')
EOF
#    ONLY if both say MATCH, release the passphrase over the initramfs dropbear:
printf '%s' '<LUKS_PASS>' | ssh root@<instance> 'cryptroot-unlock'
#    -> root unlocks (LUKS -> dm-verity), the sealed OS boots

# 6. verify (optional)                 [inside the VM]
./sealed_04_verify.sh <expected-measurement-hex>
```

## Optional inputs (set in `.env`)

| Variable | Effect |
|---|---|
| `DRIVER_COPY=1` | bake the GPU driver already on the build host (matching the image's kernel) |
| `DRIVER_INSTALL_CMD="..."` | alternative: install the driver inside the image chroot |
| `ENGINE_SRC=<dir>` | bake a daemonless engine payload (podman image store + CDI spec + `run.sh`) → `/opt/engine` |
| `WEIGHTS_SRC=<dir>` | bake model weights → `/opt/weights` |
| `ENABLE_SSHD=1` | sshd on the read-only root, using ephemeral host keys generated to tmpfs at boot |
| `ENABLE_ENGINE_SERVICE=1` | auto-start the engine at boot; leave `0` to launch it by hand over SSH |

## Notes

- The root is **read-only** (dm-verity). Everything writable (KV cache, logs, container
  layers) is tmpfs — never the measured disk.
- **No in-guest reboot** on a CC VM: always Shutdown → Start from the console.
- **Any** change to OS, driver, engine, weights, kernel or firmware changes the
  measurement — rebuild, re-run `sealed_01_measure.sh`, re-pin, re-flash. That is the point.
- The measured `cmdline` has **no** `initrd=initrd` prefix (the hypervisor adds it to
  `/proc/cmdline` but it is not in the measured append), and `root=UUID` is the **boot**
  partition — see `.env_sample`.
- Running the engine by hand (`ENABLE_ENGINE_SERVICE=0`): ensure the NVIDIA device nodes
  exist (`modprobe nvidia_modeset nvidia_uvm`; create `/dev/nvidia-modeset` if missing),
  set the GPU CC ready state (`nvidia-smi conf-compute -srs 1`), then run `/opt/engine/run.sh`.
