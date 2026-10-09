// 질문지 서브 mod. 모델이 mcp__cc-cmds__question_form 으로 여러 질문을 한 장의 패널로
// 묻고, 사람이 제출하면 답 묶음을 플러그인 출처의 새 프롬프트로 보낸다. 훅 안에서
// 사람을 기다리지 않는다 — 도구는 열기만 하고 턴을 끝내게 하며, 답은 누름 처리기가 낸다.
// `$` 는 import 너머로 넘어가지 않으므로 `$` 를 쓰는 함수는 모두 이 파일에 둔다.
import { atom, read, update } from 'claude-code'
import type { Hook, Register } from 'claude-code'

import { anyMarked } from '../pipeline-marks'
import { bannerCall } from './banner'
import { bundleText, counts, draftOf, mimicsHeader, mintFormId } from './bundle'
import type { Drafts, FormStatus } from './bundle'
import { drawForm, drawReceipt } from './render'
import type { FormHandlers } from './render'
import {
  INPUT_SCHEMA,
  NO_FORM_TOAST,
  PANE_ID,
  STAMP,
  TOOL_DESCRIPTION,
  TOOL_NAME,
  busyResult,
  contextLine,
  formTitle,
  openResult,
  receiptTitle,
  statusLine,
  unavailableResult,
} from './spec'
import type { FormInput } from './spec'
import {
  cancel,
  carryDrafts,
  decideCall,
  expired,
  isOpen,
  openRecord,
  personClose,
  placed,
  reopen,
  restorable,
  submit,
  turnComplete,
} from './transitions'
import type { FormRecord } from './transitions'
import { normalizeForm, validateForm } from './validate'

type Dollar = Parameters<Hook<'session.start'>>[0]

const recordAtom = atom({ plugin: 'cc-cmds', key: 'questionForm.record' } as const, null as FormRecord | null)
const turnBusyAtom = atom({ plugin: 'cc-cmds', key: 'questionForm.turnBusy' } as const, false)
const lastOriginAtom = atom({ plugin: 'cc-cmds', key: 'questionForm.lastPersonOrigin' } as const, null as string | null)
const focusedAtom = atom({ plugin: 'cc-cmds', key: 'questionForm.focusedElement' } as const, null as string | null)

const STORE_PREFIX = 'questionForm.open.'

// 머리줄을 흉내 낸 프롬프트 가운데 이 플러그인의 제출이 아닌 것에 도장을 단다.
const needsStamp = (e: { text: string; origin: { kind: string; name?: unknown } }) =>
  mimicsHeader(e.text) && !(e.origin.kind === 'plugin' && e.origin.name === 'cc-cmds')

// 도구 호출이 상태를 쓰기 전의 기록. .catch 가 이 호출이 만든 것을 되돌릴 때 읽는다.
const before = new Map<string, FormRecord | null>()

// 표지 넷을 리터럴로 읽는다. 셸 쪽 라우터 술어(셋)의 엄격한 상위 집합이다.
async function pipelineMarked($: Dollar): Promise<boolean> {
  return anyMarked([
    await $.env.get('CC_PIPELINE_SEGMENT'),
    await $.env.get('CC_PIPELINE_STAGE_ID'),
    await $.env.get('CC_PIPELINE_SHIFT_ID'),
    await $.env.get('CC_PIPELINE_RUN_ID'),
  ])
}

// 프로세스를 넘는 보관: 열린 기록만 세션 id 아래에 두고, 아니면 지운다. 키는 기록을 연
// 세션의 것이고, 기록이 없으면 sessionId 를, 그것도 없으면 지금 세션을 쓴다. 보관 실패는
// 질문지 자체를 막지 않는다.
async function mirror($: Dollar, rec: FormRecord | null, sessionId?: string) {
  try {
    const key = STORE_PREFIX + (rec?.sessionId ?? sessionId ?? (await $.session.id()))
    if (isOpen(rec ?? undefined)) await $.store.set(key, rec)
    else await $.store.delete(key)
  } catch {
    // 보관은 덤이다.
  }
}

async function writeRecord($: Dollar, rec: FormRecord | null) {
  await update($, recordAtom, () => rec)
  await mirror($, rec)
}

const titleOf = (rec: FormRecord) => {
  const { answered, total } = counts(rec.form, rec.drafts)
  return formTitle(rec.form.title, answered, total)
}

const statusOf = (rec: FormRecord) => {
  const { answered, total } = counts(rec.form, rec.drafts)
  return statusLine(answered, total)
}

// 새로 연 질문지의 배너. 실패는 삼킨다 — 배너가 실패해도 질문지는 열린다.
async function banner($: Dollar, form: FormInput) {
  try {
    const call = bannerCall($.plugin.root, await $.session.id(), form)
    await $.process.run(call.argv, { stdin: call.stdin, env: call.env, timeoutMs: call.timeoutMs })
  } catch {
    // 배너 없이 연다.
  }
}

// 다시 불러온 뒤나 프로세스를 넘어 되살린 질문지를 요청 없이 다시 연다. 배치 문턱에
// 못 미치면 그려지지 않으므로 상태 줄을 띄운다.
async function reshow($: Dollar, rec: FormRecord) {
  const opened = await $.ui.open({ id: PANE_ID, title: titleOf(rec) })
  const next = placed(rec, opened.isPlaced)
  await writeRecord($, next)
  await $.ui.status(next.hidden ? statusOf(next) : undefined)
}

// 이 세션이 연 기록만 되살린다. 다른 세션의 기록은 상태에서 내리고, 그 보관 키는 그
// 세션으로 돌아올 때를 위해 남긴다. 7일이 지난 보관은 이 세션의 것이어도 지운다.
async function restore($: Dollar) {
  const sid = await $.session.id()
  const now = await $.clock.now()
  const held = restorable((await read($, recordAtom)) ?? undefined, sid)
  if (!held) await update($, recordAtom, r => (isOpen(r ?? undefined) ? null : r))
  let show = held
  for (const key of await $.store.keys()) {
    if (!key.startsWith(STORE_PREFIX)) continue
    const stored = (await $.store.get(key)) as FormRecord | undefined
    if (key === STORE_PREFIX + sid) {
      if (held) continue
      show = restorable(stored, sid, now)
      if (!show) await $.store.delete(key)
    } else if (!stored || expired(stored, now)) {
      await $.store.delete(key)
    }
  }
  if (show) await reshow($, show)
}

// 프로세스 안 /resume 으로 앞 대화에 돌아오면 session.start 가 오지 않아 restore 가 돌지
// 않는다. 그래서 사람이 그 대화에서 프롬프트나 /question-form 을 칠 때, 메모리에 기록이
// 없으면 지금 세션의 보관을 되살린다. 7일이 지난 보관은 되살리지 않고 지운다.
async function rejoin($: Dollar) {
  if ((await read($, recordAtom)) !== null) return
  const sid = await $.session.id()
  const key = STORE_PREFIX + sid
  const stored = (await $.store.get(key)) as FormRecord | undefined
  if (!stored) return
  const alive = restorable(stored, sid, await $.clock.now())
  if (alive) await reshow($, alive)
  else await $.store.delete(key)
}

// 묶음을 내는 공통 경로: CAS 로 기록을 소비한 쪽만 제출한다.
async function finish($: Dollar, status: FormStatus) {
  const busy = await read($, turnBusyAtom)
  let taken: FormRecord | undefined
  await update($, recordAtom, r => {
    taken = status === '제출' ? submit(r ?? undefined, busy) : cancel(r ?? undefined)
    return status === '제출' ? (taken ?? r) : taken ? null : r
  })
  if (!taken) return
  const done = taken
  await mirror($, null, done.sessionId)
  await $.prompt.submit({ text: bundleText(done.id, status, done.form, done.drafts) })
  await $.ui.status(undefined)
  if (status === '제출') {
    const { answered, total } = counts(done.form, done.drafts)
    await $.ui.open({ id: PANE_ID, title: receiptTitle(answered, total) })
  } else {
    await $.ui.close({ id: PANE_ID })
  }
}

// 쓰던 답을 고친다. 답 수가 바뀌면 패널 제목도 바꾼다.
async function editDrafts($: Dollar, fn: (drafts: Drafts, rec: FormRecord) => Partial<FormRecord>) {
  let after: FormRecord | undefined
  let was = ''
  await update($, recordAtom, r => {
    if (!isOpen(r ?? undefined)) return r
    const rec = r as FormRecord
    was = titleOf(rec)
    after = { ...rec, ...fn(rec.drafts, rec) }
    return after
  })
  if (!after) return
  await mirror($, after)
  if (titleOf(after) !== was) await $.ui.open({ id: PANE_ID, title: titleOf(after) })
}

function handlers($: Dollar): FormHandlers {
  const setDraft = (qid: string, patch: (d: ReturnType<typeof draftOf>, rec: FormRecord) => object) =>
    editDrafts($, (drafts, rec) => ({ drafts: { ...drafts, [qid]: { ...draftOf(drafts, qid), ...patch(draftOf(drafts, qid), rec) } } }))
  const kindOf = (rec: FormRecord, qid: string) => rec.form.questions.find(q => q.id === qid)?.kind
  return {
    toggle: (qid, label) =>
      void setDraft(qid, (d, rec) => {
        if (kindOf(rec, qid) === 'multi') {
          return { selected: d.selected.includes(label) ? d.selected.filter(s => s !== label) : [...d.selected, label] }
        }
        // single: 고른 것을 다시 누르면 풀리고, 고르면 기타 입력을 비운다.
        return d.selected.includes(label) ? { selected: [] } : { selected: [label], other: '' }
      }).catch(() => undefined),
    openOther: qid =>
      void editDrafts($, (_d, rec) => ({ otherOpen: rec.otherOpen.includes(qid) ? rec.otherOpen : [...rec.otherOpen, qid] })).catch(
        () => undefined,
      ),
    setOther: (qid, value) =>
      void setDraft(qid, (_d, rec) =>
        kindOf(rec, qid) === 'single' && value.trim() !== '' ? { other: value, selected: [] } : { other: value },
      ).catch(() => undefined),
    setNote: (qid, value) => void setDraft(qid, () => ({ note: value })).catch(() => undefined),
    submit: () => void finish($, '제출').catch(() => undefined),
    cancel: () => void finish($, '취소').catch(() => undefined),
  }
}

export const register: Register = on => {
  // 대화형 세션에서만, 파이프라인 표지가 없을 때만 도구와 명령을 등록한다.
  on('session.start', { isInteractive: true }, async ($, e, next) => {
    // 등록이나 되살리기가 실패해도 세션과 같은 플러그인의 다른 시작 훅은 그대로 간다.
    // 도구가 등록되지 않으면 스킬은 ToolSearch 결과로 그것을 알고 AskUserQuestion 으로 묻는다.
    try {
      if (!(await pipelineMarked($))) {
        await $.tool.register({ name: TOOL_NAME, description: TOOL_DESCRIPTION, inputSchema: INPUT_SCHEMA })
        await $.command.register({ name: 'question-form', description: '열린 질문지 패널을 다시 연다', immediate: true })
        await restore($)
      }
    } catch {
      // 위 주석과 같다.
    }

    return next(e)
  })

  // 매처는 validate 가 소스에서 읽으므로 상수가 아니라 리터럴로 적는다.
  on('tool.call', { tool: 'mcp__cc-cmds__question_form' }, async ($, e) => {
    if (e.agentId) return { deny: unavailableResult('subagent') }
    if (await pipelineMarked($)) return { deny: unavailableResult('pipeline') }
    if (!(await $.session.surfaces()).includes('terminal')) return { deny: unavailableResult('surface') }
    if ((await read($, lastOriginAtom)) === 'bridge') return { deny: unavailableResult('remote') }

    const args = e as unknown as Record<string, unknown>
    const input = { title: args.title, intro: args.intro, replaces: args.replaces, questions: args.questions }
    const current = (await read($, recordAtom)) ?? undefined
    const invalid = validateForm(input, isOpen(current) ? current.id : undefined)
    if (invalid) return { deny: invalid }
    const decision = decideCall(current, input.replaces as string | undefined)
    if (decision.kind === 'busy') return { deny: busyResult(decision.id) }

    const form = normalizeForm(input as FormInput)
    const id = mintFormId()
    const drafts = decision.kind === 'replace' && current ? carryDrafts(current.form, current.drafts, form) : {}
    let rec = openRecord({ id, toolUseId: e.tool_use_id, form, drafts, sessionId: await $.session.id(), now: await $.clock.now() })
    before.set(e.tool_use_id, current ?? null)
    await writeRecord($, rec)
    await update($, turnBusyAtom, () => true)
    const opened = await $.ui.open({ id: PANE_ID, title: titleOf(rec), focus: true })
    if (!opened.isPlaced) {
      rec = placed(rec, false)
      await writeRecord($, rec)
    }
    await $.ui.status(rec.hidden ? statusOf(rec) : undefined)
    before.delete(e.tool_use_id)
    if (decision.kind === 'new') await banner($, form)

    return { result: openResult(id, form.questions.length, opened.isPlaced) }
  }).catch(async ($, e) => {
    // 이 호출이 만든 기록과 패널을 지우고 거절한다.
    if (before.has(e.tool_use_id)) {
      const prev = before.get(e.tool_use_id) ?? null
      before.delete(e.tool_use_id)
      try {
        await writeRecord($, prev)
        if (!prev) await $.ui.close({ id: PANE_ID })
        await $.ui.status(undefined)
      } catch {
        // 되돌리기도 실패하면 거절만 한다.
      }
    }

    return { deny: unavailableResult('error') }
  })

  // 사람의 프롬프트: 머리줄을 흉내 낸 사본에 도장, 출처 기록, 돌아온 대화의 보관
  // 되살리기, 열린 질문지가 있으면 맥락 줄. 이 mod 자신의 제출은 이 훅을 지나지 않는다.
  on('prompt.submit', async ($, e, next) => {
    const context = [...(e.context ?? [])]
    const origin = e.origin
    if (needsStamp(e)) context.push(STAMP)
    if (origin.kind === 'composer' || origin.kind === 'bridge') {
      await update($, lastOriginAtom, () => origin.kind)
      await update($, turnBusyAtom, () => true)
      try {
        await rejoin($)
      } catch {
        // 되살리지 못해도 맥락 줄과 출처 기록은 그대로 간다.
      }
      const rec = await read($, recordAtom)
      if (isOpen(rec ?? undefined)) context.push(contextLine((rec as FormRecord).id))
    }

    return next(context.length === (e.context ?? []).length ? e : { ...e, context })
  }).catch(($, e, next) => {
    // 출처 기록이나 맥락 줄이 실패해도 도장은 빠지지 않는다.
    if (!needsStamp(e)) return next(e)

    return next({ ...e, context: [...(e.context ?? []), STAMP] })
  })

  // 사람의 닫기 표시만 다룬다: 숨기고 상태 줄을 띄운다. 이 mod 자신의 닫기는 지나지 않는다.
  on('ui.close', { id: 'cc-cmds-question-form' }, async ($, e, next) => {
    if (e.origin.kind === 'person') {
      const { record, showStatus } = personClose((await read($, recordAtom)) ?? undefined)
      await writeRecord($, record ?? null)
      if (showStatus && record) await $.ui.status(statusOf(record))
    }

    return next(e)
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: 'cc-cmds-question-form' }, async ($, e) => {
    const el = $.ui.resolve(e)
    const rec = await read($, recordAtom)
    const focused = await read($, focusedAtom)
    if (rec && rec.phase === 'submitted') return drawReceipt(el, rec)
    if (rec && isOpen(rec)) return drawForm(el, rec, focused, handlers($))
    const { Text } = el

    return <Text dimColor>{NO_FORM_TOAST}</Text>
  })

  // 포커스 이동은 막지 않는다. 옮겨진 뒤에만 포커스를 받은 요소를 적는다.
  on('ui.focus', { component: 'Pane', requestId: 'cc-cmds-question-form' }, async ($, e, next) => {
    const r = await next(e)
    if (!r.deny) {
      try {
        await update($, focusedAtom, () => e.element ?? null)
      } catch {
        // 미리보기만 늦는다.
      }
    }

    return r
  }).catch(($, e, next) => next(e))

  // 사람이 친 명령이므로 폭과 무관하게 패널이 놓인다.
  on('command.run', { command: 'question-form' }, async $ => {
    try {
      await rejoin($)
    } catch {
      // 되살리지 못하면 메모리의 기록만 본다.
    }
    const rec = reopen((await read($, recordAtom)) ?? undefined)
    if (!rec) {
      await $.ui.toast(NO_FORM_TOAST)

      return {}
    }
    await writeRecord($, rec)
    await $.ui.open({ id: PANE_ID, title: titleOf(rec), focus: true })
    await $.ui.status(undefined)

    return {}
  })

  // 주 루프의 턴 끝: 영수증을 묶음 턴에서 닫는다.
  on('turn.complete', async ($, e, next) => {
    if (e.agentId) return next(e)
    await update($, turnBusyAtom, () => false)
    const now = (await read($, recordAtom)) ?? undefined
    const { record, closeReceipt } = turnComplete(now)
    if (closeReceipt) {
      await writeRecord($, null)
      await $.ui.close({ id: PANE_ID })
      await $.ui.status(undefined)
    } else if (record !== now) {
      await writeRecord($, record ?? null)
    }

    return next(e)
  })

  // 프로세스가 다른 세션으로 이어지는 두 끝(/clear, 프로세스 안 /resume)에서는 끝나는
  // 대화의 질문지를 다음 대화에 남기지 않는다. 그 대화를 버리는 /clear 는 보관도 지우고,
  // /resume 은 보관을 남긴다. 같은 프로세스에서 그 대화로 돌아오면 첫 프롬프트나
  // /question-form 에서 rejoin 이, 새 프로세스로 다시 열면 session.start 의 restore 가
  // 되살린다.
  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear' || e.reason === 'resume') {
      await update($, recordAtom, () => null)
      await update($, turnBusyAtom, () => false)
      try {
        if (e.reason === 'clear') await $.store.delete(STORE_PREFIX + e.sessionId)
        await $.ui.close({ id: PANE_ID })
      } catch {
        // 보관은 덤이다.
      }
      await $.ui.status(undefined)
    }

    return next(e)
  })
}
