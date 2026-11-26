#!/usr/bin/env bash
# lint-bash-portability: self-skip
# The run dashboard's list view in a real headless Chrome: the filters ride in
# the address, the turned date groups and the scroll come back on Back, reload
# and the detail page's "런 목록" link, a filter change shows at once, and an
# answer to a filter already left is never drawn.
#
# Pages, assets and /healthz come from a real `preview` server over a fixture
# root, the way S4 of test-dashboard-screen.sh starts it. Every /api/runs request
# is intercepted through the DevTools Fetch domain and answered by the node
# driver with a synthetic response per query, so a request can be answered at
# once or held and released later. The driver talks to Chrome over
# --remote-debugging-pipe; nothing outside node and Chrome is used.
#
# Chrome is looked up as google-chrome, chromium, chromium-browser, chrome on
# PATH, in that order, then at the macOS application path — the same order
# visual-capture.sh uses. With CI set, a missing Chrome or node fails the suite;
# elsewhere it prints one SKIP line and passes.
#
# Chrome runs with the back/forward cache off, so Back always runs the page again
# and goes through the storage restore. Outside fetches go to a closed local
# proxy; the loopback preview server is not proxied.
#
# THE PREVIEW SERVER, CHROME AND THE THROWAWAY PROFILE THIS SUITE MAKES ARE
# REMOVED by the exit trap. The driver stops itself after 120 seconds.
#
# Usage: bash scripts/test-dashboard-browser.sh
#
# Compatibility: bash 3.2 (macOS); BSD and GNU userland alike.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
DASH="$ORCH/dashboard.py"
MAC_CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
summary() { printf '\ntest-dashboard-browser: %d passed, %d failed\n' "$passed" "$failed"; }

find_chrome() {
  local n
  for n in google-chrome chromium chromium-browser chrome; do
    if command -v "$n" >/dev/null 2>&1; then
      command -v "$n"
      return 0
    fi
  done
  if [ -x "$MAC_CHROME" ]; then
    printf '%s\n' "$MAC_CHROME"
    return 0
  fi
  return 1
}

if ! command -v python3 >/dev/null 2>&1; then
  bad "python3" "python3 를 찾지 못했다 — 미리보기 서버를 띄울 수 없다"
  summary; exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  bad "curl" "curl 을 찾지 못했다 — 미리보기 서버를 기다릴 수 없다"
  summary; exit 1
fi

CHROME=$(find_chrome) || CHROME=""
missing=""
command -v node >/dev/null 2>&1 || missing="node"
[ -n "$CHROME" ] || missing="${missing:+$missing, }Chrome"
if [ -n "$missing" ]; then
  if [ -n "${CI:-}" ]; then
    bad "도구" "CI 에 $missing 이 없어 브라우저 시험을 돌릴 수 없다"
    summary; exit 1
  fi
  printf 'SKIP: 이 호스트에 %s 이 없다\n' "$missing"
  summary; exit 0
fi

. "$repo_root/scripts/run-fixture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-dashboard-browser.XXXXXX")
XDG_STATE_HOME="$WORK/state"
export XDG_STATE_HOME
mkdir -p "$XDG_STATE_HOME/cc-cmds/run"
PROFILE="$WORK/profile"
mkdir -p "$PROFILE"

pyq() { PYTHONDONTWRITEBYTECODE=1 python3 "$@"; }

free_port() {
  pyq -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
cleanup() {
  [ -n "${DRIVER_PID:-}" ] && kill -KILL "$DRIVER_PID" 2>/dev/null
  pkill -KILL -f -- "$PROFILE" 2>/dev/null
  if [ -n "${PREVIEW_PID:-}" ]; then
    kill "$PREVIEW_PID" 2>/dev/null
    wait_pid_gone "$PREVIEW_PID"
  fi
  fx_reap
  rm -rf "$WORK"
}
trap cleanup EXIT

get() {
  # get <port> <path> — status code on stdout.
  curl -s --path-as-is -o /dev/null -w '%{http_code}' --max-time 10 \
    -H 'X-CC-Poll: 1' "http://127.0.0.1:$1$2"
}

fx_mkrun browser-run; fx_ledger_path; fx_segment S1 실행중
PP=$(free_port)
env -u CI -u CC_PIPELINE_SEGMENT -u CC_PIPELINE_STAGE_ID XDG_STATE_HOME="$XDG_STATE_HOME" \
  PYTHONDONTWRITEBYTECODE=1 python3 "$DASH" preview --port "$PP" 2>"$WORK/preview.err" &
PREVIEW_PID=$!
preview_up() { [ "$(get "$PP" /healthz)" = "200" ]; }
wait_until preview_up
check "B preview 가 /healthz 에 답한다" "$(get "$PP" /healthz)" "200"

cat >"$WORK/drive.js" <<'JS'
const { spawn } = require("child_process");
const { StringDecoder } = require("string_decoder");
const [chromePath, origin, profile] = process.argv.slice(2);
const LIMIT_MS = 120000, STEP_MS = 10000;

function report(name, got, want) { console.log(name + "\t" + got + "\t" + want); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------ the pipe
const chrome = spawn(chromePath, ["--headless=new", "--disable-gpu", "--no-first-run",
  "--disable-background-networking", "--disable-component-update", "--disable-sync",
  "--proxy-server=127.0.0.1:9", "--disable-features=BackForwardCache", "--window-size=1280,800",
  "--user-data-dir=" + profile, "--remote-debugging-pipe", "about:blank"],
  { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
const watchdog = setTimeout(() => {
  console.error("상한 " + LIMIT_MS / 1000 + "초를 넘겼다");
  chrome.kill("SIGKILL");
  process.exit(3);
}, LIMIT_MS);
const toChrome = chrome.stdio[3], decoder = new StringDecoder("utf8");
let buf = "", seq = 0;
const waits = new Map(), listeners = [];
chrome.stdio[4].on("data", (d) => {
  buf += decoder.write(d);
  let i;
  while ((i = buf.indexOf("\0")) >= 0) {
    const m = JSON.parse(buf.slice(0, i));
    buf = buf.slice(i + 1);
    if (m.id && waits.has(m.id)) { waits.get(m.id)(m); waits.delete(m.id); }
    else if (m.method) listeners.slice().forEach((f) => f(m));
  }
});
// send resolves with the raw answer, an error included; cmd throws on an error.
function send(method, params, sessionId) {
  const msg = { id: ++seq, method, params: params || {} };
  if (sessionId) msg.sessionId = sessionId;
  toChrome.write(JSON.stringify(msg) + "\0");
  return new Promise((r) => waits.set(msg.id, r));
}
async function cmd(method, params, sessionId) {
  const m = await send(method, params, sessionId);
  if (m.error) throw new Error(method + ": " + m.error.message);
  return m.result;
}

// ------------------------------------------------------- the fake API
const TODAY = "2026-11-04", GEN = 1793700000, BASES = ["/w/alpha", "/w/beta"];
const SPAN = { "3": 3, "7": 7, "30": 30, "all": 40 };
let gen = 0;
function dayKey(i) { return new Date(Date.UTC(2026, 10, 4) - i * 86400000).toISOString().slice(0, 10); }
// Each wider period reaches older days; alpha has three runs a day and beta one,
// so thirty days of alpha are taller than the window.
function runsFor(days, base) {
  const out = [];
  for (let i = 0; i < (SPAN[days] || 0); i++) {
    BASES.forEach((b, bi) => {
      for (let k = 0; k < (bi === 0 ? 3 : 1); k++) {
        const id = b.split("/").pop() + "-" + dayKey(i) + "-" + k;
        out.push({ id, goal: "목표 " + id, attention: "ended", state: "종단", ended_day: dayKey(i), elapsed_s: 600,
          ended_at: GEN - i * 86400, base: b, seg: {}, cost_usd: 1, result: { "class": "종료 조건 성립" }, waiting: [], prs: [] });
      }
    });
  }
  return base ? out.filter((r) => r.base === base) : out;
}
const count = (days, base) => String(runsFor(days, base).length);
function bodyFor(path) {
  const u = new URL(path, "http://x"), m = u.pathname.match(/^\/api\/runs\/(.+)$/);
  gen++;
  if (m) {
    return { tz_offset_s: 32400,
      summary: { id: decodeURIComponent(m[1]), state: "진행중", attention: "watch", started_at: GEN, elapsed_s: 60 + gen, prs: [], notes: [] },
      judgments: { items: [], by_class: {} }, waiting: [], steps: [], timeline: [], shifts: [],
      clauses: [], reviews: [], segments: [], links: {}, cost: {} };
  }
  const q = u.searchParams;
  return { tz_offset_s: 32400, tz_label: "KST", generated_at: GEN + gen, today: TODAY,
    runs: runsFor(q.get("days"), q.get("base")), totals: {}, bases: BASES, hidden: 0, hidden_experiment: 0 };
}

// Every intercepted request is logged; one the hold predicate names waits in
// `held` until the driver fulfils it. Fulfilling a request the page already
// aborted answers with an error, which is accepted.
const api = { log: [], held: [], hold: null };
function fulfill(e) {
  return send("Fetch.fulfillRequest", { requestId: e.requestId, responseCode: 200,
    responseHeaders: [{ name: "Content-Type", value: "application/json" }, { name: "Cache-Control", value: "no-store" }],
    body: Buffer.from(JSON.stringify(bodyFor(e.path)), "utf8").toString("base64") }, e.sessionId);
}
listeners.push((m) => {
  if (m.method !== "Fetch.requestPaused") return;
  const u = new URL(m.params.request.url), e = { requestId: m.params.requestId, sessionId: m.sessionId, path: u.pathname + u.search };
  api.log.push(e.path);
  if (api.hold && api.hold(e.path)) api.held.push(e);
  else fulfill(e);
});
async function releaseAll() {
  api.hold = null;
  const all = api.held.splice(0);
  for (const e of all) await fulfill(e);
}

// ------------------------------------------------------------- the page
async function openPage() {
  const t = await cmd("Target.createTarget", { url: "about:blank" });
  const a = await cmd("Target.attachToTarget", { targetId: t.targetId, flatten: true });
  await cmd("Page.enable", {}, a.sessionId);
  await cmd("Fetch.enable", { patterns: [{ urlPattern: "*/api/runs*", requestStage: "Request" }] }, a.sessionId);
  return a.sessionId;
}
async function ev(s, expr) {
  const r = await cmd("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true }, s);
  if (r.exceptionDetails) throw new Error("평가 실패: " + expr + " — " + JSON.stringify(r.exceptionDetails.exception || r.exceptionDetails.text));
  return r.result.value;
}
// The next load of this page; taken before the act that navigates.
function nextLoad(s, label) {
  return new Promise((res, rej) => {
    const t = setTimeout(() => { done(); rej(new Error("로드 대기 초과: " + label)); }, STEP_MS);
    const f = (m) => { if (m.method === "Page.loadEventFired" && m.sessionId === s) { done(); res(); } };
    const done = () => { clearTimeout(t); const i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); };
    listeners.push(f);
  });
}
async function waitFor(s, expr, ms) {
  const end = Date.now() + (ms || STEP_MS);
  while (Date.now() < end) {
    if (await ev(s, "!!(" + expr + ")")) return true;
    await sleep(50);
  }
  return false;
}
async function waitUntil(pred, ms) {
  const end = Date.now() + (ms || STEP_MS);
  while (Date.now() < end) { if (pred()) return true; await sleep(50); }
  return false;
}
async function go(s, act, label) {
  const load = nextLoad(s, label);
  await act();
  await load;
}
const LIST_DRAWN = "document.querySelector('#app .filters') && !document.querySelector('.list-pending')";
async function listReady(s, label) {
  if (!(await waitFor(s, LIST_DRAWN))) throw new Error("목록 대기 초과: " + label);
}
const click = (s, css) => ev(s, "document.querySelector(" + JSON.stringify(css) + ").click(), 1");
const shown = (s) => ev(s, "(document.querySelector('#app .shown b') || {}).textContent || ''");
const pressed = "Array.from(document.querySelectorAll('#app [aria-pressed=\"true\"]')).map(function (b) { return b.getAttribute('data-fk'); }).join(',')";
const snap = (key) => "JSON.stringify({ search: location.search, pressed: " + pressed +
  ", base: (document.getElementById('repo-sel') || {}).value, open: !!(document.querySelector('details[data-key=\"" + key +
  "\"]') || {}).open, y: Math.round(window.scrollY) })";

async function reproCase(s) {
  await go(s, () => cmd("Page.navigate", { url: origin + "/" }, s), "/");
  await listReady(s, "/");
  const h0 = await ev(s, "history.length");
  await click(s, '[data-fk="days-30"]');
  await waitFor(s, "location.search === '?days=30' && " + LIST_DRAWN);
  await ev(s, "(function () { var x = document.getElementById('repo-sel'); x.value = '/w/alpha'; x.dispatchEvent(new Event('change')); return 1; })()");
  const narrowed = await waitFor(s, "location.search === '?days=30&base=%2Fw%2Falpha' && " + LIST_DRAWN +
    " && document.querySelector('#app .shown b').textContent === '" + count("30", "/w/alpha") + "'");
  report("C1 30일과 레포를 고르면 주소가 그 필터의 정규 주소다", narrowed, true);
  report("C1 필터를 바꾸는 동안 history.length 가 늘지 않는다", await ev(s, "history.length"), h0);

  const KEY = "day:" + dayKey(9);
  await click(s, 'details[data-key="' + KEY + '"] > summary');
  await waitFor(s, "document.querySelector('details[data-key=\"" + KEY + "\"]').open");
  await ev(s, "window.scrollTo(0, 600), 1");
  await sleep(600);
  const before = await ev(s, snap(KEY));
  const b = JSON.parse(before);
  report("C1 상세로 가기 전 상태 — 묶음 열림·스크롤", b.open + " " + (b.y > 0), "true true");

  const toDetail = () => go(s, () => click(s, 'details[data-key="' + KEY + '"] a.row-link'), "상세");
  await toDetail();
  await waitFor(s, "document.querySelector('#band-nav a.back')");
  report("C1 상세의 런 목록 링크가 필터를 실은 목록 주소다",
    await ev(s, "document.querySelector('#band-nav a.back').getAttribute('href')"), "/?days=30&base=%2Fw%2Falpha");

  await go(s, () => ev(s, "history.back(), 1"), "뒤로 가기");
  await listReady(s, "뒤로 가기");
  report("C1 뒤로 가기 뒤 쿼리·기간·레포·펼침·스크롤이 같다", await ev(s, snap(KEY)), before);

  await go(s, () => cmd("Page.reload", {}, s), "새로고침");
  await listReady(s, "새로고침");
  report("C1 새로고침 뒤 쿼리·기간·레포·펼침·스크롤이 같다", await ev(s, snap(KEY)), before);

  await toDetail();
  await waitFor(s, "document.querySelector('#band-nav a.back')");
  await go(s, () => click(s, "#band-nav a.back"), "런 목록 링크");
  await listReady(s, "런 목록 링크");
  report("C1 런 목록 링크로 돌아온 뒤 쿼리·기간·레포·펼침·스크롤이 같다", await ev(s, snap(KEY)), before);
}

async function pendingCase(s) {
  api.hold = (p) => p.indexOf("/api/runs?days=7&") === 0;
  const mark = api.held.length;
  await click(s, '[data-fk="days-7"]');
  report("C2 7일 요청이 붙잡혔다", await waitUntil(() => api.held.length > mark), true);
  report("C2 응답 전 눌림·합계 바쁨·상태 문구", await ev(s, "JSON.stringify({ pressed: document.querySelector('[data-fk=\"days-7\"]').getAttribute('aria-pressed'), " +
    "busy: document.querySelector('#app .kpis').getAttribute('aria-busy'), cap: !!document.querySelector('.list-pending[role=\"status\"]') })"),
    JSON.stringify({ pressed: "true", busy: "true", cap: true }));
  await releaseAll();
  report("C2 응답 뒤 표시가 없어지고 새 건수가 보인다",
    await waitFor(s, LIST_DRAWN + " && !document.querySelector('#app [aria-busy=\"true\"]') && document.querySelector('#app .shown b').textContent === '" +
      count("7", "/w/alpha") + "'"), true);
}

async function lateCase(s) {
  await click(s, '[data-fk="days-3"]');
  await waitFor(s, LIST_DRAWN + " && document.querySelector('#app .shown b').textContent === '" + count("3", "/w/alpha") + "'");
  const is3 = (p) => p.indexOf("/api/runs?days=3&") === 0, is30 = (p) => p.indexOf("/api/runs?days=30&") === 0;
  api.hold = (p) => is3(p) || is30(p);
  report("C3 3일 폴링 요청이 붙잡혔다", await waitUntil(() => api.held.some((e) => is3(e.path)), 8000), true);
  await ev(s, "window.__mark = document.getElementById('app').firstChild, 1");
  await click(s, '[data-fk="days-30"]');
  report("C3 30일 요청도 붙잡혔다", await waitUntil(() => api.held.some((e) => is30(e.path))), true);
  const old = api.held.find((e) => is3(e.path));
  api.held.splice(api.held.indexOf(old), 1);
  await fulfill(old);
  await sleep(700);
  report("C3 늦게 푼 3일 응답이 화면을 다시 만들지 않는다", await ev(s, "document.getElementById('app').firstChild === window.__mark"), true);
  report("C3 눌린 단추가 30일이고 바쁨이 남는다",
    await ev(s, pressed + " === 'days-30' && document.querySelector('#app .kpis').getAttribute('aria-busy') === 'true'"), true);
  await releaseAll();
  report("C3 30일을 풀면 30일 건수가 보인다",
    await waitFor(s, LIST_DRAWN + " && document.querySelector('#app .shown b').textContent === '" + count("30", "/w/alpha") + "'"), true);
}

async function badAddressCase(s) {
  let mark = api.log.length;
  await go(s, () => cmd("Page.navigate", { url: origin + "/?days=99&dead=yes&zz=1" }, s), "잘못된 주소");
  await listReady(s, "잘못된 주소");
  report("잘못된 주소로 열면 쿼리가 빈다", JSON.stringify(await ev(s, "location.search")), '""');
  report("잘못된 주소로 열면 오류 없이 3일 목록이 뜬다",
    await ev(s, pressed + " === 'days-3' && !document.querySelector('#app .err') && document.getElementById('offline').hidden"), true);
  report("잘못된 주소로 열면 첫 API 요청이 days=3 이다",
    api.log.slice(mark).find((p) => p.indexOf("/api/runs?") === 0), "/api/runs?days=3&base=&dead=0&exp=0");

  mark = api.log.length;
  await go(s, () => cmd("Page.navigate", { url: origin + "/?base=%2Fw%2Fgone" }, s), "없는 레포 주소");
  report("응답에 없는 레포의 주소로 열면 쿼리가 비고 모든 레포 목록이 뜬다",
    await waitFor(s, "location.search === '' && " + LIST_DRAWN + " && document.getElementById('repo-sel').value === '' && " +
      "document.querySelector('#app .shown b').textContent === '" + count("3", "") + "'"), true);
}

async function freshTabCase() {
  const s = await openPage();
  await go(s, () => cmd("Page.navigate", { url: origin + "/run/alpha-" + TODAY + "-0" }, s), "새 탭 상세");
  await waitFor(s, "document.querySelector('#band-nav a.back')");
  report("새 탭에서 상세를 바로 열면 런 목록 링크가 / 다",
    await ev(s, "(document.querySelector('#band-nav a.back') || { getAttribute: function () { return null; } }).getAttribute('href')"), "/");
}

(async () => {
  const s = await openPage();
  await reproCase(s);
  await pendingCase(s);
  await lateCase(s);
  await badAddressCase(s);
  await freshTabCase();
  await send("Browser.close");
  clearTimeout(watchdog);
  chrome.kill("SIGKILL");
  process.exit(0);
})().catch((e) => {
  console.error(e && e.stack || e);
  chrome.kill("SIGKILL");
  process.exit(1);
});
JS

node "$WORK/drive.js" "$CHROME" "http://127.0.0.1:$PP" "$PROFILE" >"$WORK/drive.out" 2>"$WORK/drive.err" &
DRIVER_PID=$!
wait "$DRIVER_PID"
rc=$?
DRIVER_PID=""
check "B 드라이버가 끝까지 돈다" "$rc $(tail -n 1 "$WORK/drive.err")" "0 "
while IFS=$'\t' read -r name got want; do
  check "B $name" "$got" "$want"
done <"$WORK/drive.out"

summary
[ "$failed" -eq 0 ]
