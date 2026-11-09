#!/usr/bin/env bash
# review-post.sh — the renderer and the verifier behind `gate.sh act --kind
# review-post`. The gate reads the remote, writes the rows and performs the one
# POST; this file only turns files into bytes and compares bytes, so it reaches
# no network and writes nothing but its own output.
#
#   review-post.sh render --format <문면 파일> --report <리포트> --worktree <워크트리>
#                         --base <베이스 sha> --head <고정 헤드>
#                         --mode 보류|직접 --stance 허용|낮춤 --p0 <n> --p1 <n>
#                         [--current-head <sha>] --out <요청 JSON>
#   review-post.sh render --settle --format <문면 파일> --report <리포트>
#                         --head <리뷰 HEAD> --p0 <n> --p1 <n>
#                         [--event COMMENT|APPROVE|REQUEST_CHANGES] --out <요청 JSON>
#   review-post.sh verify --request <요청 JSON> --review <리뷰 JSON> --comments <코멘트 JSON>
#
# RENDER. The request body of `POST repos/<slug>/pulls/<n>/reviews` is built
# from the format file's named templates and the report's `## 게시 항목`
# section, and from nothing else: the same three inputs give the same bytes.
# An item becomes an inline comment when its file is in the diff
# `<베이스 sha>...<고정 헤드>` of the worktree and its line lies inside a hunk
# of its side (`RIGHT` the new side, `LEFT` the old side); every other item —
# a whole-file finding, a finding about no file, a binary or a deleted file
# without that line, a line outside every hunk — goes into the body through
# the `본문 지적` template. `commit_id` is the pinned head. The event is
# omitted on a `보류` run, so the review stays pending; a `직접` run with
# `낮춤` sends COMMENT, and one with `허용` sends REQUEST_CHANGES when P0+P1 is
# above zero and APPROVE otherwise. When `--current-head` differs from the
# pinned head the `헤드 변경` template opens the body. The settlement mode
# (`--settle`) renders the `정산 본문` template alone, with no comment, and
# sends COMMENT unless `--event` names another.
#
# Stdout of a render is one line, `종류=<event|제안:<event>> 인라인=<n> 본문 지적=<n>`:
# the event sent, or on a `보류` run the one a `직접` run would have sent.
#
# TEMPLATES. A template is the first fenced block under its `## <이름>` head;
# the bytes inside the fence are the template and nothing outside it is read.
# The placeholder set is closed — `{등급}` `{제목}` `{근거}` `{제안}` `{파일}`
# `{줄}` `{P0}` `{P1}` `{고정 헤드}` `{현재 헤드}` `{지적 목록}` — and any
# other `{…}` in any template refuses the render. Substitution is one pass: a
# value is never read again for placeholders, and every byte that is not a
# placeholder stays as written.
#
# VERIFY. The review and its comments as GitHub returns them are compared with
# the request byte for byte: the body, the commit, the state the event implies,
# and the comment set sorted by path, line, side and body — a comment's line is
# its `original_line`, the line in the commit the comment was made on, or its
# `line` only when GitHub left `original_line` empty. The render's lines are
# lines of that commit, while GitHub moves `line` to a newer head or empties it
# once the pull request's head moves. Stdout is
# one word, `일치`, `불일치` or `판독불가` (an input that is not the JSON it
# should be), and the exit status is 0 for all three.
#
# Exit status: 0 done, 2 a refused input (a missing template, an unknown
# placeholder, an item off its grammar, counts that disagree), 1 anything else.
#
# Compatibility: bash 3.2, jq 1.6 or later, POSIX awk.
set -euo pipefail

RP_TEMPLATES='본문
본문 지적 없음
본문 지적
코멘트
헤드 변경
정산 본문'

rp_die() { printf 'review-post: %s\n' "$1" >&2; exit "${2:-2}"; }

rp_template() {
  # rp_template <file> <name> — the bytes of the first fenced block under the
  # `## <name>` head, with no newline added; status 1 when there is none.
  LC_ALL=C awk -v want="## $2" '
    st == 0 && $0 == want { st = 1; next }
    st == 1 && /^## / { exit }
    st == 1 && /^```/ { st = 2; next }
    st == 2 && /^```[ \t]*$/ { st = 3; exit }
    st == 2 { buf = buf (n++ ? "\n" : "") $0 }
    END { if (st != 3) exit 1; printf "%s", buf }' "$1"
}

rp_templates_json() {
  # rp_templates_json <file> — every template as one JSON object, refusing a
  # missing one. The trailing `x` keeps a template's own final blank lines.
  local f="$1" name t obj='{}'
  [ -f "$f" ] && [ -r "$f" ] || rp_die "문면 파일을 읽을 수 없습니다: $f"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    t=$(rp_template "$f" "$name" && printf x) || rp_die "문면 파일에 「## ${name}」 틀이 없습니다: ${f}"
    t=${t%x}
    obj=$(jq -cn --argjson o "$obj" --arg k "$name" --arg v "$t" '$o + {($k): $v}')
  done <<EOF
$RP_TEMPLATES
EOF
  printf '%s' "$obj"
}

RP_JQ_DEFS='
  def allowed: ["등급","제목","근거","제안","파일","줄","P0","P1","고정 헤드","현재 헤드","지적 목록"];
  def unknown($t): [$t | scan("\\{([^{}\n]+)\\}") | .[0]] - allowed | unique;
  def fill($t; $v): $t | gsub("\\{(?<k>[^{}\n]+)\\}"; ($v[.k] // ""));
'

rp_check_placeholders() {
  # rp_check_placeholders <templates json> — refuses any placeholder outside
  # the closed set, naming each.
  local bad
  bad=$(jq -r "$RP_JQ_DEFS"' to_entries[] | . as $e | unknown($e.value)[] | "\($e.key): {\(.)}"' <<<"$1") \
    || rp_die "문면 틀을 읽지 못했습니다" 1
  [ -z "$bad" ] || rp_die "알 수 없는 자리표시자 — $(printf '%s' "$bad" | paste -s -d, -)"
}

rp_items_tsv() {
  # rp_items_tsv <report> — one line per `### G<n>` item of `## 게시 항목`:
  # 등급, 제목, 파일, 줄, 면, 근거, 제안, tab-separated (a tab inside a value
  # becomes a space). An item that lacks one of the seven fields, or a field
  # line off its order, prints `!<n>` in its place.
  LC_ALL=C awk '
    BEGIN { nk = split("등급 제목 파일 줄 면 근거 제안", K, " ") }
    function flush(   i, out) {
      if (!open) return
      if (bad || got != nk) { print "!" id; open = 0; return }
      out = v[1]
      for (i = 2; i <= nk; i++) out = out "\t" v[i]
      print out; open = 0
    }
    /^## / { if (insec) flush(); insec = ($0 == "## 게시 항목"); next }
    !insec { next }
    /^### / { flush(); open = 1; bad = 0; got = 0; id = substr($0, 5); for (i = 1; i <= nk; i++) v[i] = ""; next }
    open && /^- \*\*[^*]+\*\*: / {
      k = $0; sub(/^- \*\*/, "", k); sub(/\*\*: .*$/, "", k)
      val = $0; sub(/^- \*\*[^*]+\*\*: /, "", val); gsub(/\t/, " ", val); sub(/[ \t]+$/, "", val)
      got++
      if (got > nk || K[got] != k) bad = 1; else v[got] = val
      next
    }
    END { if (insec) flush() }' "$1"
}

rp_items_json() {
  # rp_items_json <report> — the items as a JSON array of objects, refusing an
  # item off its grammar.
  local tsv
  tsv=$(rp_items_tsv "$1")
  if printf '%s\n' "$tsv" | grep -q '^!'; then
    rp_die "게시 항목 $(printf '%s\n' "$tsv" | sed -n 's/^!//p' | paste -s -d, -) 이 일곱 필드(등급 제목 파일 줄 면 근거 제안)를 그 순서로 갖추지 않았습니다: $1"
  fi
  printf '%s' "$tsv" | jq -R -s -c '
    split("\n") | map(select(length > 0) | split("\t")
      | {grade: .[0], title: .[1], file: .[2], line: .[3], side: .[4], basis: .[5], suggest: .[6]})'
}

rp_list_lines() {
  # rp_list_lines <report> — the `{지적 목록}` of a settlement: `- <등급>. <제목>`
  # per `## 게시 항목` item when the report has the section, otherwise per
  # column-0 `- **[` item of its P0 and P1 sections, the category tags taken
  # off the line.
  local tsv
  if grep -qx '## 게시 항목' "$1" 2>/dev/null; then
    tsv=$(rp_items_tsv "$1" | grep -v '^!' || true)
    printf '%s\n' "$tsv" | awk -F '\t' 'NF >= 2 { print "- " $1 ". " $2 }'
    return 0
  fi
  LC_ALL=C awk '
    BEGIN { R = "\360\237\224\264"; O = "\360\237\237\240" }
    /^## / { sec = ""; if (index($0, "## " R " P0") == 1) sec = "P0"; else if (index($0, "## " O " P1") == 1) sec = "P1"; next }
    sec != "" && index($0, "- **[") == 1 {
      t = substr($0, 3)
      while (t ~ /^\*\*\[[^]]*\]\*\* */) sub(/^\*\*\[[^]]*\]\*\* */, "", t)
      print "- " sec ". " t
    }' "$1"
}

rp_diff_ranges_json() {
  # rp_diff_ranges_json <worktree> <base> <head> — every hunk range of the
  # diff as `[path, side, first, last]`. The path is the new path, or the old
  # one of a deleted file, which has only a LEFT side. The `---`/`+++` heads
  # are read only before a file's first hunk, so a removed line that begins
  # with `-- ` is not taken for one.
  local out
  out=$( cd "$1" && git -c core.quotePath=false diff --no-color --no-ext-diff -M "$2...$3" ) \
    || rp_die "diff $2...$3 를 읽지 못했습니다 ($1)" 1
  printf '%s\n' "$out" | LC_ALL=C awk '
    function cnt(s,   p) { p = index(s, ","); return p ? substr(s, p + 1) + 0 : 1 }
    function beg(s,   p) { p = index(s, ","); return p ? substr(s, 1, p - 1) + 0 : s + 0 }
    /^diff --git / { hdr = 1; oldp = ""; newp = ""; del = 0; next }
    hdr && /^--- / { p = substr($0, 5); sub(/\t$/, "", p); if (p != "/dev/null") { sub(/^a\//, "", p); oldp = p }; next }
    hdr && /^\+\+\+ / { p = substr($0, 5); sub(/\t$/, "", p); if (p == "/dev/null") del = 1; else { sub(/^b\//, "", p); newp = p }; next }
    /^@@ -[0-9]/ {
      hdr = 0
      split($0, w, " ")
      o = substr(w[2], 2); n = substr(w[3], 2)
      key = del ? oldp : newp
      if (key == "") next
      if (!del && cnt(n) > 0) printf "%s\tRIGHT\t%d\t%d\n", key, beg(n), beg(n) + cnt(n) - 1
      if (cnt(o) > 0) printf "%s\tLEFT\t%d\t%d\n", key, beg(o), beg(o) + cnt(o) - 1
    }' | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | [.[0], .[1], (.[2] | tonumber), (.[3] | tonumber)])'
}

rp_count() {
  case "$1" in ''|*[!0-9]*) rp_die "$2 는 0 이상의 정수입니다 (받은 값: ${1:-없음})" ;; esac
}

rp_render() {
  local fmt="" rep="" wt="" base="" head="" mode="" stance="" p0="" p1="" cur="" out="" settle=0 event=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --format) fmt="${2:-}"; shift 2 ;;
      --report) rep="${2:-}"; shift 2 ;;
      --worktree) wt="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      --head) head="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --stance) stance="${2:-}"; shift 2 ;;
      --p0) p0="${2:-}"; shift 2 ;;
      --p1) p1="${2:-}"; shift 2 ;;
      --current-head) cur="${2:-}"; shift 2 ;;
      --event) event="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      --settle) settle=1; shift ;;
      *) rp_die "render 가 모르는 인자입니다: $1" ;;
    esac
  done
  [ -n "$fmt" ] && [ -n "$rep" ] && [ -n "$head" ] && [ -n "$out" ] || rp_die "render 에는 --format --report --head --out 이 필요합니다"
  rp_count "$p0" --p0; rp_count "$p1" --p1
  [ -f "$rep" ] && [ -r "$rep" ] || rp_die "리포트를 읽을 수 없습니다: $rep"
  local tpl
  tpl=$(rp_templates_json "$fmt")
  rp_check_placeholders "$tpl"
  if [ "$settle" = "1" ]; then
    case "${event:-COMMENT}" in COMMENT|APPROVE|REQUEST_CHANGES) ;; *) rp_die "--event 는 COMMENT·APPROVE·REQUEST_CHANGES 중 하나입니다 (받은 값: $event)" ;; esac
    local list
    list=$(rp_list_lines "$rep")
    jq -n -c "$RP_JQ_DEFS"'
      {commit_id: $head,
       body: fill($tpl["정산 본문"]; {"고정 헤드": $head, "P0": $p0, "P1": $p1, "지적 목록": $list}),
       event: $event, comments: []}' \
      --argjson tpl "$tpl" --arg head "$head" --arg p0 "$p0" --arg p1 "$p1" \
      --arg list "$list" --arg event "${event:-COMMENT}" > "$out" || rp_die "정산 본문을 만들지 못했습니다" 1
    printf '종류=%s 인라인=0 본문 지적=0\n' "${event:-COMMENT}"
    return 0
  fi
  [ -n "$wt" ] && [ -n "$base" ] || rp_die "render 에는 --worktree 와 --base 가 필요합니다"
  case "$mode" in 보류|직접) ;; *) rp_die "--mode 는 보류 또는 직접입니다 (받은 값: ${mode:-없음})" ;; esac
  case "$stance" in 허용|낮춤) ;; *) rp_die "--stance 는 허용 또는 낮춤입니다 (받은 값: ${stance:-없음})" ;; esac
  local items ranges bad
  items=$(rp_items_json "$rep")
  bad=$(jq -r --arg p0 "$p0" --arg p1 "$p1" '
    (map(select(.grade == "P0")) | length) as $a | (map(select(.grade == "P1")) | length) as $b
    | [ (.[] | select(.grade != "P0" and .grade != "P1") | "등급 \(.grade)"),
        (.[] | select(.side != "RIGHT" and .side != "LEFT") | "면 \(.side)"),
        (.[] | select(.line != "없음" and (.line | test("^[1-9][0-9]*$") | not)) | "줄 \(.line)"),
        (if $a != ($p0 | tonumber) or $b != ($p1 | tonumber) then "등급 수 P0 \($a)·P1 \($b) 가 리뷰의 P0 \($p0)·P1 \($p1) 과 다름" else empty end)
      ] | join(", ")' <<<"$items") || rp_die "게시 항목을 읽지 못했습니다" 1
  [ -z "$bad" ] || rp_die "게시 항목이 문법에 맞지 않습니다 — $bad"
  ranges=$(rp_diff_ranges_json "$wt" "$base" "$head")
  jq -n -c "$RP_JQ_DEFS"'
    def inl($it): $it.file != "없음" and $it.line != "없음"
      and any($ranges[]; .[0] == $it.file and .[1] == $it.side
                         and .[2] <= ($it.line | tonumber) and ($it.line | tonumber) <= .[3]);
    def ev: if $stance == "낮춤" then "COMMENT"
            elif (($p0 | tonumber) + ($p1 | tonumber)) > 0 then "REQUEST_CHANGES" else "APPROVE" end;
    def vals($g; $it): $g + {"등급": $it.grade, "제목": $it.title, "근거": $it.basis, "제안": $it.suggest,
                             "파일": $it.file, "줄": $it.line};
    {"고정 헤드": $head, "현재 헤드": $cur, "P0": $p0, "P1": $p1} as $g
    | ($items | map(select(inl(.)))) as $in
    | ($items | map(select(inl(.) | not))) as $out
    | ([ (if $cur != "" and $cur != $head then fill($tpl["헤드 변경"]; $g) else empty end),
         (if (($p0 | tonumber) + ($p1 | tonumber)) > 0 then fill($tpl["본문"]; $g) else fill($tpl["본문 지적 없음"]; $g) end) ]
       + ($out | map(fill($tpl["본문 지적"]; vals($g; .))))) as $parts
    | {commit_id: $head, body: ($parts | join("\n\n")),
       comments: ($in | map({path: .file, line: (.line | tonumber), side: .side, body: fill($tpl["코멘트"]; vals($g; .))}))}
      + (if $mode == "직접" then {event: ev} else {} end)
    | . as $req
    | {req: $req, kind: (if $mode == "직접" then ev else "제안:" + ev end), inline: ($in | length), body: ($out | length)}' \
    --argjson tpl "$tpl" --argjson items "$items" --argjson ranges "$ranges" \
    --arg head "$head" --arg cur "$cur" --arg p0 "$p0" --arg p1 "$p1" \
    --arg mode "$mode" --arg stance "$stance" > "$out.all" || { rm -f "$out.all"; rp_die "리뷰 요청을 만들지 못했습니다" 1; }
  jq -c '.req' "$out.all" > "$out"
  jq -r '"종류=\(.kind) 인라인=\(.inline) 본문 지적=\(.body)"' "$out.all"
  rm -f "$out.all"
}

rp_verify() {
  local req="" rev="" com=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --request) req="${2:-}"; shift 2 ;;
      --review) rev="${2:-}"; shift 2 ;;
      --comments) com="${2:-}"; shift 2 ;;
      *) rp_die "verify 가 모르는 인자입니다: $1" ;;
    esac
  done
  [ -n "$req" ] && [ -n "$rev" ] && [ -n "$com" ] || rp_die "verify 에는 --request --review --comments 가 필요합니다"
  local v
  v=$(jq -n -r --slurpfile q "$req" --slurpfile r "$rev" --slurpfile c "$com" '
    def norm: map({path: .path, line: (.original_line // .line), side: .side, body: .body})
              | sort_by(.path, .line, .side, .body);
    def state($e): {"COMMENT": "COMMENTED", "APPROVE": "APPROVED", "REQUEST_CHANGES": "CHANGES_REQUESTED"}[$e] // "PENDING";
    if ($q | length) != 1 or ($r | length) != 1 or ($c | length) != 1
       or ($r[0] | type) != "object" or ($c[0] | type) != "array" then "판독불가"
    else $q[0] as $q | $r[0] as $r | $c[0] as $c
      | if $r.body == $q.body and $r.commit_id == $q.commit_id and $r.state == state($q.event // "")
           and ($c | norm) == ($q.comments | norm) then "일치" else "불일치" end
    end' 2>/dev/null) || v="판독불가"
  printf '%s\n' "${v:-판독불가}"
}

case "${1:-}" in
  render) shift; rp_render "$@" ;;
  verify) shift; rp_verify "$@" ;;
  *) rp_die "사용법: review-post.sh render|verify …" ;;
esac
