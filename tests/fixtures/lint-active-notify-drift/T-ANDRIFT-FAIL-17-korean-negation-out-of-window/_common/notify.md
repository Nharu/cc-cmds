# Active Notify (Shared Procedure)

Single (mode=single) or event-scoped repeat (mode=repeat) lifecycle.

fire-now is the only dispatch surface, called ahead of any verification
that could strand the banner (SKILL.md §4.4 Fire-now ordering within the
turn); when unsure an ARM is live it fires regardless (SKILL.md §4.5
Defensive fire-now).

The permission-test bypass path (per SKILL.md §7 Permission test bypass)
carries its own user-narration contract.

Termination: the cycle ends when the flag is deleted, and cancel performs
the same removal whether the user issued it or the model self-cancelled.

훅 주도의 turn-end auto-fire 는 이 문서의 다른 부분에서 여러 차례 반복해서 설명하고 있는 것과 마찬가지로 어떠한 조건 아래에서도 어떤 시점에도 결코 일어나는 일이 없다고 적어 두어야 하며 그것이 이 계약의 핵심이므로 일어나지 않는다.
