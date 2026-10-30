#!/bin/bash
# One-shot sagit packaging: kernel -> ADT -> payload -> Android boot image.
#
#   tools/build-sagit-boot.sh xnu/out/kernel.development.sweet [RAM]
#
# RAM: 6 (default) or 4 for the 4GB Mi 6 variant.
# Requires python3 and an aarch64 cross compiler (aarch64-linux-gnu-gcc) or Zig.
# Produces out/sagit.adt, out/sagit-payload.bin, out/shim-sagit-xnu.img and
# an unpacked copy in out/check-sagit for independent comparison.
set -euo pipefail
cd "$(dirname "$0")/.."

KERNEL=${1:?usage: tools/build-sagit-boot.sh KERNEL.fat [4|6]}
RAM=${2:-6}
case "$RAM" in 4|6) ;; *) echo "RAM must be 4 or 6" >&2; exit 1;; esac
[ -f "$KERNEL" ] || { echo "no kernel: $KERNEL" >&2; exit 1; }

PY=python3
command -v "$PY" >/dev/null || PY=python
mkdir -p out

DEFAULT_CMDLINE='debug=0xc serial=3 cpus=4 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweetfb_sagit=1 sweettouch=0 sweetkeys=0 sagittouchdiag=1 sagittouch=1 sagittouchhid=1 sagittouchreset=1'
CMDLINE=${CMDLINE:-$DEFAULT_CMDLINE}
case "$CMDLINE" in *cpus=*) ;; *) echo "CMDLINE must include cpus=N" >&2; exit 1;; esac

echo "[1/4] ADT (sagit, ${RAM}GB)"
$PY tools/mkadt.py out/sagit.adt --sagit --ram "$RAM"

echo "[2/4] payload (${KERNEL})"
$PY tools/mkpayload.py "$KERNEL" out/sagit.adt out/sagit-payload.bin \
	--check-sagit-cpus --max-payload-size 0xE00000 \
	--cmdline "$CMDLINE"

echo "[3/4] shim + boot image"
PLATFORM=sagit bash shim/build.sh out/sagit-payload.bin

echo "[4/4] verify"
$PY tools/unpack_bootv2.py out/shim-sagit-xnu.img out/check-sagit
cmp out/check-sagit/ramdisk out/sagit-payload.bin
sha256sum out/shim-sagit-xnu.img

cat <<'EOF'

Next (temporary boot first, never flash without a verified backup):
  fastboot devices
  fastboot getvar product          # must print sagit
  fastboot boot out/shim-sagit-xnu.img
EOF
