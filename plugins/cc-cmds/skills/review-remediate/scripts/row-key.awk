# 행 키 저작 — SKILL.md `### Step 3: 키 저작과 프로비넌스 태그`의 구현
#
# 실행: LC_ALL=C awk -f row-key.awk <테이프> <리포트...>
#   테이프는 parse-review-report.awk 의 산출이며 첫 인자로 준다.
#
# 산출: KEY <파일> <시작 줄> <행 키 재료>
#   행 키 재료 = band | cats | path | line | s<si>.<ord> | desc64 | subhead64
#   sha1은 이 재료의 순수 함수이므로 충돌 계수에는 해시가 필요 없다 — 재료가
#   같으면 해시도 같고, 재료가 다르면 해시 충돌 확률은 무시 가능하다.
#
# perl · grep -P · sed 를 쓰지 않는다.

# ---- desc64 접두 문법 (형태-무관) ------------------------------------------

function strip_emph(s) {
    while (s ~ /^(\*\*|__|~~)/) sub(/^(\*\*|__|~~)/, "", s)
    return s
}

function strip_emoji(s,   before) {
    do {
        before = s
        sub(/^\xf0\x9f\x94\xb4[ \t]*/, "", s)
        sub(/^\xf0\x9f\x9f\xa0[ \t]*/, "", s)
        sub(/^\xf0\x9f\x9f\xa1[ \t]*/, "", s)
        sub(/^\xf0\x9f\x9f\xa2[ \t]*/, "", s)
        sub(/^\xe2\x9c\x85[ \t]*/, "", s)
        sub(/^\xe2\x9d\x8c[ \t]*/, "", s)
        sub(/^\xe2\x9a\xa0[\xef\xb8\x8f]*[ \t]*/, "", s)
        sub(/^\xf0\x9f\x92\xa1[ \t]*/, "", s)
    } while (s != before)
    return s
}

function strip_cats(s) {
    while (s ~ /^\[[^]]{1,40}\][ \t]*/) sub(/^\[[^]]{1,40}\][ \t]*/, "", s)
    return s
}

# 리포트 선언 ID 토큰 — 뒤에 . ) : ] 또는 공백이 올 때만
function strip_declid(s,   before) {
    before = s
    sub(/^P[0-3][-_][0-9]{1,3}[a-z]?([.):\]]|[ \t])/, "", s)
    if (s != before) return s
    sub(/^P[0-3][-_][a-z]{1,2}([.):\]]|[ \t])/, "", s)
    if (s != before) return s
    sub(/^[A-Z]{1,4}[-_]?[0-9]{1,3}[a-z]?([.):\]]|[ \t])/, "", s)
    if (s != before) return s
    sub(/^P[0-3]([.):\]]|[ \t])/, "", s)
    return s
}

# 5. 롤백 있는 위치 런
#   백틱 경로 토큰의 런을 접미사·괄호·결합자와 함께 제거하되,
#   닫는 백틱에 단어나 한글이 붙어 있으면 런 전체를 되돌린다.
function strip_locrun(s,   work, progressed, tail) {
    work = s
    progressed = 0
    while (work ~ /^`[^`]+`/) {
        # 닫는 백틱 직후가 단어·한글이면 그 토큰은 경로가 아니라 산문이다 → 롤백
        tail = work
        sub(/^`[^`]+`/, "", tail)
        if (tail ~ /^[A-Za-z0-9_\xea-\xed]/) return s
        work = tail
        progressed = 1
        sub(/^(:[0-9]+(-[0-9]+)?|,[0-9]+)+/, "", work)
        sub(/^[ \t]*[()]+[ \t]*/, "", work)
        sub(/^[ \t]*(,|\/|\xc2\xb7|\+|\xeb\xb0\x8f|and|vs|\xe2\x86\x94|\xe2\x86\x92|~)[ \t]*/, "", work)
    }
    if (!progressed) return s
    # 런은 구분자·공백·줄 끝에서 끝날 때만 확정한다
    if (work == "" || work ~ /^([ \t]|\xe2\x80\x94|\xe2\x80\x93|-|:|\xc2\xb7)/) return work
    return s
}

function desc64(s,   before) {
    do {
        before = s
        s = strip_emph(s)
        s = strip_emoji(s)
        s = strip_cats(s)
        s = strip_declid(s)
        sub(/^[ \t]+/, "", s)
    } while (s != before)
    s = strip_locrun(s)
    sub(/^[ \t]*(\xe2\x80\x94|\xe2\x80\x93|-|:|\xc2\xb7)[ \t]*/, "", s)
    gsub(/\*\*|__|`/, "", s)
    gsub(/[ \t]+/, " ", s)
    sub(/^ /, "", s); sub(/ $/, "", s)
    return substr(s, 1, 64)
}

# ---- 필드 추출 -------------------------------------------------------------

function head_text(s) {
    sub(/^[-*+][ \t]+/, "", s)
    sub(/^[0-9]+[.)][ \t]+/, "", s)
    sub(/^#{3,6}[ \t]+/, "", s)
    return s
}

# 누적 함수 — 호출자가 ncat/catseen/catlist를 블록마다 한 번만 리셋한다.
# 호출마다 카운터를 리셋하면 마지막 호출의 것만 남아 헤드의 카테고리가 사라진다.
function collect_cats(s,   t, c) {
    t = s
    while (match(t, /\[[^]]{1,40}\]/)) {
        c = substr(t, RSTART + 1, RLENGTH - 2)
        t = substr(t, RSTART + RLENGTH)
        gsub(/[ \t]+/, "", c)
        c = tolower(c)
        if (c != "" && !(c in catseen)) { catseen[c] = 1; ncat++; catlist[ncat] = c }
    }
}

# 경로 형태 백틱 토큰 — 슬래시 또는 확장자를 가진 것
function find_path(s,   t, tok) {
    t = s
    while (match(t, /`[^`]+`/)) {
        tok = substr(t, RSTART + 1, RLENGTH - 2)
        t = substr(t, RSTART + RLENGTH)
        if (tok ~ /\// || tok ~ /\.[A-Za-z0-9]{1,6}(:|$|#)/) {
            sub(/^\.\//, "", tok)
            return tok
        }
    }
    return ""
}

function split_pathline(tok) {
    curline = "NULL"
    if (match(tok, /:[0-9]+(-[0-9]+)?$/)) {
        curline = substr(tok, RSTART + 1)
        tok = substr(tok, 1, RSTART - 1)
    }
    sub(/#.*$/, "", tok)
    sub(/:$/, "", tok)
    return tok
}

# ---- 1패스: 테이프 읽기 ----------------------------------------------------

NR == FNR {
    if ($1 == "FIND") {
        k = $2 "\t" $3
        tape[k] = 1
        tband[k] = $5
        tsub[k] = $6
        n_tape[$2]++
    }
    next
}

# ---- 2패스: 리포트 읽기 ----------------------------------------------------

FNR == 1 { seci = 0; ordn = 0; curblock = "" }

/^## / {
    if (emoji_ok($0)) { seci++; ordn = 0 }
    curblock = ""
    next
}

# 서브헤딩 텍스트는 subhead64가 소비하므로 보관한다. next 하지 않는다 —
# 서브헤딩 줄 자체가 발견일 수 있고(레벨 선택자 규칙 3) 그 판정은 테이프가 갖는다.
/^#{3,6} / { subheadtext[FILENAME "\t" FNR] = $0 }

{
    key = FILENAME "\t" FNR
    if (key in tape) {
        ordn++
        headline[key] = $0
        pending[key] = 1
        pend_ord[key] = seci "." ordn
        bodyn[key] = 0
        curblock = key
        next
    }
    if ($0 ~ /^#{3,6} /) { curblock = ""; next }
    if (curblock != "" && bodyn[curblock] < 8) {
        bodyn[curblock]++
        body[curblock, bodyn[curblock]] = $0
    }
}

function emoji_ok(s,   c, t) {
    c = 0
    t = s; c += gsub(/\xf0\x9f\x94\xb4/, "", t)
    t = s; c += gsub(/\xf0\x9f\x9f\xa0/, "", t)
    t = s; c += gsub(/\xf0\x9f\x9f\xa1/, "", t)
    t = s; c += gsub(/\xf0\x9f\x9f\xa2/, "", t)
    return (c == 1 && s ~ /P[0-3]/)
}

END {
    for (k in pending) {
        split(k, a, "\t")
        f = a[1]; ln = a[2]
        h = head_text(headline[k])

        delete catseen; delete catlist; ncat = 0
        collect_cats(h)
        for (i = 1; i <= bodyn[k]; i++) collect_cats(body[k, i])
        n = ncat
        # 정렬 (삽입 정렬 — 집합이므로 순서가 값의 일부다)
        for (i = 2; i <= n; i++) { v = catlist[i]; j = i - 1
            while (j >= 1 && catlist[j] > v) { catlist[j+1] = catlist[j]; j-- }
            catlist[j+1] = v }
        cats = ""
        for (i = 1; i <= n; i++) cats = cats (i == 1 ? "" : ",") catlist[i]

        p = find_path(h)
        if (p == "") for (i = 1; i <= bodyn[k] && p == ""; i++) p = find_path(body[k, i])
        curline = "NULL"
        p = (p == "" ? "NULL" : split_pathline(p))

        sh = tsub[k]
        sh64 = (sh == "-" ? "" : desc64(head_text(subheadtext[f "\t" sh])))

        printf "KEY\t%s\t%s\t%s|%s|%s|%s|s%s|%s|%s\n", \
            f, ln, tband[k], cats, p, curline, pend_ord[k], desc64(h), sh64
    }
}
