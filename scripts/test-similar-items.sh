#!/usr/bin/env bash
# Test the similar-item lookup (`plugins/cc-cmds/orchestrator/similar-items.py`)
# and its measurement harness, offline.
#
# The judgment endpoint is a loopback `http.server` stub that records every
# request it receives, and `gh` is a PATH stub. Nothing here reaches a network
# or reads a real credential: the credential store is always pointed into the
# work directory. Temporary files live under one `mktemp -d` only.
#
# WHAT THE GATE'S OWN SUITE CANNOT SEE. `scripts/test-gate.sh` pins how the gate
# grades this tool's argv — a read under `--lexical-only`/`--replay-log`, an
# external state change without them. That grade is only honest if the tool
# really sends nothing under those flags, which is a property of the tool, not
# of the gate. It is pinned here (zero requests under both flags), together with
# the request bytes the recorded measurement depends on and the lookup's
# fallback behaviour.
#
# Usage: bash scripts/test-similar-items.sh

set -uo pipefail

# Inherited pipeline variables change what the tool is allowed to do inside an
# unattended stage while CI has none of them, so an assertion could pass in CI
# and fail only in a stage. Nothing below depends on them.
for v in $(compgen -v CC_PIPELINE_); do unset "$v"; done

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
SI="$ORCH/similar-items.py"
TRACKER="$ORCH/cc_tracker.py"
MEASURE="$repo_root/scripts/measure-similar-items.py"

python3 --version

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-similar-items-test.XXXXXX")
STUB_PID=''
cleanup() {
  if [ -n "$STUB_PID" ]; then kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

passed=0
failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

status_before=$(cd "$repo_root" && git status --porcelain)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# The judgment stub. The mode file is re-read on every request, so a case
# switches behaviour without restarting the server.
cat > "$WORK/stub.py" <<'PYEOF'
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
work = sys.argv[1]
lock = threading.Lock()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def reply(self, code, payload=b""):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with lock, open(os.path.join(work, "reqlog.jsonl"), "a") as f:
            f.write(json.dumps({"auth": self.headers.get("Authorization"), "body": raw.decode("utf-8")}) + "\n")
        with open(os.path.join(work, "mode.json")) as f:
            mode = json.load(f)
        kind = mode.get("kind", "fixed")
        if kind == "hang":
            time.sleep(60)
            return
        if kind != "fixed":
            self.reply(int(kind))
            return
        cand = list(json.loads(raw)["state"].values())[1]
        if cand["title"] in mode.get("fail", []):
            self.reply(mode.get("fail_code", 422))
            return
        p = mode.get("probs", {}).get(cand["title"], 0.5)
        self.reply(200, json.dumps({"model": mode.get("model", "jev-1.13.0"),
                                    "answers": {"same_place": {"type": "noul", "noul": p}}}).encode())
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
with open(os.path.join(work, "port.tmp"), "w") as f:
    f.write(str(srv.server_address[1]))
os.rename(os.path.join(work, "port.tmp"), os.path.join(work, "port"))
srv.serve_forever()
PYEOF
printf '{"kind": "fixed"}\n' > "$WORK/mode.json"
python3 "$WORK/stub.py" "$WORK" &
STUB_PID=$!
for _ in $(seq 1 100); do [ -s "$WORK/port" ] && break; sleep 0.1; done
PORT=$(cat "$WORK/port" 2>/dev/null)
if [ -z "$PORT" ]; then
  bad "루프백 스텁이 뜬다" "포트 파일이 없다"
  exit 1
fi

# `gh` stub: records argv, answers `issue list` / `issue view` from files.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'SHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB_DIR/gh.argv"
case "$1 $2" in
  "issue list") src=$(cat "$GH_STUB_DIR/gh.list") ;;
  "issue view") src=$(cat "$GH_STUB_DIR/gh.view") ;;
  *) exit 1 ;;
esac
[ "$src" = fail ] && exit 1
cat "$src"
SHEOF
chmod 755 "$WORK/bin/gh"
GH_STUB_DIR="$WORK"; export GH_STUB_DIR
PATH="$WORK/bin:$PATH"; export PATH

SENTINEL='sk-sentinel-5f3a9c'
mkdir -p "$WORK/store-empty" "$WORK/store-good" "$WORK/store-644"
printf 'TYPESAFE_API_KEY="%s"\n' "$SENTINEL" > "$WORK/store-good/typesafe.env"
chmod 600 "$WORK/store-good/typesafe.env"
printf 'TYPESAFE_API_KEY="%s"\n' "$SENTINEL" > "$WORK/store-644/typesafe.env"
chmod 644 "$WORK/store-644/typesafe.env"

CC_SIMILAR_JEV_URL="http://127.0.0.1:$PORT"; export CC_SIMILAR_JEV_URL
CC_CMDS_CRED_STORE="$WORK/store-empty"; export CC_CMDS_CRED_STORE

# Korean, English, one-syllable Hangul (which is not a token) and digits. The
# expected order below was computed beforehand from the measurement's own
# definition, not from this tool.
cat > "$WORK/lex.json" <<'JSONEOF'
[
{"number": 1, "title": "게이트 잠금 lockf 75 실패", "body": "설계 문서 잠금이 lockf 로 75 를 돌려준다. 수 차례 재시도해도 같다.", "url": "https://github.com/o/r/issues/1"},
{"number": 2, "title": "lockf 잠금 충돌", "body": "형제 세그먼트가 같은 문서를 쓴다. 75 가 나온다.", "url": "https://github.com/o/r/issues/2"},
{"number": 3, "title": "README 생성기 오류", "body": "yq 가 없으면 README 가 비는 수 가 있다.", "url": "https://github.com/o/r/issues/3"},
{"number": 4, "title": "게이트 등급 행 누락", "body": "새 스크립트 이름에 등급 미상. 게이트 사본이 오래됐다.", "url": "https://github.com/o/r/issues/4"},
{"number": 5, "title": "Merge queue stalls", "body": "The merge step waits forever when CI is red.", "url": "https://github.com/o/r/issues/5"},
{"number": 6, "title": "설계 문서 동결 해시", "body": "동결 뒤 문서 해시가 바뀌면 게이트가 멈춘다. 설계 문서 재수렴.", "url": "https://github.com/o/r/issues/6"},
{"number": 7, "title": "Notification noise", "body": "terminal-notifier fires twice per turn.", "url": "https://github.com/o/r/issues/7"},
{"number": 8, "title": "재시도 예산 초과", "body": "재시도 두 번 뒤에도 실패하면 lockf 대신 대기한다.", "url": "https://github.com/o/r/issues/8"},
{"number": 9, "title": "숫자 1234 와 75 비교", "body": "75 1234 5678 v2.25.3 실패", "url": "https://github.com/o/r/issues/9"},
{"number": 10, "title": "한 글자 수 문 제", "body": "가 나 다 라 마 바", "url": "https://github.com/o/r/issues/10"}
]
JSONEOF
LEX_ORDER='[2, 6, 9, 4, 8, 3, 5, 7, 10]'

# Two candidates and one query.
cat > "$WORK/small.json" <<'JSONEOF'
[
{"number": 1, "title": "lockf 잠금 실패", "body": "lockf 75", "url": ""},
{"number": 2, "title": "lockf 잠금 충돌", "body": "lockf 75 재현", "url": ""},
{"number": 3, "title": "잠금 파일 경로", "body": "lockf 경로", "url": ""}
]
JSONEOF
printf '[{"number": 1, "title": "lonely", "body": "only item", "url": ""}]\n' > "$WORK/alone.json"

# The synthetic pair whose request bytes are pinned. The digest was computed
# beforehand from the measurement client's request shape.
cat > "$WORK/pair.json" <<'JSONEOF'
[
{"number": 9001, "title": "Gate lock", "body": "문서 잠금 실패 #7"},
{"number": 9002, "title": "Lock skew", "body": "lockf 가 75 를 돌려준다"}
]
JSONEOF
PAIR_SHA='e03de204d603c1bd1666f317d9d61ed9abc354ecaa4fdeb22e8f9420932d39f1'

python3 - "$WORK" <<'PYEOF'
import json, os, sys
w = sys.argv[1]
# Twenty-one items sharing one token: equal overlap, so lexical order is corpus order.
json.dump([{"number": i, "title": "item-%d" % i, "body": "shared alpha-%d" % i, "url": ""} for i in range(1, 22)],
          open(os.path.join(w, "twenty.json"), "w"))
# Exactly the corpus limit.
json.dump([{"number": i, "title": "bulk %d" % i, "body": "bulk entry %d" % i, "url": "https://github.com/o/r/issues/%d" % i}
           for i in range(1, 3001)], open(os.path.join(w, "bulk.json"), "w"))
# A long candidate body, cut at 3500 characters in the request.
json.dump([{"number": 1, "title": "long query", "body": "short"},
           {"number": 2, "title": "long candidate", "body": "가" * 5000}], open(os.path.join(w, "long.json"), "w"))
PYEOF

run_si() { "$SI" "$@" > "$WORK/out" 2> "$WORK/err"; }
jf() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$WORK/out" "$1"; }
reqs() { if [ -f "$WORK/reqlog.jsonl" ]; then wc -l < "$WORK/reqlog.jsonl" | tr -d ' '; else echo 0; fi; }
reset_reqs() { : > "$WORK/reqlog.jsonl"; }
set_mode() { printf '%s\n' "$1" > "$WORK/mode.json"; }
header() { head -1 "$WORK/out"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "'$3' 없음: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "'$3' 있음" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
# 1. Syntax, executable bits, documented call spelling, abbreviations
# ---------------------------------------------------------------------------
if PYTHONPYCACHEPREFIX="$WORK/pycache" python3 -m py_compile "$SI" "$TRACKER" "$MEASURE"; then
  ok "세 파일이 컴파일된다"
else
  bad "세 파일이 컴파일된다" "py_compile 실패"
fi
for f in "$SI" "$MEASURE"; do
  if [ -x "$f" ]; then ok "$(basename "$f") 에 실행 비트가 있다"
  else bad "$(basename "$f") 에 실행 비트가 있다" "인터프리터를 앞에 두면 게이트가 불투명한 워크트리 쓰기로 매긴다"; fi
done
check "similar-items.py 셔뱅" "$(head -1 "$SI")" "#!/usr/bin/env python3"
check "measure-similar-items.py 셔뱅" "$(head -1 "$MEASURE")" "#!/usr/bin/env python3"

# EVERY occurrence of the tool name must sit in a code span that begins with
# `<plugin root>/orchestrator/`. The call sits mid-bullet, so this is judged per
# occurrence, not per line start. Prose naming a wrong spelling would have to
# write something other than the tool's file name.
CALL='<plugin root>/orchestrator/similar-items.py'
for f in plugins/cc-cmds/skills/github-ops/SKILL.md plugins/cc-cmds/skills/design/SKILL.md; do
  total=$(grep -o 'similar-items\.py' "$repo_root/$f" | wc -l | tr -d ' ')
  good=0
  while IFS= read -r span; do
    case "$span" in
      *similar-items.py*)
        case "$span" in
          '`'"$CALL"*) good=$((good + $(printf '%s\n' "$span" | grep -o 'similar-items\.py' | wc -l | tr -d ' '))) ;;
        esac ;;
    esac
  done < <(grep -o '`[^`]*`' "$repo_root/$f")
  if [ "$total" -gt 0 ]; then ok "$f — 도구 호출이 있다"; else bad "$f — 도구 호출이 있다" "매치 없음"; fi
  check "$f — 모든 출현이 \`<plugin root>/orchestrator/\` 로 시작하는 코드 스팬 안이다" "$good" "$total"
done
DEF='is the directory holding `orchestrator/` and `skills/`'
sec6=$(sed -n '/^## 6\. /,$p' "$repo_root/plugins/cc-cmds/skills/github-ops/SKILL.md")
has "github-ops — 호출 절에 <plugin root> 정의 문장이 있다" "$sec6" "$DEF"
design_line=$(grep -F "$CALL" "$repo_root/plugins/cc-cmds/skills/design/SKILL.md" || true)
has "design — 호출 글머리에 <plugin root> 정의 문장이 있다" "$design_line" "$DEF"

"$SI" file --corpus "$WORK/lex.json" --issue 1 --lo x > /dev/null 2>&1
check "similar-items.py — 접두 약어 --lo 는 2" "$?" "2"
"$SI" file --corpus "$WORK/lex.json" --issue 1 --liv > /dev/null 2>&1
check "similar-items.py — 접두 약어 --liv 는 2" "$?" "2"
"$MEASURE" --data-dir "$WORK" --lo x > /dev/null 2>&1
check "measure-similar-items.py — 접두 약어 --lo 는 2" "$?" "2"
"$MEASURE" --data-dir "$WORK" --liv > /dev/null 2>&1
check "measure-similar-items.py — 접두 약어 --liv 는 2" "$?" "2"
"$MEASURE" --data-dir "$WORK" --patient > /dev/null 2>&1
check "measure-similar-items.py — --live 없는 --patient 는 2" "$?" "2"

# ---------------------------------------------------------------------------
# 2. Lexical order matches the measurement definition
# ---------------------------------------------------------------------------
run_si file --corpus "$WORK/lex.json" --issue 1 --lexical-only --format json
check "어휘 순서가 미리 계산한 기대 순서와 같다" \
  "$(jf '[c["id"] for c in sorted(d["candidates"], key=lambda c: c["lexical"])]')" "$LEX_ORDER"
check "어휘 전용 상태" "$(jf 'd["status"]')" "lexical"

# ---------------------------------------------------------------------------
# 3. Request shape
# ---------------------------------------------------------------------------
reset_reqs
set_mode '{"kind": "fixed"}'
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/pair.json" --issue 9001 --format json
check "합성 쌍 요청이 1건 갔다" "$(reqs)" "1"
got_sha=$(python3 -c 'import hashlib,json,sys; r=json.loads(open(sys.argv[1]).readline()); print(hashlib.sha256(r["body"].encode("utf-8")).hexdigest())' "$WORK/reqlog.jsonl")
check "요청 본문이 미리 적은 바이트와 같다" "$got_sha" "$PAIR_SHA"
shape=$(python3 -c '
import json,sys
r=json.loads(open(sys.argv[1]).readline()); b=json.loads(r["body"])
print(b["model"], b["questions"]["same_place"]["type"], sorted(b["state"]), [sorted(v) for v in b["state"].values()], "9002" in r["body"], "9001" in r["body"])' "$WORK/reqlog.jsonl")
check "모델·질문 형식·상태 키에 번호가 없다" "$shape" "jev-1.13.0 noul ['issue_a', 'issue_b'] [['body', 'title'], ['body', 'title']] False False"
reset_reqs
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/long.json" --issue 1 --format json
check "후보 본문은 3500자에서 잘린다" \
  "$(python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); print(len(json.loads(r["body"])["state"]["issue_b"]["body"]))' "$WORK/reqlog.jsonl")" "3500"

# ---------------------------------------------------------------------------
# 4. Semantic re-rank
# ---------------------------------------------------------------------------
# 6 and 4 tie at 0.7; 6 is ahead lexically but behind in the corpus, so the
# tie shows which order breaks it.
reset_reqs
set_mode '{"kind": "fixed", "probs": {"lockf 잠금 충돌": 0.3, "설계 문서 동결 해시": 0.7, "숫자 1234 와 75 비교": 0.9, "게이트 등급 행 누락": 0.7, "재시도 예산 초과": 0.1}}'
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/lex.json" --issue 1 --format json
check "확률 순서, 동률은 어휘 순서" "$(jf '[c["id"] for c in d["candidates"]]')" "[9, 6, 4, 3, 5, 7, 10, 2, 8]"
check "전부 판정되면 semantic" "$(jf 'd["status"]')" "semantic"
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/lex.json" --issue 1
check "텍스트 출력은 머리줄과 상위 3건뿐이다" "$(wc -l < "$WORK/out" | tr -d ' ')" "4"
check "첫 후보 줄" "$(sed -n 2p "$WORK/out" | cut -f1-3)" "$(printf '1\t#9\t0.90')"
has "머리줄" "$(header)" "status=semantic source=file:lex.json corpus=10 shortlist=9 judged=9 model=jev-1.13.0"

# ---------------------------------------------------------------------------
# 5. No key
# ---------------------------------------------------------------------------
reset_reqs
run_si file --corpus "$WORK/lex.json" --issue 1
has "키 없음 — lexical" "$(header)" "status=lexical"
check "키 없음 — 알림 한 줄" "$(grep -c '^notice: ' "$WORK/out")" "1"
has "키 없음 — 알림 문면" "$(grep '^notice: ' "$WORK/out")" "(사유: 판정 키 없음)"
check "키 없음 — 후보 줄이 있다" "$(grep -c "$(printf '^[0-9]\t')" "$WORK/out")" "3"
check "키 없음 — 요청 0건" "$(reqs)" "0"
run_si file --corpus "$WORK/lex.json" --issue 1 --format json
check "키 없음 — reason" "$(jf 'd["reason"]')" "key-absent"

# ---------------------------------------------------------------------------
# 6. Key file mode 644, and the key value never leaves the process
# ---------------------------------------------------------------------------
reset_reqs
CC_CMDS_CRED_STORE="$WORK/store-644" run_si file --corpus "$WORK/lex.json" --issue 1 --format json --log "$WORK/k644.log"
check "모드 644 — key-invalid" "$(jf 'd["reason"]')" "key-invalid"
check "모드 644 — 요청 0건" "$(reqs)" "0"
leak=$(cat "$WORK/out" "$WORK/err" "$WORK/k644.log" 2>/dev/null)
hasnt "모드 644 — 키 값이 출력·로그에 없다" "$leak" "$SENTINEL"
reset_reqs
set_mode '{"kind": "fixed"}'
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/lex.json" --issue 1 --format json --log "$WORK/good.log"
check "유효 키 — Bearer 로 보낸다" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["auth"])' "$WORK/reqlog.jsonl")" "Bearer $SENTINEL"
leak=$(cat "$WORK/out" "$WORK/err" "$WORK/good.log")
hasnt "유효 키 — 키 값이 출력·로그에 없다" "$leak" "$SENTINEL"
check "유효 키 — 로그가 쌍마다 한 줄" "$(wc -l < "$WORK/good.log" | tr -d ' ')" "9"

# ---------------------------------------------------------------------------
# 7. Rejection: no retry
# ---------------------------------------------------------------------------
reset_reqs
set_mode '{"kind": "401"}'
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/small.json" --issue 1 --format json
check "401 — 쌍마다 요청 1건" "$(reqs)" "2"
check "401 — lexical" "$(jf 'd["status"]')" "lexical"
check "401 — reason" "$(jf 'd["reason"]')" "http:401"
has "401 — 알림" "$(jf 'd["notice"]')" "(사유: 판정 요청 거부 HTTP 401)"

# ---------------------------------------------------------------------------
# 8. Retries and the deadline
# ---------------------------------------------------------------------------
reset_reqs
set_mode '{"kind": "503"}'
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/small.json" --issue 1 --format json
check "503 — 쌍마다 3건(재시도 2)" "$(reqs)" "6"
check "503 — lexical" "$(jf 'd["status"]')" "lexical"
has "503 — 알림" "$(jf 'd["notice"]')" "(사유: 판정 응답 없음)"
set_mode '{"kind": "hang"}'
start=$SECONDS
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/small.json" --issue 1 --format json
elapsed=$((SECONDS - start))
if [ "$elapsed" -le 35 ]; then ok "무응답 — 35초 안에 끝난다 (${elapsed}s)"; else bad "무응답 — 35초 안에 끝난다" "${elapsed}s"; fi
check "무응답 — timeout" "$(jf 'd["reason"]')" "timeout"
check "무응답 — 종료 코드 0 과 lexical" "$(jf 'd["status"]')" "lexical"

# ---------------------------------------------------------------------------
# 9. Partial failure
# ---------------------------------------------------------------------------
probs=$(python3 -c 'import json; print(json.dumps({"item-%d" % i: i / 100 for i in range(1, 22)}))')
set_mode "{\"kind\": \"fixed\", \"probs\": $probs, \"fail\": [\"item-3\", \"item-7\", \"item-11\", \"item-15\", \"item-19\"]}"
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/twenty.json" --issue 1 --format json
check "5건 실패 — partial" "$(jf 'd["status"]')" "partial"
check "5건 실패 — 판정 앞(확률 순)·미판정 뒤(어휘 순)" "$(jf '[c["id"] for c in d["candidates"]]')" \
  "[21, 20, 18, 17, 16, 14, 13, 12, 10, 9, 8, 6, 5, 4, 2, 3, 7, 11, 15, 19]"
has "5건 실패 — 알림이 수를 적는다" "$(jf 'd["notice"]')" "후보 20건 중 5건은 의미 판정을 받지 못해"
fail18=$(python3 -c 'import json; print(json.dumps(["item-%d" % i for i in range(2, 22) if i not in (2, 4)]))')
set_mode "{\"kind\": \"fixed\", \"probs\": $probs, \"fail\": $fail18}"
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/twenty.json" --issue 1 --format json
check "18건 실패 — lexical" "$(jf 'd["status"]')" "lexical"
check "18건 실패 — 어휘 순서 그대로" "$(jf '[c["id"] for c in d["candidates"]][:3]')" "[2, 3, 4]"
set_mode '{"kind": "fixed"}'
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/small.json" --issue 1 --format json
check "후보 2건 둘 다 판정 — semantic" "$(jf 'd["status"]')" "semantic"
set_mode '{"kind": "fixed", "fail": ["잠금 파일 경로"]}'
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/small.json" --issue 1 --format json
check "후보 2건 중 하나만 판정 — lexical" "$(jf 'd["status"]')" "lexical"
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/alone.json" --issue 1 --format json
check "질의 하나뿐 — lexical" "$(jf 'd["status"]')" "lexical"
check "질의 하나뿐 — no-candidates" "$(jf 'd["reason"]')" "no-candidates"

# ---------------------------------------------------------------------------
# 10. Offline flags send nothing, even with a valid key
# ---------------------------------------------------------------------------
set_mode '{"kind": "fixed"}'
reset_reqs
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/lex.json" --issue 1 --lexical-only --format json
check "--lexical-only — 요청 0건" "$(reqs)" "0"
check "--lexical-only — reason" "$(jf 'd["reason"]')" "requested"
printf '' > "$WORK/empty-replay.jsonl"
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/lex.json" --issue 1 --replay-log "$WORK/empty-replay.jsonl" --format json
check "--replay-log — 요청 0건" "$(reqs)" "0"

# ---------------------------------------------------------------------------
# 11. Replay
# ---------------------------------------------------------------------------
# The hashes come from a logged live run; test 3 pins those bytes separately.
set_mode '{"kind": "fixed"}'
rm -f "$WORK/cap.log"
CC_CMDS_CRED_STORE="$WORK/store-good" run_si file --corpus "$WORK/small.json" --issue 1 --format json --log "$WORK/cap.log"
python3 - "$WORK" <<'PYEOF'
import json, os, sys
w = sys.argv[1]
recs = [json.loads(l) for l in open(os.path.join(w, "cap.log"))]
def rec(tag, sha, p):
    return json.dumps({"tag": tag, "req_sha": sha, "resp": {"model": "jev-1.13.0", "answers": {"same_place": {"type": "noul", "noul": p}}}})
sha = {r["tag"].split(":")[1]: r["req_sha"] for r in recs}
with open(os.path.join(w, "replay-full.jsonl"), "w") as f:
    f.write(rec("A:1:2", sha["2"], 0.1) + "\n")
    f.write(rec("A:1:3", sha["3"], 0.4) + "\n")
    f.write(rec("B:1:2", sha["2"], 0.9) + "\n")
    f.write(rec("B:1:3", sha["3"], 0.4) + "\n")
with open(os.path.join(w, "replay-miss.jsonl"), "w") as f:
    f.write(rec("B:1:2", sha["2"], 0.9) + "\n")
PYEOF
reset_reqs
run_si file --corpus "$WORK/small.json" --issue 1 --replay-log "$WORK/replay-full.jsonl" --replay-tag-prefix B: --format json
check "재생 — 해시가 다 맞으면 semantic" "$(jf 'd["status"]')" "semantic"
check "재생 — 접두 B: 가 고른 답" "$(jf '[c["p"] for c in d["candidates"] if c["id"] == 2][0]')" "0.9"
run_si file --corpus "$WORK/small.json" --issue 1 --replay-log "$WORK/replay-full.jsonl" --replay-tag-prefix A: --format json
check "재생 — 접두 A: 가 고른 답" "$(jf '[c["p"] for c in d["candidates"] if c["id"] == 2][0]')" "0.1"
run_si file --corpus "$WORK/small.json" --issue 1 --replay-log "$WORK/replay-miss.jsonl" --replay-tag-prefix B: --format json
check "재생 — 해시가 없는 쌍은 실패로 친다" "$(jf 'd["judged"]')" "1"
check "재생 — 요청 0건" "$(reqs)" "0"

# ---------------------------------------------------------------------------
# 12. Endpoint override is loopback only
# ---------------------------------------------------------------------------
CC_SIMILAR_JEV_URL='https://example.com' run_si file --corpus "$WORK/lex.json" --issue 1 --lexical-only
check "루프백이 아닌 판정 URL 재정의는 2" "$?" "2"
CC_SIMILAR_JEV_URL="http://localhost:$PORT" run_si file --corpus "$WORK/lex.json" --issue 1 --lexical-only
check "localhost 재정의는 받는다" "$?" "0"

# ---------------------------------------------------------------------------
# 13. gh adapter
# ---------------------------------------------------------------------------
: > "$WORK/gh.argv"
printf '%s\n' "$WORK/lex.json" > "$WORK/gh.list"
printf 'fail\n' > "$WORK/gh.view"
run_si github --issue 1 --lexical-only --format json
has "gh — 목록 인자" "$(head -1 "$WORK/gh.argv")" "issue list --state open --limit 3000 --json number,title,body,url"
gh_order=$(jf '[c["id"] for c in d["candidates"]]')
check "gh — source 는 url 에서 읽는다" "$(jf 'd["source"]')" "github:o/r"
run_si file --corpus "$WORK/lex.json" --issue 1 --lexical-only --format json
check "gh — file 어댑터와 순위가 같다" "$gh_order" "$(jf '[c["id"] for c in d["candidates"]]')"
printf 'fail\n' > "$WORK/gh.list"
run_si github --issue 1 --lexical-only --format json
rc=$?
check "gh 실패 — 종료 코드 0" "$rc" "0"
check "gh 실패 — unavailable" "$(jf 'd["status"]')" "unavailable"
check "gh 실패 — reason" "$(jf 'd["reason"]')" "corpus"
printf '%s\n' "$WORK/bulk.json" > "$WORK/gh.list"
run_si github --repo o/r --issue 1 --lexical-only --format json
has "gh — 한도에 닿으면 절단 알림" "$(jf 'd["notice"]')" "열린 항목이 3000건 이상이라 앞의 3000건만 대조했다."
printf '%s\n' "$WORK/lex.json" > "$WORK/gh.list"
printf '{"number": 77, "title": "lockf 잠금 충돌 재현", "body": "형제 세그먼트 lockf 75", "url": "https://github.com/o/r/issues/77"}\n' > "$WORK/view.json"
printf '%s\n' "$WORK/view.json" > "$WORK/gh.view"
: > "$WORK/gh.argv"
run_si github --issue 77 --lexical-only --format json
has "목록 밖 N — issue view 를 부른다" "$(cat "$WORK/gh.argv")" "issue view 77 --json number,title,body,url"
check "목록 밖 N — 그 항목이 질의가 된다" "$(jf 'd["candidates"][0]["id"]')" "2"
check "목록 밖 N — 코퍼스 전체가 후보다" "$(jf 'd["shortlist"]')" "10"
printf 'fail\n' > "$WORK/gh.view"
run_si github --issue 77 --lexical-only --format json
rc=$?
check "질의도 못 얻으면 — 종료 코드 0" "$rc" "0"
check "질의도 못 얻으면 — unavailable" "$(jf 'd["status"]')" "unavailable"
check "질의도 못 얻으면 — reason" "$(jf 'd["reason"]')" "query"

# ---------------------------------------------------------------------------
# 14. The checkout stays clean
# ---------------------------------------------------------------------------
if [ -e "$ORCH/__pycache__" ]; then
  bad "조회 뒤에도 orchestrator/__pycache__ 가 없다" "$ORCH/__pycache__"
else
  ok "조회 뒤에도 orchestrator/__pycache__ 가 없다"
fi
if grep -Eq '^[[:space:]]*(import|from)[[:space:]]+cc_tracker' "$MEASURE"; then
  bad "하니스는 cc_tracker 를 import 하지 않는다" "$MEASURE"
else
  ok "하니스는 cc_tracker 를 import 하지 않는다"
fi
check "시험 전후 git status 가 같다" "$(cd "$repo_root" && git status --porcelain)" "$status_before"

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
