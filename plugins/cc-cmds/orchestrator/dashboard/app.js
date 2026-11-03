// app.js — the run dashboard's two screens: the run list at `/` and one run's
// detail at `/run/<id>`. No build, no third-party code.
//
// Every value shown comes from the read layer's JSON (`/api/runs` and
// `/api/runs/<id>`). Text goes in as text nodes through el(), SVG is built
// element by element through sv(), and a bar's length is an SVG width or x
// attribute computed from the response.
//
// Polling: the list every 5 s, a run's detail every 3 s, each with an ETag.
// Timer polls carry `X-CC-Poll: 1` so a forgotten tab cannot keep the server
// alive. A hidden tab polls nothing, and a run that reached 종단 is not polled
// again. `/healthz` is checked on every poll and the page reloads when the
// server's version changes.
//
// A redraw replaces every node under #app, and almost every poll redraws because
// the list's `generated_at` and a live run's `elapsed_s` move the ETag. So what
// the reader opened and focused is carried across by stable keys, and the redraw
// waits while they hold a text selection or press the repo <select>.
//
// Clock text is drawn in the server's display time zone: an epoch is shifted
// by the response's `tz_offset_s` and read through the UTC accessors, so the
// browser's own zone never appears. Durations on the list use the response's
// `generated_at` as "now" for the same reason.
"use strict";

(function () {
  var SVGNS = "http://www.w3.org/2000/svg";
  var app = document.getElementById("app");
  var offline = document.getElementById("offline");
  var etags = {};
  var cache = {};
  var timer = null;
  var serverVersion = null;
  var view = { days: "3", base: "", dead: false, exp: false };
  // The display time zone of the last response; null until one arrives.
  var tz = null;
  // Wall-clock millis of the last successful fetch, for the stale line.
  var lastOk = null;
  // A <details> the reader turned away from how it is drawn by default, by its
  // data-key. The keys carry text from the response, hence a Map.
  var flipped = new Map();
  // A response was held back from the screen and is still to be drawn.
  var redrawOwed = false;
  // Until this wall-clock milli, the repo <select> may have its list open. Closing
  // a list without changing the value fires no event on some browsers, so the
  // hold runs out by itself rather than waiting for one.
  var selectHeldUntil = 0;
  var SELECT_HOLD_MS = 15000;
  var FOCUSABLE = "a, button, select, summary";
  var PERIODS = [["3", "3일"], ["7", "7일"], ["30", "30일"], ["all", "전체"]];
  var WEEKDAYS = ["일", "월", "화", "수", "목", "금", "토"];
  var TZ_TIP = "표시 시간대는 서버 프로세스가 처음 뜰 때의 CC_CMDS_AUTOPILOT_TZ 를 따릅니다(기본 KST). 값을 바꾼 뒤에는 서버가 다시 뜰 때까지 이전 값을 써서, 다른 화면과 「오늘」 이 갈릴 수 있습니다.";
  var TODAY_TIP = "오늘 쓴 비용은 cost 행(스테이지가 끝날 때 쓰는 누적 스냅샷)의 증가분입니다. 자정을 걸쳐 돈 스테이지의 비용은 모두 끝난 날에 들어갑니다.";
  var PAIR_TIP = "원장의 cost 행에는 스테이지를 가리키는 필드가 없어, 시도마다 그 stage-result 행 뒤 첫 cost 행의 누적 차이를 그 시도의 비용으로 짝짓습니다. 여러 스테이지가 겹쳐 돈 구간의 비용은 뒤 스테이지로 갈 수 있고, 어디에도 묶이지 않은 차액은 기타에 듭니다.";

  // ------------------------------------------------------------- builders

  function el(name, attrs) {
    var n = document.createElement(name);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        if (attrs[k] == null) return;
        if (k === "text") n.textContent = attrs[k];
        else if (k === "cls") n.className = attrs[k];
        else if (k.slice(0, 2) === "on") n.addEventListener(k.slice(2), attrs[k]);
        else n.setAttribute(k, attrs[k]);
      });
    }
    for (var i = 2; i < arguments.length; i++) {
      var c = arguments[i];
      if (c == null) continue;
      n.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    }
    return n;
  }

  function sv(name, attrs, text) {
    var n = document.createElementNS(SVGNS, name);
    Object.keys(attrs || {}).forEach(function (k) { if (attrs[k] != null) n.setAttribute(k, attrs[k]); });
    if (text != null) n.textContent = text;
    return n;
  }

  // <svg class="ico ..."><use href="#i-..."/></svg>; the symbols live in index.html.
  function ico(id, cls) {
    var s = sv("svg", { "class": "ico" + (cls ? " " + cls : "") });
    s.appendChild(sv("use", { href: "#" + id }));
    return s;
  }

  // A status chip: the colour class and, always, a text beside the icon.
  function tag(kind, text, icon, extra) {
    return el("span", { cls: "tag tag-" + kind + (extra ? " " + extra : "") },
      icon ? ico(icon, "ico-sm") : null, text);
  }

  function span(cls, text, title) {
    return el("span", { cls: cls, text: text, title: title });
  }

  function copyText(text, num) {
    return el("span", { cls: "copy" + (num ? " num" : ""), text: text });
  }

  // ----------------------------------------------------------- formatting

  function pad2(n) { return (n < 10 ? "0" : "") + n; }

  function tzLabel(off) {
    if (off === 32400) return "KST";
    if (off === 0) return "UTC";
    var a = Math.abs(off);
    return "UTC" + (off < 0 ? "-" : "+") + pad2(Math.floor(a / 3600)) + ":" + pad2(Math.floor(a % 3600 / 60));
  }

  function setTz(off, label) {
    if (off == null) return;
    tz = { off: off, label: label || (tz && tz.off === off ? tz.label : tzLabel(off)) };
  }

  // The display zone's calendar fields of an epoch, read through UTC accessors.
  function shifted(epoch) { return new Date((epoch + (tz ? tz.off : 0)) * 1000); }
  function fmtHM(e) { var d = shifted(e); return pad2(d.getUTCHours()) + ":" + pad2(d.getUTCMinutes()); }
  function fmtHMS(e) { var d = shifted(e); return fmtHM(e) + ":" + pad2(d.getUTCSeconds()); }
  function fmtMD(e) { var d = shifted(e); return pad2(d.getUTCMonth() + 1) + "/" + pad2(d.getUTCDate()); }
  function fmtMDHM(e) { return fmtMD(e) + " " + fmtHM(e); }
  function fmtYMD(e) { var d = shifted(e); return d.getUTCFullYear() + "-" + pad2(d.getUTCMonth() + 1) + "-" + pad2(d.getUTCDate()); }
  function fmtYMDHM(e) { return fmtYMD(e) + " " + fmtHM(e); }

  function dayParts(key) {
    var p = String(key).split("-");
    return new Date(Date.UTC(+p[0], +p[1] - 1, +p[2]));
  }

  function dayLabel(key) { return key + " (" + WEEKDAYS[dayParts(key).getUTCDay()] + ")"; }

  function dayBefore(key) {
    var d = new Date(dayParts(key).getTime() - 86400000);
    return d.getUTCFullYear() + "-" + pad2(d.getUTCMonth() + 1) + "-" + pad2(d.getUTCDate());
  }

  function dur(sec) {
    if (sec == null) return "미상";
    var s = Math.max(0, Math.floor(sec));
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    if (d > 0) return d + "일 " + h + "시간";
    if (h > 0) return h + "시간 " + m + "분";
    if (m > 0) return m + "분";
    return s + "초";
  }

  function usd(v) { return v == null ? "—" : "$" + Number(v).toFixed(2); }
  function pctText(v, total) { return total > 0 ? Math.round(v / total * 1000) / 10 + "%" : "—"; }
  function periodLabel() {
    for (var i = 0; i < PERIODS.length; i++) if (PERIODS[i][0] === view.days) return PERIODS[i][1];
    return view.days;
  }

  function repoName(base) {
    if (!base) return "레포 없음";
    var p = base.split("/");
    return p[p.length - 1] || base;
  }

  function firstLine(t) { return (t || "").split("\n")[0]; }

  function isAsk(w) { return w.kind === "승인" || w.kind === "중단 기록"; }

  function bySince(a, b) {
    if (a.since == null) return b.since == null ? 0 : 1;
    if (b.since == null) return -1;
    return a.since - b.since;
  }

  function asks(r) { return (r.waiting || []).filter(isAsk).sort(bySince); }

  function oldestSince(r) {
    var a = asks(r);
    return a.length && a[0].since != null ? a[0].since : null;
  }

  function countKinds(items) {
    var c = { "승인": 0, "중단 기록": 0, "사용량 한도": 0 };
    items.forEach(function (w) { if (c[w.kind] != null) c[w.kind]++; });
    return c;
  }

  function sumBy(arr, f) { var t = 0; arr.forEach(function (x) { t += f(x) || 0; }); return t; }

  // ------------------------------------------------------------- fetching

  function fetchJSON(url, poll) {
    var headers = {};
    if (poll) headers["X-CC-Poll"] = "1";
    if (etags[url]) headers["If-None-Match"] = etags[url];
    return fetch(url, { headers: headers, cache: "no-store" }).then(function (r) {
      if (r.status === 304) return { same: true, data: cache[url] };
      if (!r.ok) return { error: r.status };
      etags[url] = r.headers.get("ETag");
      return r.json().then(function (d) { cache[url] = d; return { same: false, data: d }; });
    }, function () {
      return { offline: true };
    });
  }

  function checkVersion(poll) {
    return fetch("/healthz", { headers: poll ? { "X-CC-Poll": "1" } : {}, cache: "no-store" })
      .then(function (r) { return r.json(); })
      .then(function (h) {
        if (serverVersion && h.version !== serverVersion) location.reload();
        serverVersion = h.version;
        var v = document.getElementById("version");
        if (v) v.textContent = "플러그인 v" + h.version;
      }, function () {});
  }

  // ---------------------------------------------------------------- shell

  function setConn(ok, detail, stopped, held) {
    var conn = document.getElementById("conn");
    if (!conn) return;
    if (ok) {
      conn.className = "conn";
      conn.replaceChildren(ico("i-plug", "ico-sm"), held ? "연결됨 · 갱신 미룸 — 선택을 풀면 이어집니다"
        : stopped ? "연결됨 · 갱신 멈춤" : "연결됨 · " + (detail ? 3 : 5) + "초마다 갱신");
    } else {
      conn.className = "conn is-off";
      conn.replaceChildren(ico("i-unplug", "ico-sm"), "연결 끊김");
    }
  }

  function setFresh(ms) {
    var f = document.getElementById("fresh");
    if (!f || !tz) return;
    f.replaceChildren("마지막 갱신 ", el("b", { cls: "num", text: fmtHMS(ms / 1000) }), " " + tz.label);
  }

  function hideOffline() {
    if (offline) { offline.hidden = true; offline.replaceChildren(); }
  }

  function showOffline(detail) {
    if (!offline) return;
    var period = detail ? 3 : 5;
    var since = lastOk != null ? Math.round((Date.now() - lastOk) / 1000) : null;
    offline.replaceChildren(
      el("div", { cls: "err", role: "alert" },
        ico("i-warn", "ico-lg"),
        el("div", null,
          el("b", { text: "대시보드 서버에 연결할 수 없습니다" }),
          el("p", { cls: "num", text: location.host + " 이 응답하지 않습니다. " + period + "초마다 다시 시도하고 있습니다. 서버가 유휴 종료됐다면 /cc-cmds:dashboard 로 다시 띄울 수 있습니다." }),
          el("button", { type: "button", cls: "btn btn-primary", onclick: function () { refresh(false); } }, ico("i-refresh"), "지금 다시 시도"))),
      lastOk != null && tz ? el("div", { cls: "stale num" }, ico("i-clock", "ico-sm"),
        (detail ? "화면의 값은 " : "아래 목록은 ") + fmtHMS(lastOk / 1000) + " 에 받은 것입니다 · " + since + "초 지남") : null);
    offline.hidden = false;
  }

  // -------------------------------------------------------------- loading

  function skTile(a, b) {
    return el("div", { cls: "sk-tile" }, el("span", { cls: "sk " + a }), el("span", { cls: "sk sk-big " + b }));
  }

  function skRow(ws) {
    var r = el("div", { cls: "sk-row" });
    ws.forEach(function (w) { r.appendChild(el("span", { cls: "sk " + w })); });
    return r;
  }

  function loadingList() {
    var box = el("div", { "aria-busy": "true" });
    box.appendChild(el("div", { cls: "sk-tiles" }, skTile("w45", "w30"), skTile("w60", "w30"), skTile("w60", "w45")));
    box.appendChild(el("div", { cls: "sk-rows" },
      skRow(["w80", "w60", "w80", "w45"]), skRow(["w60", "w45", "w60", "w45"]), skRow(["w80", "w60", "w30", "w45"])));
    box.appendChild(el("div", { cls: "loading-cap" }, ico("i-refresh"), "런 목록을 불러오는 중…"));
    return box;
  }

  function loadingDetail() {
    return el("div", { cls: "card", "aria-busy": "true" },
      el("div", { cls: "skel" }, el("i", { cls: "w1" }), el("i", { cls: "w2" }), el("i", { cls: "w3" }), el("i", { cls: "w4" })),
      el("div", { cls: "ro-note" }, ico("i-clock", "ico-sm"), "런 상세를 불러오는 중입니다."));
  }

  function listError(status) {
    return el("div", { cls: "err", role: "alert" },
      ico("i-warn", "ico-lg"),
      el("div", null,
        el("b", { text: "런 목록을 읽지 못했습니다" }),
        el("p", { cls: "num", text: "서버가 " + status + " 로 답했습니다. 5초마다 다시 시도하고 있습니다." }),
        el("button", { type: "button", cls: "btn btn-primary", onclick: function () { refresh(false); } }, ico("i-refresh"), "지금 다시 시도")));
  }

  function detailError(id, status) {
    var missing = status === 404;
    return el("div", { cls: "card" },
      el("div", { cls: "err", role: "alert" },
        tag("bad", "오류", "i-x"),
        el("div", { cls: "msg" },
          el("b", { text: missing ? "이 런을 찾을 수 없습니다" : "런 상세를 읽지 못했습니다" }),
          el("span", { cls: "sub small num", text: missing ? id + " 의 런 디렉터리와 원장이 모두 없습니다." : "서버가 " + status + " 로 답했습니다." })),
        el("a", { cls: "lnk", href: "/", text: "런 목록으로" })));
  }

  // ------------------------------------------------------------------ list

  function listURL() {
    return "/api/runs?days=" + view.days + "&base=" + encodeURIComponent(view.base) +
      "&dead=" + (view.dead ? 1 : 0) + "&exp=" + (view.exp ? 1 : 0);
  }

  function resultBucket(r) {
    var c = r.result && r.result["class"];
    if (c === "종료 조건 성립") return "ok";
    if (c === "P0 잔존" || c === "무효화") return "bad";
    return "neutral";
  }

  function resultTag(res) {
    if (!res) return tag("neutral", "결과 미상");
    var label = res["class"] === "경계" && res.label ? res.label : res["class"];
    if (res["class"] === "종료 조건 성립") return tag("ok", label, "i-check");
    if (res["class"] === "P0 잔존" || res["class"] === "무효화") return tag("bad", label, "i-x");
    return tag("neutral", label);
  }

  function tileLabel(icon, text, cls) {
    return el("div", { cls: cls || "l" }, ico(icon, cls === "l" ? null : "ico-sm"), text);
  }

  function distBar(counts, total) {
    var svg = sv("svg", { "class": "dist", viewBox: "0 0 600 8", preserveAspectRatio: "none", role: "img",
      "aria-label": counts.map(function (c) { return c.label + " " + c.n; }).join(", ") });
    var nonzero = counts.filter(function (c) { return c.n > 0; });
    if (!total || !nonzero.length) {
      svg.appendChild(sv("rect", { "class": "f-track", x: 0, y: 0, width: 600, height: 8 }));
      return svg;
    }
    var gap = 2, usable = 600 - gap * (nonzero.length - 1), x = 0;
    nonzero.forEach(function (c, i) {
      var w = c.n / total * usable;
      svg.appendChild(sv("rect", { "class": "f-" + c.key, x: Math.round(x * 100) / 100, y: 0, width: Math.max(1, Math.round(w * 100) / 100), height: 8 }));
      x += w + (i < nonzero.length - 1 ? gap : 0);
    });
    return svg;
  }

  function repoRow(label, title, v, max, rest) {
    var svg = sv("svg", { viewBox: "0 0 200 8", preserveAspectRatio: "none", "aria-hidden": "true" });
    svg.appendChild(sv("rect", { "class": "f-track", x: 0, y: 0, width: 200, height: 8 }));
    svg.appendChild(sv("rect", { "class": "f-brand", x: 0, y: 0, width: max > 0 ? Math.max(0, Math.round(v / max * 200)) : 0, height: 8 }));
    return el("div", { cls: "repo num" }, span("p" + (rest ? " rest" : ""), label, title), svg, span("amt", usd(v)));
  }

  function kpis(d, need, watch, ended, dead, now) {
    var runs = d.runs || [];
    var sec = el("section", { cls: "kpis", "aria-label": "요약" });

    // 내 손 필요 — counted across the response, which is already period-free for need runs.
    var needKinds = { "승인": 0, "중단 기록": 0 }, oldest = null;
    need.forEach(function (r) {
      (r.waiting || []).forEach(function (w) {
        if (!isAsk(w)) return;
        needKinds[w.kind]++;
        if (w.since != null && (oldest == null || w.since < oldest)) oldest = w.since;
      });
    });
    var tn = el("div", { cls: "tile tile-need" },
      tileLabel("i-hand", "내 손 필요"),
      el("div", { cls: "v num", text: String(need.length) }),
      el("div", { cls: "s", text: "기간과 무관하게 셉니다 · 실험 런 " + (view.exp ? "포함" : "제외") }),
      el("div", { cls: "need-break" },
        el("div", null, el("span", null, ico("i-stamp", "ico-sm"), "열린 승인"), el("b", { cls: "num", text: String(needKinds["승인"]) })),
        el("div", null, el("span", null, ico("i-flag", "ico-sm"), "답 없는 중단 기록"), el("b", { cls: "num", text: String(needKinds["중단 기록"]) }))),
      oldest != null
        ? el("p", { cls: "need-old" }, "가장 오래 기다린 런 ", el("b", { cls: "num", text: dur(now - oldest) }))
        : el("p", { cls: "need-old", text: "기다리는 런이 없습니다" }),
      need.length ? el("a", { cls: "go", href: "#g-need" }, ico("i-down"), "묶음으로 이동") : null);
    sec.appendChild(tn);

    // 도는 런
    var stall = watch.filter(function (r) { return r.state === "정지경고"; }).length;
    var tr = el("div", { cls: "tile tile-run" },
      tileLabel("i-play", "도는 런"),
      el("div", { cls: "v num", text: String(watch.length) }),
      el("div", { cls: "row-tags" },
        tag("run", "진행 " + (watch.length - stall)),
        stall ? tag("stall", "정지경고 " + stall, "i-warn") : null));
    sec.appendChild(tr);

    // 끝난 런
    var ok = 0, bad = 0, neutral = 0;
    ended.forEach(function (r) { var b = resultBucket(r); if (b === "ok") ok++; else if (b === "bad") bad++; else neutral++; });
    var te = el("div", { cls: "tile tile-end" },
      tileLabel("i-check", "끝난 런 · " + periodLabel()),
      el("div", { cls: "v num", text: String(ended.length) }),
      el("div", { cls: "row-tags" }, tag("ok", "성립 " + ok), tag("bad", "실패 " + bad), tag("neutral", "그 밖 " + neutral)));
    sec.appendChild(te);

    // 상태 분포
    var counts = [
      { key: "need", label: "내 손 필요", n: need.length },
      { key: "run", label: "진행", n: watch.length - stall },
      { key: "stall", label: "정지경고", n: stall },
      { key: "ok", label: "성립", n: ok },
      { key: "bad", label: "실패·무효화·P0 잔존", n: bad },
      { key: "neutral", label: "경계·질의 잔여·파생 종단·미상" + (dead.length ? "·버려짐" : ""), n: neutral + dead.length }
    ];
    var legend = el("div", { cls: "legend num" });
    counts.forEach(function (c) {
      legend.appendChild(el("span", null, el("i", { cls: "lg-" + c.key }), c.label + " ", el("b", { text: String(c.n) })));
    });
    var hiddenTotal = (d.hidden || 0) + (d.hidden_experiment || 0);
    var td = el("div", { cls: "tile tile-dist" },
      el("div", { cls: "dist-head" },
        el("span", { cls: "l" }, "상태 분포 · 보이는 런 ", el("b", { cls: "num", text: String(runs.length) })),
        span("hid num", "숨긴 런 " + hiddenTotal + " — 실험 " + (d.hidden_experiment || 0) + " · 버려짐 " + (d.hidden || 0))),
      distBar(counts, runs.length), legend);
    sec.appendChild(td);

    // 비용
    var totals = d.totals || {};
    var byBase = totals.by_base || {};
    var keys = Object.keys(byBase).sort(function (a, b) { return (byBase[b] || 0) - (byBase[a] || 0); });
    var top = keys.slice(0, 3), rest = keys.slice(3);
    var max = top.length ? byBase[top[0]] || 0 : 0;
    var repos = el("div", { cls: "repos" }, el("div", { cls: "l" }, ico("i-folder", "ico-sm"), "레포별 합계"));
    top.forEach(function (k) {
      repos.appendChild(repoRow(k === "-" ? "레포 없음" : k, k === "-" ? null : k, byBase[k] || 0, max, false));
    });
    if (rest.length) {
      repos.appendChild(repoRow("나머지 " + rest.length + "곳", null, sumBy(rest, function (k) { return byBase[k]; }), max, true));
    }
    if (!keys.length) repos.appendChild(el("div", { cls: "none", text: "—" }));
    var tc = el("div", { cls: "tile tile-cost" },
      el("div", { cls: "cost-top" },
        tileLabel("i-coin", "기간 합계 · " + (view.days === "all" ? "전체" : "최근 " + periodLabel())),
        tag("neutral", "시간대 " + (d.tz_label || tzLabel(d.tz_offset_s)), null, "tz")),
      el("div", { cls: "cost-pair" },
        el("div", null,
          el("div", { cls: "v num", text: usd(totals.period_usd) }),
          el("div", { cls: "s", text: view.exp ? "실험 런 포함" : "숨긴 실험 런 " + (d.hidden_experiment || 0) + "건 제외" })),
        el("div", { cls: "today" },
          el("div", { cls: "l" }, "오늘 쓴 비용 ",
            el("span", { cls: "info", title: TODAY_TIP }, ico("i-info", "ico-sm"), span("sr", "집계 한계 보기"))),
          el("div", { cls: "v num", title: TODAY_TIP, text: usd(totals.today_usd) }),
          el("div", { cls: "s num", text: (d.today || "") + " 자정부터" }))),
      repos);
    tc.querySelector(".tz").setAttribute("title", TZ_TIP);
    sec.appendChild(tc);
    return sec;
  }

  function switchBtn(fk, on, icon, label, cnt, disabled, onclick) {
    var b = el("button", { type: "button", cls: "switch", role: "switch", "aria-checked": on ? "true" : "false", "data-fk": fk, onclick: onclick },
      el("span", { cls: "track", "aria-hidden": "true" }), ico(icon), label + " ", el("span", { cls: "cnt num", text: cnt }));
    if (disabled) b.setAttribute("disabled", "");
    return b;
  }

  function filters(d, runs, dead) {
    var box = el("div", { cls: "filters", role: "group", "aria-label": "목록 필터" });
    box.appendChild(el("span", { cls: "fl" }, ico("i-calendar"), "기간"));
    var seg = el("div", { cls: "seg", role: "group", "aria-label": "기간" });
    PERIODS.forEach(function (p) {
      seg.appendChild(el("button", { type: "button", "aria-pressed": view.days === p[0] ? "true" : "false", text: p[1], "data-fk": "days-" + p[0],
        onclick: function () { view.days = p[0]; refresh(false); } }));
    });
    box.appendChild(seg);

    var bases = d.bases || [];
    box.appendChild(el("label", { cls: "fl", "for": "repo-sel" }, ico("i-folder"), "레포"));
    var sel = el("select", { cls: "select", id: "repo-sel", "data-fk": "repo",
      onmousedown: function () { selectHeldUntil = Date.now() + SELECT_HOLD_MS; },
      onkeydown: function (e) { selectHeldUntil = e.key === "Escape" ? 0 : Date.now() + SELECT_HOLD_MS; },
      onblur: function () { selectHeldUntil = 0; },
      onchange: function (e) { selectHeldUntil = 0; view.base = e.target.value; refresh(false); } });
    if (bases.length <= 1) {
      sel.appendChild(el("option", { value: "", text: bases.length ? bases[0] + " (하나뿐)" : "레포 없음" }));
      sel.setAttribute("disabled", "");
    } else {
      sel.appendChild(el("option", { value: "", text: "모든 레포 (" + bases.length + "곳)" }));
      bases.forEach(function (b) {
        var o = el("option", { value: b, text: b });
        if (b === view.base) o.setAttribute("selected", "");
        sel.appendChild(o);
      });
    }
    box.appendChild(sel);

    var shownExp = runs.filter(function (r) { return r.experiment; }).length;
    var hiddenExp = d.hidden_experiment || 0;
    box.appendChild(switchBtn("exp", view.exp, "i-flask", "실험 런 보기",
      view.exp ? shownExp + "건 표시 중" : (hiddenExp ? "숨긴 " + hiddenExp : "숨긴 실험 런 없음"),
      !view.exp && !hiddenExp, function () { view.exp = !view.exp; refresh(false); }));
    var hiddenDead = d.hidden || 0;
    box.appendChild(switchBtn("dead", view.dead, "i-archive", "버려진 런 보기",
      view.dead ? dead.length + "건 표시 중" : (hiddenDead ? "숨긴 " + hiddenDead : "숨긴 버려진 런 없음"),
      !view.dead && !hiddenDead, function () { view.dead = !view.dead; refresh(false); }));

    var total = runs.length + hiddenDead + hiddenExp;
    box.appendChild(el("span", { cls: "shown num" }, total + "건 중 ", el("b", { text: String(runs.length) }), "건 표시"));
    return box;
  }

  function colsHeader() {
    return el("div", { cls: "cols", "aria-hidden": "true" },
      el("span", { text: "목표" }), el("span", { text: "지금 · 결과" }), el("span", { text: "기다리는 것" }),
      el("span", { text: "PR" }), span("r", "경과 · 마감"), span("r", "비용"));
  }

  function emptyList(d) {
    var parts = [];
    if (d.hidden_experiment) parts.push("숨긴 실험 런 " + d.hidden_experiment + "건");
    if (d.hidden) parts.push("버려진 런 " + d.hidden + "건");
    var idx = -1;
    PERIODS.forEach(function (p, i) { if (p[0] === view.days) idx = i; });
    var wider = idx >= 0 && idx < PERIODS.length - 1 ? PERIODS[idx + 1] : null;
    return el("div", { cls: "empty" },
      ico("i-inbox", "ico-lg"),
      el("b", { text: view.days === "all" ? "보일 런이 없습니다" : "최근 " + periodLabel() + "에 끝나거나 도는 런이 없습니다" }),
      el("span", { cls: "num", text: parts.length ? parts.join(" · ") + "이 있습니다." : "숨긴 런도 없습니다." }),
      wider ? el("button", { type: "button", cls: "btn", text: "기간 " + wider[1] + "로 넓히기", "data-fk": "widen",
        onclick: function () { view.days = wider[0]; refresh(false); } }) : null);
  }

  function groupHead(icon, id, title, sub, count) {
    return el("div", { cls: "gh" }, ico(icon, "ico-lg"), el("h2", { id: id, text: title }),
      sub ? span("sub", sub) : null, span("c num", String(count)));
  }

  function goalCell(r) {
    var meta = el("div", { cls: "meta num" },
      el("span", { text: r.id }), el("span", { cls: "dotsep" }), span(null, repoName(r.base), r.base || null));
    if (r.state === "버려짐") meta.appendChild(tag("neutral", r.state));
    else if (r.state === "정지경고" && r.attention === "need") meta.appendChild(tag("stall", r.state, "i-warn"));
    return el("div", { cls: "cell" },
      el("a", { cls: "row-link ell", href: "/run/" + encodeURIComponent(r.id), text: r.goal || r.id, title: r.goal || null }),
      meta);
  }

  function nowLine(now) {
    if (now && now.stage) {
      return el("div", { cls: "ell" }, span("step", now.stage), " ",
        span("kind", (now.kind || "종류 미상") + (now.attempt ? " · 시도 " + now.attempt : "")));
    }
    if (now && now.blocked) {
      return el("div", { cls: "ell", title: now.blocked }, span("step", "막힘"), " ", span("kind", now.blocked));
    }
    return el("div", { cls: "ell" }, span("dim", "지금 단계 없음"));
  }

  function waitCell(r, now) {
    var a = asks(r);
    if (a.length) {
      var w = a[0];
      var line = el("div", { cls: "wline" },
        tag("need", w.kind, w.kind === "승인" ? "i-stamp" : "i-flag"),
        span("wt ell", firstLine(w.text) || "(문면 없음)", w.text || null));
      var sub = w.since != null ? dur(now - w.since) + "째 기다림" : "기다린 시간 미상";
      if (w.returned) sub += " · 되돌림";
      if (a.length > 1) {
        var k = countKinds(a.slice(1)), more = [];
        if (k["승인"]) more.push("승인 " + k["승인"] + "건");
        if (k["중단 기록"]) more.push("중단 기록 " + k["중단 기록"] + "건");
        sub += " · 외 " + more.join(" · ");
      }
      return el("div", { cls: "cell" }, line, span("t2 num", sub));
    }
    var limits = (r.waiting || []).filter(function (w) { return w.kind === "사용량 한도"; }).sort(bySince);
    if (limits.length) {
      var l = limits[0];
      return el("div", { cls: "cell" },
        el("div", { cls: "wline" }, tag("neutral", "사용량 한도", "i-hourglass"), span("wt ell", l.text || "사용량 한도 대기", l.ref || null)),
        span("t2 num", (l.since != null ? dur(now - l.since) + "째" : "시작 시각 미상") + " · 사람 할 일 없음"));
    }
    return el("div", { cls: "cell none", text: "—" });
  }

  function prCell(prs) {
    if (!prs || !prs.length) return el("div", { cls: "cell none", text: "—" });
    var c = el("div", { cls: "cell pr-list" });
    prs.forEach(function (p) {
      var title = "세그먼트 " + p.seg;
      c.appendChild(p.url
        ? el("a", { cls: "pr num", href: p.url, text: String(p.number), title: title })
        : el("span", { cls: "pr num", text: String(p.number), title: title + " · 주소 없음" }));
    });
    return c;
  }

  function deadlineText(r) {
    if (r.deadline_left_s != null) return r.deadline_left_s >= 0 ? "마감까지 " + dur(r.deadline_left_s) : "마감 지남";
    return "마감 없음";
  }

  function elapsedCell(r, ended) {
    if (r.elapsed_s == null) return el("div", { cls: "cell r none", text: "—" });
    var sub = ended
      ? (r.ended_at != null ? fmtHM(r.ended_at) + " 종단" : "종단 시각 미상")
      : deadlineText(r);
    return el("div", { cls: "cell r num" }, dur(r.elapsed_s), span("t2", sub));
  }

  function costCell(r) { return el("div", { cls: "cell r num cost", text: usd(r.cost_usd) }); }

  function rowNeed(r, now) {
    return el("div", { cls: "row", id: "run-" + r.id },
      goalCell(r), el("div", { cls: "cell" }, nowLine(r.now)), waitCell(r, now), prCell(r.prs), elapsedCell(r, false), costCell(r));
  }

  function rowRun(r, now) {
    var status = r.state === "정지경고"
      ? tag("stall", "정지경고 · 성장 없음 " + (r.last_growth != null ? dur(now - r.last_growth) : "미상"), "i-warn", "num")
      : tag("run", r.state === "정산중" ? "정산 중" : "진행", "i-play");
    return el("div", { cls: "row", id: "run-" + r.id },
      goalCell(r), el("div", { cls: "cell" }, nowLine(r.now), status), waitCell(r, now), prCell(r.prs), elapsedCell(r, false), costCell(r));
  }

  function resCell(r) {
    var res = el("div", { cls: "res" }, resultTag(r.result));
    var left = (r.waiting || []).length;
    if (left) res.appendChild(tag("neutral", "남은 기록 " + left, null, "num"));
    var seg = r.seg || {};
    res.appendChild(span("dim num", "머지 " + (seg.merged || 0) + " · park " + (seg.park || 0)));
    var cell = el("div", { cls: "cell" }, res);
    if (r.result && r.result["class"] === "미상" && r.result.line) {
      cell.appendChild(span("t2 ell", r.result.line, r.result.line));
    }
    return cell;
  }

  function rowEnded(r) {
    return el("div", { cls: "row", id: "run-" + r.id },
      goalCell(r), resCell(r), el("div", { cls: "cell none", text: "—" }), prCell(r.prs), elapsedCell(r, true), costCell(r));
  }

  function rowGone(r) {
    var sub = r.last_growth != null ? "마지막 성장 " + fmtMDHM(r.last_growth) : "지금 단계 없음";
    return el("div", { cls: "row", id: "run-" + r.id },
      goalCell(r), el("div", { cls: "cell" }, tag("neutral", "버려짐"), span("t2 num", sub)),
      el("div", { cls: "cell none", text: "—" }), prCell(r.prs), elapsedCell(r, false), costCell(r));
  }

  function groupNeed(rows, now) {
    var box = el("div", { cls: "rows" });
    rows.forEach(function (r) { box.appendChild(rowNeed(r, now)); });
    return el("section", { cls: "group g-need", id: "g-need", "aria-labelledby": "h-need" },
      groupHead("i-hand", "h-need", "내 손이 필요한 런", "가장 오래 기다린 순", rows.length), box);
  }

  function groupRun(rows, now) {
    var box = el("div", { cls: "rows" });
    rows.forEach(function (r) { box.appendChild(rowRun(r, now)); });
    return el("section", { cls: "group g-run", id: "g-run", "aria-labelledby": "h-run" },
      groupHead("i-play", "h-run", "도는 런", null, rows.length), box);
  }

  function groupEnded(rows, d) {
    var byDay = {}, keys = [];
    rows.forEach(function (r) {
      var k = r.ended_day || "";
      if (!byDay[k]) { byDay[k] = []; keys.push(k); }
      byDay[k].push(r);
    });
    // Descending dates; the empty key (unknown day) ends up last.
    keys.sort().reverse();
    var yesterday = d.today ? dayBefore(d.today) : null;
    var sec = el("section", { cls: "group g-ended", id: "g-ended", "aria-labelledby": "h-ended" },
      groupHead("i-check", "h-ended", "끝난 런", "끝난 날짜별 · " + (tz ? tz.label : "") + " 자정 기준", rows.length));
    keys.forEach(function (k) {
      var list = byDay[k];
      var open = k && (k === d.today || k === yesterday);
      var det = el("details", { cls: "day", "data-key": "day:" + k, "data-default-open": open ? "" : null });
      if (open) det.setAttribute("open", "");
      var sum = el("summary", null, ico("i-chev", "chev"));
      if (!k) sum.appendChild(document.createTextNode("날짜 미상"));
      else if (k === d.today) { sum.appendChild(document.createTextNode("오늘 ")); sum.appendChild(span("dim num", dayLabel(k))); }
      else if (k === yesterday) { sum.appendChild(document.createTextNode("어제 ")); sum.appendChild(span("dim num", dayLabel(k))); }
      else sum.appendChild(span("num", dayLabel(k)));
      sum.appendChild(span("sum num", list.length + "건 · " + usd(sumBy(list, function (r) { return r.cost_usd; }))));
      det.appendChild(sum);
      var box = el("div", { cls: "rows" });
      list.forEach(function (r) { box.appendChild(rowEnded(r)); });
      det.appendChild(box);
      sec.appendChild(det);
    });
    return sec;
  }

  function groupGone(rows) {
    var box = el("div", { cls: "rows" });
    rows.forEach(function (r) { box.appendChild(rowGone(r)); });
    return el("section", { cls: "group g-gone", id: "g-gone", "aria-labelledby": "h-gone" },
      groupHead("i-archive", "h-gone", "버려진 런", "한 시간 넘게 성장이 없고 기다리는 것도 없는 런", rows.length), box);
  }

  function renderList(d) {
    setTz(d.tz_offset_s, d.tz_label);
    var now = d.generated_at != null ? d.generated_at : Math.floor(Date.now() / 1000);
    var runs = d.runs || [];
    var need = [], watch = [], ended = [], dead = [];
    runs.forEach(function (r) {
      if (r.attention === "need") need.push(r);
      else if (r.attention === "watch") watch.push(r);
      else if (r.attention === "ended") ended.push(r);
      else dead.push(r);
    });
    // The response keeps its own order; the need group is the screen's sort.
    need.sort(function (a, b) {
      var x = oldestSince(a), y = oldestSince(b);
      if (x == null) return y == null ? 0 : 1;
      if (y == null) return -1;
      return x - y;
    });
    var frag = document.createDocumentFragment();
    frag.appendChild(kpis(d, need, watch, ended, dead, now));
    frag.appendChild(filters(d, runs, dead));
    if (!runs.length) {
      frag.appendChild(emptyList(d));
    } else {
      frag.appendChild(colsHeader());
      if (need.length) frag.appendChild(groupNeed(need, now));
      if (watch.length) frag.appendChild(groupRun(watch, now));
      if (ended.length) frag.appendChild(groupEnded(ended, d));
      if (view.dead && dead.length) frag.appendChild(groupGone(dead));
    }
    app.replaceChildren(frag);
  }

  // ---------------------------------------------------------------- detail

  function stateTag(state) {
    if (state === "정지경고") return tag("stall", "상태 " + state, "i-warn");
    if (state === "승인대기") return tag("need", "상태 " + state, "i-clock");
    if (state === "종단" || state === "버려짐") return tag("neutral", "상태 " + state);
    return tag("run", "상태 " + state, "i-play");
  }

  function statusTag(status, merged) {
    if (status === "끝남") return tag("ok", merged ? "끝남 · 머지" : "끝남", "i-check");
    if (status === "도는 중") return tag("run", status, "i-play");
    if (status === "실패") return tag("bad", status, "i-x");
    if (status === "park") return tag("neutral", status, "i-pause");
    return tag("neutral", status || "대기", "i-clock");
  }

  function sboxClass(status) {
    return { "끝남": "s-ok", "도는 중": "s-run", "실패": "s-bad", "park": "s-park" }[status] || "s-wait";
  }

  function dotFor(status) {
    var map = { "끝남": ["ok", "i-tick"], "도는 중": ["run", "i-play"], "실패": ["bad", "i-cross"], "park": ["wait", "i-pause"] };
    var m = map[status] || ["wait", "i-clock"];
    return el("span", { cls: "dot " + m[0] }, ico(m[1], "ico-sm"));
  }

  function stepKind(s) { return s.kind && s.kind !== "reconverge" ? s.kind : (s.skill || s.kind || "-"); }

  function sectionHead(icon, id, title, aside) {
    return el("div", { cls: "sec-h" }, ico(icon, "ico-lg"), el("h2", { id: id, text: title }),
      aside ? el("span", { cls: "aside num" }, aside) : null);
  }

  function meter(ratio, label) {
    var p = Math.max(0, Math.min(100, Math.round(ratio * 100)));
    var svg = sv("svg", { "class": "meter", viewBox: "0 0 100 8", preserveAspectRatio: "none", role: "img", "aria-label": label });
    svg.appendChild(sv("rect", { "class": "mt-bg", x: 0, y: 0, width: 100, height: 8, rx: 2 }));
    svg.appendChild(sv("rect", { "class": "mt-fill", x: 0, y: 0, width: p, height: 8, rx: 2 }));
    return svg;
  }

  function detailHead(d, now) {
    var s = d.summary, m = d.manifest || {};
    var waiting = d.waiting || [];
    var askN = waiting.filter(isAsk).length, kinds = countKinds(waiting);
    var ended = s.state === "종단";
    var tzName = tz ? tz.label : "";
    var meta = el("div", { cls: "meta" },
      el("span", { cls: "k" }, "런 ", copyText(s.id, true)),
      el("span", { cls: "k" }, "레포 ", s.base ? copyText(s.base) : span("sub", "없음")));
    var tags = el("span", { cls: "tags" });
    if (s.attention === "need") tags.appendChild(tag("need-solid", "내 손 필요 " + askN, "i-hand"));
    tags.appendChild(stateTag(s.state));
    if (ended) {
      tags.appendChild(resultTag(s.result));
      if (waiting.length) tags.appendChild(tag("neutral", "남은 기록 " + waiting.length));
    }
    meta.appendChild(tags);
    if (s.started_at != null) meta.appendChild(span("k num", "시작 " + fmtMDHM(s.started_at) + " " + tzName));
    (s.notes || []).forEach(function (n) { meta.appendChild(span("k sub", n)); });

    var head = el("div", { cls: "head-top" },
      el("h1", { cls: "goal", id: "goal", text: m.goal || s.goal || "매니페스트 없음 — 목표를 읽을 수 없습니다" }), meta);
    if (ended && s.result && s.result.line) {
      // 원장의 결과 줄은 UTC 시각으로 시작하므로, 표시 시간대의 종단 시각이 있으면 그것으로 바꿔 적는다
      var resultText = s.ended_at != null
        ? fmtYMDHM(s.ended_at) + " " + s.result.line.replace(/^\d{4}-\d{2}-\d{2}T\S+\s+/, "")
        : s.result.line;
      head.appendChild(span("sub small num", resultText, s.result.line));
    }

    var cost = d.cost || {};
    var costStat = el("div", { cls: "stat" }, el("span", { cls: "l" }, ico("i-coin", "ico-sm"), cost.ceiling != null ? "비용 · 천장 대비" : "비용"));
    if (cost.ceiling != null && cost.ratio != null) {
      costStat.appendChild(el("span", { cls: "v num" }, usd(cost.usd) + " ",
        el("small", { text: "/ 천장 " + usd(cost.ceiling) + " · " + Math.round(cost.ratio * 100) + "%" })));
      costStat.appendChild(meter(cost.ratio, "비용 천장의 " + Math.round(cost.ratio * 100) + "% 사용"));
    } else {
      costStat.appendChild(el("span", { cls: "v num", text: usd(cost.usd) }));
      costStat.appendChild(span("sub small", cost.ceiling != null ? "천장 " + usd(cost.ceiling) : "비용 천장 없음"));
    }

    var dl = el("div", { cls: "stat" }, el("span", { cls: "l" }, ico("i-flag", "ico-sm"), ended ? "마감" : "마감까지"));
    if (s.deadline_left_s != null && !ended) {
      dl.appendChild(el("span", { cls: "v num", text: s.deadline_left_s >= 0 ? dur(s.deadline_left_s) : "지남 " + dur(-s.deadline_left_s) }));
    } else {
      dl.appendChild(el("span", { cls: "v num", text: s.deadline != null ? (typeof s.deadline === "number" ? fmtMDHM(s.deadline) : String(s.deadline)) : "마감 없음" }));
    }
    if (typeof s.deadline === "number") dl.appendChild(span("sub small num", "벽시계 마감 " + fmtMDHM(s.deadline) + " " + tzName));

    var waitStat = el("div", { cls: "stat" + (askN ? " need" : "") },
      el("span", { cls: "l" }, ico("i-hand", "ico-sm"), "기다리는 것"),
      el("span", { cls: "v num" }, String(waiting.length) + " ",
        waiting.length ? el("small", { text: "승인 " + kinds["승인"] + " · 중단 기록 " + kinds["중단 기록"] + (kinds["사용량 한도"] ? " · 사용량 한도 " + kinds["사용량 한도"] : "") }) : null));

    var stats = el("div", { cls: "stats" },
      el("div", { cls: "stat" }, el("span", { cls: "l" }, ico("i-clock", "ico-sm"), ended ? "걸린 시간" : "경과"),
        el("span", { cls: "v num", text: dur(s.elapsed_s) })),
      dl, costStat, waitStat);
    var card = el("section", { cls: "card", "aria-labelledby": "goal" }, head, stats);
    if (ended) card.appendChild(el("div", { cls: "ro-note" }, ico("i-pause", "ico-sm"), "끝난 런이라 3초 갱신을 멈췄습니다."));
    return card;
  }

  function waitItem(w, now) {
    var isHalt = w.kind === "중단 기록", isLimit = w.kind === "사용량 한도";
    var chip = isLimit ? tag("neutral", w.kind, "i-hourglass") : tag("need", w.kind, isHalt ? "i-flag" : "i-stamp");
    var body = el("div", { cls: "body" }, el("p", { cls: "wtext", text: w.text || "(문면 없음)" }));
    var kv = el("dl", { cls: "kv" });
    kv.appendChild(el("dt", { text: isHalt ? "기록 경로" : isLimit ? "대기 파일" : "승인 id" }));
    kv.appendChild(el("dd", null, copyText(w.ref || "-", !isHalt)));
    if (isHalt) {
      var where = [];
      if (w.step) where.push(w.step);
      if (w.skill) where.push(w.skill);
      kv.appendChild(el("dt", { text: "스텝" }));
      kv.appendChild(el("dd", { text: where.length ? where.join(" · ") : "-" }));
      if (w["class"]) { kv.appendChild(el("dt", { text: "분류" })); kv.appendChild(el("dd", { text: w["class"] })); }
    }
    if (w.returned) { kv.appendChild(el("dt", { text: "상태" })); kv.appendChild(el("dd", null, tag("neutral", "되돌림"))); }
    body.appendChild(kv);
    if (isHalt && w.recommend) body.appendChild(el("div", { cls: "rec" }, el("b", { text: "추천" }), el("span", { text: w.recommend })));
    var waited = el("div", { cls: "waited" }, span("sub small", "기다린 시간"),
      span("v num", w.since != null ? dur(now - w.since) : "미상"),
      w.since != null ? span("sub small num", fmtMDHM(w.since) + " 부터") : null);
    return el("div", { cls: "wait" }, chip, body, waited);
  }

  function waitingSection(d, now) {
    var items = (d.waiting || []).slice().sort(bySince);
    var askN = items.filter(isAsk).length;
    var sec = el("section", { cls: "card", "aria-labelledby": "h-wait" });
    var head = sectionHead("i-hand", "h-wait", "지금 기다리는 것", items.length ? items.length + "건 · 가장 오래 기다린 것부터" : "0건");
    if (askN) head.className = "sec-h need";
    sec.appendChild(head);
    if (items.length) {
      items.forEach(function (w) { sec.appendChild(waitItem(w, now)); });
    } else {
      var n = d.summary.now;
      var line = el("div", { cls: "nowline" }, span("sub", "기다리는 것이 없습니다. 지금 단계"));
      if (n && n.stage) {
        line.appendChild(tag("run", "도는 중", "i-play"));
        line.appendChild(el("b", { text: n.stage }));
        line.appendChild(el("span", { text: (n.kind || "종류 미상") + (n.attempt ? " · 시도 " + n.attempt : "") }));
      } else if (n && n.blocked) {
        line.appendChild(tag("neutral", "막힘"));
        line.appendChild(el("span", { text: n.blocked }));
      } else {
        line.appendChild(el("span", { cls: "sub", text: d.summary.state === "종단" ? "없음 — 끝난 런" : "없음" }));
      }
      sec.appendChild(line);
    }
    sec.appendChild(el("div", { cls: "ro-note" }, ico("i-eye", "ico-sm"), "대시보드는 읽기 전용입니다 — 답하기 단추가 없습니다."));
    return sec;
  }

  function stepLine(steps) {
    var line = el("div", { cls: "stepline", role: "list", "aria-label": "매니페스트 스텝 순서" });
    steps.forEach(function (s, i) {
      if (i) line.appendChild(el("span", { cls: "conn", "aria-hidden": "true" }));
      var segs = (s.segments || []).map(function (c) { return c.id; });
      line.appendChild(el("div", { cls: "sbox " + sboxClass(s.status), role: "listitem" },
        el("div", { cls: "top" }, dotFor(s.status), span("id", s.id)),
        span("kd", stepKind(s) + (segs.length ? " · " + segs.join(" ") : "")),
        span("st num", s.status + (s.attempts > 1 ? " · 시도 " + s.attempts : ""))));
    });
    return line;
  }

  function th(text, cls) { return el("th", { cls: cls, text: text }); }
  function td(text, cls) { return el("td", { cls: cls, text: text }); }

  function segTable(step, d, segIndex, prsBySeg) {
    var t = el("table", { cls: "segs" },
      el("thead", null, el("tr", null, th("세그먼트"), th("상태"), th("선행"), th("PR"), th("사이클 수", "r"), th("시도", "r"))));
    var tb = el("tbody");
    (step.segments || []).forEach(function (c) {
      var g = segIndex[c.id] || {};
      var prs = prsBySeg[c.id] || [];
      var prCellEl = el("td");
      if (!prs.length) prCellEl.textContent = "-";
      prs.forEach(function (p) {
        prCellEl.appendChild(p.url ? el("a", { cls: "lnk", href: p.url, text: "#" + p.number }) : el("span", { text: "#" + p.number }));
      });
      tb.appendChild(el("tr", null,
        el("td", null, el("b", { text: c.id })),
        el("td", null, statusTag(c.status, g.state === "머지됨")),
        td((g.deps || []).length ? g.deps.join(", ") : "-"),
        prCellEl,
        td(String((g.cycles || []).length), "r num"),
        td(String(c.attempts || 0), "r num")));
    });
    t.appendChild(tb);
    return t;
  }

  function stepsTable(d, now, segIndex, prsBySeg) {
    var t = el("table", { cls: "tbl" },
      el("thead", null, el("tr", null, th("스텝"), th("종류"), th("상태"), th("시도", "r"), th("시작"), th("끝"),
        th("걸린 시간", "r"), th("비용", "r"), th("종단 부류", "w"))));
    var tb = el("tbody");
    (d.steps || []).forEach(function (s) {
      var hasSeg = (s.segments || []).length > 0;
      var took = s.started != null && s.ended != null ? dur(s.ended - s.started)
        : (s.status === "도는 중" && s.started != null ? dur(now - s.started) + "째" : "-");
      tb.appendChild(el("tr", { cls: hasSeg ? "has-seg" : null },
        td(s.id, "sid"), td(stepKind(s)), el("td", null, statusTag(s.status)),
        td(String(s.attempts || 0), "r num"),
        td(s.started != null ? fmtMDHM(s.started) : "-", "num"),
        td(s.ended != null ? fmtMDHM(s.ended) : "-", "num"),
        td(took, "r num"), td(s.usd != null ? usd(s.usd) : "-", "r num"), td(s.end_class || "-", "w")));
      if (hasSeg) {
        tb.appendChild(el("tr", { cls: "segwrap" }, el("td", { colspan: "9" }, segTable(s, d, segIndex, prsBySeg))));
      }
    });
    t.appendChild(tb);
    return t;
  }

  function tickStep(span) {
    var steps = [900, 1800, 3600, 3 * 3600, 6 * 3600, 12 * 3600, 86400, 2 * 86400, 7 * 86400];
    for (var i = 0; i < steps.length; i++) if (span / steps[i] <= 10) return steps[i];
    return steps[steps.length - 1];
  }

  function barClass(cls) {
    if (cls === "정상 완료") return "b-ok";
    if (cls === "의도된 park") return "b-park";
    return "b-bad";
  }

  function timeBand(d, now) {
    var ended = d.summary.state === "종단";
    var items = (d.timeline || []).filter(function (t) { return t.start != null && t.end != null; });
    var skipped = (d.timeline || []).length - items.length;
    var shifts = (d.shifts || []).filter(function (s) { return s.at != null; });
    var box = el("div", { cls: "tband" },
      el("h3", { cls: "sub-h" }, ico("i-clock", "ico-sm"), "시간 띠 — 시도마다 한 막대, 막대에 올리면 시도와 교대 이름이 보입니다"));
    if (!items.length) {
      box.appendChild(el("div", { cls: "empty-line", text: "시작과 끝을 아는 시도가 없어 시간 띠를 그리지 않았습니다." }));
      return box;
    }
    var rows = [], rowOf = {};
    items.forEach(function (t) {
      var k = t.stage || "?";
      if (rowOf[k] == null) { rowOf[k] = rows.length; rows.push(k); }
    });
    var times = [];
    items.forEach(function (t) { times.push(t.start, t.end); });
    shifts.forEach(function (s) { times.push(s.at); });
    if (d.run_start != null) times.push(d.run_start);
    if (!ended) times.push(now);
    else if (d.summary.ended_at != null) times.push(d.summary.ended_at);
    var t0 = Math.min.apply(null, times), t1 = Math.max.apply(null, times);
    if (t1 <= t0) t1 = t0 + 60;
    var W = 1200, L = 120, R = 20, TOP = 24, RH = 22;
    var H = TOP + rows.length * RH + 26;
    var x = function (t) { return Math.round((L + (t - t0) / (t1 - t0) * (W - L - R)) * 10) / 10; };
    var svg = sv("svg", { "class": "tb", viewBox: "0 0 " + W + " " + H, role: "img",
      "aria-label": "스텝 시도별 시간 띠, " + fmtMDHM(t0) + " 부터 " + (ended ? fmtMDHM(t1) + " 까지" : "지금까지") });

    var grid = sv("g");
    var step = tickStep(t1 - t0), off = tz ? tz.off : 0;
    var first = Math.ceil((t0 + off) / step) * step - off;
    for (var t = first; t < t1; t += step) {
      if (t <= t0) continue;
      grid.appendChild(sv("line", { "class": "grid", x1: x(t), y1: TOP, x2: x(t), y2: TOP + rows.length * RH }));
      var atMidnight = (t + off) % 86400 === 0;
      grid.appendChild(sv("text", { "class": "t-sub", x: x(t), y: 16, "text-anchor": "middle" }, atMidnight ? fmtMD(t) + " 00:00" : fmtHM(t)));
    }
    grid.appendChild(sv("text", { "class": "t-sub", x: L, y: 16 }, fmtMDHM(t0)));
    grid.appendChild(sv("text", { "class": "t-main", x: W - R, y: 16, "text-anchor": "end" }, ended ? "종단 " + fmtHM(t1) : "지금 " + fmtHM(now)));
    svg.appendChild(grid);

    var lines = sv("g");
    rows.forEach(function (name, i) {
      var y = TOP + (i + 1) * RH;
      lines.appendChild(sv("line", { "class": "row-line", x1: 0, y1: y, x2: W, y2: y }));
      lines.appendChild(sv("text", { "class": "t-main", x: 8, y: y - 7 }, name));
    });
    svg.appendChild(lines);

    var bars = sv("g");
    items.forEach(function (t) {
      var y = TOP + rowOf[t.stage || "?"] * RH + 4;
      var w = Math.max(2, x(t.end) - x(t.start));
      var rect = sv("rect", { "class": barClass(t["class"]), x: x(t.start), y: y, width: Math.round(w * 10) / 10, height: 14, rx: 2 });
      var title = (t.stage || "?") + " 시도 " + (t.attempt || "?") + " · " + (t.kind || "종류 미상") + " · " +
        fmtMDHM(t.start) + "–" + fmtHM(t.end) + " · " + (t["class"] || "부류 미상") +
        (t.usd != null ? " · " + usd(t.usd) : "") + (t.shift ? " · 띄운 교대 " + t.shift : "");
      rect.appendChild(sv("title", null, title));
      bars.appendChild(rect);
    });
    svg.appendChild(bars);
    if (!ended) svg.appendChild(sv("line", { "class": "now", x1: x(now), y1: TOP, x2: x(now), y2: H - 4 }));

    var marks = sv("g");
    shifts.forEach(function (s) {
      var cx = x(s.at), cy = H - 11;
      var p = sv("polygon", { "class": "shift", points: cx + "," + (cy - 5) + " " + (cx + 5) + "," + cy + " " + cx + "," + (cy + 5) + " " + (cx - 5) + "," + cy });
      p.appendChild(sv("title", null, "교대 " + (s.ordinal || "?") + " · " + fmtMDHM(s.at) + (s.reason ? " · " + s.reason : "")));
      marks.appendChild(p);
    });
    svg.appendChild(marks);
    box.appendChild(svg);

    box.appendChild(el("div", { cls: "legend" },
      el("span", null, el("i", { cls: "sw ok" }), "정상 완료"),
      el("span", null, el("i", { cls: "sw bad" }), "실패(크래시·정지)"),
      el("span", null, el("i", { cls: "sw park" }), "의도된 park"),
      el("span", null, el("i", { cls: "sw shift" }), "교대")));
    if (shifts.length) {
      var ul = el("ul", { cls: "shifts" });
      shifts.forEach(function (s) {
        ul.appendChild(el("li", null, el("i", { cls: "sw shift" }),
          el("span", null, el("b", { text: "교대 " + (s.ordinal || "?") }), " ", span("sub num", fmtMDHM(s.at)), s.reason ? " · " + s.reason : "")));
      });
      box.appendChild(ul);
    }
    if (skipped) box.appendChild(el("div", { cls: "note num", text: "시작이나 끝 시각을 모르는 시도 " + skipped + "건은 띠에 그리지 않았습니다." }));
    return box;
  }

  function stepsSection(d, now) {
    var steps = d.steps || [];
    var segIndex = {};
    (d.segments || []).forEach(function (g) { segIndex[g.id] = g; });
    var prsBySeg = {};
    (d.summary.prs || []).forEach(function (p) { (prsBySeg[p.seg] = prsBySeg[p.seg] || []).push(p); });
    var counts = {};
    steps.forEach(function (s) { counts[s.status] = (counts[s.status] || 0) + 1; });
    var aside = ["스텝 " + steps.length];
    ["끝남", "도는 중", "실패", "대기", "park"].forEach(function (k) { if (counts[k]) aside.push(k + " " + counts[k]); });
    var sec = el("section", { cls: "card", "aria-labelledby": "h-steps" },
      sectionHead("i-steps", "h-steps", "단계별 진행", aside.join(" · ")));
    if (!steps.length) {
      sec.appendChild(el("div", { cls: "sec-b" }, el("div", { cls: "empty-line", text: "매니페스트가 없어 단계를 그릴 수 없습니다." })));
    } else {
      sec.appendChild(stepLine(steps));
      sec.appendChild(stepsTable(d, now, segIndex, prsBySeg));
    }
    sec.appendChild(timeBand(d, now));
    return sec;
  }

  function clauseTag(state) {
    if (state === "성립") return tag("ok", state, "i-check");
    if (state === "미판정") return tag("neutral", state, "i-pause");
    return tag("neutral", state || "-", "i-clock");
  }

  function clausesSection(d) {
    var cl = d.clauses || [];
    var counts = {}, order = [];
    cl.forEach(function (c) { if (counts[c.state] == null) { counts[c.state] = 0; order.push(c.state); } counts[c.state]++; });
    var sec = el("section", { cls: "card", "aria-labelledby": "h-exit" },
      sectionHead("i-flag", "h-exit", "종료 조건", order.map(function (k) { return k + " " + counts[k]; }).join(" · ") || "절 없음"));
    if (!cl.length) {
      sec.appendChild(el("div", { cls: "sec-b" }, el("div", { cls: "empty-line", text: "종료 절이 없습니다." })));
      return sec;
    }
    var t = el("table", { cls: "tbl" }, el("thead", null, el("tr", null, th("절"), th("문면", "w"), th("판정", "verdict"))));
    var tb = el("tbody");
    cl.forEach(function (c) {
      tb.appendChild(el("tr", null, td(c.id, "sid"), td(c.text, "w"), el("td", { cls: "verdict" }, clauseTag(c.state))));
    });
    t.appendChild(tb);
    sec.appendChild(t);
    return sec;
  }

  function cnt(label, n) { return el("span", { cls: "cnt" }, label + " ", el("b", { cls: "num", text: String(n) })); }

  function judgmentsSection(d) {
    var j = d.judgments || { items: [], by_class: {} };
    var items = j.items || [];
    var sec = el("section", { cls: "card", "aria-labelledby": "h-judge" },
      sectionHead("i-scale", "h-judge", "자율 판단", items.length ? items.length + "건 · 시간순 · 행을 펼치면 근거가 보입니다" : "0건"));
    if (!items.length) {
      sec.appendChild(el("div", { cls: "sec-b" }, el("div", { cls: "empty-line", text: "원장에 자율 판단 행이 없습니다." })));
      return sec;
    }
    var counts = el("div", { cls: "counts" }, span("sub small", "판단 부류"));
    var classes = Object.keys(j.by_class || {});
    if (!classes.length) counts.appendChild(span("sub small", "-"));
    classes.forEach(function (k) { counts.appendChild(cnt(k, j.by_class[k])); });
    counts.appendChild(el("span", { cls: "sep", "aria-hidden": "true" }));
    counts.appendChild(span("sub small", "출처"));
    var src = {};
    items.forEach(function (it) { src[it.source] = (src[it.source] || 0) + 1; });
    ["판단", "자동 답", "자동 해소"].forEach(function (k) { if (src[k]) counts.appendChild(cnt(k, src[k])); });
    sec.appendChild(counts);
    sec.appendChild(el("div", { cls: "jgrid jhead" }, el("span", { text: "시각" }), el("span", { text: "출처" }), el("span", { text: "결정" }),
      el("span", { text: "세그먼트" }), el("span", { text: "등급" }), el("span", { text: "되돌리는 법" }), el("span")));
    // A row's position can shift when a later ledger row pairs with an earlier
    // automatic resolution, so its key is its content and its count among equals.
    var keyCount = new Map();
    items.forEach(function (it) {
      var jkey = [it.source, it["결정"], it["세그먼트"], it["근거"], it["해소 승인"]].join("|");
      var nth = keyCount.get(jkey) || 0;
      keyCount.set(jkey, nth + 1);
      var sum = el("summary", { cls: "jgrid" },
        span("num", it.at != null ? fmtMDHM(it.at) : "-"), el("span", { text: it.source || "-" }),
        el("span", { text: it["결정"] || "-" }), el("span", { text: it["세그먼트"] || "-" }),
        el("span", { text: it["등급"] || "-" }), el("span", { text: it["되돌리는 법"] || "-" }), ico("i-chev", "chev"));
      var body = el("dl", { cls: "jbody" });
      function kv(k, v, copy) {
        body.appendChild(el("dt", { text: k }));
        body.appendChild(el("dd", null, copy && v ? copyText(v, true) : (v || "-")));
      }
      if (it.source === "판단") { kv("판단 부류", it["판단 부류"]); kv("기준", it["기준"]); }
      kv("근거", it["근거"]);
      if (it.source === "자동 해소") kv("승인 id", it["해소 승인"], true);
      else kv("해소 승인", it["해소 승인"], true);
      sec.appendChild(el("details", { cls: "jrow", "data-key": "judgment:" + jkey + "|" + nth }, sum, body));
    });
    return sec;
  }

  function pbar(p0, p1, unit) {
    var svg = sv("svg", { "class": "pbar", viewBox: "0 0 120 12", preserveAspectRatio: "none", role: "img",
      "aria-label": "P0 " + p0 + " 건, P1 " + p1 + " 건" });
    svg.appendChild(sv("rect", { "class": "pb-bg", x: 0, y: 0, width: 120, height: 12, rx: 2 }));
    var x = 0;
    if (p0 > 0) { svg.appendChild(sv("rect", { "class": "pb-0", x: 0, y: 0, width: Math.round(p0 * unit), height: 12, rx: 2 })); x = p0 * unit + 2; }
    if (p1 > 0) svg.appendChild(sv("rect", { "class": "pb-1", x: Math.round(x), y: 0, width: Math.round(p1 * unit), height: 12, rx: 2 }));
    return svg;
  }

  function reviewsSection(d) {
    var reviews = d.reviews || [];
    var bySeg = {};
    reviews.forEach(function (r) { bySeg[r.seg] = r.cycles || []; });
    var order = (d.segments || []).map(function (g) { return g.id; });
    reviews.forEach(function (r) { if (order.indexOf(r.seg) < 0) order.push(r.seg); });
    var maxTotal = 1;
    reviews.forEach(function (r) { (r.cycles || []).forEach(function (c) { maxTotal = Math.max(maxTotal, (c.P0 || 0) + (c.P1 || 0)); }); });
    var unit = 120 / Math.max(6, maxTotal);
    var sec = el("section", { cls: "card", "aria-labelledby": "h-review" },
      el("div", { cls: "sec-h" }, ico("i-cycle", "ico-lg"), el("h2", { id: "h-review", text: "리뷰 사이클" }),
        el("span", { cls: "aside" }, el("span", null, el("i", { cls: "sw bad" }), " P0"), el("span", null, el("i", { cls: "sw park" }), " P1"))));
    var body = el("div", { cls: "sec-b" });
    if (!order.length) body.appendChild(el("div", { cls: "empty-line", text: "세그먼트가 없어 리뷰 사이클도 없습니다." }));
    order.forEach(function (seg) {
      var block = el("div", { cls: "seg-block" }, el("h3", { cls: "sub-h", text: "세그먼트 " + seg }));
      var cycles = bySeg[seg] || [];
      if (!cycles.length) {
        block.appendChild(el("div", { cls: "empty-line", text: "아직 리뷰 사이클이 없습니다." }));
      } else {
        var t = el("table", { cls: "tbl" }, el("thead", null, el("tr", null,
          th("사이클", "r"), th("P0", "r"), th("P1", "r"), th("개수", "w"), th("모드"), th("종결"))));
        var tb = el("tbody");
        cycles.forEach(function (c) {
          var p0 = c.P0 || 0, p1 = c.P1 || 0, close = c["리뷰 종결"];
          tb.appendChild(el("tr", null,
            td(c["사이클"] != null ? String(c["사이클"]) : "-", "r num"),
            td(c.P0 != null ? String(c.P0) : "-", "r num" + (p0 > 0 ? " p0-hit" : "")),
            td(c.P1 != null ? String(c.P1) : "-", "r num"),
            el("td", { cls: "w" }, pbar(p0, p1, unit)),
            td(c["모드"] || "-"),
            el("td", null, close == null ? "-" : (close === "통과" ? tag("ok", close, "i-check") : tag("neutral", close)))));
        });
        t.appendChild(tb);
        block.appendChild(el("div", { cls: "rv-tbl" }, t));
      }
      body.appendChild(block);
    });
    sec.appendChild(body);
    return sec;
  }

  function linksSection(d) {
    var links = d.links || {};
    var segIndex = {};
    (d.segments || []).forEach(function (g) { segIndex[g.id] = g; });
    var dl = el("dl", { cls: "links" });
    function row(label, dd) { dl.appendChild(el("dt", { text: label })); dl.appendChild(dd); }
    function pathRow(label, path) { row(label, el("dd", null, path ? copyText(path) : span("sub small", "없음"))); }

    var prs = el("dd");
    (links.prs || []).forEach(function (p) {
      prs.appendChild(p.url ? el("a", { cls: "lnk", href: p.url, text: "#" + p.number }) : el("span", { cls: "num", text: "#" + p.number + " (주소 없음)" }));
      var st = (segIndex[p.seg] || {}).state;
      prs.appendChild(st === "머지됨" ? tag("ok", p.seg + " · 머지", "i-check")
        : tag("neutral", p.seg + " · " + (st === "완료" || st === "park" ? st : "열림")));
    });
    if (!(links.prs || []).length) prs.appendChild(span("sub small", "없음"));
    row("PR", prs);

    var br = el("dd", { cls: "col" });
    (links.branches || []).forEach(function (b) { br.appendChild(copyText(b.branch)); });
    if (!(links.branches || []).length) br.appendChild(span("sub small", "없음"));
    row("브랜치", br);
    pathRow("설계 문서", links.design_doc);
    pathRow("보고서", links.report);

    var rr = el("dd", { cls: "col" });
    var reported = {};
    (links.review_reports || []).forEach(function (r) { reported[r.seg + "#" + r.cycle] = true; rr.appendChild(copyText(r.path)); });
    (d.reviews || []).forEach(function (r) {
      (r.cycles || []).forEach(function (c) {
        if (!reported[r.seg + "#" + c["사이클"]]) rr.appendChild(span("sub small", r.seg + " 사이클 " + (c["사이클"] || "?") + " — 리포트 경로 없음"));
      });
    });
    if (!rr.childNodes.length) rr.appendChild(span("sub small", "없음"));
    row("리뷰 리포트", rr);
    pathRow("원장", links.ledger);
    pathRow("매니페스트", links.manifest);

    return el("section", { cls: "card", "aria-labelledby": "h-links" },
      sectionHead("i-link", "h-links", "링크", "경로는 눌러서 통째로 고를 수 있습니다"),
      el("div", { cls: "sec-b" }, dl));
  }

  function costColumn(title, map, order, total, etcTip) {
    var col = el("div", { cls: "cost-col" }, el("h3", { cls: "sub-h", text: title }));
    var keys = Object.keys(map || {});
    var ordered = [];
    (order || []).forEach(function (k) { if (keys.indexOf(k) >= 0 && ordered.indexOf(k) < 0) ordered.push(k); });
    keys.filter(function (k) { return ordered.indexOf(k) < 0 && k !== "기타"; })
      .sort(function (a, b) { return (map[b] || 0) - (map[a] || 0); })
      .forEach(function (k) { ordered.push(k); });
    if (keys.indexOf("기타") >= 0) ordered.push("기타");
    var max = 0;
    ordered.forEach(function (k) { max = Math.max(max, Math.abs(map[k] || 0)); });
    if (!ordered.length) col.appendChild(el("div", { cls: "empty-line", text: "분해할 비용이 없습니다." }));
    ordered.forEach(function (k) {
      var v = map[k] || 0, etc = k === "기타";
      var svg = sv("svg", { "class": "cbar", viewBox: "0 0 400 12", preserveAspectRatio: "none", "aria-hidden": "true" });
      svg.appendChild(sv("rect", { "class": "cb-bg", width: 400, height: 12, rx: 2 }));
      svg.appendChild(sv("rect", { "class": etc ? "cb-etc" : "cb-v", width: max > 0 ? Math.max(0, Math.round(Math.abs(v) / max * 400)) : 0, height: 12, rx: 2 }));
      col.appendChild(el("div", { cls: "crow" }, span("lab", k, etc ? etcTip : k), svg, span("usd num", usd(v)), span("pct num", pctText(v, total))));
    });
    col.appendChild(el("div", { cls: "crow total" }, span("lab", "합계"), el("span"), span("usd num", usd(total)), span("pct num", total > 0 ? "100%" : "—")));
    return col;
  }

  function costSection(d) {
    var c = d.cost || {};
    var total = c.usd || 0;
    var sec = el("section", { cls: "card", "aria-labelledby": "h-cost" },
      el("div", { cls: "sec-h" }, ico("i-coin", "ico-lg"), el("h2", { id: "h-cost", text: "비용 분해" }),
        el("span", { cls: "aside" }, el("span", { cls: "hint", title: PAIR_TIP }, ico("i-info", "ico-sm"), "짝짓기 한계"))));
    var sum = el("div", { cls: "cost-sum" },
      el("div", null, el("div", { cls: "l", text: "합계" }), el("div", { cls: "v num", text: usd(c.usd) })),
      el("div", null, el("div", { cls: "l", text: "천장" }), el("div", { cls: "v num", text: c.ceiling != null ? usd(c.ceiling) : "없음" })));
    if (c.ceiling != null && c.ratio != null) {
      var p = Math.round(c.ratio * 100);
      sum.appendChild(el("div", { cls: "meterwrap" },
        el("div", { cls: "l num", text: "천장의 " + p + "% · 남은 " + usd(c.ceiling - total) }),
        meter(c.ratio, "천장의 " + p + "%")));
    }
    sum.appendChild(span("sub small", "겹쳐 돈 구간의 비용은 뒤 스테이지로 갈 수 있습니다." +
      (c.unknown ? " 비용 불명 스테이지 " + c.unknown + "개." : "")));
    sec.appendChild(sum);
    var stepOrder = (d.steps || []).map(function (s) { return s.id; });
    sec.appendChild(el("div", { cls: "cost-cols" },
      costColumn("스텝별", c.by_step, stepOrder, total, "어느 스텝에도 묶이지 않은 차액"),
      costColumn("종류별", c.by_kind, null, total, "어느 종류에도 묶이지 않은 차액"),
      costColumn("세그먼트별", c.by_segment, null, total, "어느 세그먼트에도 묶이지 않은 차액 — 런 범위 스테이지 포함")));
    return sec;
  }

  function renderDetail(d) {
    setTz(d.tz_offset_s, null);
    var s = d.summary;
    var now = s.state !== "종단" && s.started_at != null && s.elapsed_s != null
      ? s.started_at + s.elapsed_s : Math.floor(Date.now() / 1000);
    var frag = document.createDocumentFragment();
    frag.appendChild(detailHead(d, now));
    frag.appendChild(waitingSection(d, now));
    frag.appendChild(stepsSection(d, now));
    frag.appendChild(clausesSection(d));
    frag.appendChild(judgmentsSection(d));
    frag.appendChild(el("div", { cls: "pair" }, reviewsSection(d), linksSection(d)));
    frag.appendChild(costSection(d));
    app.replaceChildren(frag);
  }

  // ------------------------------------------------ what survives a redraw

  // Holding the redraw while a selection lives is what keeps the copy chips
  // usable; a selection outside #app is not lost by a redraw and holds nothing.
  function readerBusy() {
    if (Date.now() < selectHeldUntil) return true;
    var s = window.getSelection();
    return !!(s && !s.isCollapsed && (app.contains(s.anchorNode) || app.contains(s.focusNode)));
  }

  function focusKey(n) {
    if (n.tagName === "SUMMARY") return "summary:" + n.parentNode.getAttribute("data-key");
    if (n.tagName === "A") return "link:" + n.getAttribute("href");
    var fk = n.getAttribute("data-fk");
    return fk == null ? null : "control:" + fk;
  }

  // The focused control as its key and its count among controls with that key,
  // since one PR link can appear in several sections of a run's page.
  function focusSpot() {
    var cur = document.activeElement;
    if (!cur || !app.contains(cur)) return null;
    var key = focusKey(cur);
    if (key == null) return null;
    var nth = 0, nodes = app.querySelectorAll(FOCUSABLE);
    for (var i = 0; i < nodes.length && nodes[i] !== cur; i++) {
      if (focusKey(nodes[i]) === key) nth++;
    }
    return { key: key, nth: nth };
  }

  function restoreFocus(spot) {
    if (!spot) return;
    var nodes = app.querySelectorAll(FOCUSABLE), seen = 0;
    for (var i = 0; i < nodes.length; i++) {
      if (focusKey(nodes[i]) !== spot.key) continue;
      if (seen++ === spot.nth) { nodes[i].focus({ preventScroll: true }); return; }
    }
  }

  // Only a turn away from the default is kept, so a day that stops being today
  // or yesterday closes by itself unless the reader opened it.
  function rememberOpen() {
    var dets = app.querySelectorAll("details[data-key]");
    for (var i = 0; i < dets.length; i++) {
      var k = dets[i].getAttribute("data-key");
      if (dets[i].open === dets[i].hasAttribute("data-default-open")) flipped.delete(k);
      else flipped.set(k, dets[i].open);
    }
  }

  function restoreOpen() {
    var dets = app.querySelectorAll("details[data-key]");
    for (var i = 0; i < dets.length; i++) {
      var k = dets[i].getAttribute("data-key");
      if (flipped.has(k)) dets[i].open = flipped.get(k);
    }
  }

  function redraw(paint) {
    var spot = focusSpot();
    rememberOpen();
    paint();
    restoreOpen();
    restoreFocus(spot);
  }

  // ---------------------------------------------------------------- polling

  function route() {
    var m = location.pathname.match(/^\/run\/([^/]+)$/);
    return m ? { run: decodeURIComponent(m[1]) } : { run: null };
  }

  function applyRoute(r) {
    app.className = r.run ? "wrap p-detail" : "wrap p-list";
    document.title = (r.run ? "런 상세 — " + r.run : "런 대시보드") + " — cc-cmds";
    document.body.classList.toggle("on-detail", !!r.run);
    var nav = document.getElementById("band-nav");
    if (nav && r.run && !nav.firstChild) {
      nav.replaceChildren(el("a", { cls: "back", href: "/" }, ico("i-back"), "런 목록"), span("crumb num", r.run));
    }
  }

  function schedule(ms) {
    clearTimeout(timer);
    timer = setTimeout(function () { refresh(true); }, ms);
  }

  function refresh(poll) {
    if (document.hidden) return;
    var r = route();
    applyRoute(r);
    var url = r.run ? "/api/runs/" + encodeURIComponent(r.run) : listURL();
    var period = r.run ? 3000 : 5000;
    if (!app.firstChild) app.replaceChildren(r.run ? loadingDetail() : loadingList());
    checkVersion(poll);
    fetchJSON(url, poll).then(function (res) {
      if (res.offline) {
        setConn(false, !!r.run);
        showOffline(!!r.run);
        schedule(period);
        return;
      }
      setConn(true, !!r.run);
      hideOffline();
      if (res.error) {
        // A passing server error waits behind a live selection like any redraw.
        if (app.getAttribute("data-url") === url && readerBusy()) {
          redrawOwed = true;
          setConn(true, !!r.run, false, true);
        } else {
          lastOk = Date.now();
          redraw(function () { app.replaceChildren(r.run ? detailError(r.run, res.error) : listError(res.error)); });
          app.removeAttribute("data-url");
          redrawOwed = false;
          setFresh(lastOk);
        }
        schedule(period);
        return;
      }
      var d = res.data;
      setTz(d.tz_offset_s, d.tz_label);
      var sameView = app.getAttribute("data-url") === url;
      if (!res.same || !sameView || redrawOwed) {
        if (sameView && readerBusy()) {
          redrawOwed = true;
        } else {
          redraw(function () { if (r.run) renderDetail(d); else renderList(d); });
          app.setAttribute("data-url", url);
          redrawOwed = false;
        }
      }
      if (redrawOwed) {
        setConn(true, !!r.run, false, true);
      } else {
        lastOk = Date.now();
        setFresh(lastOk);
      }
      if (!redrawOwed && r.run && d.summary && d.summary.state === "종단") {
        setConn(true, true, true);
        return;
      }
      schedule(period);
    });
  }

  document.addEventListener("visibilitychange", function () {
    if (document.hidden) clearTimeout(timer); else refresh(true);
  });
  refresh(false);
})();
