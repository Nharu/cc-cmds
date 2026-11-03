#!/usr/bin/env bash
# Test the base design split tool (`plugins/cc-cmds/orchestrator/base-split.py`)
# offline: its predicates (`check`), its publication plan (`plan`), its
# registry writer (`record`, `record --started`) and the ticket delivery
# commands (`child-doc`, `fence-check`, `revise`).
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

# ---------------------------------------------------------------------------
# Ticket delivery designs (`**문서 종류**: 티켓 배달 설계`).
# `td.py <variant> <path>` writes one. The passing shape is two tickets — T1
# (계약, provides C1, child design 생략 가능) and T2 (구현, consumes C1 after
# T1, child design 필요 with a directory entry) — three design subsections,
# one of them with a comma in its heading, three residual items (two on T1,
# one on T2) that cite headings with `§` and each other with `R<n>`, two open
# unresolved entries (the 구현 전 결정 one on T1) and one closed entry.
# ---------------------------------------------------------------------------
cat > "$WORK/td.py" <<'PYEOF'
import sys

variant, out = sys.argv[1], sys.argv[2]
kind_lines = ["**문서 종류**: 티켓 배달 설계"]
header = [("티켓 수", "2"), ("임계 경로", "T1 → T2"), ("병렬 폭", "1"),
          ("분할 사유", "형식과 화면이 다른 시점에 나간다.")]
history = ["## 개정 이력", "없음"]
t1 = {"owned": ["src/fmt.py", "README.md"], "shared": ["src/common.py"],
      "design": ["저장 형식", "읽기, 쓰기 경로"], "sub": "생략 가능",
      "residual": ["R1. 형식 확인", "R2. 경로 확인"], "open": ["열린 항목 하나"]}
t2 = {"owned": ["ui/"], "shared": [],
      "design": ["화면", "읽기, 쓰기 경로"], "sub": "필요",
      "residual": ["R3. 화면 확인"], "open": ["열린 항목 둘"]}
raw = {}
r3_body = "**검증 레시피**: R1 을 먼저 본다."
table = []

if variant == "bothkinds":
    kind_lines.append("**문서 종류**: 베이스 설계")
elif variant == "noreason":
    header = header[:3]
elif variant == "tworeason":
    header.append(("분할 사유", "다른 이유."))
elif variant == "nohist":
    history = []
elif variant == "t1missing":
    t1["design"].append("없는 절")
elif variant == "t1unnamed":
    t2["design"] = ["읽기, 쓰기 경로"]
elif variant == "t1bad":
    raw[("T1", "설계 절")] = "### 저장 형식"
elif variant == "t2dir":
    t1["owned"].append("src/lib/")
elif variant == "t2glob":
    t1["owned"].append("src/*.py")
elif variant.startswith("t2n"):
    # Owned and shared entries together: README.md, src/fmt.py, src/common.py
    # and as many more as it takes to reach the number.
    t1["owned"] += ["src/f%d.py" % k for k in range(int(variant[3:]) - 3)]
elif variant == "t2skill":
    t1["owned"] = ["src/fmt.py", "skills/x/SKILL.md"]
elif variant == "t2value":
    t1["sub"] = "아마"
elif variant == "t3unassigned":
    t2["residual"] = []
elif variant == "t3twice":
    t2["residual"].append("R1. 형식 확인")
elif variant == "t3missing":
    t2["residual"].append("R9. 없는 항목")
elif variant == "t4unassigned":
    t2["open"] = []
elif variant == "t4closed":
    t2["open"].append("닫힌 항목")
elif variant == "t4twice":
    t2["open"].append("열린 항목 하나")
elif variant == "t4row":
    table = ["| 항목 | 상태 |", "|---|---|", "| 표로 적은 항목 | 보류 |", ""]
elif variant == "t5":
    r3_body = "**검증 레시피**: §없는 절 을 본다."
elif variant != "ok":
    raise SystemExit("unknown variant " + variant)

def qlist(items):
    return ", ".join("「### %s」" % x for x in items) or "없음"

def files(items):
    return ", ".join("`%s`" % p for p in items) or "없음"

def tblock(tid, title, kind, deps, prov, cons, t):
    def v(key, value):
        return "**%s**: %s" % (key, raw.get((tid, key), value))
    return ["### 티켓 %s — %s" % (tid, title), v("종류", kind), v("레포", "o/r"), v("선행", deps),
            v("제공 계약", prov), v("소비 계약", cons), v("소유 파일", files(t["owned"])),
            v("공유 파일", files(t["shared"])), v("설계 절", qlist(t["design"])),
            v("하위 설계", t["sub"]), v("잔여 항목", qlist(t["residual"])),
            v("미해결 항목", qlist(t["open"])),
            "**범위**: %s 의 범위." % title, "**완료 기준**:", "- 시험이 통과한다.",
            "**발행 제목**: %s 구현" % title, "**발행 본문**:", "````text",
            "이 작업은 상태 파일의 %s 을 맡는다." % title, "````", ""]

L = ["# 상태 파일 티켓 배달", ""] + kind_lines + ["**상태**: 초안", "",
     "## 팀이 정한 요구 결정", "요구 하나: 상태 파일은 하나다.", "",
     "## 합의된 아키텍처", "상태 파일과 그 위의 소비자.", "",
     "### 저장 형식", "이름과 크기 두 필드.", "",
     "### 읽기, 쓰기 경로", "한 번에 하나의 쓰기.", "",
     "### 화면", "목록 하나.", "",
     "## 주요 결정사항과 근거", "", "### 읽기", "읽기는 잠그지 않는다.", "",
     "### 결정 둘", "쓰기는 원자적이다.", "",
     "## 미해결 이슈 / 트레이드오프", ""] + table + [
     "### 열린 항목 하나", "**상태**: 보류", "**구현 처분**: 구현 전 결정", "",
     "### 열린 항목 둘", "**상태**: 구현 재량", "",
     "### 닫힌 항목", "**상태**: 해결 — 정함", "",
     "## 검증 기록", "V1 관측한 사실.", "",
     "## 구현 시 검증 항목", "",
     "### R1. 형식 확인", "**검증 레시피**: §저장 형식 의 필드를 본다. R2 와 R3 을 함께 본다.", "",
     "### R2. 경로 확인", "**검증 레시피**: §읽기, 쓰기 경로 아래를 본다.", "",
     "### R3. 화면 확인", r3_body, "",
     "## 티켓 간 계약", "",
     "### 계약 C1 — 형식", "**제공 티켓**: T1", "**소비 티켓**: T2", "**형태**: 파일 형식",
     "**인터페이스**:", "````text", "name=<이름>", "````", "",
     "## 티켓 분할"] + ["**%s**: %s" % kv for kv in header] + ["",
     "### 베이스 티켓", "**발행 제목**: 상태 파일 도입", "**발행 본문**:", "````text",
     "상태 파일을 들인다.", "````", ""]
L += tblock("T1", "형식", "계약", "없음", "C1", "없음", t1)
L += tblock("T2", "화면", "구현", "T1", "없음", "C1", t2)
L += history
with open(out, "w", encoding="utf-8") as f:
    f.write("\n".join(L) + "\n")
PYEOF
tdgen() { python3 "$WORK/td.py" "$1" "$DOCS/td-$1.md"; }

tdgen ok
run_bs check "$DOCS/td-ok.md"
# Passing also shows that the comma inside 「### 읽기, 쓰기 경로」 does not
# split the item, and that T2's directory entry is allowed because its child
# design is not skipped.
check "td check: passing fixture exits 0" "$rc" "0"
check "td check: passing fixture prints nothing" "$out" ""
run_bs check "$DOCS/ok.md"
check "td check: the base kind fixture still passes" "$rc:$out" "0:"

expect_td() {  # <variant> <needle>
  tdgen "$1"
  run_bs check "$DOCS/td-$1.md"
  check "td check $1: exits 1" "$rc" "1"
  has "td check $1: reports '$2'" "$out" "$2"
}
expect_td bothkinds   "D0 판별자 줄 둘"
expect_td noreason    "T0 분할 사유 줄 없음"
expect_td tworeason   "T0 분할 사유 줄이 둘 이상"
expect_td nohist      "T0 ## 개정 이력 표제 0개"
expect_td t1missing   "T1 T1 설계 절에 맞는 표제 없음 「### 없는 절」"
expect_td t1unnamed   "T1 어느 티켓도 이름 부르지 않은 설계 절 소절 「### 화면」"
expect_td t1bad       "T1 T1 설계 절 목록 형식 오류"
expect_td t2dir       "T2 T1 생략 가능 티켓의 소유 파일 항목이 파일 경로가 아님 src/lib/"
expect_td t2glob      "T2 T1 생략 가능 티켓의 소유 파일 항목이 파일 경로가 아님 src/*.py"
expect_td t2n21       "T2 T1 생략 가능 티켓의 파일 21개 (상한 20)"
expect_td t2skill     "T2 T1 생략 가능 티켓이 SKILL.md 를 담고 README.md 를 담지 않음"
expect_td t2value     "T2 T1 하위 설계 값 아마"
expect_td t3unassigned "T3 잔여 항목 배정 없음 「### R3. 화면 확인」"
expect_td t3twice     "T3 잔여 항목 두 티켓 이상에 배정 「### R1. 형식 확인」"
expect_td t3missing   "T3 T2 의 잔여 항목 항목에 맞는 표제 없음 「### R9. 없는 항목」"
expect_td t4unassigned "T4 미해결 항목 배정 없음 「### 열린 항목 둘」"
expect_td t4closed    "T4 T2 의 미해결 항목 항목에 맞는 표제 없음 「### 닫힌 항목」"
expect_td t4twice     "T4 미해결 항목 두 티켓 이상에 배정 「### 열린 항목 하나」"
expect_td t4row       "T4 표 행으로 적힌 열린 미해결 항목 표로 적은 항목"
expect_td t5          "T5 R3 의 § 참조에 맞는 표제 없음 §없는 절"
tdgen t2n20
run_bs check "$DOCS/td-t2n20.md"
check "td check t2n20: twenty files pass" "$rc:$out" "0:"


# ---------------------------------------------------------------------------
# child-doc
# ---------------------------------------------------------------------------
CHILD="$WORK/child"
mkdir -p "$CHILD"
run_bs child-doc "$DOCS/td-ok.md" --ticket T1 --cutpoint 머지 --out "$CHILD/t1.md"
check "child-doc: exits 0" "$rc" "0"
C1DOC=$(cat "$CHILD/t1.md")
check "child-doc: heading order" "$(grep -E '^##? ' "$CHILD/t1.md" | tr '\n' '|')" \
  "# 형식|## 베이스 제약|## 합의된 아키텍처|## 미해결 이슈 / 트레이드오프|## 구현 시 검증 항목|## 구현 슬라이싱|"
check "child-doc: third-level headings in order" "$(grep -E '^### ' "$CHILD/t1.md" | tr '\n' '|')" \
  "### 티켓 T1 — 형식|### 계약 C1 — 형식|### 저장 형식|### 읽기, 쓰기 경로|### 상위 문서의 주요 결정사항과 근거|### 읽기|### 결정 둘|### 열린 항목 하나|### R1. 형식 확인|### R2. 경로 확인|### 슬라이스 A — 형식|"
has "child-doc: frozen" "$C1DOC" "**상태**: 동결됨"
has "child-doc: base document field" "$C1DOC" "**베이스 문서**: docs/td-ok.md"
has "child-doc: ticket field" "$C1DOC" "**티켓**: T1"
has "child-doc: base sha256 field" "$C1DOC" "**베이스 sha256**: $(shasum -a 256 "$DOCS/td-ok.md" | cut -d' ' -f1)"
check "child-doc: the ticket block is verbatim" \
  "$(python3 - "$DOCS/td-ok.md" "$CHILD/t1.md" <<'PYEOF'
import sys
def block(path, head):
    lines = open(path, encoding="utf-8").read().split("\n")
    i = lines.index(head)
    j = next(k for k in range(i + 1, len(lines)) if lines[k].startswith("## ") or lines[k].startswith("### "))
    seg = lines[i:j]
    while seg and not seg[-1].strip():
        seg.pop()
    return seg
a, b = sys.argv[1], sys.argv[2]
for head in ("### 티켓 T1 — 형식", "### 계약 C1 — 형식", "### 저장 형식", "### 읽기, 쓰기 경로",
             "### 읽기", "### 결정 둘", "### 열린 항목 하나"):
    if block(a, head) != block(b, head):
        print("differs " + head)
print("same")
PYEOF
)" "same"
has "child-doc: the linkage sentence" "$C1DOC" '이 문서의 `## 베이스 제약` 절에 옮긴 티켓 블록과 계약 블록은 이 절의 결정과 똑같이 구현을 구속한다.'
has "child-doc: the child sentence" "$C1DOC" '이 문서의 설계는 `## 베이스 제약` 에 옮긴 상위 티켓 부분이 전부다.'
check "child-doc: the linkage sentence is the first line of the architecture" \
  "$(grep -A2 '^## 합의된 아키텍처$' "$CHILD/t1.md" | sed -n 3p)" \
  '이 문서의 `## 베이스 제약` 절에 옮긴 티켓 블록과 계약 블록은 이 절의 결정과 똑같이 구현을 구속한다.'
hasnt "child-doc: an entry of another ticket is not copied" "$C1DOC" "### 열린 항목 둘"
hasnt "child-doc: a closed entry is not copied" "$C1DOC" "### 닫힌 항목"
has "child-doc: § is rewritten and the words after it stay" "$C1DOC" \
  "**검증 레시피**: 상위 문서의 「저장 형식」 의 필드를 본다. R2 와 상위 문서의 「### R3. 화면 확인」 을 함께 본다."
has "child-doc: § takes the longest heading" "$C1DOC" "**검증 레시피**: 상위 문서의 「읽기, 쓰기 경로」 아래를 본다."
has "child-doc: slice count 1 at 머지" "$C1DOC" "**슬라이스 수**: 1"
has "child-doc: declared files are owned then shared" "$C1DOC" '**선언 파일**: `src/fmt.py`, `README.md`, `src/common.py`'
has "child-doc: the slice repository" "$C1DOC" "**레포**: o/r"
has "child-doc: the cutpoint" "$C1DOC" "**절단점**: 머지"
has "child-doc: the residual list names the child headings" "$C1DOC" "**잔여 항목**: 「### R1. 형식 확인」, 「### R2. 경로 확인」"
run_bs fence-check "$CHILD/t1.md"
check "child-doc: the child document passes fence-check" "$rc:$out" "0:"

run_bs child-doc "$DOCS/td-ok.md" --ticket T1 --cutpoint 커밋 --out "$CHILD/t1-commit.md"
has "child-doc: slice count 0 at 커밋" "$(cat "$CHILD/t1-commit.md")" "**슬라이스 수**: 0"
run_bs child-doc "$DOCS/td-ok.md" --ticket T1 --cutpoint PR --out "$CHILD/t1-pr.md"
has "child-doc: slice count 1 at PR" "$(cat "$CHILD/t1-pr.md")" "**슬라이스 수**: 1"
run_bs child-doc "$DOCS/td-ok.md" --ticket T1 --cutpoint 머지 --out "$CHILD/t1.md"
check "child-doc: refused when --out exists" "$rc" "3"
run_bs child-doc "$DOCS/td-ok.md" --ticket T2 --cutpoint 머지 --out "$CHILD/t2.md"
check "child-doc: refused for a ticket whose child design is needed" "$rc:$([ -e "$CHILD/t2.md" ] && echo y || echo n)" "3:n"
run_bs child-doc "$DOCS/td-t5.md" --ticket T1 --cutpoint 머지 --out "$CHILD/t5.md"
check "child-doc: refused on an unmatched § in the upper document" "$rc:$([ -e "$CHILD/t5.md" ] && echo y || echo n)" "3:n"
run_bs child-doc "$DOCS/td-t4unassigned.md" --ticket T1 --cutpoint 머지 --out "$CHILD/viol.md"
check "child-doc: refused on an upper check violation" "$rc:$([ -e "$CHILD/viol.md" ] && echo y || echo n)" "3:n"
run_bs child-doc "$DOCS/td-ok.md" --ticket T1 --cutpoint 나중 --out "$CHILD/bad.md"
check "child-doc: refused on a cutpoint outside the vocabulary" "$rc" "3"
run_bs child-doc "$DOCS/ok.md" --ticket T1 --cutpoint 머지 --out "$CHILD/base.md"
check "child-doc: refused on a base kind document" "$rc" "3"
python3 - "$DOCS/td-ok.md" "$DOCS/td-noopen.md" <<'PYEOF'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
t = t.replace("**미해결 항목**: 「### 열린 항목 하나」", "**미해결 항목**: 없음")
t = t.replace("**미해결 항목**: 「### 열린 항목 둘」", "**미해결 항목**: 「### 열린 항목 둘」, 「### 열린 항목 하나」")
open(sys.argv[2], "w", encoding="utf-8").write(t)
PYEOF
run_bs child-doc "$DOCS/td-noopen.md" --ticket T1 --cutpoint 머지 --out "$CHILD/noopen.md"
check "child-doc: 없음 when no entry is assigned" \
  "$(grep -A2 '^## 미해결 이슈 / 트레이드오프$' "$CHILD/noopen.md" | sed -n 3p)" "없음"

# ---------------------------------------------------------------------------
# fence-check
# ---------------------------------------------------------------------------
fence_doc() {  # <name> <python replacement pairs...>: a child document edited from t1.md
  python3 - "$CHILD/t1.md" "$CHILD/$1.md" "${@:2}" <<'PYEOF'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
pairs = sys.argv[3:]
for old, new in zip(pairs[::2], pairs[1::2]):
    assert old in t, old
    t = t.replace(old, new)
open(sys.argv[2], "w", encoding="utf-8").write(t)
PYEOF
}
DECL='**선언 파일**: `src/fmt.py`, `README.md`, `src/common.py`'
fence_doc outside "$DECL" "$DECL, \`src/x.py\`"
run_bs fence-check "$CHILD/outside.md"
check "fence-check: a declared file outside the fence fails" "$rc:$out" "1:F1 슬라이스 A 울타리 밖 선언 파일 src/x.py"
fence_doc listed "$DECL" "$DECL, \`src/x.py\`
**티켓 밖 파일**:
- \`src/x.py\` — 앞 티켓 결함 — 읽기 경로가 틀렸다"
run_bs fence-check "$CHILD/listed.md"
check "fence-check: an outside file listed with a reason passes" "$rc:$out" "0:"
fence_doc noreason "$DECL" "$DECL, \`src/x.py\`
**티켓 밖 파일**:
- \`src/x.py\` — "
run_bs fence-check "$CHILD/noreason.md"
check "fence-check: an empty reason fails" "$rc" "1"
has "fence-check: names the empty reason" "$out" "F1 슬라이스 A 티켓 밖 파일 사유 없음 src/x.py"
fence_doc undeclared "$DECL" "$DECL
**티켓 밖 파일**:
- \`src/y.py\` — 쓰지 않는 항목"
run_bs fence-check "$CHILD/undeclared.md"
check "fence-check: an outside entry that is not declared fails" "$rc:$out" "1:F1 슬라이스 A 선언 파일에 없는 티켓 밖 파일 항목 src/y.py"
fence_doc dirfence '**소유 파일**: `src/fmt.py`, `README.md`' '**소유 파일**: `src/`, `README.md`' "$DECL" "$DECL, \`src/deep/z.py\`"
run_bs fence-check "$CHILD/dirfence.md"
check "fence-check: a directory entry covers by prefix" "$rc:$out" "0:"
fence_doc noticket '### 티켓 T1 — 형식' '### 티켓 아님'
run_bs fence-check "$CHILD/noticket.md"
check "fence-check: a missing ticket block fails" "$rc" "1"
has "fence-check: names the missing ticket block" "$out" "F1 ## 베이스 제약 의 티켓 블록 0개 (정확히 하나여야 함)"

# ---------------------------------------------------------------------------
# record --started
# ---------------------------------------------------------------------------
cp "$DOCS/td-ok.md" "$DOCS/rs.md"
RSREG="$DOCS/design-base/rs.tickets.md"
run_bs record --started "$DOCS/rs.md" --ticket T1 --run r1
check "record --started: refused without a registry" "$rc:$([ -e "$RSREG" ] && echo y || echo n)" "3:n"
run_bs record "$DOCS/rs.md" --row "$NONE_ROW" --doc-only
check "record --started: the registry is made by record --doc-only" "$rc" "0"
run_bs record --started "$DOCS/rs.md" --ticket T1 --run r1
check "record --started: exits 0" "$rc" "0"
has "record --started: writes the row" "$(cat "$RSREG")" '- `착수` | id=T1 | 런=r1'
cp "$RSREG" "$WORK/rs.once"
run_bs record --started "$DOCS/rs.md" --ticket T1 --run r1
check "record --started: a second call for the same run changes nothing" \
  "$rc:$(cmp -s "$RSREG" "$WORK/rs.once" && echo same || echo differs)" "0:same"
run_bs record --started "$DOCS/rs.md" --ticket T1 --run r0
run_bs record --started "$DOCS/rs.md" --ticket T2 --run r0
check "record --started: rows of other runs stay, by ticket then run" \
  "$(grep '착수' "$RSREG" | tr '\n' '|')" '- `착수` | id=T1 | 런=r0|- `착수` | id=T1 | 런=r1|- `착수` | id=T2 | 런=r0|'
check "record --started: started rows sit after ticket rows and before relation rows" \
  "$(sed -e '1d' -e '$d' "$RSREG" | cut -d'|' -f1 | uniq | tr '\n' '|')" '- `베이스` |- `티켓` |- `착수` |- `관계` |'
check "record --started: the lock is gone" "$([ -e "$DOCS/rs.md.revise.lock" ] && echo y || echo n)" "n"
cp "$RSREG" "$WORK/rs.three"
run_bs check "$DOCS/rs.md"
run_bs record "$DOCS/rs.md" --row "$NONE_ROW" --doc-only
check "record --started: record --doc-only keeps the started rows byte for byte" \
  "$rc:$(cmp -s "$RSREG" "$WORK/rs.three" && echo same || echo differs)" "0:same"
mkdir "$DOCS/rs.md.revise.lock"
run_bs record --started "$DOCS/rs.md" --ticket T2 --run r5
check "record --started: refused while the lock is held" "$rc" "3"
hasnt "record --started: nothing is written under a held lock" "$(cat "$RSREG")" "런=r5"
rmdir "$DOCS/rs.md.revise.lock"
run_bs record --started "$DOCS/rs.md" --ticket T9 --run r1
check "record --started: refused for a ticket the document lacks" "$rc" "3"
run_bs record --started "$DOCS/rs.md" --ticket T1 --run 'r 1'
check "record --started: refused for a run id the registry cannot hold" "$rc" "3"
run_bs record --started "$DOCS/rs.md" --ticket T1 --run r1 --row "$NONE_ROW"
check "record --started: --row is a usage error" "$rc" "2"
run_bs record --started "$DOCS/rs.md" --ticket T1 --run r1 --doc-only
check "record --started: --doc-only is a usage error" "$rc" "2"
run_bs record "$DOCS/rs.md" --doc-only
check "record: --row is still required without --started" "$rc" "2"
run_bs record --started "$DOCS/none.md" --ticket T1 --run r1
check "record --started: refused on a base kind document" "$rc" "3"
OLDSHA=$(head -1 "$RSREG" | sed -E 's/.*doc-sha256=([0-9a-f]+);.*/\1/')
printf '\n' >> "$DOCS/rs.md"
run_bs record --started "$DOCS/rs.md" --ticket T2 --run r6
check "record --started: the head keeps the document sha256 it read" \
  "$rc:$(head -1 "$RSREG" | sed -E 's/.*doc-sha256=([0-9a-f]+);.*/\1/')" "0:$OLDSHA"

# ---------------------------------------------------------------------------
# revise
# ---------------------------------------------------------------------------
RV="$WORK/rv"
mkdir -p "$RV/docs"
cp "$DOCS/td-ok.md" "$RV/pristine.md"
RVDOC="$RV/docs/up.md"
RVREG="$RV/docs/design-base/up.tickets.md"
# reg_with <started rows...>: a registry for up.md holding those `T<n>:<run>` rows.
reg_with() {
  cp "$RV/pristine.md" "$RVDOC"
  rm -rf "$RV/docs/design-base" "$RVDOC.revise.lock"
  "$BS" record "$RVDOC" --row "$NONE_ROW" --doc-only >/dev/null
  for x in "$@"; do "$BS" record --started "$RVDOC" --ticket "${x%%:*}" --run "${x#*:}" >/dev/null; done
  cp "$RVREG" "$RV/reg.before"
}
# cand <name> [--changed V] [--run R] [--nohist|--twohist] <old> <new> ...: a
# candidate edited from the pristine copy, with one revision entry appended.
cand() {
  python3 - "$RV/pristine.md" "$RV/$1.md" "${@:2}" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
changed, run, hist = "설계 절", "r1", 1
while args and args[0].startswith("--"):
    flag = args.pop(0)
    if flag == "--changed":
        changed = args.pop(0)
    elif flag == "--run":
        run = args.pop(0)
    elif flag == "--nohist":
        hist = 0
    elif flag == "--twohist":
        hist = 2
t = open(src, encoding="utf-8").read()
for old, new in zip(args[::2], args[1::2]):
    assert old in t, old
    t = t.replace(old, new, 1)
entries = []
for n in range(1, hist + 1):
    entries += ["### 개정 %d — 2026-11-03 · 런 %s · 티켓 T1" % (n, run), "**바꾼 절**: " + changed,
                "**영향 티켓**: T1", "**완료 티켓 차이**: 없음", ""]
if hist:
    assert t.endswith("## 개정 이력\n없음\n")
    t = t[:-len("없음\n")] + "\n".join(entries).rstrip("\n") + "\n"
open(dst, "w", encoding="utf-8").write(t)
PYEOF
}
# revise_ok <case> <candidate> [revise args...]
revise_ok() {
  run_bs revise "$RVDOC" --from "$RV/pristine.md" --to "$RV/$2.md" --ticket T1 "${@:3}"
  check "revise $1: exits 0" "$rc" "0"
  check "revise $1: the document is the candidate" "$(cmp -s "$RVDOC" "$RV/$2.md" && echo same || echo differs)" "same"
  check "revise $1: the registry head carries the new sha256" \
    "$(head -1 "$RVREG" | sed -E 's/.*doc-sha256=([0-9a-f]+);.*/\1/')" "$(shasum -a 256 "$RV/$2.md" | cut -d' ' -f1)"
  check "revise $1: the lock is gone" "$([ -e "$RVDOC.revise.lock" ] && echo y || echo n)" "n"
}
# revise_no <case> <candidate> <needle> [revise args...]
revise_no() {
  run_bs revise "$RVDOC" --from "$RV/pristine.md" --to "$RV/$2.md" --ticket T1 "${@:4}"
  check "revise $1: refused" "$rc" "3"
  has "revise $1: says why" "$(cat "$WORK/stderr")" "$3"
  check "revise $1: the document and the registry are unchanged" \
    "$(cmp -s "$RVDOC" "$RV/pristine.md" && cmp -s "$RVREG" "$RV/reg.before" && echo same || echo differs)" "same"
  check "revise $1: the lock is gone" "$([ -e "$RVDOC.revise.lock" ] && echo y || echo n)" "n"
}
T1D='**설계 절**: 「### 저장 형식」, 「### 읽기, 쓰기 경로」'

reg_with T1:r1
cand design "$T1D" '**설계 절**: 「### 저장 형식」'
revise_ok "P ticket design sections" design --run r1
has "revise: prints the old and new sha256" "$out" "개정 $RVDOC $(shasum -a 256 "$RV/pristine.md" | cut -d' ' -f1) → "
has "revise: the started rows stay" "$(cat "$RVREG")" '- `착수` | id=T1 | 런=r1'
reg_with T1:r1
cand t2owned '**소유 파일**: `ui/`' '**소유 파일**: `ui/`, `web/`'
revise_ok "owned files of an unstarted ticket" t2owned --run r1
reg_with T1:r1 T2:r0
cand subsection '이름과 크기 두 필드.' '이름과 크기와 시각 세 필드.'
revise_ok "a subsection only P tickets name" subsection --run r1
reg_with T1:r1 T2:r0
cand decisions --changed '주요 결정사항과 근거' '쓰기는 원자적이다.' '쓰기는 임시 파일을 거쳐 원자적이다.'
revise_ok "decisions within the changed sections" decisions --run r1
reg_with T1:r1 T2:r0
cand openentry --changed '미해결 이슈 / 트레이드오프' '**구현 처분**: 구현 전 결정' '**구현 처분**: 구현 전 결정
**사유**: 형식이 아직 둘이다.'
revise_ok "an open entry assigned to P" openentry --run r1
reg_with T1:r1 T2:r0
cand residual --changed 'R2. 경로 확인' '아래를 본다.' '아래를 다시 본다.'
revise_ok "a residual item assigned to P" residual --run r1
reg_with T1:r1 T1:r2 T2:r0
cand rekick --run r2 "$T1D" '**설계 절**: 「### 저장 형식」'
revise_ok "a follow-up run after a re-kickoff" rekick --run r2

reg_with T1:r1 T2:r0
cand doneticket '**설계 절**: 「### 화면」, 「### 읽기, 쓰기 경로」' '**설계 절**: 「### 화면」'
revise_no "a started ticket of another run" doneticket "T2 의 바꿀 수 없는 필드가 바뀜 설계 절" --run r1
cand pubtitle '**발행 제목**: 형식 구현' '**발행 제목**: 형식 새 구현'
revise_no "a publication title" pubtitle "T1 의 바꿀 수 없는 필드가 바뀜 발행 제목" --run r1
cand pubbody '이 작업은 상태 파일의 형식 을 맡는다.' '이 작업은 상태 파일의 새 형식 을 맡는다.'
revise_no "a publication body" pubbody "T1 의 바꿀 수 없는 필드가 바뀜 발행 본문" --run r1
cand scope '**범위**: 형식 의 범위.' '**범위**: 형식 의 넓은 범위.'
revise_no "the scope of a P ticket" scope "T1 의 바꿀 수 없는 필드가 바뀜 범위" --run r1
cand done '**완료 기준**:
- 시험이 통과한다.' '**완료 기준**:
- 시험이 모두 통과한다.'
revise_no "the done criteria of a P ticket" done "T1 의 바꿀 수 없는 필드가 바뀜 완료 기준" --run r1
cand contract '**형태**: 파일 형식' '**형태**: 새 파일 형식'
revise_no "a contract block" contract "## 티켓 간 계약 는 바꿀 수 없는 절" --run r1
cand ownfiles '**소유 파일**: `src/fmt.py`, `README.md`' '**소유 파일**: `src/fmt.py`, `README.md`, `src/more.py`'
revise_no "the own ticket's owned files" ownfiles "T1 의 바꿀 수 없는 필드가 바뀜 소유 파일" --run r1
cand ownshared '**공유 파일**: `src/common.py`' '**공유 파일**: `src/common.py`, `src/more.py`'
revise_no "the own ticket's shared files" ownshared "T1 의 바꿀 수 없는 필드가 바뀜 공유 파일" --run r1
cand ownnest '**범위**: 형식 의 범위.' '**중첩 사유**: 넓힌다.
**범위**: 형식 의 범위.'
revise_no "the own ticket's nesting reason" ownnest "T1 의 바꿀 수 없는 필드가 바뀜 중첩 사유" --run r1
cand requirements '요구 하나: 상태 파일은 하나다.' '요구 하나: 상태 파일은 둘이다.'
revise_no "the team requirements" requirements "## 팀이 정한 요구 결정 는 바꿀 수 없는 절" --run r1
cand record 'V1 관측한 사실.' 'V1 다르게 관측한 사실.'
revise_no "the verification record" record "## 검증 기록 는 바꿀 수 없는 절" --run r1
cand decnot '쓰기는 원자적이다.' '쓰기는 임시 파일을 거쳐 원자적이다.'
revise_no "decisions outside the changed sections" decnot "## 주요 결정사항과 근거 가 바뀌었는데 바꾼 절 이 그 절을 적지 않음" --run r1
cand otheropen --changed '미해결 이슈 / 트레이드오프' '**상태**: 구현 재량' '**상태**: 구현 재량
**사유**: 바꿔 본다.'
revise_no "an open entry assigned to a started ticket" otheropen "항목 「### 열린 항목 둘」 을 배정받은 티켓 T2 가 바꿀 수 있는 티켓이 아님" --run r1
cand nohist --nohist "$T1D" '**설계 절**: 「### 저장 형식」'
revise_no "a missing revision entry" nohist "새 개정 항목이 정확히 하나가 아님 (0개)" --run r1
cand twohist --twohist "$T1D" '**설계 절**: 「### 저장 형식」'
revise_no "two revision entries" twohist "새 개정 항목이 정확히 하나가 아님 (2개)" --run r1
revise_no "a run without a started row" design "등록부에 T1 의 런 r9 착수 행이 없음" --run r9
cand badcheck "$T1D" '**설계 절**: 「### 저장 형식」, 「### 없는 절」'
revise_no "a candidate that fails check" badcheck "후보 점검 위반" --run r1
reg_with T1:r1 T2:r0
rc=0; out=$(CC_PIPELINE_RUN_ID=r7 "$BS" revise "$RVDOC" --from "$RV/pristine.md" --to "$RV/design.md" \
  --ticket T1 --run r1 2>"$WORK/stderr") || rc=$?
check "revise: refused when --run is not the run's id" "$rc" "3"
has "revise: says the run id differs" "$(cat "$WORK/stderr")" "--run 이 이 런의 run id 와 다름"

reg_with T1:r1
cand addowned '**소유 파일**: `ui/`' '**소유 파일**: `ui/`, `src/fmt.py`'
revise_no "an unstarted ticket taking a started ticket's file" addowned "T2 에 더한 src/fmt.py 가 착수한 T1 의 소유 파일 src/fmt.py 와 겹침" --run r1
cand addshared '**공유 파일**: 없음' '**공유 파일**: `src/fmt.py`'
revise_no "an unstarted ticket sharing a started ticket's file" addshared "T2 에 더한 src/fmt.py 가 착수한 T1 의 소유 파일 src/fmt.py 와 겹침" --run r1

cp "$RV/design.md" "$RV/other.md"
printf '\n' >> "$RV/other.md"
run_bs revise "$RVDOC" --from "$RV/other.md" --to "$RV/design.md" --ticket T1 --run r1
check "revise: refused when the document is not the --from copy" "$rc" "3"
has "revise: says the sha256 differs" "$(cat "$WORK/stderr")" "상위 문서의 sha256 이 --from 과 다름"
mkdir "$RVDOC.revise.lock"
run_bs revise "$RVDOC" --from "$RV/pristine.md" --to "$RV/design.md" --ticket T1 --run r1
check "revise: refused while another call holds the lock" "$rc" "3"
check "revise: a held lock leaves the document unchanged" "$(cmp -s "$RVDOC" "$RV/pristine.md" && echo same || echo differs)" "same"
check "revise: a lock it did not take stays" "$([ -d "$RVDOC.revise.lock" ] && echo y || echo n)" "y"
rmdir "$RVDOC.revise.lock"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
