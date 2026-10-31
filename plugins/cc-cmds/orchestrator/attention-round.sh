#!/usr/bin/env bash
# attention-round.sh — the deterministic half of the run-end attention seat.
#
# WHAT THIS FILE IS. After a run ends, a separate model seat re-reads the run's
# decision ledger, its stop records and the prose its stages wrote, and points
# the morning reader at the places worth a second look. The gate owns the
# round — the record, the lock, the call, the ledger row and the cost — and
# sources this file for everything that must come out the same whoever asks:
# where the round's files live, which ledger row ends a run, what the seat is
# shown, how its answer is checked and written down, and what the morning
# report prints for a run.
#
# NOT `attention.sh`. That file beside this one is the attention-event spool
# library a remote relay reads, under `<state root>/attention`, an opt-in root
# nobody creates. Nothing here reads, writes or creates that directory: every
# path below is under `<state root>/attention-round`.
#
# THE REPORT READER NEVER CALLS THE GATE. `bash attention-round.sh report
# <ledger> <run-id>` reads the result file, the round record and the ledger's
# end token, and prints one of six fixed outputs. Entering the gate rewrites a
# run's reap clock, so the morning report reads these files directly — which
# is why the path rule and the end-token selector live here and the gate calls
# them, rather than the other way round.
#
# Compatibility: bash 3.2, and safe to source under `set -euo pipefail`: no
# top-level `readonly`, no command at top level that can fail, and the entry
# point runs only when this file is executed rather than sourced.

attention_schema() { printf '%s' 'cc-attention-run v1'; }
attention_result_marker() { printf '%s' '<!-- cc-run-attention v1 -->'; }

# Input budget, in bytes. The whole input stays at or under the total, which
# is the judgment-call input cap the rekick branch judgment already uses; the
# prompt file and the separator line `judgment_call` adds are outside it, and
# the prompt's own cap keeps the one `-p` argument under 131072.
attention_input_max() { printf '%s' 112000; }
attention_ledger_max() { printf '%s' 55000; }
attention_halt_max() { printf '%s' 16000; }
attention_transcript_max() { printf '%s' 40000; }
attention_scope_max() { printf '%s' 1000; }

attention_root() {
  printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/attention-round"
}

attention_safe_name() {
  # attention_safe_name <run-id> — the one name the record, the output file and
  # the result file are all called by. An id made only of `[A-Za-z0-9._-]` is
  # used as it is; any other id — empty, `.`, `..`, or carrying anything else,
  # newlines included — is stored under the first 16 hex of its sha256. The
  # check deletes the allowed bytes and wants nothing left; the trailing `x`
  # keeps a final newline from being stripped out of sight.
  local id="$1"
  if [ -n "$id" ] && [ "$id" != "." ] && [ "$id" != ".." ] \
     && [ "$(printf '%s' "$id" | LC_ALL=C tr -d 'A-Za-z0-9._-'; printf x)" = x ]; then
    printf '%s' "$id"
  else
    printf '%s' "$id" | shasum -a 256 | cut -c1-16
  fi
}

attention_record_path() { printf '%s' "$(attention_root)/runs/$(attention_safe_name "$1").json"; }
attention_out_path() { printf '%s' "$(attention_root)/out/$(attention_safe_name "$1").json"; }
attention_lockdir() { printf '%s' "$(attention_root)/lock"; }
attention_stamp() { printf '%s' "$(attention_root)/stamp"; }

attention_result_path() {
  # attention_result_path <ledger> <run-id> — beside the ledger, so it lives as
  # long as the ledger does and outlives the run directory.
  printf '%s' "$(dirname "$1")/$(attention_safe_name "$2").attention.md"
}

attention_end_token_row() {
  # attention_end_token_row <ledger> — print the row that ends the run, or
  # print nothing and return 1. The earliest of these wins: a `자율 승인` row
  # with `결정=종료`, or a run-scope `blocked` row carrying a `재킥 원인` that is
  # not `대상미선언` or `슬라이싱` — those two park a slice and the run goes on.
  #
  # ONE SELECTOR FOR EVERY READER. The gate reads its own run's end token
  # through this, the round reads another run's through this, and the morning
  # report reads it through this; a second copy would be free to pick a
  # different row.
  [ -n "${1:-}" ] && [ -f "$1" ] || return 1
  awk '
    (index($0, "- `자율 승인` | ") == 1 && index($0, " | 결정=종료 | ") > 0) ||
    (index($0, "- `blocked` | ") == 1 && index($0, " | 스코프=run | ") > 0) {
      blk = (index($0, "- `blocked` | ") == 1)
      n = split($0, f, / \| /)
      for (i = 2; i <= n; i++) {
        if (index(f[i], "재킥 원인=") == 1) {
          v = f[i]; sub(/^재킥 원인=/, "", v)
          if (blk && (v == "대상미선언" || v == "슬라이싱")) break
          print; found = 1; exit
        }
      }
    }
    END { exit found ? 0 : 1 }' "$1" 2>/dev/null
}

attention_clip() {
  # attention_clip <max-bytes> — stdin to stdout, at most that many bytes, cut
  # on a UTF-8 character boundary and without a trailing newline. Lines are
  # kept; a cut lands inside the line that crosses the budget. Under
  # `LC_ALL=C`, `length` and `substr` count bytes, and a trailing partial
  # sequence is dropped by reading the last lead byte's announced length.
  LC_ALL=C awk -v n="$1" '
    function trim(t,   m, i, c, k) {
      m = length(t)
      for (i = 0; i < 4 && m - i >= 1; i++) {
        c = substr(t, m - i, 1)
        if (c < "\200") break
        if (c >= "\300") {
          k = (c < "\340") ? 2 : ((c < "\360") ? 3 : 4)
          if (i + 1 != k) t = substr(t, 1, m - i - 1)
          break
        }
      }
      return t
    }
    stop { next }
    {
      sep = (NR > 1) ? 1 : 0
      if (used + sep + length($0) <= n) {
        printf "%s%s", (sep ? "\n" : ""), $0; used += sep + length($0); next
      }
      room = n - used - sep
      if (room > 0) printf "%s%s", (sep ? "\n" : ""), trim(substr($0, 1, room))
      stop = 1
    }'
}

attention_bytes() { LC_ALL=C wc -c < "$1" | tr -d ' '; }

attention_ledger_rows() {
  # attention_ledger_rows <ledger> — the ledger rows the seat may read, one per
  # line as `<priority>\t<order>\t<line>\t<row>`, unsorted. Priorities:
  #   1 an automatic `중단 답` (answered by the seat or the shift, or the older
  #     `자동 채택(구속-이탈) — ` prefix with no `답한 주체`);
  #   2 `리뷰 기각`;
  #   3 a `자율 승인` that is not an exec row, higher `등급` first — the two
  #     kinds another run's round writes into this ledger (`halt-report`,
  #     `metrics-filing`) are left out;
  #   4 an exec row the morning report's reach audit selects;
  #   5 `cycle`;
  #   6 `stage-result`, cut down to its segment, kind, exit code and end class.
  # An exec row the audit does not select is printed as `X\t0\t<line>\t` so the
  # caller can count it.
  #
  # THE REACH AUDIT SELECTOR IS THE REPORT'S RULE, WORD FOR WORD: an exec row
  # whose `도달` is `dev`, `prod`, `배포트리거` or `협업` — read from the reach in
  # its `행 값=<표면>/<도달>` when it carries one —, every row whose `등급 출처`
  # is `불투명` or `미상`, every row carrying a `표지`, every `dev` row whose
  # `식별자 대조` is `미선언` or `대조불가`, and every read whose `도달` is `prod`.
  awk '
    function fv(name,   i, p) {
      p = name "="
      for (i = 2; i <= nf; i++) if (index(F[i], p) == 1) return substr(F[i], length(p) + 1)
      return ""
    }
    function has(name,   i, p) {
      p = name "="
      for (i = 2; i <= nf; i++) if (index(F[i], p) == 1) return 1
      return 0
    }
    /^- `/ {
      nf = split($0, F, / \| /)
      k = F[1]; sub(/^- `/, "", k); sub(/`$/, "", k)
      if (k == "중단 답") {
        who = fv("답한 주체")
        if (who == "좌석" || who == "교대" || (!has("답한 주체") && index(fv("근거"), "자동 채택(구속-이탈) — ") == 1))
          printf "1\t0\t%d\t%s\n", NR, $0
        next
      }
      if (k == "리뷰 기각") { printf "2\t0\t%d\t%s\n", NR, $0; next }
      if (k == "자율 승인") {
        if (fv("결정") != "exec") {
          kd = fv("kind")
          if (kd == "halt-report" || kd == "metrics-filing") next
          g = fv("등급"); if (g !~ /^[0-9]+$/) g = 0
          printf "3\t%d\t%d\t%s\n", 9 - g, NR, $0
          next
        }
        r = fv("도달"); hv = fv("행 값")
        if (hv != "" && index(hv, "/") > 0) { r = hv; sub(/^.*\//, "", r) }
        src = fv("등급 출처"); mark = fv("표지"); idc = fv("식별자 대조"); ax = fv("축2")
        if (r == "dev" || r == "prod" || r == "배포트리거" || r == "협업" \
            || src == "불투명" || src == "미상" \
            || (mark != "" && mark != "-") \
            || (r == "dev" && (idc == "미선언" || idc == "대조불가")) \
            || (ax == "읽기" && r == "prod"))
          printf "4\t0\t%d\t%s\n", NR, $0
        else
          printf "X\t0\t%d\t\n", NR
        next
      }
      if (k == "cycle") { printf "5\t0\t%d\t%s\n", NR, $0; next }
      if (k == "stage-result") {
        printf "6\t0\t%d\t- `stage-result` | 세그먼트=%s | 종류=%s | 종료 코드=%s | 종단 부류=%s\n", NR, fv("세그먼트"), fv("종류"), fv("종료 코드"), fv("종단 부류")
        next
      }
    }' "$1"
}

attention_halt_record() {
  # attention_halt_record <file> — the fields of one stop record the seat
  # reads, under its heading line: the question, every option line, the
  # recommendation and its basis, and the observed details.
  awk -v name="${1##*/}" '
    BEGIN { print "정지 기록 " name }
    /^\*\*선택지\*\*:/ { inopt = 1; print; next }
    /^\*\*/ { inopt = 0 }
    inopt && /^- / { print; next }
    /^\*\*(질문 문면|추천|추천 근거|관측 상세)\*\*:/ { print }' "$1" 2>/dev/null
}

attention_sessions() {
  # attention_sessions <ledger> — the stage sessions the ledger names, merged
  # by session id. Prints `S\t<last line>\t<head>\t<sid>\t<lane>` per session,
  # in the order of each session's last row, the head being that last row's
  # `<스테이지>#<실행 버전>` (`-` for a missing version), and one `U` line per
  # row whose session id is `미상`, `-`, empty or absent — such a row counts
  # in the denominator of 「세션 읽음」 and is never read.
  awk '
    function fv(name,   i, p) {
      p = name "="
      for (i = 2; i <= nf; i++) if (index(F[i], p) == 1) return substr(F[i], length(p) + 1)
      return ""
    }
    index($0, "- `stage-result` | ") == 1 {
      nf = split($0, F, / \| /)
      sid = fv("세션 id"); st = fv("스테이지"); v = fv("실행 버전")
      if (v == "") v = "-"
      if (sid == "" || sid == "-" || sid == "미상" || sid ~ /[\/[:space:]]/) { print "U"; next }
      if (!(sid in last)) order[++n] = sid
      last[sid] = NR; head[sid] = st "#" v; lane[sid] = fv("레인")
    }
    END { for (i = 1; i <= n; i++) { s = order[i]; printf "S\t%d\t%s\t%s\t%s\n", last[s], head[s], s, lane[s] } }' "$1" \
    | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n
}

attention_transcript_file() {
  # attention_transcript_file <lane> <sid> — the session's transcript under the
  # lane's `projects/`, at either of the two depths the gate's session lookup
  # reads; nothing when the lane is unknown or no file exists.
  local lane="$1" sid="$2" f
  case "$lane" in ''|-|'(미상)') return 0 ;; esac
  case "$lane" in '~') lane="$HOME" ;; '~/'*) lane="$HOME/${lane#\~/}" ;; esac
  for f in "$lane/projects/$sid.jsonl" "$lane/projects"/*/"$sid.jsonl"; do
    if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 0
}

attention_checkpush_re() {
  # The commands whose result is a check-push result: the `make` target or the
  # script, RUN — at the start of the command, after a shell separator, or after
  # the `--` the gate's exec form puts before the command. A command that only
  # names the file (`cat scripts/check-push.sh`, `grep check-push …`) is not one.
  printf '%s' '(^|[;&|(]\s*|--\s+)(make(\s+[^;&|\s]+)*\s+check-push(\s|$)|((ba)?sh\s+)?(\S*/)?scripts/check-push\.sh(\s|$))'
}

attention_session_blocks() {
  # attention_session_blocks <transcript> <head> <allocation> — one JSON object:
  # the session's selected blocks as `text`, their byte count with one newline
  # each, how many check-push results were taken, and whether any block carries
  # a question marker.
  #
  # Only the assistant's `text` blocks and the results of check-push calls are
  # read; every other tool call and tool result is left out. A text block is cut
  # to 1500 bytes with its head line; a check-push result keeps its last 1500
  # bytes under `<head> check-push`, and a result that is only the notice of a
  # background start is not one. Within the allocation the check-push results go
  # first, then the blocks carrying a question marker, then the rest, both from
  # the end of the session; the selection is printed in session order.
  jq -R -n -c --arg head "$2" --argjson alloc "$3" --arg re "$(attention_checkpush_re)" '
    def cpb: if . < 128 then 1 elif . < 2048 then 2 elif . < 65536 then 3 else 4 end;
    def takeb($n): reduce .[] as $c ({b: 0, o: [], s: false};
      if .s then . else ($c | cpb) as $w | if .b + $w > $n then .s = true else .b += $w | .o += [$c] end end) | .o;
    def clipb($n): if utf8bytelength <= $n then . else (explode | takeb($n) | implode) end;
    def tailb($n): if utf8bytelength <= $n then . else (explode | reverse | takeb($n) | reverse | implode) end;
    def flat: if type == "string" then .
      elif type == "array" then [.[] | if type == "string" then . elif type == "object" and (.text | type) == "string" then .text else empty end] | join("\n")
      else "" end;
    [inputs | try fromjson catch empty | select(type == "object")] as $L
    | [$L[] | select(.type == "assistant") | .message.content[]? | objects
       | select(.type == "tool_use" and .name == "Bash" and (.input.command | type) == "string" and (.input.command | test($re)))
       | .id] as $cp
    | [$L[]
       | if .type == "assistant" then
           (.message.content[]? | objects | select(.type == "text" and (.text | type) == "string") | {k: "t", s: .text})
         elif .type == "user" then
           (.message.content[]? | objects | select(.type == "tool_result") | . as $r
            | select(any($cp[]; . == $r.tool_use_id)) | {k: "c", s: ($r.content | flat)}
            | select(.s | test("running in background"; "i") | not))
         else empty end]
    | to_entries | map(.value + {i: .key})
    | map(.s |= gsub("\u0000"; "")
          | if .k == "t" then
              .x = (($head + "\n" + .s) | clipb(1500)) | .q = (.s | test("[?]|까요|할지|대신|가정"))
            else
              .x = ($head + " check-push\n" + (.s | tailb(1500))) | .q = false
            end
          | .b = ((.x | utf8bytelength) + 1))
    | . as $B
    | ([$B[] | select(.k == "c")]
       + ([$B[] | select(.k == "t" and .q)] | reverse)
       + ([$B[] | select(.k == "t" and (.q | not))] | reverse)) as $order
    | reduce $order[] as $c ({u: 0, sel: []}; if .u + $c.b <= $alloc then .u += $c.b | .sel += [$c] else . end)
    | {text: ([.sel | sort_by(.i)[] | .x] | join("\n")), bytes: .u,
       cp: ([.sel[] | select(.k == "c")] | length), hasq: any($B[]; .q)}' < "$1" 2>/dev/null
}

attention_input() {
  # attention_input <ledger> <run-dir> <out> — assemble the seat's input into
  # <out>, and beside it `<out>.heads` (the sources an item may name: `S\t` and
  # a ledger line, a stop record heading or a check-push head; `T\t` and a
  # session head) and `<out>.meta` (`세션 읽음=a/b` and the scope line). Returns
  # 1 when the ledger cannot be read or a temporary file cannot be made.
  #
  # Every cap counts the heads and prefixes inside it, and every cut lands on a
  # UTF-8 boundary. The stop records and the transcripts are assembled first;
  # the ledger section then takes what the total leaves, never more than its
  # own cap, so the whole input — the section headings and the blank lines
  # between them included — stays at or under the total.
  local ledger="$1" rd="$2" out="$3" tmp f name hb tb sb lb cap sep total
  local nh=0 hd=0 halt_gone=0 a=0 b=0 skipped=0 cpn=0 nsess=0 alloc rec bytes cnt
  local ld le _line _q head sid lane obj
  [ -n "$ledger" ] && [ -r "$ledger" ] || return 1
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/attention-input.XXXXXX" 2>/dev/null) || return 1
  : > "$tmp/heads" && : > "$tmp/halt" && : > "$tmp/tr" && : > "$tmp/led" || { rm -rf "$tmp"; return 1; }

  # Stop records.
  if [ -n "$rd" ] && [ -d "$rd" ]; then
    hb=0
    for f in "$rd"/halt/*.md; do
      [ -f "$f" ] || continue
      case "$f" in *.answer.md) continue ;; esac
      name=${f##*/}
      attention_halt_record "$f" | attention_clip 2000 > "$tmp/rec" || true
      printf '\n' >> "$tmp/rec"
      bytes=$(attention_bytes "$tmp/rec")
      if [ $((hb + bytes)) -le "$(attention_halt_max)" ]; then
        cat "$tmp/rec" >> "$tmp/halt"; hb=$((hb + bytes)); nh=$((nh + 1))
        printf 'S\t정지 기록 %s\n' "$name" >> "$tmp/heads"
      else
        hd=$((hd + 1))
      fi
    done
  else
    halt_gone=1
  fi

  # Transcripts.
  attention_sessions "$ledger" > "$tmp/sess" 2>/dev/null || : > "$tmp/sess"
  b=$(grep -c . "$tmp/sess" 2>/dev/null || true); b=${b:-0}
  nsess=$(grep -c '^S' "$tmp/sess" 2>/dev/null || true); nsess=${nsess:-0}
  if [ "$nsess" -gt 0 ]; then
    alloc=$(( $(attention_transcript_max) / nsess ))
    [ "$alloc" -ge 1500 ] || alloc=1500
    : > "$tmp/cand"
    while IFS="$(printf '\t')" read -r rec _line head sid lane; do
      [ "$rec" = S ] || continue
      f=$(attention_transcript_file "$lane" "$sid")
      [ -n "$f" ] || continue
      if attention_session_blocks "$f" "$head" "$alloc" > "$tmp/blk" 2>/dev/null && [ -s "$tmp/blk" ]; then
        printf '%s\t%s\t%s\n' "$(jq -r 'if .hasq then 0 else 1 end' "$tmp/blk" 2>/dev/null || printf 1)" \
          "$head" "$(jq -c . "$tmp/blk")" >> "$tmp/cand"
      fi
    done < "$tmp/sess"
    # A session whose share fell to the one-block floor is taken in order of
    # whether it carries a question marker; otherwise in ledger order.
    if [ $(( $(attention_transcript_max) / nsess )) -lt 1500 ]; then
      LC_ALL=C sort -s -t "$(printf '\t')" -k1,1n "$tmp/cand" > "$tmp/cand2" 2>/dev/null || cp "$tmp/cand" "$tmp/cand2"
    else
      cp "$tmp/cand" "$tmp/cand2"
    fi
    tb=0
    while IFS="$(printf '\t')" read -r _q head obj; do
      [ -n "$obj" ] || continue
      bytes=$(printf '%s' "$obj" | jq -r '.bytes' 2>/dev/null || printf 0)
      if [ "$((tb + bytes))" -gt "$(attention_transcript_max)" ]; then
        skipped=$((skipped + 1)); continue
      fi
      if [ "${bytes:-0}" -gt 0 ]; then
        printf '%s' "$obj" | jq -r '.text' >> "$tmp/tr" 2>/dev/null || true
        tb=$((tb + bytes))
      fi
      a=$((a + 1))
      printf 'T\t%s\n' "$head" >> "$tmp/heads"
      cnt=$(printf '%s' "$obj" | jq -r '.cp' 2>/dev/null || printf 0)
      if [ "${cnt:-0}" -gt 0 ]; then
        cpn=$((cpn + cnt))
        printf 'S\t%s check-push\n' "$head" >> "$tmp/heads"
      fi
    done < "$tmp/cand2"
  fi

  # The ledger section takes what is left.
  sep=$(printf '## 원장\n\n## 정지 기록\n\n## 트랜스크립트\n\n## 범위\n\n' | LC_ALL=C wc -c | tr -d ' ')
  hb=$(attention_bytes "$tmp/halt"); tb=$(attention_bytes "$tmp/tr")
  cap=$(( $(attention_input_max) - hb - tb - $(attention_scope_max) - sep ))
  [ "$cap" -le "$(attention_ledger_max)" ] || cap=$(attention_ledger_max)
  attention_ledger_rows "$ledger" > "$tmp/rows" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n -k3,3n "$tmp/rows" \
    | LC_ALL=C awk -F '\t' -v cap="$cap" -v heads="$tmp/heads" -v stats="$tmp/lstat" '
      function trim(t,   m, i, c, k) {
        m = length(t)
        for (i = 0; i < 4 && m - i >= 1; i++) {
          c = substr(t, m - i, 1)
          if (c < "\200") break
          if (c >= "\300") {
            k = (c < "\340") ? 2 : ((c < "\360") ? 3 : 4)
            if (i + 1 != k) t = substr(t, 1, m - i - 1)
            break
          }
        }
        return t
      }
      $1 == "X" { ex++; next }
      {
        row = $0; sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", row)
        line = "원장 " $3 ": " row
        if (length(line) > 1000) line = trim(substr(line, 1, 1000))
        if (full || used + length(line) + 1 > cap) { full = 1; dropped++; next }
        print line; used += length(line) + 1; kept++
        printf "S\t원장 %s\n", $3 >> heads
      }
      END { printf "%d\t%d\t%d\n", kept + 0, dropped + 0, ex + 0 > stats }' > "$tmp/led" || { rm -rf "$tmp"; return 1; }
  lb=$(awk -F '\t' '{ print $1 }' "$tmp/lstat" 2>/dev/null || printf 0)
  ld=$(awk -F '\t' '{ print $2 }' "$tmp/lstat" 2>/dev/null || printf 0)
  le=$(awk -F '\t' '{ print $3 }' "$tmp/lstat" 2>/dev/null || printf 0)

  if [ "$halt_gone" = 1 ]; then
    sb="정지 기록 없음(런 디렉터리 회수)"
  else
    sb="정지 기록 ${nh}건 넣음 · 상한으로 뺀 정지 기록 ${hd}건"
  fi
  printf '범위: 원장 %s행 넣음 · 상한으로 뺀 원장 행 %s · 도달 감사 밖 exec 행 %s(수만 셈) · %s · 세션 읽음 %s/%s · 칸이 차서 넣지 못한 세션 %s · check-push 결과 %s\n' \
    "${lb:-0}" "${ld:-0}" "${le:-0}" "$sb" "$a" "$b" "$skipped" "$cpn" | attention_clip "$(attention_scope_max)" > "$tmp/scope"

  {
    printf '## 원장\n'; cat "$tmp/led"
    printf '\n## 정지 기록\n'; cat "$tmp/halt"
    printf '\n## 트랜스크립트\n'; cat "$tmp/tr"
    printf '\n## 범위\n'; cat "$tmp/scope"; printf '\n'
  } > "$out" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  total=$(attention_bytes "$out")
  if [ "${total:-0}" -gt "$(attention_input_max)" ]; then
    rm -rf "$tmp"; return 1
  fi
  cp "$tmp/heads" "$out.heads" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  { printf '세션 읽음=%s/%s\n' "$a" "$b"; printf '범위=%s\n' "$(cat "$tmp/scope")"; } > "$out.meta" 2>/dev/null \
    || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  return 0
}

attention_meta() {
  # attention_meta <meta-file> <key> — the value of `<key>=` in an input's meta.
  [ -f "$1" ] || return 0
  { sed -n "s/^$2=//p" "$1" 2>/dev/null || true; } | head -n 1
}

attention_items() {
  # attention_items <envelope> <heads> — the seat's items as result-file lines,
  # one JSON object `{reread: [line…], transcript: [line…]}`.
  #
  # EVERY FIELD IS CLEANED BEFORE IT REACHES A FILE A PERSON READS, in this
  # order: known secret shapes are masked as `[가림]`; control characters and
  # line breaks become spaces; the field is cut to its byte cap (400 for the
  # summary and the evidence, 200 for the source and the stage) on a character
  # boundary, saying it was cut; and the line is written inside a quote block.
  # An item whose source or stage is not among the heads the input carried
  # keeps its place and ends with 「(출처 확인 안 됨)」.
  jq -c --rawfile heads "$2" '
    def cpb: if . < 128 then 1 elif . < 2048 then 2 elif . < 65536 then 3 else 4 end;
    def takeb($n): reduce .[] as $c ({b: 0, o: [], s: false};
      if .s then . else ($c | cpb) as $w | if .b + $w > $n then .s = true else .b += $w | .o += [$c] end end) | .o;
    def clipb($n): if utf8bytelength <= $n then . else (explode | takeb($n - 11) | implode) + "…(잘림)" end;
    def mask: gsub("(ghp_|gho_|ghs_|ghu_|ghr_|github_pat_)[A-Za-z0-9_]+"; "[가림]")
      | gsub("sk-ant-[A-Za-z0-9_-]+"; "[가림]")
      | gsub("sk-[A-Za-z0-9_-]{8,}"; "[가림]")
      | gsub("AKIA[0-9A-Z]{16}"; "[가림]")
      | gsub("xox[bpars]-[A-Za-z0-9-]+"; "[가림]")
      | gsub("(?i)bearer\\s+[A-Za-z0-9._~+/=-]+"; "[가림]")
      | gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----"; "[가림]");
    def clean: gsub("[\\x00-\\x1f\\x7f\\x{0080}-\\x{009f}\\x{2028}\\x{2029}]"; " ") | gsub(" {2,}"; " ") | sub("^ "; "") | sub(" $"; "");
    def safe($n): (if type == "string" then . else tostring end) | mask | clean | clipb($n);
    def key: (if type == "string" then . else tostring end) | gsub("^\\s+|\\s+$"; "");
    ($heads | split("\n") | map(select(length > 0))) as $H
    | ([$H[] | select(startswith("S\t")) | .[2:]]) as $S
    | ([$H[] | select(startswith("T\t")) | .[2:]]) as $T
    | {"weak_basis": "근거 약함", "skipped_verification": "건너뛴 검증",
       "risky_choice": "위험한 선택", "unlogged_decision": "로그에 없는 결정"} as $lab
    | (.structured_output // {}) as $o
    | {reread: [($o.reread // [])[] | objects | . as $it
         | "> - [\($lab[$it.kind] // "위험한 선택")] \($it.source | safe(200)) — \($it.summary | safe(400)) — 근거: \($it.evidence | safe(400))"
           + (if any($S[]; . == ($it.source | key)) then "" else " (출처 확인 안 됨)" end)],
       transcript: [($o.transcript // [])[] | objects | . as $it
         | "> - [로그에 없는 결정] \($it.stage | safe(200)) — \($it.summary | safe(400)) — 근거: \($it.evidence | safe(400))"
           + (if any($T[]; . == ($it.stage | key)) then "" else " (출처 확인 안 됨)" end)]}' "$1" 2>/dev/null
}

attention_served_model() {
  # attention_served_model <envelope> — the served model, read the way the
  # judgment call reads it, or `(미상)`.
  local m
  m=$(jq -r '(.modelUsage // {}) | keys | map(sub("\\[.*$"; "")) | unique | join(",")' "$1" 2>/dev/null || true)
  printf '%s' "${m:-(미상)}"
}

attention_cost() {
  # attention_cost <envelope> — the envelope's `total_cost_usd`, or nothing.
  local c
  [ -f "${1:-}" ] || return 0
  c=$(jq -r '.total_cost_usd // empty | numbers' "$1" 2>/dev/null || true)
  printf '%s' "$c"
}

attention_write_result() {
  # attention_write_result <path> <run-id> <결과> <사유> <원장 행 없음 0|1>
  #   <envelope|-> <heads|-> <meta|-> — write the result file through a
  # temporary file in the same directory and a rename, so a reader never sees
  # half of it. A failed round writes zero items and keeps the seat's cost and
  # model when its envelope carried them.
  local path="$1" id="$2" res="$3" why="$4" norow="$5" env="$6" heads="$7" meta="$8"
  local tmp items n=0 m=0 sess="-" model="(미상)" cost="" scope="" rr="" tt=""
  tmp=$(mktemp "$(dirname "$path")/.attention.XXXXXX" 2>/dev/null) || return 1
  if [ "$env" != "-" ] && [ -f "$env" ]; then
    model=$(attention_served_model "$env")
    cost=$(attention_cost "$env")
  fi
  if [ "$meta" != "-" ] && [ -f "$meta" ]; then
    sess=$(attention_meta "$meta" '세션 읽음'); [ -n "$sess" ] || sess="-"
    scope=$(attention_meta "$meta" '범위')
  fi
  if [ "$res" = "완료" ] && [ "$heads" != "-" ] && [ -f "$heads" ]; then
    items=$(attention_items "$env" "$heads") || items=""
    if [ -n "$items" ]; then
      rr=$(printf '%s' "$items" | jq -r '.reread[]' 2>/dev/null || true)
      tt=$(printf '%s' "$items" | jq -r '.transcript[]' 2>/dev/null || true)
      n=$(printf '%s' "$items" | jq -r '.reread | length' 2>/dev/null || printf 0)
      m=$(printf '%s' "$items" | jq -r '.transcript | length' 2>/dev/null || printf 0)
    fi
  fi
  model=$(printf '%s' "$model" | LC_ALL=C tr -d '\000-\037' | attention_clip 128)
  if ! {
    printf '# 주의 절 — 런 %s\n' "$id"
    printf '%s\n' "$(attention_result_marker)"
    printf '**결과**: %s\n' "$res"
    [ "$res" = "완료" ] || printf '**사유**: %s\n' "$why"
    [ "$norow" != 1 ] || printf '**원장 행**: 없음(런 디렉터리 회수)\n'
    printf '**재독**: %s\n' "${n:-0}"
    printf '**대조**: %s\n' "${m:-0}"
    printf '**세션 읽음**: %s\n' "$sess"
    printf '**서빙 모델**: %s\n' "$model"
    printf '**비용 usd**: %s\n' "${cost:-0}"
    printf '\n## 재독\n'
    if [ -n "$rr" ]; then printf '%s\n' "$rr"; else printf '(없음)\n'; fi
    printf '\n## 대조\n'
    if [ -n "$tt" ]; then printf '%s\n' "$tt"; else printf '(없음)\n'; fi
    printf '\n## 범위\n'
    printf '%s\n' "${scope:-범위: 입력을 조립하지 않음}"
  } > "$tmp" 2>/dev/null || ! mv "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

attention_result_field() {
  # attention_result_field <result-file> <name> — the value of `**<name>**: `.
  [ -f "$1" ] || return 0
  { sed -n "s/^\*\*$2\*\*: //p" "$1" 2>/dev/null || true; } | head -n 1
}

attention_result_ok() {
  # attention_result_ok <file> — the file is a result file of this format.
  [ -f "$1" ] && [ "$(sed -n '2p' "$1" 2>/dev/null || true)" = "$(attention_result_marker)" ]
}

attention_report() {
  # attention_report <ledger> <run-id> — the morning report's attention
  # section, one of six fixed outputs. Reads only; starts nothing.
  local ledger="$1" id="$2" res rec st why
  res=$(attention_result_path "$ledger" "$id")
  if attention_result_ok "$res"; then
    case "$(attention_result_field "$res" '결과')" in
      완료)
        printf '주의 좌석 — 재독 %s건 · 대조 %s건 · 세션 읽음 %s · 서빙 모델 %s · 비용 $%s\n' \
          "$(attention_result_field "$res" '재독')" "$(attention_result_field "$res" '대조')" \
          "$(attention_result_field "$res" '세션 읽음')" "$(attention_result_field "$res" '서빙 모델')" \
          "$(attention_result_field "$res" '비용 usd')"
        if grep -q '^> - \[' "$res" 2>/dev/null; then
          grep '^> - \[' "$res" 2>/dev/null || true
        else
          printf '주의 항목 없음\n'
        fi
        { grep -m 1 '^범위: ' "$res" 2>/dev/null || true; }
        printf '이 절은 런이 끝난 뒤 별도 좌석이 원장·정지 기록·스테이지 트랜스크립트를 다시 읽고 쓴 것입니다 — 런의 판단·머지·승인을 바꾸지 않았습니다\n'
        return 0 ;;
      *)
        printf '주의 절 생성 실패 — %s\n' "$(attention_result_field "$res" '사유')"
        return 0 ;;
    esac
  fi
  rec=$(attention_record_path "$id")
  if [ ! -f "$rec" ]; then
    printf '주의 좌석 기록 없음 — 이 기능 이전에 열린 런입니다\n'
    return 0
  fi
  st=$(jq -r '.["상태"] // empty' "$rec" 2>/dev/null || true)
  case "$st" in
    실행중)
      printf '주의 좌석이 도는 중입니다 — 끝난 뒤 다시 보고를 받으세요\n' ;;
    종결)
      why=$(jq -r '[.["사유"], .["결과"]] | map(select(. != null and . != "")) | (.[0] // "결과 파일 없음") | tostring' \
              "$rec" 2>/dev/null || true)
      printf '주의 절 생성 실패 — %s\n' "${why:-결과 파일 없음}" ;;
    *)
      if attention_end_token_row "$ledger" >/dev/null; then
        printf '주의 좌석 대기 — 런은 끝났고 다음 계기에 돕니다\n'
      else
        printf '종료 토큰 없음 — 런이 끝나지 않아 주의 좌석이 돌지 않았습니다\n'
      fi ;;
  esac
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  case "${1:-}" in
    report)
      [ "$#" -eq 3 ] || { printf 'usage: attention-round.sh report <ledger> <run-id>\n' >&2; exit 2; }
      attention_report "$2" "$3" ;;
    *)
      printf 'usage: attention-round.sh report <ledger> <run-id>\n' >&2
      exit 2 ;;
  esac
fi
