// 질문지 키트 시험의 공용 세계. 엔진 밑의 연산(세션·패널·상태 줄·프로세스·제출·보관·
// 시계·환경)을 모두 스텁으로 세운다. 표지 변수 넷은 늘 명시적으로 모의해 호스트 환경을
// 읽지 않으며, 세계 연산의 스텁은 { value } 형식으로 답한다.
import type { On } from 'claude-code'
import { mock } from 'claude-code/testing'

export const MARKS = ['CC_PIPELINE_SEGMENT', 'CC_PIPELINE_STAGE_ID', 'CC_PIPELINE_SHIFT_ID', 'CC_PIPELINE_RUN_ID'] as const
export const TOOL = 'mcp__cc-cmds__question_form'
export const PANE = 'cc-cmds-question-form'

export type Submitted = { text: string; origin: { kind: string; name?: string }; context: readonly string[] }

export type WorldOptions = {
  env?: Partial<Record<(typeof MARKS)[number], string>>
  store?: Record<string, unknown>
  now?: number
}

export function world(on: On, options: WorldOptions = {}) {
  const w = {
    // 프로세스 안 /resume 이나 /clear 뒤의 새 세션은 이 값을 바꿔 흉내 낸다.
    sessionId: 'sid-test',
    surfaces: ['terminal'] as string[],
    isPlaced: true,
    openFails: false,
    runFails: false,
    focusDeny: '',
    tools: [] as string[],
    commands: [] as string[],
    opens: [] as { id: string; title?: string; focus?: boolean; rows?: number; columns?: number }[],
    closes: [] as string[],
    statuses: [] as (string | undefined)[],
    toasts: [] as string[],
    runs: [] as { argv: string[]; stdin?: string; env?: Record<string, string>; timeoutMs?: number }[],
    submits: [] as Submitted[],
  }
  mock.env(on, { CC_PIPELINE_SEGMENT: '', CC_PIPELINE_STAGE_ID: '', CC_PIPELINE_SHIFT_ID: '', CC_PIPELINE_RUN_ID: '', ...options.env })
  const clock = mock.clock(on, { now: options.now ?? 1_000_000 })
  mock.store(on, options.store ?? {})
  // 이벤트는 결과를 그대로 돌려준다.
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  on('prompt.submit', (_$, e) => {
    w.submits.push({ text: e.text, origin: e.origin as Submitted['origin'], context: e.context ?? [] })

    return { text: e.text, context: e.context }
  })
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  // 세계 연산.
  on('session.id', () => ({ value: w.sessionId }))
  on('session.surfaces', () => ({ value: [...w.surfaces] }))
  on('tool.register', (_$, e) => {
    w.tools.push(e.name)

    return { value: { tool: `mcp__cc-cmds__${e.name}` } }
  })
  on('command.register', (_$, e) => {
    w.commands.push(e.name)

    return { value: undefined }
  })
  on('ui.panes', () => ({ value: [] }))
  on('ui.open', (_$, e) => {
    if (w.openFails) throw new Error('ui.open 거절')
    w.opens.push({ id: e.id, title: e.title, focus: e.focus, rows: e.rows, columns: e.columns })

    return { value: w.isPlaced ? { isPlaced: true } : { isPlaced: false, reason: '144칸 아래' } }
  })
  on('ui.close', (_$, e) => {
    w.closes.push(e.id)

    return { value: undefined }
  })
  // 포커스 고리: focusDeny 가 있으면 엔진이 이동을 거절한 것으로 답한다.
  on('ui.focus', () => (w.focusDeny ? { deny: w.focusDeny } : {}))
  on('ui.status', (_$, e) => {
    w.statuses.push(e.text)

    return { value: undefined }
  })
  on('ui.toast', (_$, e) => {
    w.toasts.push(e.text)

    return { value: undefined }
  })
  on('process.run', (_$, e) => {
    const init = (e.init ?? {}) as { stdin?: string; env?: Record<string, string>; timeoutMs?: number }
    w.runs.push({ argv: [...e.argv], stdin: init.stdin, env: init.env, timeoutMs: init.timeoutMs })
    if (w.runFails) throw new Error('process.run 거절')

    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })

  return { w, clock }
}

export const start = ($: any, isInteractive = true) =>
  $.session.start({ cwd: '/work', surface: isInteractive ? 'terminal' : null, isInteractive })

let seq = 0
export const call = async ($: any, input: Record<string, unknown>, extra: Record<string, unknown> = {}) => {
  const r = await $.tool.call({ tool: TOOL, tool_use_id: `tu-${++seq}`, ...input, ...extra })
  const text: string = r.result ?? r.deny ?? r.text ?? ''

  return { r, text, isRefused: r.deny !== undefined || r.isError === true }
}

export const prompt = ($: any, text: string, origin: Record<string, unknown> = { kind: 'composer' }) =>
  $.prompt.submit({ text, origin, wait: false })

export const turnDone = ($: any) => $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 't', reason: 'answer' })

export const reopenCommand = ($: any) =>
  $.command.run({
    command: 'question-form',
    args: '',
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 120 },
  })

export const mount = ($: any) =>
  $.ui.mount({
    plugin: 'cc-cmds',
    surface: 'terminal',
    component: 'Pane',
    requestId: PANE,
    props: {
      title: '질문지',
      isFocused: true,
      bodyColumns: 80,
      placement: 'dock',
      scroll: { offset: 0, bodyRows: 40 },
      view: {},
    },
  })

export const opt = (label: string, extra: Record<string, unknown> = {}) => ({ label, description: `${label} 설명`, ...extra })

export const twoQuestions = () => ({
  title: '경계 질문',
  questions: [
    {
      id: 'scope',
      header: '범위',
      question: '어디까지?',
      kind: 'single',
      options: [opt('좁게', { recommended: '추천', preview: '좁은 범위 미리보기' }), opt('넓게', { preview: '넓은 범위 미리보기' })],
    },
    { id: 'why', header: '이유', question: '왜?', kind: 'text' },
  ],
})

export const formIdOf = (text: string) => /QUESTION_FORM_OPEN (f-[0-9a-f]{8}) /.exec(text)?.[1]
