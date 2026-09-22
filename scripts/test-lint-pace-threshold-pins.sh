#!/usr/bin/env bash
# Test scripts/lint-pace-threshold-pins.sh and scripts/lint-fleet-agent-pins.sh
# over synthesized fixture trees.
#
# The fixtures are BUILT HERE rather than checked in: each one is a minimal
# `orchestrator/` + `skills/` pair derived from a single good tree by one edit,
# so the disagreement each fixture reproduces is stated as the edit that makes
# it, next to the exit code it must produce. The directory name still encodes
# the expectation the way the watcher lint's test does:
#   OK-*     → expected exit 0
#   FAIL-*   → expected exit 1
#   EXIT2-*  → expected exit 2 (the source of truth is unusable)
#
# Pace lint branches, one fixture each:
#   OK-1-agree              every mirror and mention equals the declaration
#   EXIT2-2-no-declaration  fleet.sh carries no readonly FLEET_*=<n> at all
#   EXIT2-3-double-decl     one threshold declared twice
#   FAIL-4-consumer-drift   a consumer restates a threshold with another number
#   FAIL-5-consumer-absent  a consumer file is missing — FAIL, not SKIP
#   FAIL-6-mirror-drift     gate.sh's GATE_PACE_STALE_SECONDS moved on its own
#
# Fleet-agent lint branches:
#   OK-1-agree                    template and renderer agree
#   FAIL-2-literal-interval       StartInterval carries a number, not the placeholder
#   FAIL-3-keepalive              a deliberately absent key came back
#   FAIL-4-placeholder-orphan     the template carries a placeholder the renderer does not substitute
#   FAIL-5-render-literal         the sensor render call passes a literal instead of $FLEET_START_INTERVAL

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-lint-pace-pins.XXXXXX")
trap 'rm -rf "$work"' EXIT

passed=0
failures=0

# --- the good tree, written once and copied per fixture ----------------------
good="$work/good"
mkdir -p "$good/orchestrator" "$good/skills/autopilot" "$good/skills/_common"
cat > "$good/orchestrator/fleet.sh" <<'EOF'
#!/usr/bin/env bash
readonly FLEET_START_INTERVAL=55                # sensor period
readonly FLEET_DISPATCH_START_INTERVAL=120      # dispatch period
readonly FLEET_TICK_BUDGET_SECONDS=5
readonly FLEET_STATE_STALE_SECONDS=180          # 3 x (55 + 5)
readonly FLEET_IDLE_SECONDS=1200
readonly FLEET_BURN_PP_PER_MWT=0.104
fleet_render_plist() {
  local label="$1" sub="$2" lane="$3" cfg="$4" interval="$5" dst="$6" tpl="$FLEET_DIR/fleet-agent.plist.in"
  {
    sed -e "s|@LABEL@|$label|g" -e "s|@FLEET_SH@|$FLEET_DIR/fleet.sh|g" -e "s|@SUBCOMMAND@|$sub|g" \
        -e "s|@START_INTERVAL@|$interval|g" -e "s|@LOG_DIR@|$PACE_ROOT/log|g" -e "s|@PATH@|$PATH|g" "$tpl" \
    | if [ -n "$lane" ]; then sed -e "s|@LANE@|$lane|g" -e "s|@CLAUDE_CONFIG_DIR@|$cfg|g"
      else sed -e '/@LANE@/d' -e '/@CLAUDE_CONFIG_DIR@/d'; fi
  } > "$dst"
}
fleet_agent_install() {
  for label in a.sensor a.dispatch.cc; do
    case "$label" in
      *.sensor) fleet_render_plist "$label" sensor "" "" "$FLEET_START_INTERVAL" "$dst" ;;
      *.dispatch.*) fleet_render_plist "$label" dispatch "$lane" "$h" "$FLEET_DISPATCH_START_INTERVAL" "$dst" ;;
    esac
  done
}
EOF
cat > "$good/orchestrator/gate.sh" <<'EOF'
#!/usr/bin/env bash
# The sensor fires every `FLEET_START_INTERVAL` (55s) and caps its runtime at
# `FLEET_TICK_BUDGET_SECONDS` (5s), so three periods is 180s.
readonly GATE_PACE_STALE_SECONDS=180
EOF
cat > "$good/orchestrator/run.sh" <<'EOF'
#!/usr/bin/env bash
readonly RUN_PACE_STALE_SECONDS=180
EOF
cat > "$good/orchestrator/fleet-agent.plist.in" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!--
  @START_INTERVAL@ is documented here and must not count.
  @NOT_A_REAL_ONE@ either.
-->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>@LABEL@</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>@FLEET_SH@</string>
    <string>@SUBCOMMAND@</string>
    <string>@LANE@</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>@PATH@</string>
    <key>CLAUDE_CONFIG_DIR</key><string>@CLAUDE_CONFIG_DIR@</string>
  </dict>
  <key>StartInterval</key>
  <integer>@START_INTERVAL@</integer>
  <key>StandardOutPath</key>
  <string>@LOG_DIR@/@LABEL@.log</string>
</dict>
</plist>
EOF
cat > "$good/skills/autopilot/SKILL.md" <<'EOF'
# autopilot
The sensor's period is FLEET_START_INTERVAL=55 and the idle horizon FLEET_IDLE_SECONDS=1200.
EOF
cat > "$good/skills/_common/pipeline-sidecar.md" <<'EOF'
# sidecar
A stale state is one older than three sensor periods (`FLEET_STATE_STALE_SECONDS` (180s)).
EOF

clone() {
  # clone <fixture-name> — a fresh copy of the good tree under $work/<name>
  rm -rf "$work/$1"
  cp -R "$good" "$work/$1"
}

run_case() {
  # run_case <lint-script> <fixture-name>
  local lint="$1" name="$2" want ec
  case "$name" in
    OK-*)    want=0 ;;
    FAIL-*)  want=1 ;;
    EXIT2-*) want=2 ;;
    *) echo "test-lint-pace-threshold-pins: fixture '$name' has unrecognized prefix" >&2
       failures=$((failures + 1)); return 0 ;;
  esac
  set +e
  ORCH_ROOT="$work/$name/orchestrator" SKILLS_ROOT="$work/$name/skills" \
    bash "$script_dir/$lint" >/dev/null 2>&1
  ec=$?
  set -e
  if [[ "$ec" == "$want" ]]; then
    passed=$((passed + 1))
    echo "PASS: $lint $name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $lint $name (exit=$ec, expected=$want)" >&2
  fi
}

# --- pace threshold pins -----------------------------------------------------
clone OK-1-agree
run_case lint-pace-threshold-pins.sh OK-1-agree

clone EXIT2-2-no-declaration
sed -e '/^readonly FLEET_/d' "$good/orchestrator/fleet.sh" > "$work/EXIT2-2-no-declaration/orchestrator/fleet.sh"
run_case lint-pace-threshold-pins.sh EXIT2-2-no-declaration

clone EXIT2-3-double-decl
printf 'readonly FLEET_IDLE_SECONDS=1800\n' >> "$work/EXIT2-3-double-decl/orchestrator/fleet.sh"
run_case lint-pace-threshold-pins.sh EXIT2-3-double-decl

clone FAIL-4-consumer-drift
sed -e 's/FLEET_IDLE_SECONDS=1200/FLEET_IDLE_SECONDS=1800/' "$good/skills/autopilot/SKILL.md" > "$work/FAIL-4-consumer-drift/skills/autopilot/SKILL.md"
run_case lint-pace-threshold-pins.sh FAIL-4-consumer-drift

clone FAIL-5-consumer-absent
rm "$work/FAIL-5-consumer-absent/skills/_common/pipeline-sidecar.md"
run_case lint-pace-threshold-pins.sh FAIL-5-consumer-absent

clone FAIL-6-mirror-drift
sed -e 's/^readonly GATE_PACE_STALE_SECONDS=180$/readonly GATE_PACE_STALE_SECONDS=240/' "$good/orchestrator/gate.sh" > "$work/FAIL-6-mirror-drift/orchestrator/gate.sh"
run_case lint-pace-threshold-pins.sh FAIL-6-mirror-drift

# --- fleet agent pins --------------------------------------------------------
clone OK-1-agree
run_case lint-fleet-agent-pins.sh OK-1-agree

clone FAIL-2-literal-interval
sed -e 's|<integer>@START_INTERVAL@</integer>|<integer>55</integer>|' "$good/orchestrator/fleet-agent.plist.in" > "$work/FAIL-2-literal-interval/orchestrator/fleet-agent.plist.in"
run_case lint-fleet-agent-pins.sh FAIL-2-literal-interval

clone FAIL-3-keepalive
sed -e 's|<key>StartInterval</key>|<key>KeepAlive</key><true/><key>StartInterval</key>|' "$good/orchestrator/fleet-agent.plist.in" > "$work/FAIL-3-keepalive/orchestrator/fleet-agent.plist.in"
run_case lint-fleet-agent-pins.sh FAIL-3-keepalive

clone FAIL-4-placeholder-orphan
sed -e 's|<string>@PATH@</string>|<string>@PATH@:@EXTRA_PATH@</string>|' "$good/orchestrator/fleet-agent.plist.in" > "$work/FAIL-4-placeholder-orphan/orchestrator/fleet-agent.plist.in"
run_case lint-fleet-agent-pins.sh FAIL-4-placeholder-orphan

clone FAIL-5-render-literal
sed -e 's|sensor "" "" "\$FLEET_START_INTERVAL"|sensor "" "" "55"|' "$good/orchestrator/fleet.sh" > "$work/FAIL-5-render-literal/orchestrator/fleet.sh"
run_case lint-fleet-agent-pins.sh FAIL-5-render-literal

echo "test-lint-pace-threshold-pins: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
