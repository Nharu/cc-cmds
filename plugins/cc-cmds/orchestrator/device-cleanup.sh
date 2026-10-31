#!/usr/bin/env bash
#
# device-cleanup.sh — remove the mobile devices one dispatch of a run made.
#
#   device-cleanup.sh <run id> <dispatch id|->
#
# The gate calls this as the `짝 정리` of a `사전 인가` row whose value is the
# reserved `기기 정리`: once per (dispatch id, row) unit at the stage's or the
# run's end, and once more at the run's end with dispatch `-` as the sweep of
# the whole run. It runs without a shell, from the run directory, under a
# deadline the gate puts on it.
#
# WHICH DEVICES. A device is this dispatch's when its name begins with
# `cc-<run id>-<dispatch id>-` and the rest of the name carries no `-`: an
# adopted segment id may itself contain `-`, so the prefix alone would let the
# cleanup of dispatch `A` take the devices of dispatch `A-fix`. Dispatch `-`
# takes every name that begins with `cc-<run id>-`. Nothing else is touched —
# no device of another run or session, no driver app.
#
#   simulators  `xcrun simctl list devices -j`, then `shutdown` and `delete`
#   emulators   every `emulator-<port>` of `adb devices` whose `emu avd name`
#               is chosen gets `emu kill`
#   AVDs        every chosen name of `emulator -list-avds` gets
#               `avdmanager delete avd -n`
#
# One line per device on stdout, TAB-separated:
#
#   <지움|못지움>\t<시뮬레이터|에뮬레이터|AVD>\t<id>\t<name>
#
# and one `도구없음\t<tool>` line per tool not on PATH.
#
# EXIT. 0 when every chosen device was removed or none was chosen; 1 when any
# chosen device could not be removed; 3 when none failed but at least one of
# xcrun, adb, emulator and avdmanager is not on PATH. A missing tool hides that
# side's devices, so it is not reported as success: the gate records a non-zero
# exit as `실패 rc=<n>` and the morning's residue reader shows it.

set -uo pipefail

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: device-cleanup.sh <run id> <dispatch id|->" >&2
  exit 2
fi
run_id="$1"
disp="$2"
if [ "$disp" = "-" ]; then
  prefix="cc-$run_id-"
else
  prefix="cc-$run_id-$disp-"
fi

failed=0
missing=0

chosen() {
  # chosen <name> — 0 when the name is this dispatch's.
  local name="$1" rest
  case "$name" in "$prefix"*) ;; *) return 1 ;; esac
  rest="${name#"$prefix"}"
  [ -n "$rest" ] || return 1
  if [ "$disp" != "-" ]; then
    case "$rest" in *-*) return 1 ;; esac
  fi
  return 0
}

report() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
  [ "$1" = "못지움" ] && failed=1
  return 0
}

have() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  printf '도구없음\t%s\n' "$1"
  missing=1
  return 1
}

# Simulators.
if have xcrun; then
  if ! command -v jq >/dev/null 2>&1; then
    printf '도구없음\t%s\n' jq
    missing=1
  elif list=$(xcrun simctl list devices -j 2>/dev/null); then
    while IFS="$(printf '\t')" read -r udid name; do
      [ -n "$udid" ] || continue
      chosen "$name" || continue
      xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
      if xcrun simctl delete "$udid" >/dev/null 2>&1; then
        report 지움 시뮬레이터 "$udid" "$name"
      else
        report 못지움 시뮬레이터 "$udid" "$name"
      fi
    done <<EOF
$(printf '%s' "$list" | jq -r '.devices[]?[]? | [.udid, .name] | @tsv' 2>/dev/null)
EOF
  else
    report 못지움 시뮬레이터 - "(xcrun simctl list 실패)"
  fi
fi

# Running emulators.
if have adb; then
  serials=$(adb devices 2>/dev/null | awk 'NR > 1 && $1 ~ /^emulator-[0-9]+$/ { print $1 }')
  for serial in $serials; do
    name=$(adb -s "$serial" emu avd name 2>/dev/null | sed -n '1p' | tr -d '\r')
    chosen "$name" || continue
    if adb -s "$serial" emu kill >/dev/null 2>&1; then
      report 지움 에뮬레이터 "$serial" "$name"
    else
      report 못지움 에뮬레이터 "$serial" "$name"
    fi
  done
fi

# AVDs. Listing needs `emulator` and deleting needs `avdmanager`; either one
# missing hides the AVDs, so both are checked before either is used.
have_emu=0; have_avdm=0
have emulator && have_emu=1
have avdmanager && have_avdm=1
if [ "$have_emu" = 1 ] && [ "$have_avdm" = 1 ]; then
  while IFS= read -r avd; do
    avd=$(printf '%s' "$avd" | tr -d '\r')
    [ -n "$avd" ] || continue
    chosen "$avd" || continue
    if avdmanager delete avd -n "$avd" >/dev/null 2>&1; then
      report 지움 AVD - "$avd"
    else
      report 못지움 AVD - "$avd"
    fi
  done <<EOF
$(emulator -list-avds 2>/dev/null)
EOF
fi

[ "$failed" = 1 ] && exit 1
[ "$missing" = 1 ] && exit 3
exit 0
