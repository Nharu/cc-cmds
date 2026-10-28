# entry-plan.check.jq — the structure of an entry judgment, asserted.
#
# Input: the plan JSON frozen under `## 실행 계획`. Output: nothing when the plan
# holds, and one violation per line on stderr with a non-zero exit when it does
# not (`halt_error`).
#
# THE SAME FILE IS RUN BY THREE CALLERS — the kickoff on its own output and
# after a raise, `check_manifest` on every gate entry and on the driver's start,
# and the C4 section of `scripts/test-gate.sh`. One file is what keeps the three
# from asserting different rules.
#
# A PLAN WITHOUT `design_tier_judged` IS ASSERTED ON (f) ALONE. Every plan
# frozen before the key existed lacks it, and its tier (`team-2`, `lead-solo`,
# `null`) is outside the two values below; refusing it here would stop runs
# that are already frozen.
#
# The tier and the path read as the contract sentence `run.sh` writes once, on
# `manifest_design_skill`:
#
#   > `design_tier` decides whether the graph carries the audit — `solo`: no
#   > `design-audit` step; `team-4`: exactly one, after the design.
#   > `design_path` records who writes a team-4 single-scope document —
#   > `solo-audit`: the lead alone; `discuss-audit`: the discussion team — and
#   > is `none` on every other plan. A plan with no `design_path` key was frozen
#   > before the key existed and reads `discuss-audit` where the key would name
#   > a writer (a team-4 single-scope design) and `none` elsewhere. Only
#   > `manifest_design_skill` turns scope, tier and path into the design skill.
#
# SEVEN ASSERTIONS AND NO MORE. A `team-4` graph is asserted on only through
# `design_path`, and only when the key is present:
#
#   (a) a `team-4` judgment carries at least one heavy reason that is not blank,
#       and a `solo` judgment carries none;
#   (b) the confirmed tier is never below the judged one — a person raises, the
#       kickoff never lowers;
#   (c) a `solo` plan that designs has exactly one `design` step, no
#       `design-audit` step, no `split` step and the `single` scope;
#   (d) a `design_path` key, when present, holds one of `solo-audit`,
#       `discuss-audit` and `none`. On a plan that designs it also matches the
#       plan: a `team-4` single-scope plan names a writer (`solo-audit` or
#       `discuss-audit`, never `none`), every other plan reads `none`, and a
#       `solo-audit` plan has exactly one `design` step and one `design-audit`
#       step. A plan that does not design — a rekick's follow-up, which keeps
#       the original key and drops the frozen design and the finished audit —
#       is checked on the value alone. A plan without the key passes (d).
#   (e) an `enforcement_surface` judgment, WHEN THE PLAN CARRIES ONE, has its
#       shape: a judgment from the closed four, every path naming one of the
#       four classes and listed under `classes`, at least one path when it says
#       `확인됨` and none when it says `없음`. A plan frozen before the key
#       existed has none and is not asserted on it — this file runs on every
#       gate entry, and refusing it would stop runs that are already frozen.
#       Whether a path really is a surface is the classifier's to say, not this
#       file's: (e) checks the shape the kickoff reads out, nothing more.
#   (f) a `run_profile` reads `hotfix` or `standard`, and a plan without the
#       key reads `standard`. A `hotfix` plan is the fixed frame the `--hotfix`
#       kickoff fills: the `solo` tier, the `single` scope, and its steps'
#       skills exactly `design` → `implement` → `review`. Its `unresolved`
#       carries only the stop notices of the enforcement surface: empty when
#       the judgment is `없음` or `판정불가`, and when it is `확인됨` or
#       `가능성`, at least one item and no more items than the judgment's paths
#       (one when it names no path). The items are free text, so only their
#       count is bound here; the prompt keeps each one a surface notice. A
#       hotfix plan with no `enforcement_surface` fails (f). A hotfix plan
#       that carries `review_expand` holds `[]` there: a hotfix run is always
#       reviewed on the default field. A hotfix plan without the key was
#       frozen before it existed and passes; the rationale beside it is free
#       text and is not bound. Neither the number of targets nor the number
#       of files is asked.
#   (g) a `review_expand`, WHEN THE PLAN CARRIES ONE, is an array whose items
#       are each `요구` or `문서표현` with no item twice, and a non-empty one
#       has a `review_expand_rationale` that is not blank. A plan frozen
#       before the key existed has none and is not asserted on it, for the
#       reason (e) gives.
#
# (f) RUNS ON THE EARLY RETURN TOO. A hotfix plan that dropped
# `design_tier_judged` would otherwise skip the one assertion that pins its
# frame. A plan frozen before `design_tier_judged` existed has no `run_profile`
# either, so on that branch nothing is still asserted on it.

def tier_rank:
  if . == "solo" then 0 elif . == "team-4" then 1 else null end;

# A step written as a bare skill string is an older plan shape; it is read as
# `{skill: .}`, as `check_manifest` reads it.
def plan_steps:
  [.steps[]? | if type == "object" then . else {skill: .} end];

def skill_count($s):
  [plan_steps[] | select(.skill == $s)] | length;

def blank:
  type != "string" or test("^[[:space:]]*$");

def report:
  if length > 0 then (join("\n") + "\n") | halt_error(1) else empty end;

# (f), as a list of violations.
def hotfix_violations:
  . as $p
  | ($p.run_profile // "standard") as $rp
  | if ($rp | IN("hotfix", "standard")) | not then
      "(f) 핫픽스 계획 표지 run_profile 이 hotfix · standard 중 하나가 아닙니다: \($rp | tojson)"
    elif $rp != "hotfix" then empty
    else
      ( if $p.design_tier != "solo" then
          "(f) 핫픽스 계획의 design_tier 가 solo 가 아닙니다: \($p.design_tier | tojson)"
        else empty end ),
      ( if ($p.design_scope // "single") != "single" then
          "(f) 핫픽스 계획의 design_scope 가 single 이 아닙니다: \($p.design_scope | tojson)"
        else empty end ),
      ( [plan_steps[] | .skill] as $sk
        | if $sk != ["design", "implement", "review"] then
            "(f) 핫픽스 계획의 단계가 design → implement → review 가 아닙니다: \($sk | tojson)"
          else empty end ),
      ( ([$p.unresolved[]?] | length) as $n
        | if ($p.enforcement_surface | type) != "object" then
            "(f) 핫픽스 계획에 enforcement_surface 판정이 없습니다"
          else
            ($p.enforcement_surface.judgment) as $j
            | ([$p.enforcement_surface.paths[]?] | length) as $np
            | if $j == "없음" or $j == "판정불가" then
                ( if $n != 0 then
                    "(f) 핫픽스 계획의 강제 표면 판정이 \($j)인데 unresolved 가 \($n)개입니다 — 비어 있어야 합니다"
                  else empty end )
              elif $j == "확인됨" or $j == "가능성" then
                ( if $np == 0 then 1 else $np end ) as $max
                | ( if $n < 1 or $n > $max then
                      "(f) 핫픽스 계획의 강제 표면 판정이 \($j)인데 unresolved 가 \($n)개입니다 — 1개 이상 \($max)개 이하여야 합니다"
                    else empty end )
              else
                "(f) 핫픽스 계획의 enforcement_surface.judgment 가 확인됨 · 가능성 · 없음 · 판정불가 중 하나가 아닙니다: \($j | tojson)"
              end
          end ),
      ( if ($p | has("review_expand")) and $p.review_expand != [] then
          "(f) 핫픽스 계획의 review_expand 가 [] 가 아닙니다: \($p.review_expand | tojson)"
        else empty end )
    end;

if type != "object" then
  "계획이 JSON 객체가 아닙니다\n" | halt_error(1)
elif has("design_tier_judged") | not then
  [hotfix_violations] | report
else
  . as $p
  | ($p.design_tier_judged) as $judged
  | ($p.design_tier) as $tier
  | ($p.design_heavy_reasons) as $reasons
  | [
      # (a)
      ( if $judged == "team-4" then
          if ($reasons | type) != "array" or ([$reasons[] | select(blank | not)] | length) == 0 then
            "(a) design_tier_judged 가 team-4 인데 design_heavy_reasons 에 비어 있지 않은 사유가 하나도 없습니다"
          else empty end
        elif $judged == "solo" then
          if $reasons != [] then
            "(a) design_tier_judged 가 solo 인데 design_heavy_reasons 가 빈 배열이 아닙니다"
          else empty end
        else empty end ),
      # (b)
      ( if ($judged | tier_rank) == null then
          "(b) design_tier_judged 가 solo · team-4 중 하나가 아닙니다: \($judged | tojson)"
        else empty end ),
      ( if ($tier | tier_rank) == null then
          "(b) design_tier 가 solo · team-4 중 하나가 아닙니다: \($tier | tojson)"
        else empty end ),
      ( if ($judged | tier_rank) != null and ($tier | tier_rank) != null
           and ($tier | tier_rank) < ($judged | tier_rank) then
          "(b) design_tier(\($tier)) 가 design_tier_judged(\($judged)) 보다 낮습니다 — 티어는 올리기만 합니다"
        else empty end ),
      # (c)
      ( if $tier == "solo" and $p.design_required == true then
          ( if ($p | skill_count("design")) != 1 then
              "(c) solo 계획의 design 단계가 \($p | skill_count("design"))개입니다 — 정확히 하나여야 합니다"
            else empty end ),
          ( if ($p | skill_count("design-audit")) != 0 then
              "(c) solo 계획에 design-audit 단계가 있습니다 — 감사는 team-4 에서만 돕니다"
            else empty end ),
          ( if ($p | skill_count("split")) != 0 then
              "(c) solo 계획에 split 단계가 있습니다"
            else empty end ),
          ( if ($p.design_scope // "single") != "single" then
              "(c) solo 계획의 design_scope 가 single 이 아닙니다: \($p.design_scope | tojson)"
            else empty end )
        else empty end ),
      # (d)
      ( if ($p | has("design_path")) | not then empty
        elif ($p.design_path | IN("solo-audit", "discuss-audit", "none")) | not then
          "(d) design_path 가 solo-audit · discuss-audit · none 중 하나가 아닙니다: \($p.design_path | tojson)"
        elif $p.design_required != true then empty
        else
          ( if $tier == "team-4" and ($p.design_scope // "single") == "single" then
              ( if $p.design_path == "none" then
                  "(d) team-4 단일 설계 계획의 design_path 가 none 입니다 — solo-audit 또는 discuss-audit 여야 합니다"
                else empty end )
            elif $p.design_path != "none" then
              "(d) team-4 단일 설계가 아닌 계획의 design_path 가 \($p.design_path) 입니다 — none 이어야 합니다"
            else empty end ),
          ( if $p.design_path == "solo-audit" then
              ( if ($p | skill_count("design")) != 1 then
                  "(d) solo-audit 계획의 design 단계가 \($p | skill_count("design"))개입니다 — 정확히 하나여야 합니다"
                else empty end ),
              ( if ($p | skill_count("design-audit")) != 1 then
                  "(d) solo-audit 계획의 design-audit 단계가 \($p | skill_count("design-audit"))개입니다 — 정확히 하나여야 합니다"
                else empty end )
            else empty end )
        end ),
      # (e)
      ( if $p | has("enforcement_surface") then
          ($p.enforcement_surface) as $es
          | ["프로젝트설정", "트랜스크립트", "규칙카탈로그", "지침파일"] as $cls
          | if ($es | type) != "object" then
              "(e) enforcement_surface 가 객체가 아닙니다: \($es | tojson)"
            else
              ($es.judgment) as $j
              | ([$es.paths[]?]) as $paths
              | ( if (["확인됨", "가능성", "없음", "판정불가"] | index($j)) == null then
                    "(e) enforcement_surface.judgment 가 확인됨 · 가능성 · 없음 · 판정불가 중 하나가 아닙니다: \($j | tojson)"
                  else empty end ),
                ( if ($es.classes | type) != "array" or ([$es.classes[] | select(. as $v | ($cls | index($v)) == null)] | length) > 0 then
                    "(e) enforcement_surface.classes 에 네 분류 밖의 값이 있습니다: \($es.classes | tojson)"
                  else empty end ),
                ( $paths[] | select((.class as $c | ($es.classes // []) | index($c)) == null)
                  | "(e) enforcement_surface.paths 의 \(.path | tojson) 가 classes 에 없는 분류 \(.class | tojson) 를 답니다" ),
                ( if $j == "확인됨" and ($paths | length) == 0 then
                    "(e) enforcement_surface.judgment 가 확인됨인데 paths 가 비어 있습니다"
                  elif $j == "없음" and ($paths | length) > 0 then
                    "(e) enforcement_surface.judgment 가 없음인데 paths 가 비어 있지 않습니다"
                  else empty end )
            end
        else empty end ),
      # (f)
      ( $p | hotfix_violations ),
      # (g)
      ( if $p | has("review_expand") then
          ($p.review_expand) as $rx
          | if ($rx | type) != "array" then
              "(g) review_expand 가 배열이 아닙니다: \($rx | tojson)"
            else
              ( if ([$rx[] | select(IN("요구", "문서표현") | not)] | length) > 0 then
                  "(g) review_expand 에 요구 · 문서표현 밖의 값이 있습니다: \($rx | tojson)"
                else empty end ),
              ( if ($rx | length) != ($rx | unique | length) then
                  "(g) review_expand 에 같은 값이 두 번 있습니다: \($rx | tojson)"
                else empty end ),
              ( if ($rx | length) > 0 and ($p.review_expand_rationale | blank) then
                  "(g) review_expand 가 비어 있지 않은데 review_expand_rationale 이 비어 있습니다"
                else empty end )
            end
        else empty end )
    ]
  | report
end
