#!/usr/bin/env bash
# display-tz.sh — the one place that turns a UTC instant into the time a person
# reads on an autopilot surface.
#
# A SOURCED LIBRARY, with one direct-run form. The status pane, the progress
# feed and the status line source it and call `cc_display_tz_load` once; the
# model writing the morning report runs `bash display-tz.sh iso <UTC ISO>`.
# Sourcing prints nothing and is safe under the caller's `set -u`.
#
# ONLY WHAT A PERSON SEES CHANGES. Every time written to disk — ledger rows,
# observation rows, kickoff traces, the feed's heartbeat file — stays UTC `Z`.
# Code that compares or ages those records reads them as before; this file is
# never on that path.
#
# `CC_CMDS_AUTOPILOT_TZ`, read verbatim (no trimming):
#
#   unset, empty                          → +09:00  `KST`
#   `UTC`, `Z` (any case)                 → 0       `UTC`
#   `±HH:MM` equal to +09:00              → +09:00  `KST`
#   `±HH:MM` equal to 0                   → 0       `UTC`
#   other `±HH:MM`, -12:00..+14:00,       → that    `UTC±HH:MM` (as given)
#     minutes 00-59
#   anything else (`Asia/Seoul`, `+9`,    → +09:00  `KST`
#     `+0900`, `+15:00`, padded values)
#
# An unreadable value falls back to KST without a warning: every consumer draws
# a line silently and has nowhere to put one.
#
# WHY SHELL ARITHMETIC. `date -d` is GNU and `date -j` is BSD, and the
# portability lint denies both. perl `localtime` follows the host `TZ`, so one
# surface using it would show a different zone from the others for the same
# setting. The civil-from-days / days-from-civil arithmetic below needs neither,
# and `10#` on every field keeps `08` and `09` from being read as octal. It
# agrees with the system `date` wherever epoch + offset is not negative, which
# covers every time these surfaces show.
#
# Compatibility: bash 3.2.

cc_display_tz_load() {
  # cc_display_tz_load — sets CC_DTZ_OFF (signed seconds) and CC_DTZ_LABEL.
  local v="${CC_CMDS_AUTOPILOT_TZ-}" hh mm off
  CC_DTZ_OFF=32400
  CC_DTZ_LABEL=KST
  case "$v" in
    [Uu][Tt][Cc]|[Zz]) CC_DTZ_OFF=0; CC_DTZ_LABEL=UTC; return 0 ;;
    [+-][0-9][0-9]:[0-9][0-9]) ;;
    *) return 0 ;;
  esac
  hh=$((10#${v:1:2}))
  mm=$((10#${v:4:2}))
  [ "$mm" -le 59 ] || return 0
  off=$(( hh * 3600 + mm * 60 ))
  if [ "${v:0:1}" = "-" ]; then off=$(( -off )); fi
  [ "$off" -ge -43200 ] && [ "$off" -le 50400 ] || return 0
  CC_DTZ_OFF=$off
  if [ "$off" -eq 32400 ]; then
    CC_DTZ_LABEL=KST
  elif [ "$off" -eq 0 ]; then
    CC_DTZ_LABEL=UTC
  else
    CC_DTZ_LABEL="UTC$v"
  fi
  return 0
}

_cc_dtz_civil() {
  # _cc_dtz_civil <seconds since epoch, already offset> — sets _CC_DTZ_Y/_M/_D/
  # _HH/_MI, or fails for a negative or non-numeric value.
  local t="$1" z era doe yoe doy mp s
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  z=$(( t / 86400 + 719468 ))
  era=$(( z / 146097 ))
  doe=$(( z - era * 146097 ))
  yoe=$(( (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 ))
  doy=$(( doe - (365 * yoe + yoe / 4 - yoe / 100) ))
  mp=$(( (5 * doy + 2) / 153 ))
  _CC_DTZ_D=$(( doy - (153 * mp + 2) / 5 + 1 ))
  if [ "$mp" -lt 10 ]; then _CC_DTZ_M=$(( mp + 3 )); else _CC_DTZ_M=$(( mp - 9 )); fi
  _CC_DTZ_Y=$(( yoe + era * 400 ))
  if [ "$_CC_DTZ_M" -le 2 ]; then _CC_DTZ_Y=$(( _CC_DTZ_Y + 1 )); fi
  s=$(( t % 86400 ))
  _CC_DTZ_HH=$(( s / 3600 ))
  _CC_DTZ_MI=$(( s % 3600 / 60 ))
}

cc_display_hhmm() {
  # cc_display_hhmm <epoch> — `HH:MM` in the display zone, or nothing.
  local e="${1-}" s
  case "$e" in ''|-|*[!0-9-]*|?*-*) return 0 ;; esac
  s=$(( ((e + ${CC_DTZ_OFF:-0}) % 86400 + 86400) % 86400 ))
  printf '%02d:%02d\n' $(( s / 3600 )) $(( s % 3600 / 60 ))
}

cc_display_mdhm() {
  # cc_display_mdhm <epoch> — `MM/DD HH:MM` in the display zone, or nothing.
  local e="${1-}"
  case "$e" in ''|*[!0-9]*) return 0 ;; esac
  _cc_dtz_civil $(( e + ${CC_DTZ_OFF:-0} )) || return 0
  printf '%02d/%02d %02d:%02d\n' "$_CC_DTZ_M" "$_CC_DTZ_D" "$_CC_DTZ_HH" "$_CC_DTZ_MI"
}

cc_display_iso() {
  # cc_display_iso <YYYY-MM-DDTHH:MM[:SS]Z> — `YYYY-MM-DD HH:MM <label>`, or
  # nothing when the value is not exactly that shape. A zone other than `Z`
  # yields nothing: adding an offset to a time of unknown zone draws a wrong
  # time that looks right.
  local v="${1-}" y m d hh mi ss=0 era yoe doy doe days
  case "$v" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]Z) ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ss=$((10#${v:17:2})) ;;
    *) return 0 ;;
  esac
  y=$((10#${v:0:4})); m=$((10#${v:5:2})); d=$((10#${v:8:2}))
  hh=$((10#${v:11:2})); mi=$((10#${v:14:2}))
  [ "$y" -ge 1970 ] && [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le 31 ] \
    && [ "$hh" -le 23 ] && [ "$mi" -le 59 ] && [ "$ss" -le 60 ] || return 0
  # March-based year, so the leap day falls at the end of the count.
  if [ "$m" -le 2 ]; then y=$(( y - 1 )); fi
  era=$(( y / 400 ))
  yoe=$(( y - era * 400 ))
  if [ "$m" -gt 2 ]; then
    doy=$(( (153 * (m - 3) + 2) / 5 + d - 1 ))
  else
    doy=$(( (153 * (m + 9) + 2) / 5 + d - 1 ))
  fi
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  days=$(( era * 146097 + doe - 719468 ))
  _cc_dtz_civil $(( days * 86400 + hh * 3600 + mi * 60 + ss + ${CC_DTZ_OFF:-0} )) || return 0
  printf '%04d-%02d-%02d %02d:%02d %s\n' "$_CC_DTZ_Y" "$_CC_DTZ_M" "$_CC_DTZ_D" \
    "$_CC_DTZ_HH" "$_CC_DTZ_MI" "${CC_DTZ_LABEL:-UTC}"
}

# Direct run: `bash display-tz.sh iso <UTC ISO>` prints one converted line (or
# nothing for a value of the wrong shape) and exits 0.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1-}" in
    iso)
      cc_display_tz_load
      cc_display_iso "${2-}"
      exit 0
      ;;
    *)
      printf 'usage: %s iso <YYYY-MM-DDTHH:MM[:SS]Z>\n' "$0" >&2
      exit 2
      ;;
  esac
fi
