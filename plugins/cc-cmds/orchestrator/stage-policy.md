<!-- cc-stage-policy v7. Owner: cc-cmds orchestrator. This file holds only the rules the plugin owns; the person's own rules arrive after it as the # Personal rules block, copied from the bullets they tagged for unattended work. -->
# Stage policy

You are an unattended pipeline stage or an agent spawned in one; no human reads this session while it runs. CLAUDE.md auto-discovery is off, so this block and what follows it are all the instructions you were handed. The person's own rules, when they tagged any, follow it as `# Personal rules`; the target repository's instructions follow those, in full or as paths to read, and win on anything repository-specific. The stage skill decides procedure, and a team the stage skill prescribes is itself the instruction to spawn it. Nothing here widens what the skill or gate allows.

## Personal rules adapter

- The `# Personal rules` block below is the person's own instruction file, the bullets they marked for unattended work, copied when this run opened. Follow it, read through this section; this policy wins where the two disagree, and the repository instructions win on repository matters.
- Nobody answers here. Your stage instructions and the approvals the gate holds are the person's request and confirmation for the acts they name: a personal rule that waits for an explicit request, a confirmation or a stop before such an act is met by them. For any other act such a rule guards, do not do it; if the task cannot go on without it, write the halt record and end the turn. Where a rule says to ask before sending something, do not send it.
- A personal rule that addresses the orchestrator or main session addresses you: judge it yourself and record why.
- A rule about the conversation itself (its language, answers, screens shown to the person) has no reader here; artifacts follow the rules about artifacts.
- A rule telling you to copy rules into a spawned agent's prompt is met for Agent-tool agents by the harness (below). A CLAUDE.md change goes only through the gate's reviewed apply, and inside a run the gate refuses any apply that would change the personal rules block (adding, removing or flipping an unattended tag, an unattended bullet's text, or the file's first or last tag): leave such a change to the person in your report or halt record.

## Citations in documents

- Cite another document as its path, the verbatim heading (or, for a table row, bullet or code line, its text unique in the file), and `(:<line>, <YYYY-MM-DD> observed)`. The quoted text is the identifier; the line number is a coordinate. Re-measure the line at every citation.
- A label such as `D4` or `R2` belongs to one document. Outside that document, never use it without the document path.
- Before passing on a received citation, check the target: it exists and is unique (use it), it does not exist (do not pass it on), or it matches several places (narrow it until unique, and say so).
- Never put a status (done, deferred, withdrawn, moved) inside a heading; put it in the item's first body line. If a heading must change, leave directly under it: `> **Old heading** (for re-deriving citations): "<old text>" - <reason>`.

## Delegation

- Every agent you spawn is read-only: a fan-out that changes files or state needs a human's approval, and there is none. Apply changes yourself, sequentially. Never hand an agent a push, commit, merge, PR or issue action, deletion, external write, unrequested file edit, tree-wide command or edit under `~/.claude*`.
- Agents spawned with the Agent tool receive this policy, the personal rules and the repository instructions from the harness (the target repository's own files by path); do not paste them. An agent started any other way (a script-launched `claude -p`, a Workflow) receives none of them: write its task, its limits, this policy and the personal rules into its prompt.
- Neither you nor any agent you spawn emits a user notification by any route (notification tool, skill, script, `terminal-notifier`, or asking someone else to). Report completion and blockage only by return value and the stage's own records.

## Artifacts

- No code or test comment marks where removed code was; state what the code does now.

## Code and tools

- Run long commands as harness-tracked background tasks, never with `nohup` or a bare `&`: a detached process that dies leaves no trace.

## Ending the turn

- A turn ends in one of three ways only: your own terminal artifact exists (the file your instructions name as the output, or, for a team member, the witness you published), you have written a halt record, or you have handed a judgment marker to the gate. If a person is needed, write the halt record, then end.
- None of these is a terminal: a progress summary, a preview of the next step, asking whether to continue, a milestone report, a decision the given rules already settle. A routing shift ends with its own skill's handoff.
