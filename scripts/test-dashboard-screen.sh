#!/usr/bin/env bash
# lint-bash-portability: self-skip
# The run dashboard's screen: the three static files the server hands out, read
# as text, and the two page routes served by a `preview` server over a fixture
# root.
#
# The server sends `Content-Security-Policy: default-src 'self'`, so the screen
# builds every node with DOM calls and loads nothing from outside. The static
# cases below hold that from the file side: a pattern the policy would refuse,
# or an address outside the page, fails here before a browser ever sees it.
#
# THE PREVIEW SERVER THIS SUITE STARTS IS STOPPED. `preview` writes no server
# record, so the exit trap stops it by the pid this suite holds.
#
# Usage: bash scripts/test-dashboard-screen.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
DASH="$ORCH/dashboard.py"
SCREEN="$ORCH/dashboard"
. "$repo_root/scripts/run-fixture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-dashboard-screen.XXXXXX")
XDG_STATE_HOME="$WORK/state"
export XDG_STATE_HOME
mkdir -p "$XDG_STATE_HOME/cc-cmds/run"

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

if ! command -v python3 >/dev/null 2>&1; then
  bad "python3" "python3 를 찾지 못했다 — 이 스위트는 한 줄도 돌 수 없다"
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  bad "curl" "curl 을 찾지 못했다 — 페이지 경로를 잴 수 없다"
  exit 1
fi

pyq() { PYTHONDONTWRITEBYTECODE=1 python3 "$@"; }

wait_gone() {
  local i=0
  while [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
}
free_port() {
  pyq -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
cleanup() {
  [ -n "${PREVIEW_PID:-}" ] && kill "$PREVIEW_PID" 2>/dev/null
  fx_reap
  rm -rf "$WORK"
}
trap cleanup EXIT

get() {
  # get <port> <path> — status code on stdout, body in $WORK/body.
  curl -s --path-as-is -o "$WORK/body" -w '%{http_code}' --max-time 10 \
    -H 'X-CC-Poll: 1' "http://127.0.0.1:$1$2"
}

# hits <fixed-string> <file…> — how many lines of those files carry the string.
hits() {
  local needle="$1"; shift
  { grep -F -h -- "$needle" "$@" 2>/dev/null || true; } | wc -l | tr -d ' '
}

FILES=("$SCREEN/index.html" "$SCREEN/app.js" "$SCREEN/app.css")
for f in "${FILES[@]}"; do
  [ -s "$f" ] || bad "정적 파일 ${f##*/}" "비었거나 없다"
done

# ---------------------------------------------------------------------------
# S1 — nothing the policy refuses, comments included.
# ---------------------------------------------------------------------------
for pat in 'style=' '<style' 'innerHTML' 'insertAdjacentHTML' 'eval('; do
  for f in "${FILES[@]}"; do
    check "S1 ${f##*/} 에 '$pat' 이 없다" "$(hits "$pat" "$f")" "0"
  done
done

# ---------------------------------------------------------------------------
# S2 — the light theme only.
# ---------------------------------------------------------------------------
check "S2 app.css 에 prefers-color-scheme 이 없다" "$(hits 'prefers-color-scheme' "$SCREEN/app.css")" "0"

# ---------------------------------------------------------------------------
# S3 — no address outside the page; app.js holds the SVG namespace alone.
# ---------------------------------------------------------------------------
for f in "$SCREEN/index.html" "$SCREEN/app.css"; do
  check "S3 ${f##*/} 에 http:// 가 없다" "$(hits 'http://' "$f")" "0"
  check "S3 ${f##*/} 에 https:// 가 없다" "$(hits 'https://' "$f")" "0"
done
check "S3 app.js 에 https:// 가 없다" "$(hits 'https://' "$SCREEN/app.js")" "0"
check "S3 app.js 의 http:// 는 SVG 이름공간 상수 하나뿐이다" \
  "$(pyq -c 'import re,sys
t=open(sys.argv[1],encoding="utf-8").read()
print(" ".join(m.group(0) for m in re.finditer(r"http://[^\"'"'"'\s)]*", t)))' "$SCREEN/app.js")" \
  "http://www.w3.org/2000/svg"

# ---------------------------------------------------------------------------
# S4 — a preview server over a fixture root serves index.html on both routes.
# ---------------------------------------------------------------------------
fx_mkrun screen-run; fx_ledger_path; fx_segment S1 실행중
PP=$(free_port)
env -u CI -u CC_PIPELINE_SEGMENT -u CC_PIPELINE_STAGE_ID XDG_STATE_HOME="$XDG_STATE_HOME" \
  PYTHONDONTWRITEBYTECODE=1 python3 "$DASH" preview --port "$PP" 2>"$WORK/preview.err" &
PREVIEW_PID=$!
i=0
while [ "$i" -lt 50 ] && [ "$(get "$PP" /healthz)" != "200" ]; do sleep 0.1; i=$((i + 1)); done
check "S4 preview 가 /healthz 에 답한다" "$(get "$PP" /healthz)" "200"
for path in / /run/screen-run; do
  check "S4 $path 가 200 이다" "$(get "$PP" "$path")" "200"
  check "S4 $path 의 본문이 index.html 이다" \
    "$(cmp -s "$WORK/body" "$SCREEN/index.html" && printf 같음 || printf 다름)" "같음"
done
kill "$PREVIEW_PID" 2>/dev/null
wait_gone "$PREVIEW_PID"
PREVIEW_PID=""

# ---------------------------------------------------------------------------
# S5 — source shapes the real-data capture found wrong: the goal link truncates
# only as a block, the band carries the detail navigation, a stopped poll says
# so, and the result line does not print its time twice.
# ---------------------------------------------------------------------------
check "S5 목표 링크가 블록이라 말줄임이 먹는다" "$(hits '.row-link { display: block;' "$SCREEN/app.css")" "1"
check "S5 app.js 가 머리 띠의 상세 탐색을 채운다" "$(hits 'getElementById("band-nav")' "$SCREEN/app.js")" "1"
check "S5 끝난 런의 띠가 갱신 멈춤을 말한다" "$(hits '연결됨 · 갱신 멈춤' "$SCREEN/app.js")" "1"
check "S5 결과 줄의 원장 시각을 표시 시각으로 바꾼다" "$(hits 's.result.line.replace(' "$SCREEN/app.js")" "1"

# ---------------------------------------------------------------------------
# S6 — a poll must not take away what the reader is on. The real app.js runs
# under node against a small DOM stand-in and a server whose ETag moves on every
# poll, the way `generated_at` and `elapsed_s` move it in production. Timers are
# fired by hand, so each case is one poll. A redraw is proved by the identity of
# the first node under #app, so "still open" cannot pass because nothing redrew.
# ---------------------------------------------------------------------------
cat >"$WORK/redraw.js" <<'JS'
const vm = require("vm"), fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

function report(name, got, want) { console.log(name + "\t" + got + "\t" + want); }

class N {
  constructor(tag, doc) {
    this.tagName = tag ? tag.toUpperCase() : null;
    this.doc = doc; this.attrs = new Map(); this.children = []; this.parentNode = null;
    this.listeners = {}; this.text = ""; this.hidden = false;
    const cls = new Set();
    this.classList = { toggle: (k, on) => { if (on) cls.add(k); else cls.delete(k); } };
  }
  get firstChild() { return this.children[0] || null; }
  get childNodes() { return this.children; }
  get className() { return this.getAttribute("class") || ""; }
  set className(v) { this.setAttribute("class", v); }
  get open() { return this.attrs.has("open"); }
  set open(v) { if (v) this.attrs.set("open", ""); else this.attrs.delete("open"); }
  get textContent() { return this.text + this.children.map((c) => c.textContent).join(""); }
  set textContent(v) { this.children.forEach((c) => { c.parentNode = null; }); this.children = []; this.text = String(v); }
  setAttribute(k, v) { this.attrs.set(k, String(v)); }
  getAttribute(k) { return this.attrs.has(k) ? this.attrs.get(k) : null; }
  hasAttribute(k) { return this.attrs.has(k); }
  removeAttribute(k) { this.attrs.delete(k); }
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
  fire(t, e) { (this.listeners[t] || []).forEach((f) => f(Object.assign({ target: this }, e))); }
  appendChild(c) {
    if (c.tagName === null && c.fragment) { c.children.slice().forEach((k) => this.appendChild(k)); return c; }
    if (c.parentNode) c.parentNode.children.splice(c.parentNode.children.indexOf(c), 1);
    c.parentNode = this; this.children.push(c);
    return c;
  }
  replaceChildren(...nodes) {
    this.children.forEach((c) => { c.parentNode = null; });
    this.children = []; this.text = "";
    nodes.forEach((n) => { if (n != null) this.appendChild(typeof n === "string" ? this.doc.createTextNode(n) : n); });
  }
  contains(n) { for (; n; n = n.parentNode) if (n === this) return true; return false; }
  focus() { this.doc.focused = this; }
  walk(f) { this.children.forEach((c) => { if (c.tagName) f(c); c.walk(f); }); }
  querySelectorAll(sel) {
    const tests = sel.split(",").map((s) => {
      const m = s.trim().match(/^([a-z]+)(?:\[([a-z-]+)\])?$/);
      if (!m) throw new Error("selector not supported: " + s);
      return (n) => n.tagName === m[1].toUpperCase() && (!m[2] || n.hasAttribute(m[2]));
    });
    const out = [];
    this.walk((n) => { if (tests.some((t) => t(n))) out.push(n); });
    return out;
  }
  querySelector(sel) {
    if (sel[0] !== ".") throw new Error("selector not supported: " + sel);
    let hit = null;
    this.walk((n) => { if (!hit && n.className.split(" ").includes(sel.slice(1))) hit = n; });
    return hit;
  }
}

async function boot(pathname, bodyOf) {
  const doc = {
    hidden: false, title: "", focused: null,
    createElement: (t) => new N(t, doc),
    createElementNS: (_ns, t) => new N(t, doc),
    createTextNode: (t) => { const n = new N(null, doc); n.text = String(t); return n; },
    createDocumentFragment: () => { const n = new N(null, doc); n.fragment = true; return n; },
    addEventListener: () => {},
    getElementById: (id) => nodes[id] || null,
  };
  const nodes = {};
  ["app", "offline", "conn", "fresh", "version", "band-nav"].forEach((id) => { nodes[id] = new N("div", doc); });
  doc.body = new N("body", doc);
  Object.defineProperty(doc, "activeElement", {
    get: () => (doc.focused && nodes.app.contains(doc.focused) ? doc.focused : doc.body),
  });
  const c = { app: nodes.app, nodes, doc, selection: null, urls: [], timer: null, clock: 1800000000000 };
  const fetchStub = async (url, opts) => {
    if (url === "/healthz") return { json: async () => ({ version: "1" }) };
    c.urls.push(url);
    const body = bodyOf(url), etag = JSON.stringify(body);
    if ((opts.headers || {})["If-None-Match"] === etag) return { status: 304, ok: false };
    return { status: 200, ok: true, headers: { get: () => etag }, json: async () => body };
  };
  const sandbox = {
    document: doc,
    window: { getSelection: () => c.selection },
    location: { pathname, host: "127.0.0.1:1", reload: () => {} },
    fetch: fetchStub,
    setTimeout: (f) => { c.timer = f; return f; },
    clearTimeout: () => { c.timer = null; },
    now: () => c.clock,
  };
  vm.createContext(sandbox);
  vm.runInContext("Date.now = function () { return now(); };", sandbox);
  c.settle = async () => { for (let i = 0; i < 8; i++) await new Promise((r) => setImmediate(r)); };
  c.poll = async () => { const f = c.timer; c.timer = null; c.clock += 5000; if (f) f(); await c.settle(); };
  c.details = (text) => c.app.querySelectorAll("details").find((d) => d.textContent.includes(text));
  c.link = (href) => c.app.querySelectorAll("a").find((a) => a.getAttribute("href") === href);
  c.select = () => c.app.querySelectorAll("select")[0];
  c.fresh = () => nodes.fresh.textContent;
  vm.runInContext(src, sandbox);
  await c.settle();
  return c;
}

async function listCases() {
  let gen = 1;
  const run = (id, day) => ({
    id, goal: "목표 " + id, attention: "ended", state: "종단", ended_day: day, elapsed_s: 60,
    ended_at: 1793700000, base: "/a", seg: {}, cost_usd: 1, result: { "class": "종료 조건 성립" }, waiting: [], prs: [],
  });
  const c = await boot("/", () => ({
    tz_offset_s: 32400, tz_label: "KST", generated_at: 1793700000 + gen, today: "2026-11-04",
    runs: [run("today-run", "2026-11-04"), run("old-run", "2026-11-01")],
    totals: {}, bases: ["/a", "/b"], hidden: 0, hidden_experiment: 0,
  }));
  const OLD = "2026-11-01", TODAY = "2026-11-04", root = () => c.app.firstChild;

  report("접힌 옛 날짜 묶음이 처음엔 닫혀 있다", c.details(OLD).open, false);
  report("오늘 묶음이 처음엔 열려 있다", c.details(TODAY).open, true);

  c.details(OLD).open = true;
  c.details(TODAY).open = false;
  let before = root();
  gen++; await c.poll();
  report("다음 폴링이 화면을 다시 만든다", root() !== before, true);
  report("연 옛 날짜 묶음이 폴링 뒤에도 열려 있다", c.details(OLD).open, true);
  report("닫은 오늘 묶음이 폴링 뒤에도 닫혀 있다", c.details(TODAY).open, false);

  c.details(OLD).open = false;
  gen++; await c.poll();
  report("다시 닫은 묶음이 폴링 뒤에도 닫혀 있다", c.details(OLD).open, false);

  const link = c.link("/run/old-run");
  link.focus();
  gen++; await c.poll();
  report("포커스가 새로 만든 같은 행 링크로 옮겨 간다", c.doc.activeElement === c.link("/run/old-run") && c.doc.activeElement !== link, true);

  c.select().focus();
  c.select().fire("mousedown");
  before = root();
  const freshBefore = c.fresh();
  gen++; await c.poll();
  report("누른 레포 선택이 있으면 폴링이 다시 만들지 않는다", root() === before, true);
  report("미루는 동안 마지막 갱신 시각이 움직이지 않는다", c.fresh() === freshBefore, true);
  const urls = c.urls.length;
  c.select().value = "/b";
  c.select().fire("change");
  await c.settle();
  report("레포를 고르면 곧바로 새 목록을 읽는다", c.urls.slice(urls).some((u) => u.includes("base=%2Fb")), true);
  report("레포를 고르면 곧바로 다시 그린다", root() !== before, true);
  report("다시 그린 뒤 포커스가 레포 선택에 남는다", c.doc.activeElement === c.select(), true);
  before = root();
  gen++; await c.poll();
  report("고른 뒤 포커스만 남은 레포 선택은 갱신을 막지 않는다", root() !== before, true);

  c.select().fire("mousedown");
  c.select().fire("blur");
  before = root();
  gen++; await c.poll();
  report("포커스가 떠난 레포 선택은 갱신을 막지 않는다", root() !== before, true);

  c.selection = { isCollapsed: false, anchorNode: c.link("/run/old-run") };
  before = root();
  gen++; await c.poll();
  report("화면 안의 선택이 살아 있으면 다시 만들지 않는다", root() === before, true);
  c.selection = null;
  await c.poll();
  report("선택이 풀리면 304 응답에도 밀린 화면을 그린다", root() !== before, true);

  c.selection = { isCollapsed: false, anchorNode: c.nodes.offline };
  before = root();
  gen++; await c.poll();
  report("화면 밖의 선택은 갱신을 막지 않는다", root() !== before, true);
}

async function detailCases() {
  let gen = 1, state = "진행중";
  const j = (name) => ({ at: 1793700000, source: "판단", "결정": name, "세그먼트": "A", "근거": "근거 " + name });
  let items = [j("결정A"), j("결정B")];
  const c = await boot("/run/r1", () => ({
    tz_offset_s: 32400,
    summary: { id: "r1", state, attention: "watch", started_at: 1793700000, elapsed_s: gen, prs: [], notes: [] },
    judgments: { items, by_class: {} }, waiting: [], steps: [], timeline: [], shifts: [],
    clauses: [], reviews: [], segments: [], links: {}, cost: {},
  }));
  const root = () => c.app.firstChild;

  report("근거 행이 처음엔 닫혀 있다", c.details("결정A").open, false);
  c.details("결정A").open = true;
  let before = root();
  items = [j("결정0")].concat(items);
  gen++; await c.poll();
  report("상세 폴링이 화면을 다시 만든다", root() !== before, true);
  report("펼친 근거 행이 폴링 뒤에도 열려 있다", c.details("결정A").open, true);
  report("앞에 끼어든 새 판단 행은 닫혀 있다", c.details("결정0").open, false);
  report("펼치지 않은 근거 행은 닫혀 있다", c.details("결정B").open, false);

  c.selection = { isCollapsed: false, anchorNode: c.details("결정A") };
  before = root();
  state = "종단"; gen++; await c.poll();
  report("끝난 런의 응답도 선택 중에는 다시 만들지 않는다", root() === before, true);
  report("그리지 못한 끝난 런은 폴링을 멈추지 않는다", c.timer !== null, true);
  c.selection = null;
  await c.poll();
  report("선택이 풀리면 끝난 런의 화면을 그린다", root() !== before, true);
  report("끝난 런을 그린 뒤 폴링이 멈춘다", c.timer === null, true);
  report("끝난 런을 그린 뒤 띠가 갱신 멈춤을 말한다", c.nodes.conn.textContent.includes("갱신 멈춤"), true);
}

listCases().then(detailCases).catch((e) => { console.error(e && e.stack || e); process.exit(1); });
JS

if command -v node >/dev/null 2>&1; then
  node "$WORK/redraw.js" "$SCREEN/app.js" >"$WORK/redraw.out" 2>"$WORK/redraw.err"
  check "S6 하니스가 끝까지 돈다" "$? $(tail -n 1 "$WORK/redraw.err")" "0 "
  while IFS=$'\t' read -r name got want; do
    check "S6 $name" "$got" "$want"
  done <"$WORK/redraw.out"
elif [ -n "${CI:-}" ]; then
  bad "S6 node" "CI 에 node 가 없어 폴링 시험을 돌릴 수 없다"
else
  printf 'SKIP: S6 — 이 호스트에 node 가 없다\n'
fi

printf '\ntest-dashboard-screen: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
