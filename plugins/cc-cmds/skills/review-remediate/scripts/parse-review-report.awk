# 리뷰 리포트 분절기 — 비대칭 레벨 선택자
#
# SKILL.md `### Step 2: 리포트 파싱`의 규약을 그대로 구현한다. 산문과 이 파일이
# 어긋나면 SKILL.md가 이긴다.
#
# 실행: LC_ALL=C awk -f parse-review-report.awk <파일...>
#   (LC_ALL은 명령행에 붙이고 export하지 않는다 — 서브셸에서 잃지 않기 위해서다)
#
# 산출 (TSV, 한 줄 한 레코드):
#   FIND  <파일> <시작 줄> <종류> <대역> <서브헤딩 줄|->
#   FLAG  <파일> <종류> <상세>            종류 ∈ {ZEROCAND, AMBIG, DROP, EMPTYSUB, TABLE}
#   DECL  <파일> <P0> <P1> <P2> <P3>      미진술 대역은 `-` (0이 아니다)
#   FILE  <파일> <심각도 섹션 수> <발견 수> <하드스톱 사유|->
#
# perl · grep -P · sed 를 쓰지 않는다.

function reset_file() {
    fence = 0
    sev = -1
    sec_idx = 0
    sub_line = 0
    sub_found = 0
    sub_content = 0
    sub_bracket = 0
    sub_tablerow = 0
    ord = 0
    gn = 0
    gbracket = 0
    n_finds = 0
    sec_finds = 0
    sec_cand = 0
    sec_content = 0
    declared_seen = 0
    hardstop = ""
    for (i = 0; i <= 3; i++) { decl[i] = -1; band_finds[i] = 0 }
}

# 심각도 이모지 출현 횟수 (네 종 합계)
function emoji_count(s,   t, c) {
    c = 0
    t = s; c += gsub(/\xf0\x9f\x94\xb4/, "", t)
    t = s; c += gsub(/\xf0\x9f\x9f\xa0/, "", t)
    t = s; c += gsub(/\xf0\x9f\x9f\xa1/, "", t)
    t = s; c += gsub(/\xf0\x9f\x9f\xa2/, "", t)
    return c
}

function emoji_band(s) {
    if (index(s, "\xf0\x9f\x94\xb4")) return 0
    if (index(s, "\xf0\x9f\x9f\xa0")) return 1
    if (index(s, "\xf0\x9f\x9f\xa1")) return 2
    if (index(s, "\xf0\x9f\x9f\xa2")) return 3
    return -1
}

# 경계 어휘 B — 열 0의 서브헤딩 / 리스트 마커 / 서수
function is_boundary(s) {
    return (s ~ /^#{3,6} /) || (s ~ /^[-*+] /) || (s ~ /^[0-9]+[.)] /)
}

# 열 0 리스트 항목 (그룹 구성원)
function is_listitem(s) {
    return (s ~ /^[-*+] /) || (s ~ /^[0-9]+[.)] /)
}

# 후보 어휘 C \ B — 정지 술어가 세는 추가 형태
function is_extra_candidate(s) {
    return (s ~ /^\|/) ||
           (s ~ /^>[ \t]*[-*+][ \t]/) ||
           (s ~ /^\*\*\[/) ||
           (s ~ /^[ \t]+[-*+][ \t]*\*\*\[/)
}

function is_col0_prose(s) {
    if (s ~ /^[ \t]*$/) return 0
    if (s ~ /^[ \t]/) return 0
    if (is_boundary(s)) return 0
    if (s ~ /^#{1,2} /) return 0
    return 1
}

function emit_find(ln, kind,   sh) {
    sh = (sub_line > 0 ? sub_line : "-")
    ord++
    printf "FIND\t%s\t%d\t%s\t%d\t%s\n", file, ln, kind, sev, sh
    n_finds++
    sec_finds++
    band_finds[sev]++
    sub_found = 1
}

# 그룹 종료 — 비대칭 레벨 선택자
function close_group(   i) {
    if (gn == 0) return
    if (gbracket > 0) {
        # 규칙 1 — 대괄호볼드 항목만 발견, 나머지는 DROP
        for (i = 1; i <= gn; i++) {
            if (gb[i]) emit_find(gl[i], "bullet")
            else printf "FLAG\t%s\tDROP\t%d\n", file, gl[i]
        }
    } else if (sub_line > 0) {
        # 규칙 2 — 서브트리 안이면 그룹 전체가 본문
    } else {
        # 규칙 2 — 섹션 최상위면 그룹 전체가 발견
        for (i = 1; i <= gn; i++) emit_find(gl[i], "bullet")
    }
    gn = 0
    gbracket = 0
}

# 서브트리 종료 — 규칙 3·4
function close_subtree() {
    if (sub_line == 0) return
    if (!sub_found) {
        if (sub_content) {
            # TABLE — 잎 서브헤딩 본문에 발견 형태의 표 행이 있고 열 0 불릿이 0개.
            # 첫 칸이 리포트 선언 ID인 행만 센다: 임의의 표는 발견 표가 아니다.
            if (sub_tablerow && sub_bracket == 0)
                printf "FLAG\t%s\tTABLE\t%d\t%d\n", file, sub_line, sub_tablerow
            # 규칙 3 — 서브헤딩 줄이 발견이다
            ord++
            printf "FIND\t%s\t%d\t%s\t%d\t%s\n", file, sub_line, "subhead", sev, "-"
            n_finds++
            sec_finds++
            band_finds[sev]++
        } else {
            # 규칙 4
            printf "FLAG\t%s\tEMPTYSUB\t%d\n", file, sub_line
        }
    }
    sub_line = 0
    sub_found = 0
    sub_content = 0
    sub_bracket = 0
    sub_tablerow = 0
}

function close_section() {
    close_group()
    close_subtree()
    if (sev >= 0) {
        # 섹션 단위 파싱 실패 가드 — 후보 ≥1 ∧ 파싱 0건 → 정지.
        # 「fail closed」라 이름 붙이지 않는다: 코퍼스에서 발화가 0건이다.
        if (sec_cand >= 1 && sec_finds == 0)
            hardstop = "SECTION-GUARD:" sec_head_line
        # ZEROCAND — 후보가 0개인 섹션. 정지가 아니라 3지 에스컬레이션의 트리거다.
        else if (sec_cand == 0 && sec_content)
            printf "FLAG\t%s\tZEROCAND\t%d\n", file, sec_head_line
    }
    sev = -1
    sec_finds = 0
    sec_cand = 0
    sec_content = 0
}

function emit_file(   i, a2, decls) {
    close_section()
    if (fence) hardstop = "EOF-FENCE-OPEN"

    decls = ""
    for (i = 0; i <= 3; i++) decls = decls "\t" (decl[i] >= 0 ? decl[i] : "-")
    printf "DECL\t%s%s\n", file, decls

    # A1과 A2는 서로 배타적이지 않다 — 둘 다 독립으로 평가하고 둘 다 인쇄한다.
    # 배타로 만들면 두 장치가 겹치는 파일이 한쪽에서만 세어져 발화 수가 조용히 줄고,
    # 「어느 하나도 단독으로는 조용한 0건을 다 덮지 못한다」는 근거를 검사할 수 없게 된다.
    a1 = ""
    if (sec_idx == 0) {
        if (!declared_seen) a1 = "A1-NO-SECTION-NO-DECL"
        else for (i = 0; i <= 3; i++) if (decl[i] > 0) { a1 = "A1-NO-SECTION-DECL-POSITIVE"; break }
    }
    a2 = ""
    for (i = 0; i <= 3; i++) if (decl[i] > 0 && band_finds[i] == 0) a2 = a2 (a2 == "" ? "" : ",") "P" i
    if (a2 != "") a2 = "A2-BAND-ABSENT:" a2

    stops = hardstop
    if (a1 != "") stops = stops (stops == "" ? "" : ";") a1
    if (a2 != "") stops = stops (stops == "" ? "" : ";") a2
    printf "FILE\t%s\t%d\t%d\t%s\n", file, sec_idx, n_finds, (stops == "" ? "-" : stops)
}

FNR == 1 {
    if (NR > 1) emit_file()
    file = FILENAME
    reset_file()
}

# 펜스 — 열 0에 고정하지 않는다. 펜스 줄과 그 안의 모든 줄은 경계 판정에서 제외
/^[ \t>]*```/ { fence = !fence; next }
fence { if (sev >= 0 && sub_line > 0) sub_content = 1; next }

# 발견 요약 — 첫 줄만, 대역별 첫 매치
!declared_seen && /발견 요약/ {
    declared_seen = 1
    for (i = 0; i <= 3; i++) {
        if (match($0, "P" i "[ ]*[0-9]+[ ]*건")) {
            tok = substr($0, RSTART, RLENGTH)
            sub("^P" i "[ ]*", "", tok)
            sub("[ ]*건$", "", tok)
            decl[i] = tok + 0
        }
    }
}

# 섹션 상태 리셋은 ^## 에서만
/^## / {
    close_section()
    if (emoji_count($0) == 1 && $0 ~ /P[0-3]/) {
        sev = emoji_band($0)
        sec_idx++
        sec_head_line = FNR
        ord = 0
    } else if (emoji_count($0) >= 2) {
        printf "FLAG\t%s\tAMBIG\t%d\n", file, FNR
    }
    next
}

sev < 0 { next }

# 서브헤딩 — 그룹과 이전 서브트리를 끊는다
/^#{3,6} / {
    close_group()
    close_subtree()
    sub_line = FNR
    next
}

{
    if ($0 !~ /^[ \t]*$/) sec_content = 1
    if (is_extra_candidate($0) || is_listitem($0)) sec_cand++

    if (is_listitem($0)) {
        gn++
        gl[gn] = FNR
        gb[gn] = ($0 ~ /^[-*+] \*\*\[/) ? 1 : 0
        if (gb[gn]) { gbracket++; if (sub_line > 0) sub_bracket++ }
        if (sub_line > 0) sub_content = 1
        next
    }

    # 빈 줄과 들여쓴 줄은 그룹을 끊지 않는다
    if ($0 ~ /^[ \t]*$/) next
    if ($0 ~ /^[ \t]/) { if (sub_line > 0) sub_content = 1; next }

    # 열 0 산문 — 그룹을 끊는다
    if (is_col0_prose($0)) {
        close_group()
        if (sub_line > 0) {
            sub_content = 1
            # 발견 형태의 표 행만 센다 — 첫 칸이 리포트 선언 ID인 행
            if ($0 ~ /^\|[ \t]*\**[ \t]*P[0-3][-_][0-9]/) sub_tablerow++
        }
    }
}

END { if (NR > 0) emit_file() }
