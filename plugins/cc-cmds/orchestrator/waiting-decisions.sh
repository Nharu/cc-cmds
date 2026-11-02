#!/usr/bin/env bash
# waiting-decisions.sh — the morning report's 「기다리는 결정」 section, rendered.
#
# WHAT THIS FILE IS. When a run ends, the decisions it is waiting on are spread
# over the ledger's open approvals and the run directory's halt records. The
# morning report has to put each one in front of a person with what is being
# decided, the options, the recommendation and its basis, and what each option
# risks. `bash waiting-decisions.sh report <manifest> <ledger> <run-id>` prints
# that section's body; the report copies it verbatim.
#
# THE VERDICTS ARE THE GATE'S. Which approvals are open, what question the seat
# asks for each, which halt records the seat brings to a person and which ones
# the seat may answer without one — every one of these is the result of the
# same gate function the gate and the seat call, never re-derived here. The
# gate is sourced definitions-only in ONE place below, in a subshell, and only
# the functions named in `WD_GATE_FUNCTIONS` are called. The gate's entry is
# never run, so the reap clock a gate call rewrites is not touched, and nothing
# is written to the ledger, the sidecars or the run directory.
#
# ONE SUBSHELL PER DECISION. A gate function that ends in `die` ends the
# subshell it runs in, so each decision is rendered in its own: such a failure
# turns that decision's cells into `미기재(읽기 실패 — <first line>)` and every
# other decision still renders. Warnings are discarded.
#
# Exit codes: 0 printed; 2 usage error, `jq` missing, the ledger or the
# manifest unreadable, or the gate could not be sourced — with a one-line error.
#
# Compatibility: bash 3.2.

WD_SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The gate functions this file calls, and no other.
WD_GATE_FUNCTIONS='gate_pending_approvals_json gate_prompt gate_approval_sidecar_path gate_approval_sidecar_ok gate_approval_sidecar_aid gate_returned_halts_json gate_halt_auto_answer_current gate_halt_recommendation gate_halt_option_lines gate_halt_record_tail gate_shift_halt_row_of gate_rows gate_row_field gate_text_names_file cc_cone_blocked cc_halt_answered cc_halt_returned'

# ---------------------------------------------------------------------------
# Fixed sentences. Every `답하는 곳:` line comes from this one table.
# ---------------------------------------------------------------------------
wd_where() {
  # wd_where <kind> [<label>]
  case "$1" in
    judgment) printf '%s' '다음 좌석 실행(`/cc-cmds:autopilot`)이 이 질문을 그대로 묻습니다 — 아래 라벨 하나로 답합니다' ;;
    yesno) printf '%s' '다음 좌석 실행이 이 질문을 메뉴 없이 예/아니오로 묻습니다 — 예는 `승인`, 아니오는 `거부` 로 닫힙니다' ;;
    unanswered) printf '%s' '다음 좌석 실행이 이 기록의 질문 문면과 선택지를 그대로 묻습니다 — 아래 라벨 하나로 답합니다' ;;
    returned) printf '%s' '다음 좌석 실행이 되돌아온 답과 그 답을 실행하지 못한 이유를 먼저 보이고 같은 질문을 다시 묻습니다 — 아래 라벨 하나로 다시 답합니다' ;;
    seat-apply) printf '%s' '다음 좌석 실행이 적용 미리보기의 차이를 보인 뒤 이 기록의 선택지로 묻습니다 — 아래 라벨 하나로 답합니다. 같은 세그먼트의 앞선 사람 답이 덮으면 좌석이 그 답을 이어받아 답합니다' ;;
    attach) printf '다음 좌석 실행이 이 기록의 질문 문면과 선택지를 그대로 묻습니다 — 라벨 하나로 답하되, `%s` 은 질문 문면이 말하는 내용을 첨부로 함께 내야 닫힙니다' "$2" ;;
    visual) printf '%s' '캔버스를 봐야 답하는 결정입니다 — 이 보고의 「시각 승인 대기」 절이 적은 캔버스를 연 뒤 그 절이 적은 대로 다음 좌석 실행의 질문에 라벨 하나로 답합니다' ;;
  esac
}

WD_FORM_MENU='라벨 메뉴'
WD_FORM_YESNO='예/아니오 — 예는 `승인`, 아니오는 `거부` 로 닫힙니다. `무효` 는 좌석 질문에 없습니다'
WD_AUTO_MARK='자동 답 대상 — 자동 해소가 켜져 있으면 다음 좌석 실행이 사람 없이 추천을 답으로 씁니다. 게이트가 거부하면 그때 사람에게 묻습니다'
WD_FREE_NOTE='이 승인은 자유 입력 답이 처분되지 못해 다시 묻습니다'
WD_SEAT_APPLY_REC='(없음) — 이 정지는 사람이 적용 미리보기를 보고 답하거나 같은 세그먼트의 앞선 사람 답을 이어받습니다'
WD_SEAT_APPLY_BASIS='없음 — 이 정지 스텝은 추천을 받지 않습니다'
WD_MENU_LABELS='승인 거부 무효'

wd_die() { printf 'waiting-decisions: %s\n' "$1" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Rendering — pure text work on what the gate functions returned.
# ---------------------------------------------------------------------------
wd_field_line() {
  # wd_field_line <text> <name> — the value of the first `**<name>**: ` line.
  printf '%s\n' "$1" | sed -n "s/^\*\*$2\*\*: //p" | sed -n '1p' | sed 's/[[:space:]]*$//'
}

wd_option_block() {
  # wd_option_block <text> — the option lines of a `**선택지**:` block in an
  # approval's decision aid, the same block shape a halt record uses.
  printf '%s\n' "$1" | LC_ALL=C awk '
    inb && /^\*\*/ { inb = 0 }
    /^\*\*선택지\*\*:[ \t]*$/ { inb = 1; next }
    inb && /^- `[^`]+`$/ { print; next }
    inb && /^- `[^`]+` — / { print }'
}

wd_labels_of() {
  # wd_labels_of <option lines> — one label per line.
  printf '%s\n' "$1" | LC_ALL=C awk 'length($0) > 3 { l = substr($0, 4); sub(/`.*/, "", l); print l }'
}

wd_has_label() {
  # wd_has_label <labels> <label>
  printf '%s\n' "$1" | grep -qxF -- "$2"
}

wd_render_rec() {
  # wd_render_rec <추천 value> <추천 근거 value> <labels> — prints the `추천:` and
  # `근거:` lines; WD_REC_MISSING is 1 when the recommendation counts as not
  # written.
  local rec="$1" basis="$2" labels="$3" lab
  WD_REC_MISSING=0
  case "$rec" in
    '')
      printf '추천: 미기재\n'; WD_REC_MISSING=1 ;;
    '`'*'`'*)
      lab=${rec#\`}; lab=${lab%%\`*}
      if [ -n "$lab" ] && wd_has_label "$labels" "$lab"; then
        printf '추천: `%s`\n' "$lab"
      else
        printf '추천: 미기재(형식 어긋남 — 선택지에 없는 라벨 %s)\n' "$lab"; WD_REC_MISSING=1
      fi ;;
    *)
      printf '추천: %s\n' "$rec" ;;
  esac
  printf '근거: %s\n' "${basis:-미기재}"
}

wd_render_options() {
  # wd_render_options <option lines> <risk line> <yesno 0|1> — one line per
  # option with its risk, then one line per discarded risk part.
  # WD_RISK_MISSING is 1 when a label has no risk or a part was discarded.
  local opts="$1" risk="$2" yn="$3" labels rest head part lab parts='' kept='' drops='' dropwhy='' ol desc mark r n dup
  local sep=' / `' dash='` — '
  labels=$(wd_labels_of "$opts")
  WD_RISK_MISSING=0
  if [ -n "$risk" ]; then
    rest=$risk
    while :; do
      case "$rest" in
        *"$sep"*)
          head=${rest%%"$sep"*}
          rest=${rest#*"$sep"}
          parts="$parts$head"$'\n'
          rest="\`$rest" ;;
        *) parts="$parts$rest"$'\n'; break ;;
      esac
    done
    while IFS= read -r part; do
      [ -n "$part" ] || continue
      case "$part" in
        '`'*'` — '*)
          lab=${part#\`}; lab=${lab%%\`*}
          n=$(printf '%s' "$parts" | LC_ALL=C awk -v l="$lab" 'index($0, "`" l "` — ") == 1 { c++ } END { print c + 0 }')
          if [ "$n" -gt 1 ]; then
            drops="$drops$part"$'\n'; dropwhy="$dropwhy$lab"$'\t''같은 라벨이 두 부분에 나옴'$'\n'
          elif ! wd_has_label "$labels" "$lab"; then
            drops="$drops$part"$'\n'; dropwhy="$dropwhy-"$'\t'"선택지에 없는 라벨 $lab"$'\n'
          else
            r=${part#*"$dash"}
            kept="$kept$lab"$'\t'"$r"$'\n'
          fi ;;
        *)
          drops="$drops$part"$'\n'; dropwhy="$dropwhy-"$'\t''백틱 라벨로 시작하지 않는 부분'$'\n' ;;
      esac
    done <<EOF
$parts
EOF
  fi
  [ -z "$drops" ] || WD_RISK_MISSING=1
  while IFS= read -r ol; do
    [ -n "$ol" ] || continue
    lab=${ol#'- `'}; lab=${lab%%\`*}
    desc=''
    case "$ol" in *"$dash"*) desc=${ol#*"$dash"} ;; esac
    mark=''
    if [ "$yn" = "1" ]; then
      case "$lab" in
        승인) mark=' (예)' ;;
        거부) mark=' (아니오)' ;;
        무효) mark=' (좌석 질문에 없음)' ;;
      esac
    fi
    r=$(printf '%s' "$kept" | LC_ALL=C awk -F'\t' -v l="$lab" '$1 == l { print substr($0, length(l) + 2); exit }')
    if [ -z "$r" ]; then
      WD_RISK_MISSING=1
      dup=$(printf '%s' "$dropwhy" | LC_ALL=C awk -F'\t' -v l="$lab" '$1 == l { print $2; exit }')
      [ -n "$dup" ] || dup=$(printf '%s' "$dropwhy" | sed -n '1p' | cut -f2)
      if [ -n "$dup" ]; then r="미기재(형식 어긋남 — $dup)"; else r='미기재'; fi
    fi
    if [ -n "$desc" ]; then
      printf -- '- `%s`%s — %s · 리스크: %s\n' "$lab" "$mark" "$desc" "$r"
    else
      printf -- '- `%s`%s · 리스크: %s\n' "$lab" "$mark" "$r"
    fi
  done <<EOF
$opts
EOF
  while IFS= read -r part; do
    [ -n "$part" ] || continue
    printf '버린 리스크 부분: %s\n' "$part"
  done <<EOF
$drops
EOF
}

wd_fixed_options() {
  # wd_fixed_options <labels> — option lines carrying labels and no description,
  # for an approval whose decision aid is missing.
  local l
  for l in $1; do printf -- '- `%s`\n' "$l"; done
}

wd_indent_rest() {
  # wd_indent_rest — continuation lines of a multi-line value, indented so the
  # value stays one item.
  sed '2,$s/^/  /'
}

# ---------------------------------------------------------------------------
# Inside the sourced gate.
# ---------------------------------------------------------------------------
wd_count_line() {
  # The trailing line a decision subshell ends with: `@@WD <a> <b>` for a
  # rendered decision, `@@SKIP <kind>` for a record counted only.
  printf '@@WD %s %s\n' "$1" "$2"
}

wd_one_approval() {
  # wd_one_approval <json element>
  local el="$1" id blocks cut cls disp q row tuple kind path aid arc=1 opts rec basis risk action grade yn=0 labels
  id=$(printf '%s' "$el" | jq -r '.id')
  blocks=$(printf '%s' "$el" | jq -r '.blocks')
  cut=$(printf '%s' "$el" | jq -r '.cutpoint')
  cls=$(printf '%s' "$el" | jq -r '.class')
  disp=$(printf '%s' "$el" | jq -r '.disposition')
  case "$cut" in
    판단) kind=judgment ;;
    경계) kind=boundary ;;
    *) kind=act ;;
  esac
  q=$(gate_prompt "$id" | jq -r '.question') || exit 1
  [ -n "$q" ] || exit 1
  row=$( { gate_rows '승인' | grep -F "| 승인 id=$id |" || true; } | tail -1)
  tuple=$(gate_row_field "$row" '구속 튜플')
  aid=''
  if path=$(gate_approval_sidecar_path) && gate_approval_sidecar_ok "$path"; then
    arc=0
    aid=$(gate_approval_sidecar_aid "$id") || arc=$?
  fi
  case "$kind" in
    judgment) printf '[승인 %s] 판단 승인 · 막는 세그먼트 %s · 판단 부류 %s\n' "$id" "$blocks" "$cls" ;;
    boundary) printf '[승인 %s] 경계 승인 · %s\n' "$id" "${tuple%%/*}" ;;
    act)
      action=$(wd_field_line "$aid" '행위')
      grade=${tuple##*/}
      printf '[승인 %s] 행위 승인 · %s · 막는 세그먼트 %s · 절단점 %s · 등급 %s\n' "$id" "${action:-미기재}" "$blocks" "$cut" "${grade:--}" ;;
  esac
  printf '질문: %s\n' "$q" | wd_indent_rest
  if [ "$kind" = "judgment" ]; then printf '형식: %s\n' "$WD_FORM_MENU"; else printf '형식: %s\n' "$WD_FORM_YESNO"; yn=1; fi
  if [ "$kind" = "judgment" ] && [ "$cls" = "시각-승인" ]; then
    printf '답하는 곳: %s\n' "$(wd_where visual)"
  elif [ "$kind" = "judgment" ]; then
    printf '답하는 곳: %s\n' "$(wd_where judgment)"
  else
    printf '답하는 곳: %s\n' "$(wd_where yesno)"
  fi
  case "$disp" in 자유\ 입력*) printf '%s\n' "$WD_FREE_NOTE" ;; esac
  if [ "$arc" = "2" ]; then
    printf '추천: 미기재(형식 어긋남 — 결정 보조 sha256 불일치)\n근거: 미기재\n'
    for l in $WD_MENU_LABELS; do
      printf -- '- `%s` · 리스크: 미기재(형식 어긋남 — 결정 보조 sha256 불일치)\n' "$l"
    done
    wd_count_line 1 1
    exit 0
  fi
  opts=$(wd_option_block "$aid")
  [ -n "$opts" ] || opts=$(wd_fixed_options "$WD_MENU_LABELS")
  labels=$(wd_labels_of "$opts")
  rec=$(wd_field_line "$aid" '추천')
  basis=$(wd_field_line "$aid" '추천 근거')
  risk=$(wd_field_line "$aid" '선택지 리스크')
  wd_render_rec "$rec" "$basis" "$labels"
  wd_render_options "$opts" "$risk" "$yn"
  wd_count_line "$WD_REC_MISSING" "$WD_RISK_MISSING"
  exit 0
}

wd_pointer_texts() {
  # wd_pointer_texts — one text per line that names the records the seat
  # brings to a person: the last handoff's `막힌 지점`, the fields of every cone
  # block still standing, and the record of every returned halt.
  local row subj reason r f
  row=$(gate_rows 'handoff' | tail -1)
  [ -z "$row" ] || gate_row_field "$row" '막힌 지점'; printf '\n'
  while IFS="$(printf '\t')" read -r _ subj _ reason _; do
    [ -n "$subj" ] || continue
    r=$(gate_rows 'blocked' | LC_ALL=C awk -v s="$subj" -v w="$reason" '
      index($0, "| 스코프=cone |") && (index($0, "| 앵커 세그먼트=" s " |") || (!index($0, "| 앵커 세그먼트=") && index($0, "| 대상=" s " |"))) && index($0, "| 사유=" w " |") { last = $0 }
      END { print last }')
    [ -n "$r" ] || continue
    for f in '근거' '사유' '관측' '중단 기록'; do gate_row_field "$r" "$f"; printf '\n'; done
  done <<EOF
$(cc_cone_blocked "$LEDGER")
EOF
  { printf '['; gate_returned_halts_json; printf ']'; } | jq -r '.[].record' 2>/dev/null
}

wd_one_halt() {
  # wd_one_halt <record> <relative path> <pointer texts file>
  local rec="$1" rel="$2" ptrf="$3" tail returned=0 opts step skill labels t pointed=0 key='' srow auto=1 mark=0 hdr where attach='' ol lab desc rec_l basis risk
  tail=$(gate_halt_record_tail "$rec")
  if cc_halt_answered "$LEDGER" "$tail"; then printf '@@SKIP answered\n'; exit 0; fi
  grep -qxF '<!-- /cc-pipeline-halt v1 -->' "$rec" 2>/dev/null || { printf '@@SKIP nofence\n'; exit 0; }
  cc_halt_returned "$LEDGER" "$tail" && returned=1
  opts=$(gate_halt_option_lines "$rec")
  [ -n "$opts" ] || { printf '@@SKIP noopt\n'; exit 0; }
  step=$(sed -n 's/^\*\*스텝\*\*: //p' "$rec" | sed -n '1p' | sed 's/[[:space:]]*$//')
  case "$step" in
    'Step 3 잔여 검증 좌석 실행'*|'Step 3 게이트 도달 좌석 실행'*) printf '@@SKIP seatrun\n'; exit 0 ;;
  esac
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if gate_text_names_file "$t" "$rec" || gate_text_names_file "$t" "${rec##*/}"; then pointed=1; break; fi
  done < "$ptrf"
  srow=$(gate_shift_halt_row_of "$rec")
  if [ -n "$srow" ]; then
    key=$(gate_row_field "${srow#*:}" '앵커 세그먼트')
  else
    case "$rec" in
      "$RUN_DIR"/halt/shift/*) key='' ;;
      *) hdr=$(sed -n '1p' "$rec"); key=$(printf '%s' "$hdr" | sed -n 's/.*stage=\([^;]*\).*/\1/p' | sed 's/[[:space:]]*$//'); key=${key%%#*} ;;
    esac
  fi
  if [ -n "$key" ]; then gate_halt_auto_answer_current "$key" "$rec" && auto=0; fi
  if [ "$pointed" = "0" ] && [ "$auto" != "0" ]; then printf '@@SKIP unpointed\n'; exit 0; fi
  if [ "$returned" = "0" ] && [ "$auto" = "0" ] && gate_halt_recommendation "$rec"; then mark=1; fi
  skill=$(sed -n 's/^\*\*스킬\*\*: //p' "$rec" | sed -n '1p' | sed 's/[[:space:]]*$//')
  labels=$(wd_labels_of "$opts")
  printf '[정지 기록 %s] 스킬 %s · 스텝 %s\n' "$rel" "${skill:-미기재}" "${step:-미기재}"
  printf '질문: %s\n' "$(sed -n 's/^\*\*질문 문면\*\*: //p' "$rec" | sed -n '1p')" | wd_indent_rest
  printf '형식: %s\n' "$WD_FORM_MENU"
  case "$step" in
    'Step 1 CFI-U3 BT-STOP — 미결 결정'*) wd_has_label "$labels" '재수렴' && attach='재수렴' ;;
    '교대 정지 — 종료 절 근거'*) wd_has_label "$labels" '근거 제출' && attach='근거 제출' ;;
  esac
  if [ -z "$attach" ]; then
    while IFS= read -r ol; do
      case "$ol" in
        *'` — '*'첨부:'*) lab=${ol#'- `'}; attach=${lab%%\`*}; break ;;
      esac
    done <<EOF
$opts
EOF
  fi
  case "$step" in
    시각-판정*|금지-후보*|발행-실패*) where=$(wd_where visual) ;;
    'Step 3 강제 표면 좌석 적용'*) where=$(wd_where seat-apply) ;;
    *)
      if [ -n "$attach" ]; then where=$(wd_where attach "$attach")
      elif [ "$returned" = "1" ]; then where=$(wd_where returned)
      else where=$(wd_where unanswered); fi ;;
  esac
  printf '답하는 곳: %s\n' "$where"
  [ "$mark" = "0" ] || printf '%s\n' "$WD_AUTO_MARK"
  case "$step" in
    'Step 3 강제 표면 좌석 적용'*)
      printf '추천: %s\n근거: %s\n' "$WD_SEAT_APPLY_REC" "$WD_SEAT_APPLY_BASIS"
      WD_REC_MISSING=0 ;;
    *)
      rec_l=$(sed -n 's/^\*\*추천\*\*: //p' "$rec" | sed -n '1p' | sed 's/[[:space:]]*$//')
      basis=$(sed -n 's/^\*\*추천 근거\*\*: //p' "$rec" | sed -n '1p' | sed 's/[[:space:]]*$//')
      wd_render_rec "$rec_l" "$basis" "$labels" ;;
  esac
  risk=$(sed -n 's/^\*\*선택지 리스크\*\*: //p' "$rec" | sed -n '1p' | sed 's/[[:space:]]*$//')
  wd_render_options "$opts" "$risk" 0
  wd_count_line "$WD_REC_MISSING" "$WD_RISK_MISSING"
  exit 0
}

wd_failure_block() {
  # wd_failure_block <header> <error> — a decision whose gate function failed.
  local m="미기재(읽기 실패 — $2)"
  printf '%s\n질문: %s\n형식: %s\n답하는 곳: %s\n추천: %s\n근거: %s\n' "$1" "$m" "$m" "$m" "$m" "$m"
  wd_count_line 1 1
}

wd_error_of() {
  # wd_error_of <stderr file> <rc> — the first line of a `die`, or of stderr.
  local e
  e=$(sed -n 's/.*\[run\]\[stop\] //p' "$1" 2>/dev/null | sed -n '1p')
  [ -n "$e" ] || e=$(sed -n '1p' "$1" 2>/dev/null)
  printf '%s' "${e:-종료 코드 $2}"
}

wd_record_paths() {
  # wd_record_paths — the run directory's halt records, relative to it, with
  # the answer attachments left out.
  local f
  for f in "$RUN_DIR"/halt/*.md "$RUN_DIR"/halt/shift/*.md; do
    [ -f "$f" ] || continue
    case "$f" in *.answer.md) continue ;; esac
    printf '%s\n' "${f#"$RUN_DIR"/}"
  done
}

wd_render() {
  local tmp out rc el n=0 a=0 b=0 nofence=0 noopt=0 seatrun=0 unpointed=0 body='' ptrf f rel line rundir_gone=0 list
  tmp=$(mktemp -d) || exit 4
  ptrf="$tmp/pointers"
  # Approvals, in the order the gate lists them.
  while IFS= read -r el; do
    [ -n "$el" ] || continue
    rc=0
    out=$(wd_one_approval "$el" 2>"$tmp/err") || rc=$?
    if [ "$rc" != "0" ] || [ -z "$out" ]; then
      out=$(wd_failure_block "[승인 $(printf '%s' "$el" | jq -r '.id' 2>/dev/null)]" "$(wd_error_of "$tmp/err" "$rc")")
    fi
    body="$body$(printf '%s\n' "$out" | grep -v '^@@')"$'\n\n'
    line=$(printf '%s\n' "$out" | grep '^@@WD ' | tail -1)
    set -- $line
    n=$((n + 1)); a=$((a + ${2:-0})); b=$((b + ${3:-0}))
  done <<EOF
$( { printf '['; gate_pending_approvals_json 2>/dev/null; printf ']'; } | jq -c '.[]' 2>/dev/null)
EOF
  # Halt records, by relative path in byte order.
  if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
    rundir_gone=1
  else
    ( wd_pointer_texts ) > "$ptrf" 2>/dev/null || true
    list=$(wd_record_paths | LC_ALL=C sort)
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      rc=0
      out=$(wd_one_halt "$RUN_DIR/$rel" "$rel" "$ptrf" 2>"$tmp/err") || rc=$?
      if [ "$rc" != "0" ] || [ -z "$out" ]; then
        out=$(wd_failure_block "[정지 기록 $rel]" "$(wd_error_of "$tmp/err" "$rc")")
      fi
      case "$out" in
        '@@SKIP nofence'*) nofence=$((nofence + 1)); continue ;;
        '@@SKIP noopt'*) noopt=$((noopt + 1)); continue ;;
        '@@SKIP seatrun'*) seatrun=$((seatrun + 1)); continue ;;
        '@@SKIP unpointed'*) unpointed=$((unpointed + 1)); continue ;;
        '@@SKIP'*) continue ;;
      esac
      body="$body$(printf '%s\n' "$out" | grep -v '^@@')"$'\n\n'
      line=$(printf '%s\n' "$out" | grep '^@@WD ' | tail -1)
      set -- $line
      n=$((n + 1)); a=$((a + ${2:-0})); b=$((b + ${3:-0}))
    done <<EOF
$list
EOF
  fi
  rm -rf "$tmp"
  if [ "$n" = "0" ]; then
    printf '기다리는 결정 없음\n'
  else
    printf '기다리는 결정 %s건 — 추천 미기재 %s건 · 리스크 미기재 %s건\n\n' "$n" "$a" "$b"
    printf '%s' "$body" | sed '$d'
  fi
  [ "$rundir_gone" = "0" ] || printf '런 디렉터리가 회수돼 정지 기록을 읽지 못했습니다\n'
  [ "$seatrun" = "0" ] || printf '다음 좌석 실행이 직접 실행할 정지 %s건\n' "$seatrun"
  [ "$unpointed" = "0" ] || printf '좌석이 이번 런에서 가리키지 않은 정지 기록 %s건\n' "$unpointed"
  [ "$noopt" = "0" ] || printf '선택지가 없는 정지 기록 %s건\n' "$noopt"
  [ "$nofence" = "0" ] || printf '닫는 펜스가 없는 기록 %s건\n' "$nofence"
  return 0
}

# ---------------------------------------------------------------------------
# Entry.
# ---------------------------------------------------------------------------
wd_report() {
  local manifest="$1" ledger="$2" run_id="$3" hdr ow base rundir rc=0
  command -v jq >/dev/null 2>&1 || wd_die 'jq 가 없어 게이트 판정을 읽지 못합니다'
  [ -f "$ledger" ] && [ -r "$ledger" ] || wd_die "원장을 읽지 못했습니다: $ledger"
  [ -f "$manifest" ] && [ -r "$manifest" ] || wd_die "매니페스트를 읽지 못했습니다: $manifest"
  # The base, as the driver derives it from the manifest header.
  hdr=$(sed -n '2,8p' "$manifest" | tr '\n' ' ')
  ow=$(printf '%s' "$hdr" | sed -n 's/.*[; ]origin-worktree=\([^;]*\).*/\1/p' | sed -e 's/[[:space:]]*-->.*$//' -e 's/[[:space:]]*$//')
  [ -n "$ow" ] || ow=$(git rev-parse --show-toplevel 2>/dev/null) || wd_die "매니페스트 머리에 origin-worktree 가 없습니다: $manifest"
  base=$(cd "$ow" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && base=$(dirname "$base") || base=$ow
  rundir=$(grep '^- `run` ' "$ledger" 2>/dev/null | tr '|' '\n' | sed -n 's/^ *RUN_DIR=//p' | sed 's/[[:space:]]*$//' | tail -1)
  # THE ONE PLACE THE GATE IS SOURCED, definitions only, inside a subshell.
  (
    CC_GATE_SOURCE_ONLY=1 . "$WD_SELF_DIR/gate.sh" </dev/null >/dev/null 2>&1 || exit 3
    set +e
    unset CC_GATE_SOURCE_ONLY CC_ORCH_SOURCE_ONLY
    MANIFEST=$manifest; RUN_ID=$run_id; RUN_DIR=$rundir; LEDGER=$ledger
    BASE=$base; GRANT="$base/docs/pipeline-grant/$run_id.md"
    wd_render
  ) || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) wd_die "게이트를 들여오지 못했습니다: $WD_SELF_DIR/gate.sh" ;;
    *) wd_die "기다리는 결정을 렌더하지 못했습니다 (종료 코드 $rc)" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -ne 4 ] || [ "$1" != "report" ]; then
    printf 'usage: waiting-decisions.sh report <manifest> <ledger> <run-id>\n' >&2
    exit 2
  fi
  shift
  wd_report "$@"
fi
