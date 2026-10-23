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
# A PLAN WITHOUT `design_tier_judged` IS NOT ASSERTED AT ALL. Every plan frozen
# before the key existed lacks it, and its tier (`team-2`, `lead-solo`, `null`)
# is outside the two values below; refusing it here would stop runs that are
# already frozen.
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
# FOUR ASSERTIONS AND NO MORE. A `team-4` graph is asserted on only through
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

if type != "object" then
  "계획이 JSON 객체가 아닙니다\n" | halt_error(1)
elif has("design_tier_judged") | not then
  empty
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
        end )
    ]
  | if length > 0 then (join("\n") + "\n") | halt_error(1) else empty end
end
