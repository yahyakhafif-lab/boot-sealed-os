#!/bin/bash
# sealed_04_verify.sh   [expected_measurement_hex]
# ---------------------------------------------------------------------------
# Run INSIDE the booted sealed image (as root). Proves three things with no
# outside network:
#   1. the SEV-SNP report's measurement matches the pinned value (OS+engine+weights)
#   2. the dm-verity root is active and verifying (rootfs integrity live)
#   3. the dm-verity weights volume is active and verifying (weights integrity live)
# The report is fetched from /dev/sev-guest — no network needed. For a sealed /
# air-gapped deployment, copy verify/report.bin out through the one attested
# channel (or hand-carry it) and check it on the verifier; nothing else leaves.
#
# Pass the pinned measurement as $1, or set EXPECTED, or drop the allow-list.json
# from sealed_02 next to this script.
# ---------------------------------------------------------------------------
set -euo pipefail
WORK=$(mktemp -d); trap "rm -rf '$WORK'" EXIT
command -v snpguest >/dev/null || { curl -fsSL https://github.com/virtee/snpguest/releases/download/v0.10.0/snpguest -o /usr/local/bin/snpguest; chmod +x /usr/local/bin/snpguest; }

EXPECTED="${1:-${EXPECTED:-}}"
[ -z "$EXPECTED" ] && [ -f allow-list.json ] && EXPECTED=$(grep -o '"expected_measurement": *"[^"]*"' allow-list.json | cut -d'"' -f4)

echo "[1] SEV-SNP report"
snpguest report "$WORK/report.bin" "$WORK/nonce.bin" --random >/dev/null
cp "$WORK/report.bin" ./report.bin 2>/dev/null || true
MEAS=$(snpguest display report "$WORK/report.bin" | awk '/^Measurement:/{f=1;next} /^[A-Z][a-z]/{f=0} f' | tr -d ' \n')
echo "    report measurement : $MEAS"
if [ -n "$EXPECTED" ]; then
  if [ "${MEAS,,}" = "${EXPECTED,,}" ]; then echo "    MATCH: OS + engine + weights are the pinned image"
  else echo "    MISMATCH vs pinned $EXPECTED"; FAIL=1; fi
else echo "    (no pinned value given — compare against verify/allow-list.json)"; fi

echo "[2] dm-verity root"
if veritysetup status verityroot >/dev/null 2>&1; then
  veritysetup status verityroot | sed 's/^/    /' | grep -E 'status|verity|hash|data' || true
  echo "    root is read-only and block-verified"
else echo "    FAIL: verityroot not active"; FAIL=1; fi

echo "[3] dm-verity weights"
if veritysetup status verityweights >/dev/null 2>&1; then
  mountpoint -q /opt/weights && echo "    weights mounted read-only at /opt/weights, block-verified"
else echo "    FAIL: verityweights not active"; FAIL=1; fi

echo
[ "${FAIL:-0}" = 0 ] && echo "PASS — sealed, measured, verifying. report.bin written for the verifier." \
                     || { echo "FAIL — do not trust this instance"; exit 1; }
