#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the observer's `checks` job: the batched GraphQL question, the snapshot
# pass of `checks.sh`, the delegation from an unchanged kickoff line, the hand
# back to the poller's own loop, and the fence around all of it.
#
# EVERYTHING RUNS AGAINST TEMPORARY TREES AND A `gh` STUB. The state root is a
# fresh `XDG_STATE_HOME`; each run's pinned copy is a copy of this tree's
# `orchestrator/`; the segments are local repositories whose `origin` names a
# GitHub slug nobody is asked about, because `gh` on PATH is a stub answering
# from recorded responses. The stub logs every call it gets, which is what the
# fence assertions read. Every observer started here is stopped by the exit trap.
#
# THE STAGE GUARD IS CLEARED. `observer.py adopt` refuses inside a stage, and
# this suite is run from one, so the variables that mark a stage are unset.
#
# Usage: bash scripts/test-observer-checks.sh

set -uo pipefail

CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
for _v in $(compgen -e); do
  case "$_v" in CC_PIPELINE_*|CC_OBSERVER_PID) unset "$_v" ;; esac
done
unset CI CC_CMDS_OBSERVER _v

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'SKIP: python3 가 없다 — 관측기를 띄울 수 없다\n'
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  printf 'SKIP: git 이 없다 — 세그먼트 워크트리를 만들 수 없다\n'
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-observer-checks-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
S="$WORK/state"
export XDG_STATE_HOME="$S"
export CC_OBSERVER_PERIOD=0.3 CC_OBSERVER_GRACE=600
mkdir -p "$S/cc-cmds/run" "$S/cc-cmds/session"

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

STRAYS=""
cleanup() {
  local p
  p=$(cat "$S/cc-cmds/observer/observer.pid" 2>/dev/null || true)
  [ -n "$p" ] && kill -CONT "$p" 2>/dev/null
  python3 "$ORCH/observer.py" stop >/dev/null 2>&1
  for p in $STRAYS; do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# wait_for <seconds> <command...> — poll every 0.1 s until the command succeeds.
wait_for() {
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do
    "$@" && return 0
    sleep 0.1; n=$((n - 1))
  done
  return 1
}
alive() { kill -0 "$1" 2>/dev/null; }
opid()  { tr -d '[:space:]' < "$S/cc-cmds/observer/observer.pid" 2>/dev/null; }

# ---------------------------------------------------------------------------
# The stubs: `gh`, answering both shapes from the fixture of the current phase,
# and the notifiers, which nothing here may reach.
# ---------------------------------------------------------------------------
FX="$WORK/fx"; mkdir -p "$FX/old" "$FX/gql"
export FX
STUB="$WORK/stub"; mkdir -p "$STUB"
GH_LOG="$WORK/gh.log"; : > "$GH_LOG"
NOTE_LOG="$WORK/notifier.log"
export GH_LOG
for n in terminal-notifier osascript; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$n" "$NOTE_LOG" > "$STUB/$n"
  chmod +x "$STUB/$n"
done

cat > "$STUB/gh" <<'GHSTUB'
#!/bin/sh
# One log line per call: the first three words, and for a GraphQL call whether
# the query starts with `query` and whether it carries `mutation`.
if [ "$1" = api ]; then
  q=""
  for a in "$@"; do case "$a" in query=*) q=${a#query=} ;; esac; done
  case "$q" in query*) qs=query ;; *) qs=other ;; esac
  case "$q" in *mutation*) qm=mutation ;; *) qm=clean ;; esac
  printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$qs" "$qm" >> "$GH_LOG"
  exec python3 "$FX/gql.py" "$@"
fi
printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$GH_LOG"
[ "$1" = "-R" ] || exit 2
shift 2
[ "$1" = pr ] || exit 2
verb=$2; shift 2
phase=$(cat "$FX/phase")
d="$FX/old/$phase"
case "$verb" in
  list)
    key=$(printf '%s' "$2" | tr '/' '_')
    [ -f "$d/$key.broken" ] && { printf 'HTTP 502\n' >&2; exit 1; }
    cat "$d/$key.list" 2>/dev/null || printf '[]\n'
    exit 0 ;;
  checks)
    base="$d/$1"
    [ "${2:-}" = "--required" ] && base="$base.req"
    [ -f "$base.out" ] && cat "$base.out"
    [ -f "$base.err" ] && cat "$base.err" >&2
    exit "$(cat "$base.rc" 2>/dev/null || printf 1)" ;;
esac
exit 2
GHSTUB
chmod +x "$STUB/gh"

# The recorded GraphQL side: `gql/<phase>.json` holds, per head branch, the PR
# number, its head sha and its check contexts in the node shape GitHub returns;
# `"broken"` makes that branch's list alias null and `{"broken": true}` the
# whole call fail.
cat > "$FX/gql.py" <<'PY'
import json, os, re, sys
q = ""
for a in sys.argv[1:]:
    if a.startswith("query="):
        q = a[len("query="):]
fx = os.environ["FX"]
phase = open(os.path.join(fx, "phase")).read().strip()
book = json.load(open(os.path.join(fx, "gql", phase + ".json")))
if book.get("broken"):
    sys.stderr.write("HTTP 502\n")
    sys.exit(1)
br = book.get("branches", {})
out, errs = {}, []
pat = re.compile(r'(l|p)(\d+):repository\(owner:"([^"]*)",name:"([^"]*)"\)\{'
                 r'(?:pullRequests\(headRefName:("(?:[^"\\]|\\.)*")|pullRequest\(number:(\d+))')
for m in pat.finditer(q):
    alias = m.group(1) + m.group(2)
    if m.group(1) == "l":
        e = br.get(json.loads(m.group(5)))
        if e == "broken":
            out[alias] = None
            errs.append({"path": [alias], "message": "boom"})
        elif e is None:
            out[alias] = {"pullRequests": {"nodes": []}}
        else:
            out[alias] = {"pullRequests": {"nodes": [{"number": e["number"], "headRefOid": e["sha"]}]}}
    else:
        n = int(m.group(6))
        e = next((v for v in br.values() if isinstance(v, dict) and v["number"] == n), None)
        if e is None:
            out[alias] = {"pullRequest": None}
            continue
        ctxs = e.get("contexts", [])
        roll = None
        if ctxs or e.get("more"):
            roll = {"contexts": {"pageInfo": {"hasNextPage": bool(e.get("more"))}, "nodes": ctxs}}
        out[alias] = {"pullRequest": {"headRefOid": e["sha"],
                                      "commits": {"nodes": [{"commit": {"statusCheckRollup": roll}}]}}}
doc = {"data": out}
if errs:
    doc["errors"] = errs
print(json.dumps(doc))
sys.exit(1 if errs else 0)
PY

export PATH="$STUB:$PATH"

# ---------------------------------------------------------------------------
# The segments: local repositories whose `origin` is a GitHub slug, one branch
# each, and a ledger naming them.
# ---------------------------------------------------------------------------
BRANCHES="seg/run seg/pass seg/fail seg/none seg/nopr"
i=0
for b in $BRANCHES; do
  i=$((i + 1))
  wt="$WORK/wt$i"; mkdir -p "$wt"
  ( cd "$wt" \
    && git init -q . \
    && git config user.email 't@example.invalid' \
    && git config user.name 'observer checks test' \
    && git config remote.origin.url 'https://github.com/Nharu/fx.git' \
    && git commit -q --allow-empty -m x \
    && git checkout -q -b "$b" ) >/dev/null 2>&1
done

# make_run <run id> — a run directory under the run root with a pinned copy of
# this tree's orchestrator, a ledger naming the five segments and a manifest.
make_run() {
  local rd="$S/cc-cmds/run/$1" n
  mkdir -p "$rd/plugin/cc-cmds" "$WORK/docs"
  cp -R "$ORCH" "$rd/plugin/cc-cmds/orchestrator"
  cp -R "$repo_root/plugins/cc-cmds/.claude-plugin" "$rd/plugin/cc-cmds/.claude-plugin"
  {
    printf -- '- `run` | 교대=0 | run-id=%s | prev=aaaa\n' "$1"
    for n in 1 2 3 4 5; do
      printf -- '- `segment` | 교대=0 | id=S%s | 상태=실행중 | 워크트리=%s | prev=bbbb\n' "$n" "$WORK/wt$n"
    done
  } > "$WORK/docs/$1.md"
  printf '%s\n' "$WORK/docs/$1.md" > "$rd/ledger-path"
  printf -- '- `target` | 별칭=home | 홈=예 | 원격 슬러그=Nharu/fx | 베이스 브랜치=master\n' > "$WORK/docs/$1.plan.md"
  printf '%s' "$rd"
}
ledger_of()   { printf '%s' "$WORK/docs/$(basename "$1").md"; }
manifest_of() { printf '%s' "$WORK/docs/$(basename "$1").plan.md"; }

SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHA_C=cccccccccccccccccccccccccccccccccccccccc
SHA_D=dddddddddddddddddddddddddddddddddddddddd

# old <phase> <file> <content> — one recorded answer of the `gh pr` side.
old() { mkdir -p "$FX/old/$1"; printf '%b' "$3" > "$FX/old/$1/$2"; }
# copy_old <from> <to> — a phase that starts as a copy of another.
copy_old() { mkdir -p "$FX/old/$2"; cp "$FX/old/$1/"* "$FX/old/$2/"; }

# The check contexts, in the node shape GitHub returns.
cr() { # cr <name> <status> <conclusion|null> <startedAt> <required true|false>
  local c=null; [ "$3" = null ] || c="\"$3\""
  printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":%s,"startedAt":"%s","isRequired":%s,"checkSuite":{"workflowRun":{"event":"pull_request","workflow":{"name":"ci"}}}}' \
    "$1" "$2" "$c" "$4" "$5"
}
sc() { # sc <context> <state> <createdAt> <required>
  printf '{"__typename":"StatusContext","context":"%s","state":"%s","createdAt":"%s","isRequired":%s}' "$1" "$2" "$3" "$4"
}

# ===========================================================================
# R1. The snapshot pass writes the lines the `gh` pass writes.
#
# Two runs over the same five segments: one polled by `checks.sh --once` against
# the recorded `gh pr list`/`gh pr checks` answers, one by the module's batch —
# spec, GraphQL question, snapshot, `checks.sh --once --from-snapshot` — against
# the recorded GraphQL answers for the same states. Phase by phase the two
# `checks.observed` files must carry the same lines, the time column aside.
#
#   p1  in progress (11), passed with a duplicate, a status context and a
#       cancelled run (12), failed with a pending shard, a cancelled run and a
#       required set (13), no checks (14), no PR (seg/nopr). gh's non-terminal
#       output prints a cancelled run as a `fail` row without failing the exit
#       code, so its name joins the failing names only beside a real failure.
#   p2  11 passes; an accepted rerun round on 13's head opens round 1
#   p3  12's list question breaks; 14 gets a pending check
#   p4  the whole question breaks while 11 would move
# ===========================================================================
R1A=$(make_run 20261101-000000a1)
R1B=$(make_run 20261101-000000a2)

# --- p1 ------------------------------------------------------------------
old p1 seg_run.list  "[{\"number\":11,\"headRefOid\":\"$SHA_A\"}]\n"
old p1 11.out        'test\tpending\t0\thttp://x/2\nlint\tpass\t1s\thttp://x/1\n'
old p1 11.rc         '8'
old p1 11.req.out    'lint\tpass\t1s\thttp://x/1\n'
old p1 11.req.rc     '0'
old p1 seg_pass.list "[{\"number\":12,\"headRefOid\":\"$SHA_B\"}]\n"
old p1 12.out        'ci/legacy\tpass\t0\thttp://x/4\nlint\tpass\t1s\thttp://x/3\nmacos\tfail\t1s\thttp://x/9\n'
old p1 12.rc         '0'
old p1 12.req.err    "no required checks reported on the 'seg/pass' branch\n"
old p1 12.req.rc     '1'
old p1 seg_fail.list "[{\"number\":13,\"headRefOid\":\"$SHA_C\"}]\n"
old p1 13.out        'lint\tfail\t1s\thttp://x/5\nunit\tfail\t1s\thttp://x/6\nbuild\tpending\t0\thttp://x/7\ndeploy\tfail\t1s\thttp://x/10\n'
old p1 13.rc         '1'
old p1 13.req.out    'lint\tfail\t1s\thttp://x/5\nunit\tfail\t1s\thttp://x/6\n'
old p1 13.req.rc     '1'
old p1 seg_none.list "[{\"number\":14,\"headRefOid\":\"$SHA_D\"}]\n"
old p1 14.err        "no checks reported on the 'seg/none' branch\n"
old p1 14.rc         '1'
old p1 14.req.err    "no checks reported on the 'seg/none' branch\n"
old p1 14.req.rc     '1'
old p1 seg_nopr.list '[]\n'

T1=2026-11-01T00:00:01Z; T2=2026-11-01T00:00:02Z; T3=2026-11-01T00:00:03Z
T4=2026-11-01T00:00:04Z; T5=2026-11-01T00:00:05Z
gql_p1_run="[$(cr lint COMPLETED SUCCESS $T1 true),$(cr test IN_PROGRESS null $T2 false)]"
gql_pass="[$(cr lint COMPLETED FAILURE $T3 false),$(sc ci/legacy SUCCESS $T4 false),$(cr lint COMPLETED SUCCESS $T5 false),$(cr macos COMPLETED CANCELLED $T2 false)]"
gql_fail="[$(cr deploy COMPLETED CANCELLED $T4 false),$(cr lint COMPLETED FAILURE $T1 true),$(cr unit COMPLETED TIMED_OUT $T2 true),$(cr build QUEUED null $T3 false)]"
cat > "$FX/gql/p1.json" <<EOF
{"branches": {
  "seg/run":  {"number": 11, "sha": "$SHA_A", "contexts": $gql_p1_run},
  "seg/pass": {"number": 12, "sha": "$SHA_B", "contexts": $gql_pass},
  "seg/fail": {"number": 13, "sha": "$SHA_C", "contexts": $gql_fail},
  "seg/none": {"number": 14, "sha": "$SHA_D", "contexts": []}
}}
EOF

# --- p2 ------------------------------------------------------------------
copy_old p1 p2
old p2 11.out 'lint\tpass\t1s\thttp://x/1\ntest\tpass\t2s\thttp://x/2\n'
old p2 11.rc  '0'
gql_p2_run="[$(cr lint COMPLETED SUCCESS $T1 true),$(cr test COMPLETED SUCCESS $T2 false)]"
cat > "$FX/gql/p2.json" <<EOF
{"branches": {
  "seg/run":  {"number": 11, "sha": "$SHA_A", "contexts": $gql_p2_run},
  "seg/pass": {"number": 12, "sha": "$SHA_B", "contexts": $gql_pass},
  "seg/fail": {"number": 13, "sha": "$SHA_C", "contexts": $gql_fail},
  "seg/none": {"number": 14, "sha": "$SHA_D", "contexts": []}
}}
EOF

# --- p3 ------------------------------------------------------------------
copy_old p2 p3
: > "$FX/old/p3/seg_pass.broken"
old p3 12.out 'lint\tfail\t1s\thttp://x/3\n'
old p3 12.rc  '1'
old p3 14.out 'lint\tpending\t0\thttp://x/8\n'
old p3 14.rc  '8'
rm -f "$FX/old/p3/14.err"
gql_p3_none="[$(cr lint IN_PROGRESS null $T1 false)]"
cat > "$FX/gql/p3.json" <<EOF
{"branches": {
  "seg/run":  {"number": 11, "sha": "$SHA_A", "contexts": $gql_p2_run},
  "seg/pass": "broken",
  "seg/fail": {"number": 13, "sha": "$SHA_C", "contexts": $gql_fail},
  "seg/none": {"number": 14, "sha": "$SHA_D", "contexts": $gql_p3_none}
}}
EOF

# --- p4 ------------------------------------------------------------------
copy_old p3 p4
for b in seg_run seg_pass seg_fail seg_none seg_nopr; do : > "$FX/old/p4/$b.broken"; done
old p4 11.out 'lint\tfail\t1s\thttp://x/1\n'
old p4 11.rc  '1'
printf '{"broken": true}\n' > "$FX/gql/p4.json"

# The module's side: a fake observer context that runs the pinned scripts the
# way `Ctx.call` does (bash, `CC_OBSERVER_PID`, no stdin) and records drops.
cat > "$WORK/drive.py" <<'PY'
import importlib.util, os, subprocess, sys, time
orch, rd, ledger, manifest = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("observer_checks", os.path.join(orch, "observer_checks.py"))
oc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oc)
ARGS = ["--run-dir", rd, "--ledger", ledger, "--manifest", manifest, "--interval", "60"]
class Ctx:
    pid = os.getpid()
    def call(self, run, argv, timeout=10):
        path = os.path.join(run, "plugin", "cc-cmds", "orchestrator", argv[0])
        env = dict(os.environ)
        env["CC_OBSERVER_PID"] = str(os.getpid())
        p = subprocess.run(["bash", path] + [str(a) for a in argv[1:]], env=env, cwd="/",
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=60)
        sys.stdout.write("call %s rc=%d\n" % (argv[1] if len(argv) > 1 else "", p.returncode))
        return p.returncode, p.stdout.decode("utf-8", "replace")
    def args(self, run):
        return list(ARGS)
    def drop(self, run):
        sys.stdout.write("drop %s\n" % run)
    def log(self, msg):
        sys.stdout.write("log %s\n" % msg)
oc.batch(Ctx(), [rd], time.time())
PY

r1_lines() { if [ -f "$1/checks.observed" ]; then cut -f2- "$1/checks.observed"; fi; }
for ph in p1 p2 p3 p4; do
  printf '%s\n' "$ph" > "$FX/phase"
  if [ "$ph" = p2 ]; then
    for rd in "$R1A" "$R1B"; do
      printf -- '- `CI 처분` | 교대=0 | 세그먼트=S3 | PR=Nharu/fx#13 | head sha=%s | 처분=재실행 | 상태=수락 | 회차=1 | prev=dddd\n' \
        "$SHA_C" >> "$(ledger_of "$rd")"
    done
  fi
  bash "$R1A/plugin/cc-cmds/orchestrator/checks.sh" --run-dir "$R1A" --ledger "$(ledger_of "$R1A")" \
    --manifest "$(manifest_of "$R1A")" --once > "$WORK/r1a.$ph.out" 2> "$WORK/r1a.$ph.err"
  python3 "$WORK/drive.py" "$R1B/plugin/cc-cmds/orchestrator" "$R1B" "$(ledger_of "$R1B")" \
    "$(manifest_of "$R1B")" > "$WORK/r1b.$ph.out" 2> "$WORK/r1b.$ph.err"
  r1_lines "$R1A" > "$WORK/r1a.$ph.lines"
  r1_lines "$R1B" > "$WORK/r1b.$ph.lines"
  if diff "$WORK/r1a.$ph.lines" "$WORK/r1b.$ph.lines" > "$WORK/r1.$ph.diff"; then
    ok "R1 $ph: 스냅숏 판과 gh 판의 checks.observed 전이 줄이 같다 ($(grep -c '' < "$WORK/r1a.$ph.lines" | tr -d ' ')줄)"
  else
    bad "R1 $ph: 전이 줄 대조" "$(tr '\n' '|' < "$WORK/r1.$ph.diff")"
  fi
done

# The comparison is only worth something if the states it compares are the
# ones named above: the expected lines, in order, without the time column.
r1_want=$(printf '%s\n' \
  "S1	Nharu/fx#11	$SHA_A	대기	0	0	lint	-" \
  "S2	Nharu/fx#12	$SHA_B	통과	0	0	없음	-" \
  "S3	Nharu/fx#13	$SHA_C	실패	0	1	lint, unit	lint, unit, deploy" \
  "S4	Nharu/fx#14	$SHA_D	미등록	0	0	없음	-" \
  "S1	Nharu/fx#11	$SHA_A	통과	0	0	lint	-" \
  "S3	Nharu/fx#13	$SHA_C	실패	1	1	lint, unit	lint, unit, deploy" \
  "S4	Nharu/fx#14	$SHA_D	대기	0	0	없음	-")
check "R1 대조한 전이 줄이 의도한 상태들이다" "$(cat "$WORK/r1b.p4.lines")" "$r1_want"
if grep -q '^call --from-snapshot rc=0$' "$WORK/r1b.p1.out" 2>/dev/null \
   || grep -q '^call --once rc=' "$WORK/r1b.p1.out" 2>/dev/null; then
  ok "R1 모듈이 스냅숏 판을 실제로 불렀다"
else
  bad "R1 판정 호출" "$(tr '\n' '|' < "$WORK/r1b.p1.out")"
fi
check "R1 p4: 질의가 깨진 바퀴에는 판정 호출이 없다" \
  "$( { grep -c '^call --once' "$WORK/r1b.p4.out" || true; } | tr -d ' ')" 0

# ===========================================================================
# F. The fence: the module's only child is `gh api graphql` with a query that
# starts with `query` and carries no `mutation`, even when a branch name does;
# the module names no notifier; no notifier is ever reached.
# ===========================================================================
R_F=$(make_run 20261101-000000f1)
( cd "$WORK/wt2" && git checkout -q -b seg/mutation-fix ) >/dev/null 2>&1
printf -- '- `segment` | 교대=0 | id=S6 | 상태=실행중 | 워크트리=%s | prev=bbbb\n' "$WORK/wt2" >> "$(ledger_of "$R_F")"
printf 'p1\n' > "$FX/phase"
: > "$GH_LOG"
python3 "$WORK/drive.py" "$R_F/plugin/cc-cmds/orchestrator" "$R_F" "$(ledger_of "$R_F")" \
  "$(manifest_of "$R_F")" > "$WORK/f.out" 2>&1
check "F 모듈의 gh 호출은 모두 읽기 전용 graphql 질의다" \
  "$( { grep -vc '^api graphql -f query clean$' "$GH_LOG" || true; } | tr -d ' ')" 0
if grep -q '^api graphql ' "$GH_LOG"; then ok "F 모듈이 실제로 질의했다"; else bad "F 질의 기록" "$(cat "$GH_LOG")"; fi
check "F 모듈 파일에 알림 경로 이름이 없다" \
  "$( { grep -cE 'notify-run\.sh|terminal-notifier|osascript' "$ORCH/observer_checks.py" || true; } | tr -d ' ')" 0
( cd "$WORK/wt2" && git checkout -q seg/pass ) >/dev/null 2>&1

# ===========================================================================
# S. `--spec` prints one `<slug>\t<segment>\t<branch>` line per segment asked
# about and touches neither the pid record nor the observed file.
# ===========================================================================
R_S=$(make_run 20261101-000000b1)
spec_out=$(bash "$R_S/plugin/cc-cmds/orchestrator/checks.sh" --spec --run-dir "$R_S" \
  --ledger "$(ledger_of "$R_S")" --manifest "$(manifest_of "$R_S")" 2>/dev/null)
spec_want=$(printf 'Nharu/fx\tS%s\t%s\n' 1 seg/run 2 seg/pass 3 seg/fail 4 seg/none 5 seg/nopr)
check "S --spec 출력이 세그먼트마다 슬러그·세그먼트·브랜치 한 줄이다" "$spec_out" "$spec_want"
if [ ! -e "$R_S/checks.pid" ] && [ ! -e "$R_S/checks.observed" ]; then
  ok "S --spec 는 pid·관측 파일을 건드리지 않는다"
else
  bad "S --spec 의 파일" "$(ls "$R_S")"
fi

# ===========================================================================
# P. A `--once` pass handed `CC_OBSERVER_PID` writes that pid and leaves it.
# ===========================================================================
R_P=$(make_run 20261101-000000c1)
CC_OBSERVER_PID=424242 bash "$R_P/plugin/cc-cmds/orchestrator/checks.sh" --run-dir "$R_P" \
  --ledger "$(ledger_of "$R_P")" --manifest "$(manifest_of "$R_P")" --once >/dev/null 2>&1
check "P CC_OBSERVER_PID 의 --once 는 그 pid 를 남긴다" "$(tr -d '[:space:]' < "$R_P/checks.pid" 2>/dev/null)" 424242
R_P2=$(make_run 20261101-000000c2)
bash "$R_P2/plugin/cc-cmds/orchestrator/checks.sh" --run-dir "$R_P2" \
  --ledger "$(ledger_of "$R_P2")" --manifest "$(manifest_of "$R_P2")" --once >/dev/null 2>&1
if [ ! -e "$R_P2/checks.pid" ]; then ok "P 넘겨받은 pid 가 없는 --once 는 끝날 때 pid 를 지운다"; else bad "P pid 정리" "$(cat "$R_P2/checks.pid")"; fi

# ===========================================================================
# D. Delegation end to end: the unchanged kickoff line on a marked pinned copy
# ends 0, `checks.pid` names the observer, the observed lines are the ones the
# gh pass wrote for the same state, and `done` lets the job go and removes the
# pid record.
# ===========================================================================
pid_is() { [ "$(tr -d '[:space:]' 2>/dev/null < "$1")" = "$2" ]; } 2>/dev/null
pid_runs() { # pid_runs <pid file> <ERE> — the pid in the file is alive and runs that
  local p; p=$( { tr -d '[:space:]' < "$1"; } 2>/dev/null)
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  alive "$p" && ps -p "$p" -o command= 2>/dev/null | grep -qE "$2"
}
observed_lines() { [ -s "$1/checks.observed" ] && [ "$(grep -c '' < "$1/checks.observed" | tr -d ' ')" -ge "$2" ]; }

R_D=$(make_run 20261101-000000d1)
printf 'p1\n' > "$FX/phase"
: > "$GH_LOG"
bash "$R_D/plugin/cc-cmds/orchestrator/checks.sh" --run-dir "$R_D" --ledger "$(ledger_of "$R_D")" \
  --manifest "$(manifest_of "$R_D")" --interval 1 > "$R_D/checks.log" 2>&1 < /dev/null
check "D 기동 줄이 관측기에 넘기고 0 으로 끝난다" "$?" 0
OP=$(opid)
if [ -n "$OP" ] && alive "$OP"; then ok "D 관측기가 떠 있다"; else bad "D 관측기" "$(cat "$R_D/checks.log")"; fi
if pid_is "$R_D/checks.pid" "$OP"; then ok "D checks.pid 가 관측기 pid 다"; else bad "D checks.pid" "$(cat "$R_D/checks.pid" 2>/dev/null) vs $OP"; fi
if wait_for 30 observed_lines "$R_D" 4; then
  cut -f2- "$R_D/checks.observed" > "$WORK/d.lines"
  if diff "$WORK/r1a.p1.lines" "$WORK/d.lines" > "$WORK/d.diff"; then
    ok "D 위임된 관측 줄이 gh 판의 같은 상태 줄과 같다"
  else
    bad "D 관측 줄 대조" "$(tr '\n' '|' < "$WORK/d.diff")"
  fi
else
  bad "D 관측 줄" "$(cat "$R_D/checks.log") / $(tail -n 5 "$S/cc-cmds/observer/observer.log" 2>/dev/null)"
fi
check "D 관측기가 연 gh 호출은 graphql 질의뿐이다" \
  "$( { grep -vc '^api graphql -f query clean$' "$GH_LOG" || true; } | tr -d ' ')" 0
: > "$R_D/done"
if wait_for 30 test ! -e "$R_D/checks.pid"; then ok "D done 뒤 작업이 내려지고 checks.pid 가 지워진다"; else bad "D done 뒤" "$(cat "$R_D/checks.pid")"; fi
if [ ! -e "$R_D/checks.fallback" ]; then ok "D 정상 경로는 되돌림 표지를 남기지 않는다"; else bad "D fallback" "$(cat "$R_D/checks.fallback")"; fi

# ===========================================================================
# U. A pinned copy without the mark runs its own loop: `checks.pid` names the
# process running `checks.sh`, not the observer.
# ===========================================================================
R_U=$(make_run 20261101-000000e1)
rm -f "$R_U/plugin/cc-cmds/orchestrator/observer-protocol"
bash "$R_U/plugin/cc-cmds/orchestrator/checks.sh" --run-dir "$R_U" --ledger "$(ledger_of "$R_U")" \
  --manifest "$(manifest_of "$R_U")" --interval 1 > "$R_U/checks.log" 2>&1 < /dev/null &
U_PID=$!; STRAYS="$STRAYS $U_PID"
if wait_for 20 pid_is "$R_U/checks.pid" "$U_PID"; then
  ok "U 표지 없는 사본은 자기 루프를 돌고 checks.pid 가 그 pid 다"
else
  bad "U checks.pid" "$(cat "$R_U/checks.pid" 2>/dev/null) vs $U_PID"
fi
: > "$R_U/done"
if wait_for 20 eval '! alive "$U_PID"'; then ok "U 자기 루프는 done 으로 끝난다"; else bad "U 루프 종료" "$U_PID"; fi

# ===========================================================================
# B. A state the batch cannot cover (more contexts than one page) hands the run
# back: `checks.fallback` appears, the job is dropped, and `checks.pid` names a
# process running the run's own `checks.sh`.
# ===========================================================================
copy_old p1 pf
cat > "$FX/gql/pf.json" <<EOF
{"branches": {
  "seg/run":  {"number": 11, "sha": "$SHA_A", "contexts": $gql_p1_run, "more": true},
  "seg/pass": {"number": 12, "sha": "$SHA_B", "contexts": $gql_pass},
  "seg/fail": {"number": 13, "sha": "$SHA_C", "contexts": $gql_fail},
  "seg/none": {"number": 14, "sha": "$SHA_D", "contexts": []}
}}
EOF
printf 'pf\n' > "$FX/phase"
R_B=$(make_run 20261101-000000f2)
bash "$R_B/plugin/cc-cmds/orchestrator/checks.sh" --run-dir "$R_B" --ledger "$(ledger_of "$R_B")" \
  --manifest "$(manifest_of "$R_B")" --interval 1 > "$R_B/checks.log" 2>&1 < /dev/null
check "B 기동 줄은 위임하고 0 으로 끝난다" "$?" 0
if wait_for 30 test -e "$R_B/checks.fallback"; then ok "B 덮지 못하는 상태에서 checks.fallback 이 생긴다"; else bad "B fallback" "$(tail -n 5 "$S/cc-cmds/observer/observer.log" 2>/dev/null)"; fi
if wait_for 30 pid_runs "$R_B/checks.pid" '(^|/)checks\.sh( |$)'; then
  ok "B 되돌린 런은 checks.sh 가 자기 루프를 돈다"
  STRAYS="$STRAYS $(tr -d '[:space:]' < "$R_B/checks.pid")"
else
  bad "B checks.pid" "$(cat "$R_B/checks.pid" 2>/dev/null)"
fi
: > "$R_B/done"

# ===========================================================================
# L. The fleet's liveness reads a pid running `observer.py serve` as the live
# poller and watcher, and an unrelated process still as dead.
# ===========================================================================
awk '/^fleet_reentry_(poller|watcher|script)_live\(\) \{/{f=1} f{print} f && /^\}/{f=0}' \
  "$ORCH/fleet.sh" > "$WORK/fleet-live.sh"
R_L="$WORK/live-run"; mkdir -p "$R_L"
sleep 60 & SLEEPER=$!; disown "$SLEEPER" 2>/dev/null; STRAYS="$STRAYS $SLEEPER"
OP=$(opid)
if [ -z "$OP" ] || ! alive "$OP"; then
  bad "L 관측기" "관측기가 떠 있지 않다"
else
  l_check() { # l_check <pid> — prints poller/watcher verdicts as `<0|1> <0|1>`
    printf '%s' "$1" > "$R_L/checks.pid"; printf '%s' "$1" > "$R_L/watch.pid"
    ( . "$ORCH/liveness.sh"; . "$WORK/fleet-live.sh"
      a=1; b=1
      fleet_reentry_poller_live "$R_L" && a=0
      fleet_reentry_watcher_live "$R_L" && b=0
      printf '%s %s' "$a" "$b" )
  }
  check "L 관측기 pid 를 산 폴러·감시기로 읽는다" "$(l_check "$OP")" "0 0"
  check "L 무관한 프로세스 pid 는 여전히 죽은 것으로 읽는다" "$(l_check "$SLEEPER")" "1 1"
fi

check "알림 도구가 한 번도 불리지 않았다" "$( [ -s "$NOTE_LOG" ] && cat "$NOTE_LOG" )" ""

printf '\ntest-observer-checks: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
