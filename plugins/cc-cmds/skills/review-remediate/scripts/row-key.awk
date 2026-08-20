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
#
# 종료 코드는 사유별로 갈린다 — 둘을 합치면 「테이프가 없다」와 「조인이 어긋났다」가
# 구별되지 않아 진단 해상도가 이 검사가 존재하는 이유인 바로 그 자리에서 낮아진다.
#   0  정상
#   3  빈 테이프 (1패스가 레코드를 한 건도 읽지 못함)
#   4  조인 불일치 (테이프 FIND 레코드 수 != 발행된 키 수)
#   5  비-테이프 첫 인자 (레코드는 있으나 테이프 레코드가 하나도 없음)
#
# 두 팔의 피연산자가 다르다 — 3은 **모든 레코드**를 세고 4는 **FIND 레코드**만
# 센다. 폐쇄 근거 둘: (1) 키를 만드는 것은 FIND 레코드뿐이므로 레코드-대-키
# 등호는 애초에 성립하지 않는다(발견 0건 리포트의 테이프에도 DECL·FILE
# 레코드가 있다). (2) 등호의 양변은 서로 다른 패스에서 나온다 — 좌변은 1패스가
# 테이프를 읽으며 세고 우변은 2패스가 키를 발행하며 센다. 한 패스가 양변을
# 계산하면 그 검사는 분석적이 되어 어떤 입력도 그것을 깨지 못한다.

BEGIN {
    # 탭 고정 — 기본 구분자는 경로에 공백이 있으면 테이프의 파일 필드를 쪼갠다.
    # 2패스는 필드를 하나도 읽지 않으므로($0만 쓴다) 이 변경은 2패스에 무해하다.
    FS = "\t"

    # 패스 분할은 인자 위치로 한다 — 테이프는 언제나 첫 인자다.
    #   `NR == FNR`는 테이프가 비면 첫 리포트를 통째로 테이프로 삼킨다.
    #   레코드를 세는 파일 카운터도 같은 구멍을 갖는다 — 레코드가 0건인 파일은
    #   어떤 규칙도 발화시키지 않아 카운터가 오르지 않고, 다음 파일이 그 자리를
    #   차지한다. 인자 자체를 잡아야 빈 테이프가 실제로 빈 테이프로 보인다.
    tapefile = ARGV[1]
}

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

FILENAME == tapefile {
    # 레코드를 센다 — FIND만 세면 진짜 발견 0건 리포트(DECL·FILE 레코드는 있고
    # FIND만 없는 테이프)에서 가드가 위양성을 낸다. 「테이프가 비었다」는
    # 레코드가 하나도 없다는 뜻이지 발견이 없다는 뜻이 아니다.
    tape_records++

    # 「비어 있음」과 「테이프임」은 다른 술어다. 비어 있음만 보면 첫 인자에
    # 리포트를 주는 실수가 exit 0·키 0행·stderr 0바이트로 되돌아온다 — 인자를
    # 뒤바꾼 것뿐인데 증상이 수리 이전과 바이트 단위로 같다.
    if ($1 == "FIND" || $1 == "FLAG" || $1 == "DECL" || $1 == "FILE") {
        tape_recognized++
    } else {
        tape_unrecognized++
        if (first_bad_line == 0) { first_bad_line = FNR; first_bad = $0 }
    }

    if ($1 == "FIND") {
        k = $2 "\t" $3
        tape[k] = 1
        tband[k] = $5
        tsub[k] = $6
        n_tape[$2]++
        tape_finds++
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
        keys_emitted++
        n_key[f]++
    }

    # 빈 테이프 가드 — 조인 수리를 전부 넣어도 이것 없이는 빈 테이프에서
    # 종료 코드 0·키 0행·stderr 0바이트로 조용히 통과한다. 정합 검사는 빈
    # 배열을 0회 순회하므로 발화하지 못한다.
    if (tape_records == 0) {
        print "row-key: 빈 테이프 — 첫 인자에서 레코드를 한 건도 읽지 못했다" > "/dev/stderr"
        exit 3
    }

    # 비-테이프 첫 인자 가드 — 레코드는 있으나 테이프 레코드가 하나도 없다.
    # 옛 메시지를 빌려 쓰지 않는다: 「비어 있다」와 「테이프가 아니다」는 서로
    # 다른 사고이고, 빌려 쓰면 탐지는 생기고 귀속은 생기지 않는다.
    # 진단 성분 둘을 함께 낸다 — 개수와 첫 인자 경로가 없으면 운영자가 엉뚱한
    # 파일을 들여다보고, 첫 줄이 축자로 없으면 리포트를 준 것인지 다른 테이프를
    # 준 것인지 구별하지 못한다.
    if (tape_recognized == 0) {
        printf "row-key: 첫 인자가 테이프가 아니다 — 인식되지 않은 줄 %d개, 첫 인자: %s\n", \
            tape_unrecognized + 0, tapefile > "/dev/stderr"
        printf "row-key:   인식되지 않은 첫 줄 (%s:%d): %s\n", \
            tapefile, first_bad_line + 0, first_bad > "/dev/stderr"
        exit 5
    }

    # 정합 검사 — 등호를 요구한다. 테이프와 키의 쌍에는 열화가 허용되지 않으므로
    # 부등호로 두면 조인이 어긋나 키가 한 행도 나오지 않아도 참이 된다.
    if (keys_emitted + 0 != tape_finds + 0) {
        printf "row-key: 조인 불일치 — 테이프 FIND %d, 발행된 키 %d\n", \
            tape_finds + 0, keys_emitted + 0 > "/dev/stderr"
        # 파일별 귀속 — 총계 둘만 찍으면 다중 파일 입력에서 일부만 어긋났을 때
        # 어느 파일인지 말하지 않는다. 계측만 하고 읽지 않던 배열이 여기 붙는다.
        # awk 배열 순회 순서는 비결정적이므로 상위 N만 인쇄하는 형태를 쓰지
        # 않는다 — 잘라내면 매 실행마다 다른 파일이 보고된다.
        for (tf in n_tape)
            if ((n_tape[tf] + 0) != (n_key[tf] + 0))
                printf "row-key:   어긋난 파일: %s 테이프 %d, 키 %d\n", \
                    tf, n_tape[tf] + 0, n_key[tf] + 0 > "/dev/stderr"
        for (kf in n_key)
            if (!(kf in n_tape))
                printf "row-key:   어긋난 파일: %s 테이프 0, 키 %d\n", \
                    kf, n_key[kf] + 0 > "/dev/stderr"
        exit 4
    }
}
