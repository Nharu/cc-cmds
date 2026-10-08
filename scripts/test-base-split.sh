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
has()   { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "missing '$3' in: $2"; fi; }
hasnt() { if printf '%s\n' "$2" | grep -qF -- "$3"; then bad "$1" "unexpected '$3' in: $2"; else ok "$1"; fi; }

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

# The installed ClickUp tools decide whether a ClickUp plan may exist at all:
# `plan` emits an argv only when every tool it names is there and its own
# parser lists every option the argv passes.
real_ready=1
[ -x "$ORCH/clickup-relate.py" ] || real_ready=0
if [ "$real_ready" = 1 ]; then
  "$ORCH/clickup-relate.py" --help 2>/dev/null | grep -qE -- '--depends-on' || real_ready=0
  "$ORCH/clickup-create.py" --help 2>/dev/null | grep -qE -- '--parent' || real_ready=0
fi
printf 'stale\n' > "$OUT/plan.jsonl"
run_bs plan "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT"
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
    for o in "$@"; do printf 'p.add_argument("%s")\n' "$o"; done
    printf 'p.parse_args()\n'
  } > "$STUB_DIR/$name"
  chmod +x "$STUB_DIR/$name"
}
# Every plan that succeeds is kept, so the parse check below sees each argv.
run_stub() {
  rc=0; out=$("$STUB_DIR/base-split.py" "$@" 2>"$WORK/stderr") || rc=$?
  if [ "$1" = plan ] && [ "$rc" = 0 ]; then cat "$OUT/plan.jsonl" >> "$WORK/cu-all.jsonl"; fi
}

stub_tool clickup-create.py --list --name --description-file
stub_tool clickup-relate.py --task --depends-on
refused_stub() {  # <label>
  printf 'stale\n' > "$OUT/plan.jsonl"
  run_stub plan "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT"
  check "plan clickup refuses: $1 (exit)" "$rc" "3"
  check "plan clickup refuses: $1 (no command)" "$(wc -c < "$OUT/plan.jsonl" | tr -d ' ')" "0"
}
refused_stub "create tool without --parent"
stub_tool clickup-create.py --list --name --description-file --parent
rm -f "$STUB_DIR/clickup-relate.py"
refused_stub "relate tool missing"
stub_tool clickup-relate.py --task --depends-on

run_stub plan "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT"
check "plan clickup: exits 0" "$rc" "0"
base_argv=$(argv_of base)
case "$base_argv" in
  "$STUB_DIR/clickup-create.py --list 901234 --name 상태 파일 도입 --description-file $OUT/body-base.md") ok "plan clickup: argv0 is the absolute tool path, no interpreter" ;;
  *) bad "plan clickup: argv0 is the absolute tool path, no interpreter" "$base_argv" ;;
esac
run_stub record "$DOCS/cu.md" --row "$CU_ROW" --entry base --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/abc
check "record clickup: 발행됨 without a node id is refused" "$rc" "3"
run_stub record "$DOCS/cu.md" --row "$CU_ROW" --entry base --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/abc --node-id abc
run_stub plan "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT"
check "plan clickup: child carries --parent node" "$(argv_of T2)" \
  "$STUB_DIR/clickup-create.py --list 901234 --name 조각 2 구현 --description-file $OUT/body-T2.md --parent abc"
has "plan clickup: dependency waits for its ticket" "$(entries)" "rel:선행:T3:T2:wait"
run_stub record "$DOCS/cu.md" --row "$CU_ROW" --entry T2 --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/t2 --node-id t2
run_stub record "$DOCS/cu.md" --row "$CU_ROW" --entry T1 --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/t1 --node-id t1
run_stub plan "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT"
run_stub record "$DOCS/cu.md" --row "$CU_ROW" --entry T3 --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/t3 --node-id t3
run_stub plan "$DOCS/cu.md" --row "$CU_ROW" --out "$OUT"
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
run_stub plan "$DOCS/cur.md" --row "$CU_ROW" --out "$OUT"
has "plan clickup resume: the in-flight ticket is resolved" "$(entries)" "T2:resolve"
run_stub record "$DOCS/cur.md" --row "$CU_ROW" --entry T2 --plan "$OUT/plan.jsonl" --state 발행됨 --ref https://app.clickup.com/t/t2 --node-id t2
check "record clickup: a resolve to 발행됨 exits 0" "$rc" "0"
has "record clickup: a resolve to 발행됨 ties the child relation" "$(cat "$CUREG")" \
  '- `관계` | 종류=하위 | 원=T2 | 대상=베이스 | 상태=걸림'

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
