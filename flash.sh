#!/bin/bash
# Flashes a board of the QIDI Q1 Pro from the images in firmware/. Run it on the printer.
#
#   ./flash.sh mainboard|toolhead|display [-n] [-f] [FILE]
#
#   mainboard   Klipper for the STM32F401 (/dev/ttyS0) through Katapult
#   toolhead    Klipper for the RP2040 (/dev/ttyS2) through Katapult
#   display     the screen firmware, with LibreScreen's main.py --flash-screen
#   -n          only print what would be done
#   -f          flash even if Moonraker says a print is running or paused
#   FILE        another image than the one in firmware/
#
# Klipper (mainboard, toolhead): Katapult must already be on the board
# (README.md). Klipper is stopped for the time of the flashing and started
# again at the end. Other settings (environment):
#   KATAPULT_DIR=~/katapult  LIBRESCREEN_DIR=~/LibreScreen  KLIPPER_SERVICE=klipper
#   LIBRESCREEN_SERVICE=librescreen  FLASH_TIMEOUT=1800 (screen, seconds)
#   MOONRAKER=http://localhost:7125
#   DEVICE=/dev/...  (instead of the port of the board)  BAUD=250000
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
KATAPULT_DIR=${KATAPULT_DIR:-$HOME/katapult}
LIBRESCREEN_DIR=${LIBRESCREEN_DIR:-$HOME/LibreScreen}
LIBRESCREEN_SERVICE=${LIBRESCREEN_SERVICE:-librescreen}
FLASH_TIMEOUT=${FLASH_TIMEOUT:-1800}
KLIPPER_SERVICE=${KLIPPER_SERVICE:-klipper}
BAUD=${BAUD:-250000}
MOONRAKER=${MOONRAKER:-http://localhost:7125}

usage() {
	sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

TARGET=${1:-}
[ -n "$TARGET" ] || usage
shift
DRY=false
FORCE=false
FILE=
while [ $# -gt 0 ]; do
	case "$1" in
	-n) DRY=true ;;
	-f) FORCE=true ;;
	-h | --help) usage ;;
	-*) usage ;;
	*) FILE=$1 ;;
	esac
	shift
done

# run <command...>: prints it, runs it unless -n
run() {
	echo "+ $*"
	$DRY || "$@"
}

as_root() {
	if [ "$(id -u)" -eq 0 ]; then run "$@"; else run sudo "$@"; fi
}

case "$TARGET" in
mainboard)
	DEVICE=${DEVICE:-/dev/ttyS0}
	FILE=${FILE:-$HERE/firmware/klipper/katapult/mainboard-klipper.bin}
	;;
toolhead)
	DEVICE=${DEVICE:-/dev/ttyS2}
	FILE=${FILE:-$HERE/firmware/klipper/katapult/toolhead-klipper.bin}
	;;
display)
	FILE=${FILE:-$HERE/firmware/display/display.tft}
	;;
*)
	usage
	;;
esac

[ -f "$FILE" ] || { echo "flash.sh: $FILE is not a file" >&2; exit 1; }

# The print state from Moonraker: printing, paused, standby, complete, ... or
# "unavailable" when Moonraker answered that Klipper is not ready (nothing can
# be printing), or nothing when there is no usable answer (Moonraker is down or
# stuck, an error page, something that is not JSON).
print_state() {
	curl -s -m 5 "$MOONRAKER/printer/objects/query?print_stats" 2>/dev/null |
		python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
    if "error" in d:
        print("unavailable")
    else:
        print(d["result"]["status"]["print_stats"]["state"])
except Exception:
    pass' 2>/dev/null || true
}

state=$(print_state || true)

case "$state" in
printing | paused)
	if $FORCE; then
		echo "flash.sh: the printer is $state, flashing anyway (-f)" >&2
	else
		echo "flash.sh: the printer is $state. Stop the print first, or use -f to flash anyway." >&2
		exit 1
	fi
	;;
'')
	# no answer: with Klipper stopped nothing can be printing (e.g. a board
	# without firmware); a running Klipper behind a Moonraker that does not
	# answer well may be printing
	if systemctl is-active --quiet "$KLIPPER_SERVICE"; then
		if $FORCE; then
			echo "flash.sh: $KLIPPER_SERVICE runs but Moonraker does not answer, flashing anyway (-f)" >&2
		else
			echo "flash.sh: $KLIPPER_SERVICE runs but Moonraker at $MOONRAKER gives no usable answer, so a" >&2
			echo "flash.sh: print may be running. Restart moonraker, or use -f to flash anyway." >&2
			exit 1
		fi
	else
		echo "flash.sh: $KLIPPER_SERVICE is not running, so nothing is printing"
	fi
	;;
*)
	echo "flash.sh: print state: $state"
	;;
esac

if [ "$TARGET" = display ]; then
	MAIN=$LIBRESCREEN_DIR/main.py
	[ -f "$MAIN" ] || { echo "flash.sh: $MAIN not found (LIBRESCREEN_DIR)" >&2; exit 1; }

	# The service holds the screen's serial port; started again on every exit path.
	restart_librescreen() { as_root systemctl start "$LIBRESCREEN_SERVICE" || true; }
	as_root systemctl stop "$LIBRESCREEN_SERVICE"
	trap restart_librescreen EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM HUP

	status=0
	export PYTHONDONTWRITEBYTECODE=1
	run timeout --signal=INT --kill-after=10s "$FLASH_TIMEOUT" \
		python3 -u "$MAIN" --flash-screen "$FILE" || status=$?
	case "$status" in
	0) if $DRY; then echo "flash.sh: display: nothing flashed (-n)"; else echo "flash.sh: firmware transfer acknowledged in full"; fi ;;
	130 | 143)
		echo "flash.sh: interrupted. The screen is likely stuck in download mode;" >&2
		echo "flash.sh: power-cycle the printer before the next flashing attempt." >&2
		;;
	*)
		echo "flash.sh: flashing failed (status $status)." >&2
		echo "flash.sh: if the transfer was cut off, power-cycle the printer before the next attempt." >&2
		;;
	esac
	exit "$status"
fi

FLASHTOOL=$KATAPULT_DIR/scripts/flashtool.py
[ -f "$FLASHTOOL" ] || { echo "flash.sh: $FLASHTOOL not found (KATAPULT_DIR)" >&2; exit 1; }
[ -e "$DEVICE" ] || $DRY || { echo "flash.sh: $DEVICE does not exist (DEVICE)" >&2; exit 1; }
# pyserial is in Klipper's environment
PYTHON=$HOME/klippy-env/bin/python3
[ -x "$PYTHON" ] || PYTHON=python3

restart_klipper() { as_root systemctl start "$KLIPPER_SERVICE" || true; }
as_root systemctl stop "$KLIPPER_SERVICE"
trap restart_klipper EXIT

# Klipper on the board reboots into Katapult; a board that is in Katapult
# already has nothing to answer, so a failure here is not fatal.
run "$PYTHON" "$FLASHTOOL" -r -d "$DEVICE" -b "$BAUD" ||
	echo "flash.sh: no bootloader request answered, trying Katapult directly" >&2
$DRY || sleep 2
run "$PYTHON" "$FLASHTOOL" -d "$DEVICE" -b "$BAUD" -f "$FILE"
if $DRY; then echo "flash.sh: $TARGET: nothing flashed (-n)"; else echo "flash.sh: $TARGET done"; fi
