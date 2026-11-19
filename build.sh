#!/bin/bash
# Builds Katapult and Klipper for both boards of the QIDI Q1 Pro (on the
# printer, or on any Debian with the packages below) from the commits in
# SOURCES, with the configs of QIDI_Q1_Pro-Config.
# Result: the images in firmware/ and firmware/SHA256SUMS.
#
#   sudo apt install build-essential git python3 gcc-arm-none-eabi \
#       binutils-arm-none-eabi libnewlib-arm-none-eabi
#   ./build.sh
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
WORK=$HERE/build
OUT=$HERE/firmware
# shellcheck source=SOURCES
. "$HERE/SOURCES"

for tool in make gcc g++ git python3 arm-none-eabi-gcc; do
	command -v "$tool" >/dev/null || { echo "build.sh: $tool not found (see the packages above)" >&2; exit 1; }
done

# checkout <name> <repo> <ref>: $WORK/<name> at exactly that commit
checkout() {
	if [ ! -d "$WORK/$1/.git" ]; then
		mkdir -p "$WORK"
		git clone -q "$2" "$WORK/$1"
	fi
	git -C "$WORK/$1" fetch -q origin "$3" 2>/dev/null || git -C "$WORK/$1" fetch -q origin
	git -C "$WORK/$1" checkout -q --detach "$3"
	git -C "$WORK/$1" clean -q -fdx
}

# build <source name> <config> <build name>: out/ of the build in $WORK/<build name>
build() {
	rm -rf "${WORK:?}/$3"
	cp -r "$WORK/$1" "$WORK/$3"
	cp "$CONFIGS/$2" "$WORK/$3/.config"
	make -C "$WORK/$3" olddefconfig >/dev/null
	make -C "$WORK/$3" -j"$(nproc)" >/dev/null
	# the config must survive olddefconfig: no option of it is dropped
	grep -E "^CONFIG_" "$CONFIGS/$2" | while read -r line; do
		grep -qxF "$line" "$WORK/$3/.config" || { echo "build.sh: $2: $line is not in the result" >&2; exit 1; }
	done
}

# put <name in firmware/> <build name> <file of the build>
put() { cp "$WORK/$2/out/$3" "$OUT/$1"; }

checkout config "$CONFIG_REPO" "$CONFIG_REF"
CONFIGS=$WORK/configs
rm -rf "$CONFIGS"
mkdir "$CONFIGS"
cp "$WORK"/config/firmware/klipper/*.config "$WORK"/config/firmware/katapult/*.config "$CONFIGS/"
checkout klipper "$KLIPPER_REPO" "$KLIPPER_REF"
checkout katapult "$KATAPULT_REPO" "$KATAPULT_REF"

build katapult katapult-mainboard.config          katapult-mainboard
build katapult katapult-toolhead.config           katapult-toolhead
build klipper  firmware-mainboard-katapult.config klipper-mainboard
build klipper  firmware-toolhead-katapult.config  klipper-toolhead
build klipper  firmware-mainboard.config          klipper-mainboard-standalone
build klipper  firmware-toolhead.config           klipper-toolhead-standalone

# only what this script builds; firmware/display/ (the screen) is kept
rm -rf "$OUT/katapult" "$OUT/klipper" "$OUT/BUILD-INFO" "$OUT/SHA256SUMS"
mkdir -p "$OUT/katapult" "$OUT/klipper/standalone" "$OUT/klipper/katapult"
# qd_mcu.bin: the name QIDI's bootloader reads from the microSD card
put katapult/qd_mcu.bin                       katapult-mainboard           katapult.bin
put katapult/toolhead-katapult.uf2            katapult-toolhead            katapult.uf2
put katapult/toolhead-katapult.withclear.uf2  katapult-toolhead            katapult.withclear.uf2
put klipper/standalone/qd_mcu.bin             klipper-mainboard-standalone klipper.bin
put klipper/standalone/toolhead-klipper.uf2   klipper-toolhead-standalone  klipper.uf2
put klipper/katapult/mainboard-klipper.bin    klipper-mainboard            klipper.bin
put klipper/katapult/toolhead-klipper.bin     klipper-toolhead             klipper.bin
find "$OUT" -type f -exec chmod 644 {} +

{
	echo "klipper  $KLIPPER_REF"
	echo "katapult $KATAPULT_REF"
	arm-none-eabi-gcc --version | head -n 1
} > "$OUT/BUILD-INFO"
(cd "$OUT" && find . -type f ! -name SHA256SUMS | sort | sed 's|^\./||' | xargs sha256sum > SHA256SUMS)
cat "$OUT/BUILD-INFO"
