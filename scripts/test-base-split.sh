#!/usr/bin/env bash
# Test the base design split tool (`plugins/cc-cmds/orchestrator/base-split.py`)
# offline: its predicates (`check`), its publication plan (`plan`) and its
# registry writer (`record`).
#
# Fixture documents are generated into one `mktemp -d` directory, under a
# `docs/` path component that exists only there. No tracker is reached — `plan`
# only prints argvs, and nothing here runs them.
#
# Usage: bash scripts/test-base-split.sh

set -euo pipefail

# Inherited pipeline variables change nothing in this tool, but a stage that
# runs this suite should see the same environment CI sees.
for v in $(compgen -v CC_PIPELINE_); do unset "$v"; done

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
BS="$ORCH/base-split.py"

# Normalised, so a TMPDIR with a trailing slash does not put `//` into the
# expected argvs while the tool prints its absolute path.
WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cc-base-split-test.XXXXXX")" && pwd)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
fail=0
ok()    { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { fail=$((fail + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
has() {
  if grep -qF -- "$3" <<EOF
$2
EOF
  then ok "$1"; else bad "$1" "missing '$3' in: $2"; fi
}
hasnt() {
  if grep -qF -- "$3" <<EOF
$2
EOF
  then bad "$1" "unexpected '$3' in: $2"; else ok "$1"; fi
}

[ -x "$BS" ] && ok "base-split.py is executable" || bad "base-split.py is executable"

# ---------------------------------------------------------------------------
# Fixture generator: `gen.py <variant> <path>` writes one base design document.
# The passing shape is three tickets — T1 (구현, independent), T2 (계약,
# provides C1) and T3 (구현, consumes C1 after T2) — so the first layer holds a
# contract ticket numbered after an implementation ticket.
# ---------------------------------------------------------------------------
cat > "$WORK/gen.py" <<'PYEOF'
import sys

variant, out = sys.argv[1], sys.argv[2]
# Each ticket's body names its own piece, so a body written to another
# ticket's file is caught.
BODY = "이 작업은 상태 파일의 %d번 조각을 정한다.\n완료 기준: 상태 파일은 이름과 크기 두 필드를 가진다.\n"

def ticket(n, kind, deps=(), provides=(), consumes=(), owned=("src/t%d/main.py",),
           shared=(), nesting=None, repo="o/r", body=None):
    return dict(n=n, kind=kind, deps=list(deps), provides=list(provides),
                consumes=list(consumes), owned=[p % n if "%d" in p else p for p in owned],
                shared=list(shared), nesting=nesting, repo=repo,
                body=BODY % n if body is None else body, fence=None, owned_raw=None,
                lines={})

header = {"티켓 수": "3", "임계 경로": "T2 → T3", "병렬 폭": "2"}
contracts = [dict(n=1, providers=["T2"], consumers=["T3"], lines={})]
tickets = [ticket(1, "구현"), ticket(2, "계약", provides=["C1"]),
           ticket(3, "구현", deps=["T2"], consumes=["C1"])]
kind_line, split_heading, slicing = True, True, False
base_body = "여러 저장 단위를 하나의 상태 파일로 묶는다.\n계약을 먼저 정하고 구현을 나란히 진행한다.\n"

if variant == "cycle":
    tickets[1]["deps"] = ["T3"]
elif variant == "unresolved":
    tickets[2]["deps"] = ["T2", "T9"]
elif variant == "count":
    header["티켓 수"] = "4"
elif variant == "twoprov":
    contracts[0]["providers"] = ["T1", "T2"]
    tickets[0]["provides"] = ["C1"]
elif variant == "many":
    tickets = [ticket(i, "구현") for i in range(1, 102)]
    contracts = []
    header = {"티켓 수": "101", "임계 경로": "T1", "병렬 폭": "101"}
elif variant == "parloss":
    tickets[2]["deps"] = ["T1", "T2"]
elif variant == "conc":
    tickets[0]["owned"] = ["src/shared/x.py"]
    tickets[1]["owned"] = ["src/shared/x.py"]
elif variant == "globpos":
    tickets[0]["owned"] = ["src/lib/*.py"]
    tickets[1]["owned"] = ["src/lib/core.py"]
elif variant == "globneg":
    tickets[0]["owned"] = ["src/lib/*.py"]
    tickets[1]["owned"] = ["src/app/core.py"]
elif variant == "bracepos":
    tickets[0]["owned"] = ["src/{a,b}.py"]
    tickets[1]["owned"] = ["src/a.py"]
elif variant == "classlit":
    # Written as a class, the entry still meets the file the class matches.
    tickets[0]["owned"] = ["src/[a,b].py"]
    tickets[1]["owned"] = ["src/a.py"]
elif variant == "classboth":
    # The comma inside the brackets must not split the entry: both tickets
    # own the whole `src/[a,b].py`, not the fragments `src/[a` and `b].py`.
    tickets[0]["owned"] = ["src/[a,b].py"]
    tickets[1]["owned"] = ["src/[a,b].py"]
elif variant == "openbracket":
    tickets[0]["owned_raw"] = "`src/[a,b.py`, `src/t2/main.py`"
elif variant == "mirrordir":
    # The narrow entry on T1 and the broad one on T2: overlap is symmetric.
    tickets[0]["owned"] = ["src/a/x.py"]
    tickets[1]["owned"] = ["src/a/"]
elif variant == "mirrorglob":
    tickets[0]["owned"] = ["src/lib/core.py"]
    tickets[1]["owned"] = ["src/lib/*.py"]
elif variant in ("sharedt2", "sharedboth"):
    # A shared list on either ticket exempts the pair.
    tickets[0]["owned"] = ["src/shared/x.py"]
    tickets[1]["owned"] = ["src/shared/x.py"]
    tickets[1]["shared"] = ["src/shared/x.py"]
    if variant == "sharedboth":
        tickets[0]["shared"] = ["src/shared/x.py"]
elif variant.startswith("sharedglob-"):
    # A shared glob that fixes no name covers every path: it is a whole
    # repository however it is spelled.
    tickets[0]["owned"] = ["src/shared/x.py"]
    tickets[1]["owned"] = ["src/shared/x.py"]
    tickets[0]["shared"] = [{"star": "*", "dstar": "**", "dstarstar": "**/*",
                             "rootstar": "/*", "qstar": "?*", "dotstar": "./*",
                             "lock": "*.lock", "py": "**/*.py"}[variant[len("sharedglob-"):]]]
elif variant == "barenote":
    tickets[0]["owned_raw"] = "src/t1/main.py (신규)"
elif variant in ("dotdot2", "dotdot3"):
    tickets[0]["owned"] = [".." if variant == "dotdot2" else "src/../.."]
elif variant == "routeneg":
    # A dynamic-route directory is a literal path, so it does not meet its
    # sibling under the same parent.
    tickets[0]["owned"] = ["app/[id]/page.tsx"]
    tickets[1]["owned"] = ["app/about/page.tsx"]
elif variant == "routepos":
    tickets[0]["owned"] = ["app/[id]/page.tsx"]
    tickets[1]["owned"] = ["app/[id]/page.tsx"]
elif variant == "routeglob":
    tickets[0]["owned"] = ["app/[id]/*"]
    tickets[1]["owned"] = ["app/[id]/page.tsx"]
elif variant == "routeshared":
    # The shared glob must read `[id]` literally to cover the owned path.
    tickets[0]["owned"] = ["app/[id]/page.tsx"]
    tickets[1]["owned"] = ["app/[id]/page.tsx"]
    tickets[0]["shared"] = ["app/[id]/*"]
elif variant in ("rootslash", "rootslash2"):
    tickets[0]["owned"] = ["/src/a.py" if variant == "rootslash" else "//src/a.py"]
    tickets[1]["owned"] = ["src/a.py"]
elif variant in ("padspan", "padspan2"):
    tickets[0]["owned_raw"] = "` src/t1/main.py`" if variant == "padspan" else "`src/t1/main.py `"
elif variant == "dotdot":
    tickets[0]["owned"] = ["src/../../x.py"]
elif variant == "annotated":
    tickets[0]["owned_raw"] = "`src/t1/main.py` (신규)"
elif variant == "spancomma":
    tickets[0]["owned_raw"] = "`src/a,b.py`, `lib/x.py`"
elif variant == "routegroup":
    # A route-group directory right after `/` is a path, not a note.
    tickets[0]["owned_raw"] = "`app/(auth)/login.tsx`, app/(shop)"
elif variant == "barebrace":
    # Without backticks the comma inside the braces must still not split.
    tickets[0]["owned_raw"] = "src/{a,b}.py, lib/x.py"
elif variant == "bareclose":
    # A closing bracket with nothing open is a path character; the comma
    # after it still splits the list.
    tickets[0]["owned_raw"] = "src/a].py, src/t2/main.py"
elif variant == "bracelist":
    tickets[0]["owned"] = ["src/{a,b}.py", "lib/x.py"]
    tickets[1]["owned"] = ["lib/x.py"]
elif variant == "braceneg":
    tickets[0]["owned"] = ["pkg/{a,b}.py"]
    tickets[1]["owned"] = ["lib/a.py"]
elif variant == "dirpos":
    tickets[0]["owned"] = ["src/a/"]
    tickets[1]["owned"] = ["src/a/x.py"]
elif variant == "dirneg":
    tickets[0]["owned"] = ["src/a/"]
    tickets[1]["owned"] = ["src/ab.py"]
elif variant == "dotpos":
    tickets[0]["owned"] = ["./src/a.py"]
    tickets[1]["owned"] = ["src/a.py"]
elif variant in ("wholerepo", "wholedot"):
    # `./` owns the whole repository, so it meets T2's file it does not name.
    tickets[0]["owned"] = ["./" if variant == "wholerepo" else "."]
elif variant == "sharedwhole":
    tickets[0]["owned"] = ["src/shared/x.py"]
    tickets[1]["owned"] = ["src/shared/x.py"]
    tickets[0]["shared"] = ["./"]
elif variant == "emptyspan":
    tickets[0]["owned"] = [""]
elif variant == "opentick":
    # The first span never closes, so the comma does not split the list.
    tickets[0]["owned_raw"] = "`src/a.py, `src/t2/main.py`"
elif variant == "openbrace":
    tickets[0]["owned_raw"] = "`src/{a,b.py`, `src/t2/main.py`"
elif variant == "shareddir":
    tickets[0]["owned"] = ["src/shared/x.py"]
    tickets[1]["owned"] = ["src/shared/x.py"]
    tickets[0]["shared"] = ["src/shared/"]
elif variant == "consumerside":
    contracts[0]["consumers"] = ["T3", "T1"]
elif variant == "fenceok":
    tickets[0]["fence"] = ["**선행**: T9", "### 티켓 T9 — 울타리 안", "**종류**: 없는 값"]
elif variant == "repodiff":
    tickets[0]["owned"] = ["src/shared/x.py"]
    tickets[1]["owned"] = ["src/shared/x.py"]
    tickets[0]["repo"] = "o/other"
elif variant == "sharedok":
    tickets[0]["owned"] = ["src/shared/x.py"]
    tickets[1]["owned"] = ["src/shared/x.py"]
    tickets[0]["shared"] = ["src/shared/x.py"]
elif variant == "critpath":
    header["임계 경로"] = "T1 → T3"
elif variant == "ownbullet":
    # Two concurrent tickets own one file through a bullet list under an
    # empty field line: read as an empty list it would hide the overlap.
    for t in tickets[:2]:
        t["lines"]["소유 파일"] = ["**소유 파일**:", "- `src/a.py`"]
elif variant == "ownbulletval":
    tickets[0]["lines"]["소유 파일"] = ["**소유 파일**: `src/t1/main.py`", "- `src/t2/main.py`"]
elif variant == "ownnone":
    tickets[0]["owned_raw"] = "없음"
elif variant in ("trailcomma", "emptyitem", "numbered", "blankbullet", "dupfield",
                 "onespan", "spannote", "semicolon", "gluednote", "spannotetight",
                 "widenote", "dashnote", "spansemi", "spantab"):
    # T2 owns the shared file; T1 holds it only in a spelling the field line
    # does not carry as its own entry, so a silent drop would hide the overlap.
    tickets[1]["owned"] = ["src/shared/x.py"]
    tickets[0]["lines"]["소유 파일"] = {
        "trailcomma": ["**소유 파일**: `src/t1/main.py`,", "`src/shared/x.py`"],
        "emptyitem": ["**소유 파일**: `src/t1/main.py`, , `src/shared/x.py`"],
        "numbered": ["**소유 파일**: `src/t1/main.py`", "1. `src/shared/x.py`"],
        "blankbullet": ["**소유 파일**: `src/t1/main.py`", "", "- `src/shared/x.py`"],
        "dupfield": ["**소유 파일**: `src/t1/main.py`", "**소유 파일**: `src/shared/x.py`"],
        "onespan": ["**소유 파일**: `src/shared/x.py, src/t1/main.py`"],
        "spannote": ["**소유 파일**: `src/shared/x.py (수정)`"],
        "semicolon": ["**소유 파일**: src/shared/x.py;src/t1/main.py"],
        "gluednote": ["**소유 파일**: src/shared/x.py(수정)"],
        "spannotetight": ["**소유 파일**: `src/shared/x.py(수정)`"],
        "widenote": ["**소유 파일**: `src/shared/x.py（수정）`"],
        "dashnote": ["**소유 파일**: `src/shared/x.py — 수정`"],
        "spansemi": ["**소유 파일**: `src/shared/x.py;src/t1/main.py`"],
        "spantab": ["**소유 파일**: `src/shared/x.py,\tsrc/t1/main.py`"],
    }[variant]
elif variant == "depempty":
    tickets[2]["lines"]["선행"] = ["**선행**: T2, "]
elif variant == "spacepath":
    # A path that holds a space is one entry when it sits in a code span.
    tickets[0]["owned_raw"] = "`src/a b.py`"
elif variant == "depbullet":
    tickets[2]["lines"]["선행"] = ["**선행**:", "- T2"]
elif variant == "consempty":
    contracts[0]["lines"]["소비 티켓"] = ["**소비 티켓**:"]
elif variant in ("repospan", "repocase"):
    tickets[0]["owned"] = ["src/shared/x.py"]
    tickets[1]["owned"] = ["src/shared/x.py"]
    tickets[0]["repo"] = "`o/r`" if variant == "repospan" else "O/R"
elif variant == "repoempty":
    tickets[0]["lines"]["레포"] = ["**레포**:"]
elif variant == "repobad":
    tickets[0]["repo"] = "o r"
elif variant in ("depth3", "depth3reason"):
    contracts.append(dict(n=2, providers=["T3"], consumers=["T4"], lines={}))
    tickets[2]["provides"] = ["C2"]
    tickets.append(ticket(4, "구현", deps=["T3"], consumes=["C2"]))
    header = {"티켓 수": "4", "임계 경로": "T2 → T3 → T4", "병렬 폭": "2"}
    if variant == "depth3reason":
        header["깊이 사유"] = "상태 파일 위에 색인이 놓이고 그 위에 화면이 놓인다."
elif variant == "d0kind":
    kind_line = False
elif variant == "d0slicing":
    slicing = True
elif variant == "b1docs":
    tickets[0]["body"] = "자세한 내용은 docs/x 를 본다.\n"
elif variant == "b1label":
    tickets[1]["body"] = "이 일은 T3 보다 먼저 끝난다.\n"
elif variant == "b1heading":
    base_body = "## 개요\n본문이다.\n"
elif variant != "ok":
    raise SystemExit("unknown variant " + variant)

def fields(lines, raw):
    """The field lines, each one whose key `raw` names swapped for its lines."""
    out = []
    for line in lines:
        key = line[2:line.index("**:")]
        out += raw.get(key, [line])
    return out

L = ["# 상태 파일 베이스", ""]
if kind_line:
    L.append("**문서 종류**: 베이스 설계")
L += ["**상태**: 초안", "", "## 합의된 아키텍처", "상태 파일과 그 위의 소비자.", "",
      "## 티켓 간 계약", ""]
for c in contracts:
    L += ["### 계약 C%d — 형식 %d" % (c["n"], c["n"])]
    L += fields(["**제공 티켓**: " + ", ".join(c["providers"]),
                 "**소비 티켓**: " + ", ".join(c["consumers"])], c["lines"])
    L += ["**형태**: 파일 형식", "**인터페이스**:", "````text", "name=<이름>", "### 울타리 안 표제는 표제가 아니다",
          "````", "**불변식**:", "- 필드는 둘이다.", ""]
if slicing:
    L += ["## 구현 슬라이싱", "없음", ""]
if split_heading:
    L += ["## 티켓 분할"] + ["**%s**: %s" % kv for kv in header.items()] + [""]
L += ["### 베이스 티켓", "**발행 제목**: 상태 파일 도입", "**발행 본문**:", "````text"]
L += base_body.rstrip("\n").split("\n") + ["````", ""]
for t in tickets:
    L.append("### 티켓 T%d — 조각 %d" % (t["n"], t["n"]))
    if t["fence"]:
        # Field and heading lines inside a fence, ahead of the real ones: read
        # as lines they would add a ticket and win the first-value rule.
        L += ["```text"] + t["fence"] + ["```"]
    L += fields(["**종류**: " + t["kind"], "**레포**: " + t["repo"],
                 "**선행**: " + (", ".join(t["deps"]) or "없음"),
                 "**제공 계약**: " + (", ".join(t["provides"]) or "없음"),
                 "**소비 계약**: " + (", ".join(t["consumes"]) or "없음"),
                 "**소유 파일**: " + (t["owned_raw"] or ", ".join("`%s`" % p for p in t["owned"])),
                 "**공유 파일**: " + (", ".join("`%s`" % p for p in t["shared"]) or "없음")],
                t["lines"])
    if t["nesting"]:
        L.append("**중첩 사유**: " + t["nesting"])
    L += ["**범위**: 조각 %d 의 범위." % t["n"], "**완료 기준**:", "- 시험이 통과한다.",
          "**발행 제목**: 조각 %d 구현" % t["n"], "**발행 본문**:", "````text"]
    L += t["body"].rstrip("\n").split("\n") + ["````", ""]
with open(out, "w", encoding="utf-8") as f:
    f.write("\n".join(L))
PYEOF

DOCS="$WORK/docs"
mkdir -p "$DOCS"
gen() { python3 "$WORK/gen.py" "$1" "$DOCS/$1.md"; }

# run_bs <var> <args...>: stdout into $out, exit code into $rc.
run_bs() { rc=0; out=$("$BS" "$@" 2>"$WORK/stderr") || rc=$?; }

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
gen ok
run_bs check "$DOCS/ok.md"
check "check: passing fixture exits 0" "$rc" "0"
check "check: passing fixture prints nothing" "$out" ""

expect_check() {  # <variant> <needle>
  gen "$1"
  run_bs check "$DOCS/$1.md"
  check "check $1: exits 1" "$rc" "1"
  has "check $1: reports '$2'" "$out" "$2"
}
expect_check cycle      "P1 선행 순환"
expect_check unresolved "P1 T3 선행 참조 해소 안 됨 T9"
expect_check count      "P1 티켓 수 선언 4"
expect_check twoprov    "P1 C1 제공 티켓 2개"
expect_check many       "P1 티켓 101개 (상한 100)"
expect_check parloss    "P2 병렬성 손실 T3→T1"
expect_check conc       "P3 T1·T2 동시 티켓 소유 파일 중첩"
expect_check globpos    "P3 T1·T2 동시 티켓 소유 파일 중첩"
expect_check bracepos   "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/{a,b}.py~src/a.py"
expect_check routepos   "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:app/[id]/page.tsx"
expect_check routeglob  "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:app/[id]/*~app/[id]/page.tsx"
expect_check rootslash  "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/a.py"
expect_check rootslash2 "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/a.py"
expect_check padspan    "P1 T1 소유 파일 목록 형식 오류 항목 \` src/t1/main.py\`"
expect_check padspan2   "P1 T1 소유 파일 목록 형식 오류 항목 \`src/t1/main.py \`"
expect_check dotdot     "P1 T1 소유 파일 목록 형식 오류 항목 \`src/../../x.py\`"
expect_check annotated  "P1 T1 소유 파일 목록 형식 오류 항목 \`src/t1/main.py\` (신규)"
expect_check barebrace  "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/{a,b}.py~src/t2/main.py"
expect_check bareclose  "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/t2/main.py"
expect_check sharedwhole "P1 T1 공유 파일 목록 형식 오류 레포 전체 공유 항목"
for g in star dstar dstarstar rootstar qstar dotstar; do
  expect_check "sharedglob-$g" "P1 T1 공유 파일 목록 형식 오류 레포 전체 공유 항목"
done
# A whole-repository share is dropped, so the pair it would have exempted
# is still compared.
run_bs check "$DOCS/sharedglob-dstar.md"
has "check sharedglob-dstar: the overlap is still reported" "$out" "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/shared/x.py"
expect_check sharedglob-lock "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/shared/x.py"
hasnt "check sharedglob-lock: a share that fixes a name is not a whole repository" "$out" "레포 전체"
expect_check classlit   "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/[a,b].py~src/a.py"
expect_check classboth  "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/[a,b].py"
expect_check openbracket "P1 T1 소유 파일 목록 형식 오류 닫히지 않은 괄호"
expect_check mirrordir  "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/a/x.py~src/a/"
expect_check mirrorglob "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/lib/core.py~src/lib/*.py"
expect_check barenote   "P1 T1 소유 파일 목록 형식 오류 항목 src/t1/main.py (신규)"
expect_check dotdot2    "P1 T1 소유 파일 목록 형식 오류 항목 \`..\`"
expect_check dotdot3    "P1 T1 소유 파일 목록 형식 오류 항목 \`src/../..\`"
expect_check bracelist  "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:lib/x.py"
expect_check dirpos     "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/a/~src/a/x.py"
expect_check dotpos     "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/a.py"
expect_check wholerepo  "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:./~src/t2/main.py"
expect_check wholedot   "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:./~src/t2/main.py"
expect_check emptyspan  "P1 T1 소유 파일 목록 형식 오류 항목 \`\`"
expect_check opentick   "P1 T1 소유 파일 목록 형식 오류 닫히지 않은 코드 스팬"
expect_check openbrace  "P1 T1 소유 파일 목록 형식 오류 닫히지 않은 괄호"
expect_check consumerside "P2 T1 가 소비하는 C1 의 제공 티켓 T2 에 선행으로 닿지 않음"
expect_check critpath   "P4 임계 경로 선언 T1 → T3"
expect_check depth3     "P4 깊이 3 에 깊이 사유 없음"
expect_check d0kind     "D0 판별자 줄 없음"
expect_check d0slicing  "D0 베이스 문서에 ## 구현 슬라이싱 가 있음"
expect_check b1docs     "B1 T1 본문에 문서 경로 docs/"
expect_check b1label    "B1 T2 본문에 라벨 T3"
expect_check b1heading  "B1 베이스 티켓 본문에 표제 줄"
expect_check ownbullet  "P1 T1 소유 파일 목록 형식 오류 값이 비어 있음; 값 아래 불릿 목록"
expect_check ownbullet  "P1 T2 소유 파일 목록 형식 오류 값이 비어 있음; 값 아래 불릿 목록"
expect_check ownbulletval "P1 T1 소유 파일 목록 형식 오류 값 아래 불릿 목록"
expect_check ownnone    "P1 T1 소유 파일 목록 형식 오류 없음 (소유 파일은 비어 있을 수 없음)"
expect_check depbullet  "P1 T3 선행 목록 형식 오류 값이 비어 있음; 값 아래 불릿 목록"
expect_check consempty  "P1 C1 소비 티켓 목록 형식 오류 값이 비어 있음"
# A list whose rest sits outside its field line, and a span or bare entry
# that holds more than one path, are reported rather than read as a shorter
# list that overlaps nothing.
expect_check trailcomma "P1 T1 소유 파일 목록 형식 오류 값 아래 이어지는 줄; 빈 항목"
expect_check emptyitem  "P1 T1 소유 파일 목록 형식 오류 빈 항목"
expect_check numbered   "P1 T1 소유 파일 목록 형식 오류 값 아래 이어지는 줄"
expect_check blankbullet "P1 T1 소유 파일 목록 형식 오류 값 아래 불릿 목록"
expect_check dupfield   "P1 T1 필드 중복 소유 파일"
expect_check depempty   "P1 T3 선행 목록 형식 오류 빈 항목"
expect_check onespan    "P1 T1 소유 파일 목록 형식 오류 항목 \`src/shared/x.py, src/t1/main.py\`"
expect_check spannote   "P1 T1 소유 파일 목록 형식 오류 항목 \`src/shared/x.py (수정)\`"
expect_check semicolon  "P1 T1 소유 파일 목록 형식 오류 항목 src/shared/x.py;src/t1/main.py"
# A note glued to the path, in full-width brackets or after a dash, and a
# span split by `;` or by a tab, are the same path-plus-note or two paths.
expect_check gluednote  "P1 T1 소유 파일 목록 형식 오류 항목 src/shared/x.py(수정)"
expect_check spannotetight "P1 T1 소유 파일 목록 형식 오류 항목 \`src/shared/x.py(수정)\`"
expect_check widenote   "P1 T1 소유 파일 목록 형식 오류 항목 \`src/shared/x.py（수정）\`"
expect_check dashnote   "P1 T1 소유 파일 목록 형식 오류 항목 \`src/shared/x.py — 수정\`"
expect_check spansemi   "P1 T1 소유 파일 목록 형식 오류 항목 \`src/shared/x.py;src/t1/main.py\`"
expect_check spantab    "P1 T1 소유 파일 목록 형식 오류 항목 \`src/shared/x.py,"
# The repository is compared without its code span and case-folded, so a
# spelling difference does not split one repository in two.
expect_check repospan   "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/shared/x.py"
expect_check repocase   "P3 T1·T2 동시 티켓 소유 파일 중첩 o/r:src/shared/x.py"
for v in repospan repocase; do
  run_bs check "$DOCS/$v.md"
  hasnt "check $v: a well-formed repository is not a violation" "$out" "레포 값 형식 오류"
done
expect_check repoempty  "P1 T1 레포 값 형식 오류 (빈 값)"
expect_check repobad    "P1 T1 레포 값 형식 오류 o r"

run_bs check "$DOCS/cycle.md"
hasnt "check cycle: graph predicates after a cycle are skipped" "$out" "P4"

for v in globneg braceneg dirneg repodiff sharedok shareddir depth3reason fenceok \
         routeneg routeshared spancomma routegroup spacepath sharedt2 sharedboth sharedglob-py; do
  gen "$v"
  run_bs check "$DOCS/$v.md"
  check "check $v: exits 0" "$rc" "0"
  check "check $v: prints nothing" "$out" ""
done

# ---------------------------------------------------------------------------
# plan / record — GitHub
# ---------------------------------------------------------------------------
GH_ROW='- `베이스 발행` | 트래커=github | 대상=o/r'
OUT="$WORK/out"
REG="$DOCS/design-base/ok.tickets.md"

entries() {  # entry ids and kinds of the current plan, one "id:kind" per line
  python3 -c 'import json,sys
for l in open(sys.argv[1], encoding="utf-8"):
    e = json.loads(l); print(e["entry"] + ":" + e["kind"])' "$OUT/plan.jsonl" | tr '\n' ' '
}
argv_of() {  # <entry id> — that entry's argv, space-joined
  python3 -c 'import json,sys
for l in open(sys.argv[1], encoding="utf-8"):
    e = json.loads(l)
    if e["entry"] == sys.argv[2]: print(" ".join(e["argv"]))' "$OUT/plan.jsonl" "$1"
}

run_bs plan "$DOCS/ok.md" --row "$GH_ROW" --out "$OUT"
check "plan: first plan exits 0" "$rc" "0"
check "plan: base first, contract ticket before implementation, the rest wait" \
  "$(entries)" "base:create T2:wait T1:wait T3:wait "
check "plan: base argv" "$(argv_of base)" "gh issue create --repo o/r --title 상태 파일 도입 --body-file $OUT/body-base.md"
[ ! -e "$REG" ] && ok "plan: writes no registry" || bad "plan: writes no registry"

python3 - "$DOCS/ok.md" "$OUT" <<'PYEOF' && ok "plan: body files equal the document fields byte for byte" || bad "plan: body files equal the document fields byte for byte"
import sys
doc = open(sys.argv[1], encoding="utf-8").read()
base = "여러 저장 단위를 하나의 상태 파일로 묶는다.\n계약을 먼저 정하고 구현을 나란히 진행한다.\n"
tick = "이 작업은 상태 파일의 %d번 조각을 정한다.\n완료 기준: 상태 파일은 이름과 크기 두 필드를 가진다.\n"
assert open(sys.argv[2] + "/body-base.md", "rb").read() == base.encode("utf-8")
for n in (1, 2, 3):
    assert open(sys.argv[2] + "/body-T%d.md" % n, "rb").read() == (tick % n).encode("utf-8")
PYEOF

run_bs record "$DOCS/ok.md" --row "$GH_ROW" --entry base --plan "$OUT/plan.jsonl" --state 발행중 --similar 'https://github.com/o/r/issues/7'
check "record: the base row has no similar-candidate field" "$rc" "3"
[ ! -e "$REG" ] && ok "record: a refused base --similar writes no registry" || bad "record: a refused base --similar writes no registry"
run_bs record "$DOCS/ok.md" --row "$GH_ROW" --entry base --plan "$OUT/plan.jsonl" --state 발행중
check "record: base 발행중 exits 0" "$rc" "0"
has "record: base row in flight" "$(cat "$REG")" '- `베이스` | 상태=발행중 | 참조=- | 노드 id=-'
check "record: header line" "$(head -n 1 "$REG")" \
  "<!-- cc-design-base-tickets v1; doc=docs/ok.md; doc-sha256=$(shasum -a 256 "$DOCS/ok.md" | cut -d' ' -f1); tracker=github; target=o/r -->"
check "record: end marker" "$(tail -n 1 "$REG")" "<!-- cc-design-base-tickets: end -->"
has "record: relations start waiting" "$(cat "$REG")" '- `관계` | 종류=선행 | 원=T3 | 대상=T2 | 상태=대기'

run_bs record "$DOCS/ok.md" --row "$GH_ROW" --entry base --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://github.com/o/r/issues/1
check "record: base 발행중 → 발행됨 exits 0" "$rc" "0"
has "record: base row issued" "$(cat "$REG")" '- `베이스` | 상태=발행됨 | 참조=https://github.com/o/r/issues/1 | 노드 id=-'
cp "$REG" "$WORK/reg.before"
run_bs record "$DOCS/ok.md" --row "$GH_ROW" --entry base --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://github.com/o/r/issues/1
cmp -s "$REG" "$WORK/reg.before" && ok "record: rewriting the same row is byte-identical" || bad "record: rewriting the same row is byte-identical"
run_bs record "$DOCS/ok.md" --row "$GH_ROW" --entry base --plan "$OUT/plan.jsonl" --state 발행중
check "record: 발행됨 → 발행중 is refused" "$rc" "3"
run_bs record "$DOCS/ok.md" --row "$GH_ROW" --entry base --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://github.com/o/r/issues/9
check "record: a different reference is refused" "$rc" "3"
run_bs record "$DOCS/ok.md" --row "$GH_ROW" --entry T3 --plan "$OUT/plan.jsonl" --state 발행중
check "record: a wait entry is refused" "$rc" "3"

run_bs plan "$DOCS/ok.md" --row "$GH_ROW" --out "$OUT"
check "plan: after the base is issued" "$(entries)" "T2:create T1:create T3:wait "
check "plan: child carries --parent" "$(argv_of T2)" \
  "gh issue create --repo o/r --title 조각 2 구현 --body-file $OUT/body-T2.md --parent https://github.com/o/r/issues/1"

run_bs record "$DOCS/ok.md" --row "$GH_ROW" --entry T2 --plan "$OUT/plan.jsonl" --state 발행중 --similar 'https://github.com/o/r/issues/7'
check "record: a ticket row takes --similar" "$rc" "0"
run_bs record "$DOCS/ok.md" --row "$GH_ROW" --entry T2 --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://github.com/o/r/issues/2
has "record: the similar candidates stay on the issued ticket row" "$(cat "$REG")" \
  '- `티켓` | id=T2 | 상태=발행됨 | 참조=https://github.com/o/r/issues/2 | 노드 id=- | 유사 후보=https://github.com/o/r/issues/7'
run_bs record "$DOCS/ok.md" --row "$GH_ROW" --entry T1 --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://github.com/o/r/issues/3
has "record: a creation that carried --parent ties the child relation" "$(cat "$REG")" '- `관계` | 종류=하위 | 원=T2 | 대상=베이스 | 상태=걸림'

run_bs plan "$DOCS/ok.md" --row "$GH_ROW" --out "$OUT"
check "plan: last ticket after its predecessor is issued" "$(entries)" "T3:create "
check "plan: --blocked-by carries the predecessor" "$(argv_of T3)" \
  "gh issue create --repo o/r --title 조각 3 구현 --body-file $OUT/body-T3.md --parent https://github.com/o/r/issues/1 --blocked-by https://github.com/o/r/issues/2"
run_bs record "$DOCS/ok.md" --row "$GH_ROW" --entry T3 --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://github.com/o/r/issues/4
has "record: a creation that carried --blocked-by ties the dependency" "$(cat "$REG")" '- `관계` | 종류=선행 | 원=T3 | 대상=T2 | 상태=걸림'
run_bs plan "$DOCS/ok.md" --row "$GH_ROW" --out "$OUT"
check "plan: nothing left once all is issued" "$(entries)" ""

# A registry left by an interrupted run: T1 in flight, T3 issued without its
# relations. Issued creations are skipped, only the missing relations get an
# edit, and the in-flight row is resolved rather than created again.
SHA=$(shasum -a 256 "$DOCS/ok.md" | cut -d' ' -f1)
cat > "$REG" <<EOF
<!-- cc-design-base-tickets v1; doc=docs/ok.md; doc-sha256=$SHA; tracker=github; target=o/r -->
- \`베이스\` | 상태=발행됨 | 참조=https://github.com/o/r/issues/1 | 노드 id=-
- \`티켓\` | id=T1 | 상태=발행중 | 참조=- | 노드 id=- | 유사 후보=없음
- \`티켓\` | id=T2 | 상태=발행됨 | 참조=https://github.com/o/r/issues/2 | 노드 id=- | 유사 후보=없음
- \`티켓\` | id=T3 | 상태=발행됨 | 참조=https://github.com/o/r/issues/4 | 노드 id=- | 유사 후보=없음
- \`관계\` | 종류=하위 | 원=T1 | 대상=베이스 | 상태=대기
- \`관계\` | 종류=하위 | 원=T2 | 대상=베이스 | 상태=걸림
- \`관계\` | 종류=하위 | 원=T3 | 대상=베이스 | 상태=대기
- \`관계\` | 종류=선행 | 원=T3 | 대상=T2 | 상태=대기
<!-- cc-design-base-tickets: end -->
EOF
run_bs plan "$DOCS/ok.md" --row "$GH_ROW" --out "$OUT"
check "plan resume: resolve in flight, edit only missing relations" "$(entries)" \
  "T1:resolve rel:하위:T3:베이스:edit rel:선행:T3:T2:edit "
check "plan resume: dependency edit argv" "$(argv_of rel:선행:T3:T2)" \
  "gh issue edit https://github.com/o/r/issues/4 --add-blocked-by https://github.com/o/r/issues/2"
run_bs record "$DOCS/ok.md" --row "$GH_ROW" --entry T1 --plan "$OUT/plan.jsonl" --state 없음
check "record: an in-flight row resolved to nothing is dropped" "$(grep -c 'id=T1' "$REG" || true)" "0"
run_bs plan "$DOCS/ok.md" --row "$GH_ROW" --out "$OUT"
has "plan resume: a dropped row is created again" "$(entries)" "T1:create"
run_bs record "$DOCS/ok.md" --row "$GH_ROW" --entry T1 --plan "$OUT/plan.jsonl" --similar 'https://github.com/o/r/issues/7'
check "record: similar alone needs an existing row" "$rc" "3"

# Refusals write no command at all.
refused() {  # <label> <args...>
  local label=$1; shift
  printf 'stale\n' > "$OUT/plan.jsonl"
  run_bs plan "$@"
  check "plan refuses: $label (exit)" "$rc" "3"
  check "plan refuses: $label (no command)" "$(wc -c < "$OUT/plan.jsonl" | tr -d ' ')" "0"
}
refused "트래커=없음" "$DOCS/ok.md" --row '- `베이스 발행` | 트래커=없음 | 대상=-' --out "$OUT"
refused "--tracker disagrees with the row" "$DOCS/ok.md" --row "$GH_ROW" --tracker clickup --out "$OUT"
refused "--target disagrees with the row" "$DOCS/ok.md" --row "$GH_ROW" --target o/x --out "$OUT"
refused "a malformed row" "$DOCS/ok.md" --row '- `베이스 발행` | 트래커=jira | 대상=x' --out "$OUT"
refused "check violations" "$DOCS/cycle.md" --row "$GH_ROW" --out "$OUT"
printf '\n' >> "$DOCS/ok.md"
refused "registry recorded against other document bytes" "$DOCS/ok.md" --row "$GH_ROW" --out "$OUT"

# ---------------------------------------------------------------------------
# plan — ClickUp; record --doc-only
# ---------------------------------------------------------------------------
CU_ROW='- `베이스 발행` | 트래커=clickup | 대상=901234'
gen ok && cp "$DOCS/ok.md" "$DOCS/cu.md"

# `fx.py <variant> <path>` writes one field document as
# `similar-items.py clickup --list-fields 901234` would. `empty` is a list with
# no ticket, so every field stays unset and no argv gains a field option.
cat > "$WORK/fx.py" <<'PYEOF'
import json, sys

variant, out = sys.argv[1], sys.argv[2]

def t(i, parent=None, assignees=(), tags=(), priority=None, start=None, due=None, deps=(), **extra):
    r = {"id": i, "name": i, "parent": parent, "list_id": "901234", "assignees": list(assignees),
         "tags": list(tags), "priority": priority, "start_date": start, "due_date": due}
    r.update(extra)
    r["dependencies"] = [{"task_id": a, "depends_on": b} for a, b in deps]
    return r

origin_deps = [("O", "w1"), ("s1", "O")]
doc = {"kind": "fields", "list": "901234", "partial": False, "reason": None, "tasks": [], "task_fields": []}
if variant == "rules":
    # Four top-level tickets in the denominator; the subtask, the origin and
    # the tickets outside the list's open set do not count.
    doc["tasks"] = [t("a1", assignees=[1], tags=["x"], priority=2, start="1000", due="5000"),
                    t("a2", assignees=[1, 2], tags=["x"], priority=2, start="2000"),
                    t("a3", priority=3),
                    t("a4", assignees=[1], tags=["y"]),
                    t("sub", parent="a1", assignees=[9], priority=1, start="1", due="1"),
                    t("O", assignees=[], tags=["x"])]
    doc["task_fields"] = [t("O", tags=["x"], start="7000", due="9000", deps=origin_deps),
                          t("w1", due="8000"), t("s1", start="20000")]
elif variant == "dates":
    doc["tasks"] = [t("b1", assignees=[5], start="1", due="2"), t("b2", assignees=[5], start="3", due="4")]
    doc["task_fields"] = [t("O", assignees=[7], priority=1, start="7000", due="9000", due_date_time=True,
                            deps=origin_deps),
                          t("w1", due="8000", due_date_time=False), t("s1", start="20000")]
elif variant == "foreign":
    # The list read holds neither end: w1 is closed in this list, x9 lives in
    # another one; the tool read both alone because the origin names them.
    doc["task_fields"] = [t("O", deps=[("O", "w1"), ("x9", "O")]), t("w1", due="8000"),
                          t("x9", list_id="777", start="1")]
elif variant == "tie":
    doc["tasks"] = [t("c1", priority=1), t("c2", priority=2)]
elif variant == "runnode":
    doc["tasks"] = [t("d1", assignees=[4]), t("abc")]
    doc["task_fields"] = [t("O", assignees=[4])]
elif variant == "limit":
    doc["partial"], doc["reason"] = True, "limit"
elif variant == "budget":
    doc["partial"], doc["reason"] = True, "budget"
elif variant == "nokind":
    del doc["kind"]
elif variant == "otherlist":
    doc["list"] = "5"
elif variant != "empty":
    raise SystemExit("unknown variant " + variant)
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False)
PYEOF
fx() { python3 "$WORK/fx.py" "$1" "$WORK/fields-$1.json"; printf '%s' "$WORK/fields-$1.json"; }
FX_EMPTY=$(fx empty)

# The installed ClickUp tools decide whether a ClickUp plan may exist at all:
# `plan` emits an argv only when every tool it names is there and its own
# parser lists every option the argv passes.
real_ready=1
[ -x "$ORCH/clickup-relate.py" ] || real_ready=0
if [ "$real_ready" = 1 ]; then
  relate_help=$("$ORCH/clickup-relate.py" --help 2>/dev/null) || real_ready=0
  create_help=$("$ORCH/clickup-create.py" --help 2>/dev/null) || real_ready=0
  grep -qE -- '--depends-on' <<EOF || real_ready=0
$relate_help
EOF
  for o in --parent --assignee --priority --start-date-time --due-date-time; do
    grep -qE -- "$o" <<EOF || real_ready=0
$create_help
EOF
  done
fi
printf 'stale\n' > "$OUT/plan.jsonl"
run_bs plan "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT" --fields "$FX_EMPTY"
if [ "$real_ready" = 1 ]; then
  check "plan clickup (installed tools ready): exits 0" "$rc" "0"
else
  check "plan clickup (installed tools not ready): refused" "$rc" "3"
  check "plan clickup (installed tools not ready): no command" "$(wc -c < "$OUT/plan.jsonl" | tr -d ' ')" "0"
  has "plan clickup (installed tools not ready): says which tool" "$out" "거절 ClickUp 도구 미비"
fi
[ ! -e "$DOCS/design-base/cu.tickets.md" ] && ok "plan clickup: writes no registry" || bad "plan clickup: writes no registry"

# The plan's own shape, against stand-in tools next to a copy of the script.
# Each stand-in parses with the option set `plan` relies on and does nothing
# else, so running an emitted argv proves that argv parses.
STUB_DIR="$WORK/orch"
mkdir -p "$STUB_DIR"
STUB_DIR=$(cd "$STUB_DIR" && pwd -P)
cp "$BS" "$STUB_DIR/base-split.py"
stub_tool() {  # <name> <option...>
  local name=$1; shift
  {
    printf '#!/usr/bin/env python3\nimport argparse, sys\n'
    printf 'p = argparse.ArgumentParser(prog="%s", allow_abbrev=False)\n' "$name"
    for o in "$@"; do
      case "$o" in
        *-time) printf 'p.add_argument("%s", action="store_true")\n' "$o" ;;
        --assignee) printf 'p.add_argument("%s", action="append")\n' "$o" ;;
        *) printf 'p.add_argument("%s")\n' "$o" ;;
      esac
    done
    printf 'p.parse_args()\n'
  } > "$STUB_DIR/$name"
  chmod +x "$STUB_DIR/$name"
}
# Every plan that succeeds is kept, so the parse check below sees each argv.
run_stub() {
  rc=0; out=$("$STUB_DIR/base-split.py" "$@" 2>"$WORK/stderr") || rc=$?
  if [ "$1" = plan ] && [ "$rc" = 0 ]; then cat "$OUT/plan.jsonl" >> "$WORK/cu-all.jsonl"; fi
}

CU_CREATE_OPTS="--list --name --description-file --parent --assignee --priority --start-date --start-date-time --due-date --due-date-time"
stub_tool clickup-create.py --list --name --description-file
stub_tool clickup-relate.py --task --depends-on
refused_stub() {  # <label> [plan args...]
  local label=$1; shift
  printf 'stale\n' > "$OUT/plan.jsonl"
  if [ "$#" -eq 0 ]; then set -- "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT" --fields "$FX_EMPTY"; fi
  run_stub plan "$@"
  check "plan clickup refuses: $label (exit)" "$rc" "3"
  check "plan clickup refuses: $label (no command)" "$(wc -c < "$OUT/plan.jsonl" | tr -d ' ')" "0"
}
refused_stub "create tool without --parent"
stub_tool clickup-create.py --list --name --description-file --parent
refused_stub "create tool without the field options"
has "plan clickup refuses: names the missing field options" "$out" "--assignee, --priority"
# shellcheck disable=SC2086
stub_tool clickup-create.py $CU_CREATE_OPTS
rm -f "$STUB_DIR/clickup-relate.py"
refused_stub "relate tool missing"
stub_tool clickup-relate.py --task --depends-on
refused_stub "no field document" "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT"
has "plan clickup refuses: says --fields is needed" "$out" "--fields"

run_stub plan "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT" --fields "$FX_EMPTY"
check "plan clickup: exits 0" "$rc" "0"
base_argv=$(argv_of base)
case "$base_argv" in
  "$STUB_DIR/clickup-create.py --list 901234 --name 상태 파일 도입 --description-file $OUT/body-base.md") ok "plan clickup: argv0 is the absolute tool path, no interpreter" ;;
  *) bad "plan clickup: argv0 is the absolute tool path, no interpreter" "$base_argv" ;;
esac
run_stub record "$DOCS/cu.md" --row "$CU_ROW" --entry base --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/abc
check "record clickup: 발행됨 without a node id is refused" "$rc" "3"
run_stub record "$DOCS/cu.md" --row "$CU_ROW" --entry base --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/abc --node-id abc
run_stub plan "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT" --fields "$FX_EMPTY"
check "plan clickup: child carries --parent node" "$(argv_of T2)" \
  "$STUB_DIR/clickup-create.py --list 901234 --name 조각 2 구현 --description-file $OUT/body-T2.md --parent abc"
has "plan clickup: dependency waits for its ticket" "$(entries)" "rel:선행:T3:T2:wait"
run_stub record "$DOCS/cu.md" --row "$CU_ROW" --entry T2 --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/t2 --node-id t2
run_stub record "$DOCS/cu.md" --row "$CU_ROW" --entry T1 --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/t1 --node-id t1
run_stub plan "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT" --fields "$FX_EMPTY"
run_stub record "$DOCS/cu.md" --row "$CU_ROW" --entry T3 --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/t3 --node-id t3
run_stub plan "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT" --fields "$FX_EMPTY"
check "plan clickup: the dependency is its own relate call" "$(argv_of rel:선행:T3:T2)" \
  "$STUB_DIR/clickup-relate.py --task t3 --depends-on t2"

# A ClickUp ticket left in flight and adopted by a resolve was created with
# `--parent`, so the adoption ties the child relation; no later plan entry
# would ever do it, and the split would never complete.
cp "$DOCS/cu.md" "$DOCS/cur.md"
CUSHA=$(shasum -a 256 "$DOCS/cur.md" | cut -d' ' -f1)
CUREG="$DOCS/design-base/cur.tickets.md"
cat > "$CUREG" <<EOF
<!-- cc-design-base-tickets v1; doc=docs/cur.md; doc-sha256=$CUSHA; tracker=clickup; target=901234 -->
- \`베이스\` | 상태=발행됨 | 참조=https://app.clickup.com/t/abc | 노드 id=abc
- \`티켓\` | id=T1 | 상태=발행됨 | 참조=https://app.clickup.com/t/t1 | 노드 id=t1 | 유사 후보=없음
- \`티켓\` | id=T2 | 상태=발행중 | 참조=- | 노드 id=- | 유사 후보=없음
- \`티켓\` | id=T3 | 상태=발행됨 | 참조=https://app.clickup.com/t/t3 | 노드 id=t3 | 유사 후보=없음
- \`관계\` | 종류=하위 | 원=T1 | 대상=베이스 | 상태=걸림
- \`관계\` | 종류=하위 | 원=T2 | 대상=베이스 | 상태=대기
- \`관계\` | 종류=하위 | 원=T3 | 대상=베이스 | 상태=걸림
- \`관계\` | 종류=선행 | 원=T3 | 대상=T2 | 상태=대기
<!-- cc-design-base-tickets: end -->
EOF
run_stub plan "$DOCS/cur.md" --row "$CU_ROW" --out "$OUT" --fields "$FX_EMPTY"
has "plan clickup resume: the in-flight ticket is resolved" "$(entries)" "T2:resolve"
run_stub record "$DOCS/cur.md" --row "$CU_ROW" --entry T2 --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/t2 --node-id t2
check "record clickup: a resolve to 발행됨 exits 0" "$rc" "0"
has "record clickup: a resolve to 발행됨 ties the child relation" "$(cat "$CUREG")" \
  '- `관계` | 종류=하위 | 원=T2 | 대상=베이스 | 상태=걸림'

# ---------------------------------------------------------------------------
# plan — ClickUp fields, the origin ticket and external relations
# ---------------------------------------------------------------------------
CUO_ROW='- `베이스 발행` | 트래커=clickup | 대상=901234 | 원 티켓=O'
pick() {  # <entry id> <python expression over e> — one value of a plan entry
  python3 -c 'import json,sys
for l in open(sys.argv[1], encoding="utf-8"):
    e = json.loads(l)
    if e["entry"] == sys.argv[2]: print(json.dumps(eval(sys.argv[3]), ensure_ascii=False, sort_keys=True))' \
    "$OUT/plan.jsonl" "$1" "$2"
}

# The row: the origin field is optional, follows the target, and only on clickup.
run_stub plan "$DOCS/cu.md" --row "$CUO_ROW" --out "$OUT" --fields "$(fx rules)"
check "row: a clickup row with 원 티켓 is read" "$rc" "0"
refused_stub "원 티켓 on a github row" "$DOCS/cu.md" --row '- `베이스 발행` | 트래커=github | 대상=o/r | 원 티켓=O' --out "$OUT"
has "row: 원 티켓 on a github row names the rule" "$out" "원 티켓 은 clickup 행에만 둡니다"
refused_stub "원 티켓 on a 없음 row" "$DOCS/cu.md" --row '- `베이스 발행` | 트래커=없음 | 대상=- | 원 티켓=O' --out "$OUT"
refused_stub "an empty 원 티켓" "$DOCS/cu.md" --row '- `베이스 발행` | 트래커=clickup | 대상=901234 | 원 티켓=' --out "$OUT" --fields "$(fx rules)"
refused_stub "a 원 티켓 out of order" "$DOCS/cu.md" --row '- `베이스 발행` | 트래커=clickup | 원 티켓=O | 대상=901234' --out "$OUT" --fields "$(fx rules)"

# Strict majority over the open top-level tickets other than the origin: three
# of four set assignees and a priority (in use), two of four a start date
# (exactly half, empty), one a due date (empty). The subtask's values never count.
gen ok && cp "$DOCS/ok.md" "$DOCS/fr.md"
run_stub plan "$DOCS/fr.md" --row "$CUO_ROW" --out "$OUT" --fields "$(fx rules)"
check "fields: plan exits 0" "$rc" "0"
check "fields: base argv carries the decided fields only" "$(argv_of base)" \
  "$STUB_DIR/clickup-create.py --list 901234 --name 상태 파일 도입 --description-file $OUT/body-base.md --assignee 1 --priority 2"
check "fields: assignee is the tag-sharing tickets' common one, priority the mode" \
  "$(pick base 'e["fields"]["values"]')" '{"assignees": [1], "priority": 2}'
check "fields: exactly half and below leave the field empty" \
  "$(pick base 'e["fields"]["empty"]')" '{"due_date": "리스트가 쓰지 않음", "start_date": "리스트가 쓰지 않음"}'
check "fields: no date set reads 미상(생략)" "$(pick base 'e["date_format"]')" '"미상(생략)"'
[ -f "$OUT/fields-plan.json" ] && ok "fields: plan writes fields-plan.json" || bad "fields: plan writes fields-plan.json"
cp "$OUT/fields-plan.json" "$WORK/fp1.json"
run_stub plan "$DOCS/fr.md" --row "$CUO_ROW" --out "$OUT" --fields "$WORK/fields-rules.json"
cmp -s "$OUT/fields-plan.json" "$WORK/fp1.json" && ok "fields: the same input writes the same fields-plan bytes" \
  || bad "fields: the same input writes the same fields-plan bytes"
check "fields: the origin's waits-on precede every root, its waiters follow every leaf" \
  "$(python3 -c 'import json,sys
t = json.load(open(sys.argv[1]))["tickets"]
print(" ".join("%s:%s/%s" % (k, ",".join(t[k]["external_pred"]), ",".join(t[k]["external_succ"])) for k in ("T1", "T2", "T3")))' "$OUT/fields-plan.json")" \
  "T1:w1/s1 T2:w1/ T3:/s1"

# Dates in use come from the reference tickets: a predecessor's due date as the
# start, a successor's start as the due date, else the origin's. A flag is
# copied only when the reference record carries the key.
gen ok && cp "$DOCS/ok.md" "$DOCS/fd.md"
run_stub plan "$DOCS/fd.md" --row "$CUO_ROW" --out "$OUT" --fields "$(fx dates)"
check "dates: base takes the origin's dates and its due flag" "$(argv_of base)" \
  "$STUB_DIR/clickup-create.py --list 901234 --name 상태 파일 도입 --description-file $OUT/body-base.md --assignee 7 --start-date 7000 --due-date 9000 --due-date-time"
check "dates: a flag missing from one reference reads 미상(생략)" "$(pick base 'e["date_format"]')" '"미상(생략)"'
run_stub record "$DOCS/fd.md" --row "$CUO_ROW" --entry base --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/nb --node-id nb
run_stub plan "$DOCS/fd.md" --row "$CUO_ROW" --out "$OUT" --fields "$WORK/fields-dates.json"
check "dates: a root takes its predecessor's due date, copying a false flag as none" "$(argv_of T2)" \
  "$STUB_DIR/clickup-create.py --list 901234 --name 조각 2 구현 --description-file $OUT/body-T2.md --parent nb --assignee 7 --start-date 8000 --due-date 9000 --due-date-time"
check "dates: every date copied with its flag reads 복사" "$(pick T2 'e["date_format"]')" '"복사"'
check "dates: priority unused by the list stays empty" "$(pick T2 'e["fields"]["empty"]')" '{"priority": "리스트가 쓰지 않음"}'
has "dates: an external relation waits for its ticket" "$(entries)" "rel:외부선행:T2:w1:wait"
for t in T1 T2 T3; do
  run_stub record "$DOCS/fd.md" --row "$CUO_ROW" --entry "$t" --plan "$OUT/plan.jsonl" --state 발행됨 \
    --ref "https://app.clickup.com/t/n${t#T}" --node-id "n${t#T}"
  run_stub plan "$DOCS/fd.md" --row "$CUO_ROW" --out "$OUT" --fields "$WORK/fields-dates.json"
done
check "relations: an external predecessor is waited on by the new ticket" "$(argv_of rel:외부선행:T2:w1)" \
  "$STUB_DIR/clickup-relate.py --task n2 --depends-on w1"
check "relations: an external successor waits on the new ticket" "$(argv_of rel:외부후행:T3:s1)" \
  "$STUB_DIR/clickup-relate.py --task s1 --depends-on n3"
run_stub record "$DOCS/fd.md" --row "$CUO_ROW" --entry rel:외부후행:T3:s1 --plan "$OUT/plan.jsonl" --state 발행됨 --ref -
check "relations: an external relation records" "$rc" "0"
has "relations: the registry carries the external relation" "$(cat "$DOCS/design-base/fd.tickets.md")" \
  '- `관계` | 종류=외부후행 | 원=T3 | 대상=s1 | 상태=걸림'
run_stub plan "$DOCS/fd.md" --row "$CUO_ROW" --out "$OUT" --fields "$WORK/fields-dates.json"
hasnt "relations: a recorded external relation is not planned again" "$(entries)" "rel:외부후행:T3:s1"
cp "$OUT/fields-plan.json" "$WORK/fp-dates.json"

# check --observed: the re-read is compared with the fields plan; dates by
# their millisecond value only.
python3 - "$WORK/fp-dates.json" "$WORK/obs-ok.json" "$WORK/obs-bad.json" <<'PYEOF'
import json, sys
plan = json.load(open(sys.argv[1]))["tickets"]
nodes = {"베이스": "nb", "T1": "n1", "T2": "n2", "T3": "n3"}
def rec(key, deps):
    f = plan[key]["fields"]
    return {"id": nodes[key], "name": key, "parent": None if key == "베이스" else "nb", "list_id": "901234",
            "assignees": f.get("assignees", []), "tags": [], "priority": f.get("priority"),
            # A leading zero is the same millisecond value.
            "start_date": "0" + f["start_date"] if "start_date" in f else None,
            "due_date": f.get("due_date"), "dependencies": deps}
deps = [{"task_id": "n3", "depends_on": "n2"}, {"task_id": "n1", "depends_on": "w1"},
        {"task_id": "n2", "depends_on": "w1"}, {"task_id": "s1", "depends_on": "n1"},
        {"task_id": "s1", "depends_on": "n3"}]
ok = {"kind": "fields", "list": "901234", "partial": False, "reason": None, "tasks": [],
      "task_fields": [rec(k, deps) for k in nodes]}
json.dump(ok, open(sys.argv[2], "w"))
ok["task_fields"][2]["priority"] = 4
for r in ok["task_fields"]:
    r["dependencies"] = [d for d in deps if d != {"task_id": "n2", "depends_on": "w1"}]
json.dump(ok, open(sys.argv[3], "w"))
PYEOF
run_stub check "$DOCS/fd.md" --observed "$WORK/obs-ok.json" --plan "$WORK/fp-dates.json" --row "$CUO_ROW"
check "check --observed: a matching re-read exits 0" "$rc" "0"
check "check --observed: a matching re-read prints nothing" "$out" ""
run_stub check "$DOCS/fd.md" --observed "$WORK/obs-bad.json" --plan "$WORK/fp-dates.json" --row "$CUO_ROW"
check "check --observed: a differing re-read exits 1" "$rc" "1"
has "check --observed: names the differing field" "$out" "observed T2 priority - 4"
has "check --observed: names the missing relation" "$out" "observed T2 외부선행 w1 없음"
run_stub check "$DOCS/fd.md" --observed "$WORK/obs-ok.json" --row "$CUO_ROW"
check "check --observed: needs --plan and --row with it" "$rc" "2"

# A tie for the most common priority leaves it empty; the plan says why.
gen ok && cp "$DOCS/ok.md" "$DOCS/ft.md"
run_stub plan "$DOCS/ft.md" --row "$CU_ROW" --out "$OUT" --fields "$(fx tie)"
check "fields: a tied mode is no value" "$(pick base 'e["fields"]["empty"]["priority"]')" '"참조 값 없음"'

# This split's own tickets leave the denominator once the registry names them.
gen ok && cp "$DOCS/ok.md" "$DOCS/fn.md"
run_stub plan "$DOCS/fn.md" --row "$CUO_ROW" --out "$OUT" --fields "$(fx runnode)"
hasnt "fields: half the list without assignees leaves them empty" "$(argv_of base)" "--assignee"
run_stub record "$DOCS/fn.md" --row "$CUO_ROW" --entry base --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/abc --node-id abc
run_stub plan "$DOCS/fn.md" --row "$CUO_ROW" --out "$OUT" --fields "$WORK/fields-runnode.json"
has "fields: the run's own ticket leaves the denominator" "$(argv_of T1)" "--assignee 4"

# The document's own external fields add relations; an id outside the
# snapshot, a partial or foreign document, and a missing origin are refused.
gen ok && sed -e '/^### 티켓 T1 /,/^\*\*범위\*\*/s/^\*\*공유 파일\*\*: 없음$/**공유 파일**: 없음\
**외부 선행**: s1/' "$DOCS/ok.md" > "$DOCS/fx.md"
run_stub check "$DOCS/fx.md"
check "check: an 외부 선행 field passes the predicates" "$rc" "0"
run_stub plan "$DOCS/fx.md" --row "$CU_ROW" --out "$OUT" --fields "$WORK/fields-rules.json"
check "fields: an 외부 선행 the snapshot holds is planned" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tickets"]["T1"]["external_pred"])' "$OUT/fields-plan.json")" "['s1']"
refused_stub "an external id outside the snapshot" "$DOCS/fx.md" --row "$CU_ROW" --out "$OUT" --fields "$FX_EMPTY"
has "refusal names the id outside the snapshot" "$out" "스냅숏에 없는 티켓 id s1"
refused_stub "external fields on a github row" "$DOCS/fx.md" --row "$GH_ROW" --out "$OUT"
refused_stub "--fields on a github row" "$DOCS/ok.md" --row "$GH_ROW" --out "$OUT" --fields "$FX_EMPTY"
refused_stub "a partial field document" "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT" --fields "$(fx budget)"
refused_stub "a field document cut by the limit" "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT" --fields "$(fx limit)"
has "refusal says the list is over 2000" "$out" "2000"
refused_stub "a document without kind" "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT" --fields "$(fx nokind)"
refused_stub "a field document of another list" "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT" --fields "$(fx otherlist)"
refused_stub "an origin the document did not read alone" "$DOCS/cu.md" --row "$CUO_ROW" --out "$OUT" --fields "$FX_EMPTY"

# The origin's dependency on a closed ticket of the list stays a relation; one
# on a ticket the document shows in another list is left out, with the reason,
# instead of refusing the whole plan.
gen ok && cp "$DOCS/ok.md" "$DOCS/ff.md"
run_stub plan "$DOCS/ff.md" --row "$CUO_ROW" --out "$OUT" --fields "$(fx foreign)"
check "foreign: plan exits 0" "$rc" "0"
check "foreign: the closed ticket stays, the other list's ticket leaves the relations" \
  "$(python3 -c 'import json,sys
t = json.load(open(sys.argv[1]))["tickets"]
print(" ".join("%s:%s/%s" % (k, ",".join(t[k]["external_pred"]), ",".join(t[k]["external_succ"])) for k in ("T1", "T2", "T3")))' "$OUT/fields-plan.json")" \
  "T1:w1/ T2:w1/ T3:/"
check "foreign: the plan names the left-out ticket on every leaf" \
  "$(python3 -c 'import json,sys
t = json.load(open(sys.argv[1]))["tickets"]
print(json.dumps([t[k]["external_skipped"] for k in ("T1", "T2", "T3")], ensure_ascii=False, sort_keys=True))' "$OUT/fields-plan.json")" \
  '[[{"direction": "후행", "id": "x9", "reason": "다른 리스트 777"}], [], [{"direction": "후행", "id": "x9", "reason": "다른 리스트 777"}]]'
hasnt "foreign: no relation is planned with the other list's ticket" "$(entries)" "x9"

# Every argv the ClickUp plans emitted parses against its tool.
python3 - "$WORK/cu-all.jsonl" <<'PYEOF' && ok "plan clickup: every emitted argv parses against its tool" || bad "plan clickup: every emitted argv parses against its tool"
import json, subprocess, sys
kinds = set()
for line in open(sys.argv[1], encoding="utf-8"):
    e = json.loads(line)
    if e["argv"]:
        kinds.add(e["kind"])
        subprocess.run(e["argv"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
assert kinds == {"create", "relate"}, kinds
PYEOF

NONE_ROW='- `베이스 발행` | 트래커=없음 | 대상=-'
cp "$DOCS/ok.md" "$DOCS/none.md"
run_bs record "$DOCS/none.md" --row "$NONE_ROW" --doc-only
check "record --doc-only: exits 0" "$rc" "0"
NREG="$DOCS/design-base/none.tickets.md"
check "record --doc-only: every row is 문서만" \
  "$(sed -e '1d' -e '$d' "$NREG" | grep -vc '문서만' || true)" "0"
check "record --doc-only: base + tickets + relations" "$(sed -e '1d' -e '$d' "$NREG" | wc -l | tr -d ' ')" "8"
run_bs record "$DOCS/none.md" --row "$GH_ROW" --doc-only
check "record --doc-only: refused when the row names a tracker" "$rc" "3"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
