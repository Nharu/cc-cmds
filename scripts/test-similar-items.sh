#!/usr/bin/env bash
# Test the similar-item lookup (`plugins/cc-cmds/orchestrator/similar-items.py`),
# its ClickUp adapter, the ClickUp ticket creator (`clickup-create.py`) and the
# measurement harness, offline.
#
# The judgment endpoint and the ClickUp API (under the `/cu` path prefix) are
# one loopback `http.server` stub that records every request it receives, and
# `gh` is a PATH stub. Nothing here reaches a network or reads a real
# credential: the credential store is always pointed into the work directory.
# Temporary files live under one `mktemp -d` only.
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
CREATE="$ORCH/clickup-create.py"
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

# The judgment stub, which also answers the ClickUp API under `/cu`. The mode
# files are re-read on every request, so a case switches behaviour without
# restarting the server. A ClickUp GET is answered from `cu.json` (path with
# its query string → response) and a ClickUp POST by `cu-mode.json`; every
# ClickUp request is logged to `cu-reqlog.jsonl`.
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
    def clickup(self, method, raw):
        path = self.path[len("/cu"):]
        with lock, open(os.path.join(work, "cu-reqlog.jsonl"), "a") as f:
            f.write(json.dumps({"method": method, "path": path, "auth": self.headers.get("Authorization"),
                                "body": raw.decode("utf-8")}) + "\n")
        if method == "POST":
            with open(os.path.join(work, "cu-mode.json")) as f:
                code = json.load(f).get("create", 200)
            if code != 200:
                self.reply(code, b'{"err": "stub"}')
                return
            self.reply(200, json.dumps({"id": "NEW1", "url": "https://app.clickup.com/t/NEW1"}).encode())
            return
        with open(os.path.join(work, "cu.json")) as f:
            routes = json.load(f)
        if path not in routes:
            self.reply(404, b'{"err": "not found"}')
            return
        self.reply(200, json.dumps(routes[path]).encode())
    def do_GET(self):
        if self.path.startswith("/cu/"):
            self.clickup("GET", b"")
            return
        self.reply(404)
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.startswith("/cu/"):
            self.clickup("POST", raw)
            return
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
if PYTHONPYCACHEPREFIX="$WORK/pycache" python3 -m py_compile "$SI" "$TRACKER" "$MEASURE" "$CREATE"; then
  ok "네 파일이 컴파일된다"
else
  bad "네 파일이 컴파일된다" "py_compile 실패"
fi
for f in "$SI" "$MEASURE" "$CREATE"; do
  if [ -x "$f" ]; then ok "$(basename "$f") 에 실행 비트가 있다"
  else bad "$(basename "$f") 에 실행 비트가 있다" "인터프리터를 앞에 두면 게이트가 불투명한 워크트리 쓰기로 매긴다"; fi
done
check "similar-items.py 셔뱅" "$(head -1 "$SI")" "#!/usr/bin/env python3"
check "measure-similar-items.py 셔뱅" "$(head -1 "$MEASURE")" "#!/usr/bin/env python3"
check "clickup-create.py 셔뱅" "$(head -1 "$CREATE")" "#!/usr/bin/env python3"

# EVERY occurrence of a tool name must sit in a code span that begins with
# `<plugin root>/orchestrator/<that name>`. The call sits mid-bullet, so this is
# judged per occurrence, not per line start. Prose naming a wrong spelling would
# have to write something other than the tool's file name.
CALL='<plugin root>/orchestrator/similar-items.py'
CLICKUP_OPS=plugins/cc-cmds/skills/clickup-ops/SKILL.md
for pair in "github-ops/SKILL.md similar-items.py" "_common/requirements-interview.md similar-items.py" \
            "clickup-ops/SKILL.md similar-items.py" "clickup-ops/SKILL.md clickup-create.py"; do
  f="plugins/cc-cmds/skills/${pair%% *}"
  name="${pair#* }"
  pat=$(printf '%s' "$name" | sed 's/\./\\./g')
  total=$(grep -o "$pat" "$repo_root/$f" | wc -l | tr -d ' ')
  good=0
  while IFS= read -r span; do
    case "$span" in
      *"$name"*)
        case "$span" in
          '`<plugin root>/orchestrator/'"$name"*) good=$((good + $(printf '%s\n' "$span" | grep -o "$pat" | wc -l | tr -d ' '))) ;;
        esac ;;
    esac
  done < <(grep -o '`[^`]*`' "$repo_root/$f")
  if [ "$total" -gt 0 ]; then ok "$f — $name 호출이 있다"; else bad "$f — $name 호출이 있다" "매치 없음"; fi
  check "$f — $name 의 모든 출현이 \`<plugin root>/orchestrator/\` 로 시작하는 코드 스팬 안이다" "$good" "$total"
done
DEF='is the directory holding `orchestrator/` and `skills/`'
sec6=$(sed -n '/^## 6\. /,$p' "$repo_root/plugins/cc-cmds/skills/github-ops/SKILL.md")
has "github-ops — 호출 절에 <plugin root> 정의 문장이 있다" "$sec6" "$DEF"
interview_line=$(grep -F "$CALL" "$repo_root/plugins/cc-cmds/skills/_common/requirements-interview.md" || true)
has "requirements-interview — 호출 글머리에 <plugin root> 정의 문장이 있다" "$interview_line" "$DEF"
has "requirements-interview — ClickUp 티켓은 clickup --task 로 부른다" "$interview_line" \
  '`<plugin root>/orchestrator/similar-items.py clickup --task <ID|URL>`'
cu_sec3=$(sed -n '/^## 3\. /,/^## 4\. /p' "$repo_root/$CLICKUP_OPS")
cu_sec4=$(sed -n '/^## 4\. /,$p' "$repo_root/$CLICKUP_OPS")
has "clickup-ops ## 3. — <plugin root> 정의 문장이 있다" "$cu_sec3" "$DEF"
has "clickup-ops ## 4. — <plugin root> 정의 문장이 있다" "$cu_sec4" "$DEF"
STAGE_SENTENCE='When you are running as an unattended pipeline stage (`CC_PIPELINE_RUN_ID` is set), add `--lexical-only`, do not propose the candidates or ask about them, and copy the output lines — the `similar-items:` line, any `notice:` line and the candidate lines — verbatim into the report the stage writes when it finishes. Proceed with the original ticket'"'"'s scope.'
if printf '%s\n' "$cu_sec4" | grep -qxF "$STAGE_SENTENCE"; then
  ok "clickup-ops ## 4. — 무인 스테이지 문장이 바이트 그대로 있다"
else
  bad "clickup-ops ## 4. — 무인 스테이지 문장이 바이트 그대로 있다" "한 줄로 일치하는 문장 없음"
fi

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
# ClickUp fixtures
# ---------------------------------------------------------------------------
# Two workspaces; the query's space S1 sits in the SECOND one, so a lookup that
# took the first workspace on trust reads the wrong team. The space corpus is
# two pages. T2 has no `text_content`, so its body comes from `description`.
CU_SENTINEL='pk-cu-sentinel-81d2e4'
CU_BARE='pk-cu-bare-3c77a0'
mkdir -p "$WORK/store-cu" "$WORK/store-cu-644" "$WORK/store-cu-bare"
cp "$WORK/store-good/typesafe.env" "$WORK/store-cu/typesafe.env"
printf 'CLICKUP_API_TOKEN="%s"\n' "$CU_SENTINEL" > "$WORK/store-cu/clickup.env"
printf 'CLICKUP_API_TOKEN="%s"\n' "$CU_SENTINEL" > "$WORK/store-cu-644/clickup.env"
printf '%s\n' "$CU_BARE" > "$WORK/store-cu-bare/clickup.env"
chmod 600 "$WORK/store-cu/typesafe.env" "$WORK/store-cu/clickup.env" "$WORK/store-cu-bare/clickup.env"
chmod 644 "$WORK/store-cu-644/clickup.env"
python3 - "$WORK" <<'PYEOF'
import json, os, sys
w = sys.argv[1]
def t(i, name, lst, text="", desc=""):
    return {"id": i, "name": name, "text_content": text, "description": desc,
            "url": "https://app.clickup.com/t/" + i, "list": {"id": lst}, "space": {"id": "S1"}, "team_id": "200"}
T1 = t("T1", "게이트 잠금 lockf 실패", "L1", text="lockf 75 잠금")
T2 = t("T2", "lockf 잠금 충돌", "L1", desc="lockf 75 재현")
T3 = t("T3", "잠금 파일 경로", "L2", text="lockf 경로")
T4 = t("T4", "README 생성기", "L2", text="yq 없음")
T5 = t("T5", "lockf 잠금 재시도", "L1", text="lockf 75")
page = "/team/200/task?space_ids[]=S1&page=%d&include_closed=false&subtasks=true"
routes = {
    "/task/T1": T1,
    "/list/L1": {"id": "L1", "space": {"id": "S1"}},
    "/list/L9": {"id": "L9", "space": {"id": "S404"}},
    "/team": {"teams": [{"id": "100"}, {"id": "200"}]},
    "/team/100/space": {"spaces": [{"id": "S9"}]},
    "/team/200/space": {"spaces": [{"id": "S1"}]},
    page % 0: {"tasks": [T1, T2, T3], "last_page": False},
    page % 1: {"tasks": [T4, T5], "last_page": True},
}
json.dump(routes, open(os.path.join(w, "cu.json"), "w"), ensure_ascii=False)
PYEOF
printf '{"create": 200}\n' > "$WORK/cu-mode.json"
printf '잠금 lockf 75 충돌 초안\n' > "$WORK/cu-draft.md"
CC_SIMILAR_CLICKUP_URL="http://127.0.0.1:$PORT/cu"; export CC_SIMILAR_CLICKUP_URL
cu_reqs() { if [ -f "$WORK/cu-reqlog.jsonl" ]; then wc -l < "$WORK/cu-reqlog.jsonl" | tr -d ' '; else echo 0; fi; }
cu_reset() { : > "$WORK/cu-reqlog.jsonl"; }
cu_log() { python3 -c 'import json,sys; print(eval(sys.argv[2], {"r": [json.loads(l) for l in open(sys.argv[1])]}))' "$WORK/cu-reqlog.jsonl" "$1"; }

# ---------------------------------------------------------------------------
# 15. ClickUp lookup
# ---------------------------------------------------------------------------
cu_reset
CC_CMDS_CRED_STORE="$WORK/store-cu" run_si clickup --task T1 --lexical-only --format json
rc=$?
check "ClickUp --task — 종료 코드 0" "$rc" "0"
check "ClickUp --task — lexical" "$(jf 'd["status"]')" "lexical"
check "ClickUp --task — source 는 스페이스" "$(jf 'd["source"]')" "clickup:space/S1"
check "ClickUp --task — 두 쪽을 last_page 까지 받는다" "$(jf 'd["corpus"]')" "5"
check "ClickUp --task — 질의 티켓은 후보에서 빠진다" "$(jf 'sorted(c["id"] for c in d["candidates"])')" "['T2', 'T3', 'T4', 'T5']"
check "ClickUp --task — 같은 리스트 표지" \
  "$(jf 'sorted((c["id"], c["same_list"]) for c in d["candidates"])')" \
  "[('T2', True), ('T3', False), ('T4', False), ('T5', True)]"
check "ClickUp --task — 요청 경로" "$(cu_log '[x["path"] for x in r]')" \
  "['/task/T1', '/team/200/task?space_ids[]=S1&page=0&include_closed=false&subtasks=true', '/team/200/task?space_ids[]=S1&page=1&include_closed=false&subtasks=true']"
check "ClickUp — 인증 헤더는 Bearer 없는 토큰 그대로다" "$(cu_log 'sorted({x["auth"] for x in r})')" "['$CU_SENTINEL']"
hasnt "ClickUp — 토큰 값이 출력에 없다" "$(cat "$WORK/out" "$WORK/err")" "$CU_SENTINEL"

CC_CMDS_CRED_STORE="$WORK/store-cu" run_si clickup --task T1 --lexical-only
has "ClickUp text — 같은 리스트 후보 줄 끝에 표지" "$(grep "$(printf '\tT2\t')" "$WORK/out")" "$(printf '\thttps://app.clickup.com/t/T2\t같은 리스트')"
hasnt "ClickUp text — 다른 리스트 후보에는 표지가 없다" "$(grep "$(printf '\tT3\t')" "$WORK/out" || true)" "같은 리스트"
hasnt "ClickUp text — 티켓 id 앞에 # 가 없다" "$(sed -n '2,$p' "$WORK/out")" "#T"

cu_reset
CC_CMDS_CRED_STORE="$WORK/store-cu" run_si clickup --task https://app.clickup.com/t/T1 --lexical-only --format json
check "ClickUp --task URL — 경로에서 id 를 꺼낸다" "$(cu_log 'r[0]["path"]')" "/task/T1"
check "ClickUp --task URL — 같은 코퍼스" "$(jf 'd["corpus"]')" "5"

cu_reset
CC_CMDS_CRED_STORE="$WORK/store-cu" run_si clickup --list L1 --title "잠금 충돌 초안" --body-file "$WORK/cu-draft.md" --lexical-only --format json
check "ClickUp --list — lexical" "$(jf 'd["status"]')" "lexical"
check "ClickUp --list — 초안은 코퍼스에 없으므로 전부 후보다" "$(jf 'd["shortlist"]')" "5"
has "ClickUp --list — 스페이스를 가진 둘째 팀으로 코퍼스를 받는다" "$(cu_log '[x["path"] for x in r]')" "/team/200/task?space_ids[]=S1&page=0"
hasnt "ClickUp --list — 첫 팀으로 코퍼스를 받지 않는다" "$(cu_log '[x["path"] for x in r]')" "/team/100/task"
check "ClickUp --list — 인자 리스트로 같은 리스트 표지" \
  "$(jf 'sorted(c["id"] for c in d["candidates"] if c["same_list"])')" "['T1', 'T2', 'T5']"

CC_CMDS_CRED_STORE="$WORK/store-cu" run_si clickup --list L9 --title x --body-file "$WORK/cu-draft.md" --lexical-only --format json
rc=$?
check "ClickUp 스페이스를 가진 팀이 없으면 — 종료 코드 0" "$rc" "0"
check "ClickUp 스페이스를 가진 팀이 없으면 — unavailable" "$(jf 'd["status"]')" "unavailable"
check "ClickUp 스페이스를 가진 팀이 없으면 — reason" "$(jf 'd["reason"]')" "corpus"

cu_reset
run_si clickup --task T1 --lexical-only --format json
rc=$?
check "ClickUp 토큰 없음 — 종료 코드 0" "$rc" "0"
check "ClickUp 토큰 없음 — unavailable" "$(jf 'd["status"]')" "unavailable"
check "ClickUp 토큰 없음 — reason" "$(jf 'd["reason"]')" "tracker-key"
has "ClickUp 토큰 없음 — 알림이 규칙 위치를 적는다" "$(jf 'd["notice"]')" "~/.config/cc-cmds/clickup.env"
check "ClickUp 토큰 없음 — ClickUp 요청 0건" "$(cu_reqs)" "0"

CC_CMDS_CRED_STORE="$WORK/store-cu-644" run_si clickup --task T1 --lexical-only --format json
check "ClickUp 토큰 모드 644 — reason" "$(jf 'd["reason"]')" "tracker-key-invalid"
has "ClickUp 토큰 모드 644 — 알림이 chmod 600 을 가리킨다" "$(jf 'd["notice"]')" "chmod 600"
hasnt "ClickUp 토큰 모드 644 — 토큰 값이 출력에 없다" "$(cat "$WORK/out" "$WORK/err")" "$CU_SENTINEL"
check "ClickUp 토큰 모드 644 — ClickUp 요청 0건" "$(cu_reqs)" "0"

cu_reset
CC_CMDS_CRED_STORE="$WORK/store-cu-bare" run_si clickup --task T1 --lexical-only --format json
check "ClickUp = 없는 한 줄 토큰 파일을 받는다" "$(cu_log 'sorted({x["auth"] for x in r})')" "['$CU_BARE']"

reset_reqs
set_mode '{"kind": "fixed"}'
CC_CMDS_CRED_STORE="$WORK/store-cu" run_si clickup --task T1 --format json
check "ClickUp 판정 — 후보마다 요청 1건" "$(reqs)" "4"
check "ClickUp 판정 — semantic" "$(jf 'd["status"]')" "semantic"
check "ClickUp 판정 — 상태 키는 item_a/item_b 이고 일반화 문면이다" \
  "$(python3 -c 'import json,sys; b=json.loads(json.loads(open(sys.argv[1]).readline())["body"]); print(sorted(b["state"]), b["questions"]["same_place"]["instructions"].startswith("`item_a` and `item_b` are two open work items"))' "$WORK/reqlog.jsonl")" \
  "['item_a', 'item_b'] True"
reset_reqs
CC_CMDS_CRED_STORE="$WORK/store-cu" run_si clickup --task T1 --question measured --format json
check "ClickUp 판정 — --question measured 로 덮어쓴다" \
  "$(python3 -c 'import json,sys; b=json.loads(json.loads(open(sys.argv[1]).readline())["body"]); print(sorted(b["state"]))' "$WORK/reqlog.jsonl")" \
  "['issue_a', 'issue_b']"

CC_SIMILAR_CLICKUP_URL='https://example.com' CC_CMDS_CRED_STORE="$WORK/store-cu" run_si clickup --task T1 --lexical-only
check "루프백이 아닌 ClickUp 기점 재정의는 2" "$?" "2"
run_si clickup --task T1 --list L1 --lexical-only
check "ClickUp --task 와 --list 를 섞으면 2" "$?" "2"
run_si clickup --issue 1 --lexical-only
check "ClickUp 어댑터에 --issue 는 2" "$?" "2"

# ---------------------------------------------------------------------------
# 16. ClickUp ticket creation
# ---------------------------------------------------------------------------
run_create() { "$CREATE" "$@" > "$WORK/out" 2> "$WORK/err"; }
printf '## 문제\n잠금이 75 를 돌려준다.\n' > "$WORK/cu-desc.md"
cu_reset
printf '{"create": 200}\n' > "$WORK/cu-mode.json"
CC_CMDS_CRED_STORE="$WORK/store-cu" run_create --list L1 --name "새 티켓" --description-file "$WORK/cu-desc.md"
rc=$?
check "생성 — 종료 코드 0" "$rc" "0"
check "생성 — 출력은 id 와 url 한 줄" "$(cat "$WORK/out")" "$(printf 'NEW1\thttps://app.clickup.com/t/NEW1')"
check "생성 — POST 한 건이 리스트 경로로 간다" "$(cu_log '[(x["method"], x["path"]) for x in r]')" "[('POST', '/list/L1/task')]"
check "생성 — 본문은 name 과 markdown_description 뿐이다" \
  "$(python3 -c 'import json,sys; print(sorted(json.loads(json.loads(open(sys.argv[1]).readline())["body"])))' "$WORK/cu-reqlog.jsonl")" \
  "['markdown_description', 'name']"
check "생성 — 본문 값" \
  "$(python3 -c 'import json,sys; b=json.loads(json.loads(open(sys.argv[1]).readline())["body"]); print(b["name"], "assignees" in b, "status" in b, b["markdown_description"] == open(sys.argv[2]).read())' "$WORK/cu-reqlog.jsonl" "$WORK/cu-desc.md")" \
  "새 티켓 False False True"
check "생성 — 인증 헤더는 Bearer 없는 토큰 그대로다" "$(cu_log 'r[0]["auth"]')" "$CU_SENTINEL"
hasnt "생성 — 토큰 값이 출력에 없다" "$(cat "$WORK/out" "$WORK/err")" "$CU_SENTINEL"

cu_reset
CC_PIPELINE_MANIFEST="$WORK/manifest.md" CC_CMDS_CRED_STORE="$WORK/store-cu" \
  run_create --list L1 --name x --description-file "$WORK/cu-desc.md"
check "생성 — 무인 런 안에서는 5" "$?" "5"
check "생성 — 무인 런 거부는 요청 0건" "$(cu_reqs)" "0"

run_create --list L1 --name x --description-file "$WORK/cu-desc.md"
check "생성 — 토큰 없음은 3" "$?" "3"
check "생성 — 토큰 없음은 요청 0건" "$(cu_reqs)" "0"

printf '{"create": 500}\n' > "$WORK/cu-mode.json"
CC_CMDS_CRED_STORE="$WORK/store-cu" run_create --list L1 --name x --description-file "$WORK/cu-desc.md"
check "생성 — API 오류는 4" "$?" "4"
check "생성 — API 오류는 재시도하지 않는다" "$(cu_reqs)" "1"
hasnt "생성 — API 오류 문면에 토큰이 없다" "$(cat "$WORK/out" "$WORK/err")" "$CU_SENTINEL"
printf '{"create": 200}\n' > "$WORK/cu-mode.json"

cu_reset
CC_CMDS_CRED_STORE="$WORK/store-cu" run_create --list L1 --name x --description-file "$WORK/cu-desc.md" --descr "$WORK/cu-desc.md"
check "생성 — 접두 약어 --descr 는 2" "$?" "2"
check "생성 — 접두 약어 거부는 요청 0건" "$(cu_reqs)" "0"
CC_SIMILAR_CLICKUP_URL='https://example.com' CC_CMDS_CRED_STORE="$WORK/store-cu" \
  run_create --list L1 --name x --description-file "$WORK/cu-desc.md"
check "생성 — 루프백이 아닌 ClickUp 기점 재정의는 2" "$?" "2"

if grep -q 'POST' "$SI"; then
  bad "조회 도구 파일에 POST 코드가 없다" "$SI"
else
  ok "조회 도구 파일에 POST 코드가 없다"
fi

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
