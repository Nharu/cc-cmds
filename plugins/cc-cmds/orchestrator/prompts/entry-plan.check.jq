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
# THREE ASSERTIONS AND NO MORE. A `team-4` graph is never asserted on: that tier
# keeps the design discussion and the audit it always had.
#
#   (a) a `team-4` judgment carries at least one heavy reason that is not blank,
#       and a `solo` judgment carries none;
#   (b) the confirmed tier is never below the judged one — a person raises, the
#       kickoff never lowers;
#   (c) a `solo` plan that designs has exactly one `design` step, no
#       `design-audit` step, no `split` step and the `single` scope.

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
        else empty end )
    ]
  | if length > 0 then (join("\n") + "\n") | halt_error(1) else empty end
end
