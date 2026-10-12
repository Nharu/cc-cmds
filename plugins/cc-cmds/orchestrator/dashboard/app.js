// app.js — the dashboard screen. No build, no third-party code.
//
// Every value shown comes from a run's ledger or manifest, so nothing is ever
// written through innerHTML: text goes in as text nodes and SVG is built
// element by element.
//
// Polling: the list every 5 s, a run's detail every 3 s, each with ETag. Timer
// polls carry `X-CC-Poll: 1` so a forgotten tab cannot keep the server alive.
// A hidden tab polls nothing, and a run that reached 종단 is not polled again.
"use strict";

(function () {
  var SVGNS = "http://www.w3.org/2000/svg";
  var app = document.getElementById("app");
  var offline = document.getElementById("offline");
  var etags = {};
  var cache = {};
  var timer = null;
  var serverVersion = null;
  var view = { days: "3", base: "", dead: false };

  function el(tag, attrs) {
    var n = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
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

  function sv(tag, attrs, text) {
    var n = document.createElementNS(SVGNS, tag);
    Object.keys(attrs || {}).forEach(function (k) { n.setAttribute(k, attrs[k]); });
    if (text != null) n.textContent = text;
    return n;
  }

  function fetchJSON(url, poll) {
    var headers = {};
    if (poll) headers["X-CC-Poll"] = "1";
    if (etags[url]) headers["If-None-Match"] = etags[url];
    return fetch(url, { headers: headers, cache: "no-store" }).then(function (r) {
      offline.hidden = true;
      if (r.status === 304) return { same: true, data: cache[url] };
      if (!r.ok) return { error: r.status };
      etags[url] = r.headers.get("ETag");
      return r.json().then(function (d) { cache[url] = d; return { same: false, data: d }; });
    }, function () {
      offline.hidden = false;
      return { offline: true };
    });
  }

  function checkVersion(poll) {
    return fetch("/healthz", { headers: poll ? { "X-CC-Poll": "1" } : {}, cache: "no-store" })
      .then(function (r) { return r.json(); })
      .then(function (h) {
        if (serverVersion && h.version !== serverVersion) location.reload();
        serverVersion = h.version;
        document.getElementById("version").textContent = "v" + h.version;
      }, function () { offline.hidden = false; });
  }

  function ago(epoch) {
    if (epoch == null) return "기록 없음";
    var s = Math.max(0, Math.floor(Date.now() / 1000 - epoch));
    if (s < 60) return s + "초 전";
    if (s < 3600) return Math.floor(s / 60) + "분 전";
    if (s < 86400) return Math.floor(s / 3600) + "시간 전";
    return Math.floor(s / 86400) + "일 전";
  }

  function age(sec) {
    if (sec == null) return "기록 없음";
    return ago(Date.now() / 1000 - sec);
  }

  function clock(epoch) {
    if (epoch == null) return "미상";
    var d = new Date(epoch * 1000);
    return d.toLocaleString("ko-KR", { hour12: false });
  }

  function usd(v) { return v == null ? "비용 불명" : v.toFixed(2) + " USD"; }

  function stateBadge(r) {
    return el("span", { cls: "state s-" + r.state, text: r.state });
  }

  function repoName(base) {
    if (!base) return "매니페스트 없음";
    var p = base.split("/");
    return p[p.length - 1] || base;
  }

  function copyButton(text) {
    return el("button", { cls: "copy", text: "복사", onclick: function () {
      if (navigator.clipboard) navigator.clipboard.writeText(text);
    } });
  }

  // ------------------------------------------------------------------ list

  function listURL() {
    return "/api/runs?days=" + view.days + "&base=" + encodeURIComponent(view.base) + "&dead=" + (view.dead ? 1 : 0);
  }

  function runRow(r) {
    var seg = r.seg;
    return el("tr", null,
      el("td", null, el("a", { href: "/run/" + encodeURIComponent(r.id), cls: "mono", text: r.id })),
      el("td", { text: repoName(r.base) }),
      el("td", null, stateBadge(r), (r.notes || []).length ? el("span", { cls: "note", text: r.notes.join(" · ") }) : null),
      el("td", { text: "머지 " + seg.merged + " · 완료 " + seg.done + " · park " + seg.park + " · 열림 " + seg.open }),
      el("td", { text: usd(r.cost_usd) }),
      el("td", { text: ago(r.last_growth) }));
  }

  function table(rows) {
    if (!rows.length) return el("div", { cls: "empty", text: "없음" });
    var t = el("table", null, el("tr", null,
      el("th", { text: "런" }), el("th", { text: "레포" }), el("th", { text: "상태" }),
      el("th", { text: "세그먼트" }), el("th", { text: "누적 비용" }), el("th", { text: "마지막 성장" })));
    rows.forEach(function (r) { t.appendChild(runRow(r)); });
    return t;
  }

  function dayKey(epoch) {
    if (epoch == null) return "시각 미상";
    var d = new Date(epoch * 1000);
    return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
  }

  function renderList(d) {
    var live = d.runs.filter(function (r) { return r.band === "live"; });
    var recent = d.runs.filter(function (r) { return r.band === "recent"; });
    var older = d.runs.filter(function (r) { return r.band === "older"; });
    var frag = document.createDocumentFragment();
    frag.appendChild(el("h2", { text: "살아 있는 런 (" + live.length + ")" }));
    frag.appendChild(table(live));
    frag.appendChild(el("h2", { text: "최근 3일 안에 끝난 런 (" + recent.length + ")" }));
    var groups = {};
    recent.forEach(function (r) { var k = dayKey(r.ended_at); (groups[k] = groups[k] || []).push(r); });
    var keys = Object.keys(groups).sort().reverse();
    if (!keys.length) frag.appendChild(el("div", { cls: "empty", text: "없음" }));
    keys.forEach(function (k) { frag.appendChild(el("h3", { text: k })); frag.appendChild(table(groups[k])); });

    var filters = el("div", { cls: "filters" }, el("span", { cls: "muted", text: "기간" }));
    [["3", "3일"], ["7", "7일"], ["30", "30일"], ["all", "전체"]].forEach(function (p) {
      filters.appendChild(el("button", { cls: view.days === p[0] ? "on" : "", text: p[1], onclick: function () { view.days = p[0]; refresh(false); } }));
    });
    var sel = el("select", { onchange: function (e) { view.base = e.target.value; refresh(false); } }, el("option", { value: "", text: "모든 레포" }));
    (d.bases || []).forEach(function (b) {
      var o = el("option", { value: b, text: repoName(b) + " — " + b });
      if (b === view.base) o.selected = true;
      sel.appendChild(o);
    });
    filters.appendChild(sel);
    filters.appendChild(el("button", { cls: view.dead ? "on" : "", text: (view.dead ? "숨기기" : "보이기") + " — 숨긴 껍데기 " + d.hidden + "개",
      onclick: function () { view.dead = !view.dead; refresh(false); } }));
    frag.appendChild(el("h2", { text: "그 밖의 런 (" + older.length + ")" }));
    frag.appendChild(filters);
    frag.appendChild(table(older));
    app.replaceChildren(frag);
  }

  // ---------------------------------------------------------------- detail

  var STATE_COLOR = { "머지됨": "#2e8b57", "완료": "#6e6e73", "park": "#b26b00" };

  function segColor(st) { return STATE_COLOR[st] || "#1f7ae0"; }

  function stepOf(segId, steps) {
    var best = null;
    steps.forEach(function (s) {
      if (segId.indexOf(s.id) === 0 && (!best || s.id.length > best.id.length)) best = s;
    });
    return best;
  }

  function graph(d) {
    var steps = (d.manifest && d.manifest.steps) || [];
    if (!steps.length) return el("div", { cls: "empty", text: "매니페스트 없음 — 단계 그래프를 그릴 수 없습니다" });
    var depth = {};
    function dep(s, seen) {
      if (depth[s.id] != null) return depth[s.id];
      if (seen[s.id]) return 0;
      seen[s.id] = true;
      var m = 0;
      (s.depends_on || []).forEach(function (p) {
        var ps = steps.filter(function (x) { return x.id === p; })[0];
        if (ps) m = Math.max(m, dep(ps, seen) + 1);
      });
      return (depth[s.id] = m);
    }
    steps.forEach(function (s) { dep(s, {}); });
    var cols = {};
    steps.forEach(function (s) { (cols[depth[s.id]] = cols[depth[s.id]] || []).push(s); });
    var segsBy = {};
    d.segments.forEach(function (g) { var s = stepOf(g.id, steps); var k = s ? s.id : ""; (segsBy[k] = segsBy[k] || []).push(g); });
    var W = 170, H = 34, pos = {}, maxY = 0;
    Object.keys(cols).forEach(function (c) {
      var y = 10;
      cols[c].forEach(function (s) {
        pos[s.id] = { x: 10 + c * (W + 40), y: y };
        y += H + 8 + ((segsBy[s.id] || []).length) * 22 + 10;
      });
      maxY = Math.max(maxY, y);
    });
    var width = 20 + Object.keys(cols).length * (W + 40);
    var svg = sv("svg", { width: width, height: maxY + 10, viewBox: "0 0 " + width + " " + (maxY + 10) });
    steps.forEach(function (s) {
      (s.depends_on || []).forEach(function (p) {
        if (!pos[p]) return;
        svg.appendChild(sv("line", { x1: pos[p].x + W, y1: pos[p].y + H / 2, x2: pos[s.id].x, y2: pos[s.id].y + H / 2, class: "axis" }));
      });
    });
    steps.forEach(function (s) {
      var p = pos[s.id];
      svg.appendChild(sv("rect", { x: p.x, y: p.y, width: W, height: H, rx: 6, fill: "none", stroke: "#888" }));
      svg.appendChild(sv("text", { x: p.x + 8, y: p.y + 14 }, s.id + " · " + s.skill));
      (segsBy[s.id] || []).forEach(function (g, i) {
        var y = p.y + H + 6 + i * 22;
        svg.appendChild(sv("rect", { x: p.x + 12, y: y, width: W - 12, height: 18, rx: 4, fill: segColor(g.state), opacity: 0.85 }));
        var t = sv("text", { x: p.x + 18, y: y + 13, fill: "#fff" }, g.id + " — " + (g.state || "미상"));
        t.setAttribute("fill", "#fff");
        svg.appendChild(t);
      });
    });
    return svg;
  }

  function clauses(d) {
    var box = el("div");
    if (!d.clauses.length) box.appendChild(el("div", { cls: "empty", text: "종료 절 없음" }));
    else {
      var t = el("table", null, el("tr", null, el("th", { text: "절" }), el("th", { text: "문면" }), el("th", { text: "판정" })));
      d.clauses.forEach(function (c) { t.appendChild(el("tr", null, el("td", { cls: "mono", text: c.id }), el("td", { text: c.text }), el("td", { text: c.state }))); });
      box.appendChild(t);
    }
    var dv = d.derived;
    box.appendChild(el("h3", { text: "대시보드 유도 미충족 사유" }));
    box.appendChild(el("div", { text: "비종단 세그먼트 " + dv.nonterminal_segments.length + "개" + (dv.nonterminal_segments.length ? " (" + dv.nonterminal_segments.join(", ") + ")" : "") +
      " · 열린 승인 " + dv.open_approvals + "건 · 풀리지 않은 런 범위 막힘 " + dv.unresolved_blocks + "건" }));
    box.appendChild(el("div", { cls: "muted", text: "게이트 내부의 종료 조건 판정은 이 화면에 보이지 않습니다." }));
    if (d.done_text) box.appendChild(el("div", null, el("h3", { text: "done" }), el("code", { text: d.done_text }), " ", copyButton(d.done_text)));
    return box;
  }

  function gantt(d) {
    var rows = d.timeline;
    if (!rows.length) return el("div", { cls: "empty", text: "스테이지 기록 없음" });
    var times = [];
    rows.forEach(function (t) { if (t.start != null) times.push(t.start); if (t.end != null) times.push(t.end); });
    d.shifts.forEach(function (s) { if (s.at != null) times.push(s.at); });
    if (d.run_start != null) times.push(d.run_start);
    var t0 = Math.min.apply(null, times.length ? times : [0]);
    var t1 = Math.max.apply(null, times.length ? times : [1]);
    if (t1 <= t0) t1 = t0 + 60;
    var L = 150, W = 900, RH = 22, top = 24;
    var x = function (t) { return L + (t - t0) / (t1 - t0) * W; };
    var height = top + rows.length * RH + 30;
    var svg = sv("svg", { width: L + W + 140, height: height, viewBox: "0 0 " + (L + W + 140) + " " + height });
    svg.appendChild(sv("text", { x: L, y: 14 }, clock(t0)));
    svg.appendChild(sv("text", { x: L + W - 120, y: 14 }, clock(t1)));
    d.shifts.forEach(function (s) {
      if (s.at == null) return;
      svg.appendChild(sv("line", { x1: x(s.at), y1: top - 6, x2: x(s.at), y2: height - 20, class: "shift" }));
      svg.appendChild(sv("text", { x: x(s.at) + 3, y: height - 6 }, "교대 " + (s.ordinal || "") + " · " + (s.reason || "")));
    });
    var cycles = {};
    d.segments.forEach(function (g) { cycles[g.id] = g.cycles; });
    rows.forEach(function (t, i) {
      var y = top + i * RH;
      svg.appendChild(sv("text", { x: 4, y: y + 14 }, (t.stage || "?") + " #" + (t.attempt || "?") + " " + (t.kind || "")));
      var label = t["class"] || "";
      var ox = L + W + 6;
      if (t.start != null && t.end != null) {
        svg.appendChild(sv("rect", { x: x(t.start), y: y + 4, width: Math.max(2, x(t.end) - x(t.start)), height: RH - 8, rx: 3,
          fill: t.rc === 0 ? "#2e8b57" : "#c0392b", opacity: t.start_src === "sup" ? 0.9 : 0.5 }));
        if (t.start_src === "err" || t.start_src === "duration") label += " · 추정";
        ox = Math.min(L + W + 6, x(t.end) + 4);
      } else if (t.duration_s != null) {
        svg.appendChild(sv("rect", { x: L, y: y + 4, width: Math.max(2, t.duration_s / (t1 - t0) * W), height: RH - 8, rx: 3, fill: "#888", opacity: 0.4 }));
        label += " · 소요만";
      } else {
        label += " · 시작 " + (t.start != null ? clock(t.start) : "기록 없음") + " · 끝 " + (t.end != null ? clock(t.end) : "미상");
      }
      (t.reattach || []).forEach(function (r) {
        svg.appendChild(sv("line", { x1: x(r), y1: y + 2, x2: x(r), y2: y + RH - 2, class: "tick" }));
      });
      label += " · " + usd(t.usd);
      svg.appendChild(sv("text", { x: ox, y: y + 14 }, label));
    });
    var box = el("div", null, svg);
    if (!d.has_sup) box.appendChild(el("div", { cls: "muted", text: "재부착 기록 없음 — 이 런에는 sup.log 가 없습니다." }));
    var cyc = [];
    d.segments.forEach(function (g) {
      (g.cycles || []).forEach(function (c) { cyc.push(g.id + " 사이클 " + c.cycle + ": P0 " + c.p0 + " · P1 " + c.p1 + (c.mode ? " · " + c.mode : "")); });
    });
    if (cyc.length) {
      box.appendChild(el("h3", { text: "리뷰 사이클" }));
      cyc.forEach(function (s) { box.appendChild(el("div", { text: s })); });
    }
    return box;
  }

  function tiles(d) {
    var c = d.cost, h = d.heartbeat;
    var costLine = usd(c.usd) + (c.ceiling != null ? " / 천장 " + c.ceiling + " USD" : "") + (c.ratio != null ? " (" + Math.round(c.ratio * 100) + "%)" : "");
    return el("div", { cls: "tiles" },
      el("div", { cls: "tile" }, el("div", { cls: "muted", text: "누적 비용" }), el("div", { cls: "big", text: costLine }),
        el("div", { cls: "muted", text: "비용 불명 스테이지 " + c.unknown + "개 · 외부 종료 " + c.external_end + "개" })),
      el("div", { cls: "tile" }, el("div", { cls: "muted", text: "감시기 하트비트" }), el("div", { cls: "big", text: age(h.watch_age_s) }),
        el("div", { cls: "muted", text: "원장 마지막 성장 " + ago(h.last_growth) + " · 진행 채널 " + age(h.feed_age_s) })),
      el("div", { cls: "tile" }, el("div", { cls: "muted", text: "살아 있는 스테이지" }), el("div", { cls: "big", text: String(h.live_stages.length) }),
        el("div", { cls: "muted", text: h.live_stages.join(", ") || "없음" })));
  }

  function renderDetail(d) {
    var s = d.summary;
    var m = d.manifest;
    var frag = document.createDocumentFragment();
    frag.appendChild(el("h2", null, el("span", { cls: "mono", text: s.id }), " ", stateBadge(s),
      (s.notes || []).length ? el("span", { cls: "note", text: s.notes.join(" · ") }) : null));
    frag.appendChild(el("div", { cls: "muted", text: "레포 " + repoName(s.base) + " · 목표 " + ((m && m.goal) || "매니페스트 없음") +
      (m && m.deadline ? " · 마감 " + m.deadline : "") + " · 런 시작 " + clock(d.run_start) }));
    if (s.run_dir) frag.appendChild(el("div", { cls: "muted" }, el("code", { text: s.run_dir }), " ", copyButton(s.run_dir)));
    frag.appendChild(tiles(d));
    frag.appendChild(el("div", { cls: "split" },
      el("div", null, el("h2", { text: "단계 그래프" }), graph(d)),
      el("div", null, el("h2", { text: "종료 절" }), clauses(d))));
    frag.appendChild(el("h2", { text: "스테이지 타임라인" }));
    frag.appendChild(gantt(d));
    app.replaceChildren(frag);
  }

  // ---------------------------------------------------------------- polling

  function route() {
    var m = location.pathname.match(/^\/run\/([^/]+)$/);
    return m ? { run: decodeURIComponent(m[1]) } : { run: null };
  }

  function schedule(ms) {
    clearTimeout(timer);
    timer = setTimeout(function () { refresh(true); }, ms);
  }

  function refresh(poll) {
    if (document.hidden) return;
    var r = route();
    var url = r.run ? "/api/runs/" + encodeURIComponent(r.run) : listURL();
    checkVersion(poll);
    fetchJSON(url, poll).then(function (res) {
      document.getElementById("fresh").textContent = "갱신 " + new Date().toLocaleTimeString("ko-KR", { hour12: false });
      if (res.offline) { schedule(r.run ? 3000 : 5000); return; }
      if (res.error) {
        app.replaceChildren(el("div", { cls: "empty", text: r.run ? "그런 런이 없습니다 (" + res.error + ")" : "목록을 읽지 못했습니다 (" + res.error + ")" }));
        return;
      }
      if (!res.same || !app.firstChild) {
        if (r.run) renderDetail(res.data); else renderList(res.data);
      }
      if (r.run && res.data && res.data.summary.state === "종단") return;
      schedule(r.run ? 3000 : 5000);
    });
  }

  document.addEventListener("visibilitychange", function () {
    if (document.hidden) clearTimeout(timer); else refresh(true);
  });
  refresh(false);
})();
