// 질문지 서브 mod. 모델이 mcp__cc-cmds__question_form 으로 여러 질문을 한 장의 패널로
// 묻고, 사람이 제출하면 답 묶음을 플러그인 출처의 새 프롬프트로 보내고 패널을 닫는다.
// 훅 안에서 사람을 기다리지 않는다 — 도구는 열기만 하고 턴을 끝내게 하며, 답은 누름
// 처리기가 낸다. `$` 는 import 너머로 넘어가지 않으므로 `$` 를 쓰는 함수는 모두 이 파일에 둔다.
import { atom, read, update } from 'claude-code'
import type { Hook, Register } from 'claude-code'

import { anyMarked } from '../pipeline-marks'
import { bannerCall } from './banner'
import { bundleText, counts, mimicsHeader, mintFormId } from './bundle'
import type { FormStatus } from './bundle'
import { SUBMIT_KEY, landingKey, layoutRows, paneSize } from './layout'
import { drawForm } from './render'
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
  sentToast,
  statusLine,
  unavailableResult,
} from './spec'
import type { FormInput } from './spec'
import {
  advance,
  cancel,
  carryDrafts,
  choose,
  commitText,
  decideCall,
  expired,
  isOpen,
  jump,
  openEditor,
  openRecord,
  personClose,
  placed,
  reopen,
  restorable,
  retreat,
  submit,
  typeText,
} from './transitions'
import type { FormEditor, FormRecord, Move } from './transitions'
import { normalizeForm, validateForm } from './validate'

type Dollar = Parameters<Hook<'session.start'>>[0]

const recordAtom = atom({ plugin: 'cc-cmds', key: 'questionForm.record' } as const, null as FormRecord | null)
const lastOriginAtom = atom({ plugin: 'cc-cmds', key: 'questionForm.lastPersonOrigin' } as const, null as string | null)
const focusedAtom = atom({ plugin: 'cc-cmds', key: 'questionForm.focusedElement' } as const, null as string | null)

const STORE_PREFIX = 'questionForm.open.'

// 마지막으로 그린 패널 본문의 칸 수. 크기를 잴 때 줄이 감기는 폭으로 쓴다. 그리는 중에는
// 상태를 쓸 수 없으므로 모듈 변수에 둔다 — 틀려도 크기 요청이 조금 어긋날 뿐이다.
let lastBodyColumns = 80

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

// 패널을 열 때 함께 주는 제목과 크기. 크기는 지금 보이는 줄에서 잰다.
type Frame = { title: string; rows: number; columns: number }

function frameOf(rec: FormRecord): Frame {
  const { answered, total } = counts(rec.form, rec.drafts)
  return { title: formTitle(rec.form.title, answered, total), ...paneSize(rec, lastBodyColumns) }
}

const sameFrame = (a: Frame, b: Frame) => a.title === b.title && a.rows === b.rows && a.columns === b.columns

const openPane = ($: Dollar, rec: FormRecord, focus?: true) =>
  $.ui.open({ id: PANE_ID, ...frameOf(rec), ...(focus ? { focus } : {}) })

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
  const opened = await openPane($, rec)
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

// 묶음을 내는 공통 경로: CAS 로 기록을 소비한 쪽만 제출한다. 묶음을 낸 자리에서 패널을
// 닫고 기록을 버린다 — 답은 묶음이 들고 가고, 다음 질문지는 새로 열린다.
async function finish($: Dollar, status: FormStatus) {
  let taken: FormRecord | undefined
  await update($, recordAtom, r => {
    taken = status === '제출' ? submit(r ?? undefined) : cancel(r ?? undefined)
    return taken ? null : r
  })
  if (!taken) return
  const done = taken
  await mirror($, null, done.sessionId)
  await $.prompt.submit({ text: bundleText(done.id, status, done.form, done.drafts) })
  await $.ui.status(undefined)
  await $.ui.close({ id: PANE_ID })
  if (status === '제출') {
    const { answered, total } = counts(done.form, done.drafts)
    await $.ui.toast(sentToast(answered, total))
  }
}

// 열린 기록을 순수 전이로 바꾼다. 제목이나 바라는 크기가 바뀌었으면 패널을 다시 열고,
// 전이가 포커스 자리를 정했으면 그리로 옮긴다(옮기지 못해도 답은 그대로다).
async function change($: Dollar, fn: (rec: FormRecord) => { record: FormRecord; focus?: string }) {
  let after: { record: FormRecord; focus?: string } | undefined
  let was: Frame | undefined
  await update($, recordAtom, r => {
    if (!isOpen(r ?? undefined)) return r
    const rec = r as FormRecord
    was = frameOf(rec)
    after = fn(rec)
    return after.record
  })
  if (!after || !was) return
  await mirror($, after.record)
  if (!sameFrame(frameOf(after.record), was)) await openPane($, after.record)
  if (after.focus) {
    try {
      await $.ui.focus({ requestId: PANE_ID, key: after.focus })
    } catch {
      // 포커스는 덤이다.
    }
  }
}

// 전이가 말한 이동을 포커스 자리로: 다음 질문의 첫 조작부, 질문이 끝나면 [제출].
const focusOf = (rec: FormRecord, move: Move) => (move === 'next' ? landingKey(rec) : move === 'end' ? SUBMIT_KEY : undefined)

function handlers($: Dollar): FormHandlers {
  const run = (fn: (rec: FormRecord) => { record: FormRecord; focus?: string }) => void change($, fn).catch(() => undefined)
  const moved = (r: { record: FormRecord; move: Move }) => ({ record: r.record, focus: focusOf(r.record, r.move) })
  const step = (go: (rec: FormRecord) => FormRecord | undefined) => (rec: FormRecord) => {
    const next = go(rec)
    return next ? { record: next, focus: landingKey(next) } : { record: rec, focus: SUBMIT_KEY }
  }
  return {
    choose: (qid, label) => run(rec => moved(choose(rec, qid, label))),
    jump: qid => run(rec => {
      const next = jump(rec, qid)
      return { record: next, focus: landingKey(next) }
    }),
    openEditor: (qid: string, field: FormEditor['field']) => run(rec => {
      const next = openEditor(rec, qid, field)
      return { record: next, focus: landingKey(next) }
    }),
    typeText: (qid, field, value) => run(rec => ({ record: typeText(rec, qid, field, value) })),
    commitText: (qid, field, value) => run(rec => moved(commitText(rec, qid, field, value))),
    next: () => run(step(advance)),
    prev: () => run(rec => {
      const back = retreat(rec)
      return back ? { record: back, focus: landingKey(back) } : { record: rec }
    }),
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
    const opened = await openPane($, rec, true)
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
    lastBodyColumns = e.props.bodyColumns
    const rec = await read($, recordAtom)
    const focused = await read($, focusedAtom)
    if (rec && isOpen(rec)) {
      return drawForm(
        el,
        layoutRows(rec, focused),
        rec.form.questions.map(q => q.id),
        handlers($),
      )
    }
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
    await openPane($, rec, true)
    await $.ui.status(undefined)

    return {}
  })

  // 프로세스가 다른 세션으로 이어지는 두 끝(/clear, 프로세스 안 /resume)에서는 끝나는
  // 대화의 질문지를 다음 대화에 남기지 않는다. 그 대화를 버리는 /clear 는 보관도 지우고,
  // /resume 은 보관을 남긴다. 같은 프로세스에서 그 대화로 돌아오면 첫 프롬프트나
  // /question-form 에서 rejoin 이, 새 프로세스로 다시 열면 session.start 의 restore 가
  // 되살린다.
  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear' || e.reason === 'resume') {
      await update($, recordAtom, () => null)
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
