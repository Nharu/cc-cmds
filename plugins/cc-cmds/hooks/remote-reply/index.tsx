// 원격 선택지·텍스트 답 모드. 중계가 우편함에 놓은 선택지 답·텍스트 답 봉투를 이 세션의 열린
// 질문이나 질문지에 넣고, 쉬는 세션에는 차례 넘김 텍스트 봉투를 새 지시로 제출하며, 런 주소
// 승인 봉투를 가져가 쉬는 라우터 좌석을 깨운다. 스풀을 읽고 쓰는
// 일(수락 판정, 수령, 적용 기록, 처리 표지, 정리)은 모두 seam.sh 가 하고, 이 모드는 `$.fs`
// 로 이름만 본 뒤 언제 무엇을 seam.sh 에 맡길지와 경합의 승자만 정한다.
// 권한 대화창의 원격 허용·거부(결정 봉투)는 권한 요청 훅이 받는다. 그 스풀 읽기와 쓰기는
// 모두 session-permission-decide.sh 가 하고, 이 모드는 언제 부를지와 대화창과의 경합만 정한다.
// 상태 모드가 질문지 모드 다음에 이 모드를 등록한다.
import type { Hook, Register, Timer } from 'claude-code'

import { anyMarked } from '../pipeline-marks'
import { applyRemote, openFormTarget, remoteMarkLine } from '../question-form/index'
import type { FormTarget, RemotePick } from '../question-form/index'

type Dollar = Parameters<Hook<'session.start'>>[0]

// 우편함 살핌 간격과, 살핌 주기를 지켜보는 감시 주기의 간격.
export const SCAN_MS = 15_000
export const WATCH_MS = 40_000
// 감시는 살핌의 마지막 틱이 이보다 오래면, 살핌은 감시의 마지막 틱이 이보다 오래면 다시 건다.
export const SCAN_STALL_MS = 45_000
export const WATCH_STALL_MS = 120_000
// 차례가 돌고 있지 않고 마지막 사람 입력 뒤 이만큼 지났으면 쉬고 있다.
export const IDLE_MS = 45_000
// 살필 것이 앞 틱과 같으면 이만큼 지나기 전에는 scan 을 다시 부르지 않는다.
export const RESCAN_MS = 60_000
// 정리는 활성이 된 직후와 이만큼의 틱마다.
export const CLEANUP_TICKS = 80
const SEAM_TIMEOUT_MS = 20_000

// 깨우기 리터럴의 정규식. seam.sh 가 낸 줄을 제출 전에 다시 확인한다.
export const WAKE_RE = /^<cc-remote-approval run=[A-Za-z0-9-]{1,64} id=[A-Za-z0-9_-]{1,55}-[0-9a-f]{8}\/>$/

// 원격 표지 줄의 발신자 꼴. 첫 줄이 표지 줄인 프롬프트는 원격 지시이고 사람 입력이 아니다.
const SENDER_RE = /^[A-Za-z0-9_.@:-]{1,64}$/
const MARK_PREFIX = '[cc-cmds 원격 입력] 발신='
export const isRemoteMarked = (text: string) => {
  const first = text.split('\n', 1)[0] ?? ''
  return first.startsWith(MARK_PREFIX) && SENDER_RE.test(first.slice(MARK_PREFIX.length))
}

type Wake = { run_id: string; approval_id: string; reply_id: string }
type Turn = { reply_id: string; text: string; sender: string; created_at_ms: number }
type ScanOut = {
  form: { reply_id: string; picks: RemotePick[]; kind?: string; sender?: string } | null
  turn?: Turn | null
  wake: Wake[]
}
type Question = { question: string; header?: string; multiSelect?: boolean; options?: { label: string }[] }

let isActive = false
let home = ''
let stateDir = ''
let scanTimer: Timer | undefined
let watchTimer: Timer | undefined
let lastScanAt = 0
let lastWatchAt = 0
let isTicking = false
let ticks = 0
// 쉼 판정: 주 루프 차례가 돌고 있는지와 마지막 사람 입력 시각.
let isTurnRunning = false
let lastHumanAt = 0
// 앞 scan 이 본 것과 그 시각.
let lastScanKey = ''
let lastScanCallAt = 0

// 표지 다섯을 리터럴로 읽는다. 셸 쪽 라우터 술어(넷)의 엄격한 상위 집합이다.
async function pipelineMarked($: Dollar): Promise<boolean> {
  return anyMarked([
    await $.env.get('CC_PIPELINE_SEGMENT'),
    await $.env.get('CC_PIPELINE_STAGE_ID'),
    await $.env.get('CC_PIPELINE_SHIFT_ID'),
    await $.env.get('CC_PIPELINE_RUN_ID'),
    await $.env.get('CC_PIPELINE_REENTRY'),
  ])
}

const spoolRoot = () => `${home}/.local/state/cc-cmds/attention`
export const safeSid = (sid: string) => sid.replace(/[^A-Za-z0-9_.-]/g, '_')
const seamArgv = ($: Dollar, sub: string, args: readonly string[]) => ['bash', `${$.plugin.root}/hooks/remote-reply/seam.sh`, sub, ...args]

// 스풀 루트가 디렉터리로 있는가. 없으면 모드는 잠든 채로 아무것도 하지 않는다.
async function isAwake($: Dollar): Promise<boolean> {
  try {
    await $.fs.list(spoolRoot())
    return true
  } catch {
    return false
  }
}

// 디렉터리에 있는 봉투 이름. 디렉터리가 없으면 빈 목록이다.
async function envelopes($: Dollar, dir: string): Promise<string[]> {
  try {
    return (await $.fs.list(dir)).filter(one => one.kind === 'file' && one.name.endsWith('.json') && !one.name.startsWith('.')).map(one => one.name).sort()
  } catch {
    return []
  }
}

// 봉투 경로 → 그 봉투의 `kind`. 읽거나 파싱하지 못한 봉투는 빈 문자열로 기억한다.
const kindOf = new Map<string, string>()

// 세션 우편함의 봉투 가운데 결정 봉투를 뺀 것. 앞 틱에 없던 이름만 한 번 읽어 종류를
// 기억하고, 목록에서 사라진 이름은 잊는다. 읽지 못한 봉투는 센다 — 결정 봉투는 권한 요청
// 훅이 받으므로, 세면 거절·만료된 결정 봉투가 살핌 틱마다 헛된 scan 을 부른다.
async function optionEnvelopes($: Dollar, dir: string, names: string[]): Promise<string[]> {
  const present = new Set(names.map(name => `${dir}/${name}`))
  for (const path of [...kindOf.keys()]) {
    if (path.startsWith(`${dir}/`) && !present.has(path)) kindOf.delete(path)
  }
  const kept: string[] = []
  for (const name of names) {
    const path = `${dir}/${name}`
    if (!kindOf.has(path)) {
      let kind = ''
      try {
        const text = await $.fs.read(path)
        const parsed = typeof text === 'string' ? (JSON.parse(text) as { kind?: unknown }) : null
        if (parsed && typeof parsed.kind === 'string') kind = parsed.kind
      } catch {
        kind = ''
      }
      kindOf.set(path, kind)
    }
    if (kindOf.get(path) !== 'permission-decision') kept.push(name)
  }
  return kept
}

// 정방향 색인의 런 id. 색인이 없으면 빈 목록이다.
async function indexRuns($: Dollar, sid: string): Promise<string[]> {
  try {
    const text = await $.fs.read(`${stateDir}/session/${sid}`)
    if (typeof text !== 'string') return []
    return text.split('\n').filter(line => /^[A-Za-z0-9-]{1,64}$/.test(line))
  } catch {
    return []
  }
}

async function seam($: Dollar, sub: string, args: readonly string[], stdin: string): Promise<string> {
  const r = await $.process.run(seamArgv($, sub, args), { stdin, timeoutMs: SEAM_TIMEOUT_MS })
  return r.exitCode === 0 ? r.stdout : ''
}

async function isIdle($: Dollar, now: number): Promise<boolean> {
  return !isTurnRunning && now - lastHumanAt >= IDLE_MS
}

// 시계 콜백은 일을 기다리지 않고 곧바로 돌아오며, 거부가 밖으로 나가지 않게 일 전체를 잡는다.
function armScan($: Dollar, now: number) {
  scanTimer?.cancel()
  lastScanAt = now
  scanTimer = $.clock.every(SCAN_MS, () => {
    onScan($).catch(() => undefined)
  })
}

function armWatch($: Dollar, now: number) {
  watchTimer?.cancel()
  lastWatchAt = now
  watchTimer = $.clock.every(WATCH_MS, () => {
    onWatch($).catch(() => undefined)
  })
}

async function onScan($: Dollar) {
  const now = await $.clock.now()
  lastScanAt = now
  if (now - lastWatchAt > WATCH_STALL_MS) armWatch($, now)
  await tick($)
}

async function onWatch($: Dollar) {
  const now = await $.clock.now()
  lastWatchAt = now
  if (now - lastScanAt > SCAN_STALL_MS) armScan($, now)
}

// 시계는 거부된 주기에서 끝난다. 모드가 듣는 모든 사건에서 같은 판정으로 둘을 다시 건다.
async function recover($: Dollar) {
  if (!isActive) return
  const now = await $.clock.now()
  if (now - lastScanAt > SCAN_STALL_MS) armScan($, now)
  if (now - lastWatchAt > WATCH_STALL_MS) armWatch($, now)
}

async function tick($: Dollar) {
  if (!isActive || isTicking) return
  isTicking = true
  try {
    await look($)
  } finally {
    isTicking = false
  }
}

const formArg = (t: FormTarget) => ({ form_id: t.form_id, session_id: t.session_id, questions: t.questions })

// 살핌 틱 하나: 이름만 보고, 후보가 없으면 프로세스를 띄우지 않는다. 쉬고 있고 자기 세션
// 우편함에 봉투가 있으면 열린 질문지가 없어도 차례 넘김 후보를 묻는다.
async function look($: Dollar) {
  if (!(await isAwake($))) return
  ticks += 1
  const sid = await $.session.id()
  if (ticks % CLEANUP_TICKS === 0) await seam($, 'cleanup', [], JSON.stringify({ session_id: sid }))
  const ownDir = `${spoolRoot()}/inbox/s-${safeSid(sid)}`
  const own = await optionEnvelopes($, ownDir, await envelopes($, ownDir))
  const runNames: string[] = []
  for (const run of await indexRuns($, sid)) {
    for (const name of await envelopes($, `${spoolRoot()}/inbox/r-${run}`)) runNames.push(`${run}/${name}`)
  }
  const target = own.length > 0 ? await openFormTarget($) : null
  const now = await $.clock.now()
  const idle = await isIdle($, now)
  const askTurn = idle && own.length > 0
  if (target === null && runNames.length === 0 && !askTurn) return
  const key = JSON.stringify([own, runNames, target?.form_id ?? null, idle])
  if (key === lastScanKey && now - lastScanCallAt < RESCAN_MS) return
  lastScanKey = key
  lastScanCallAt = now
  const raw = await seam($, 'scan', [], JSON.stringify({ session_id: sid, form: target ? formArg(target) : null, turn: askTurn }))
  let out: ScanOut
  try {
    out = JSON.parse(raw) as ScanOut
  } catch {
    return
  }
  if (out.form && target && (await applyForm($, sid, target, out.form))) return
  if (out.turn && askTurn && (await applyTurn($, sid, out.turn))) return
  const first = out.wake?.[0]
  if (first && (await isIdle($, await $.clock.now()))) await wake($, sid, first)
}

// 질문지 봉투 하나: 초안이 없을 때만 수령하고, 원자 갱신이 소비했고 엔진이 제출을 받았을
// 때만 기록한다. 소비하지 못했거나 제출이 드롭됐으면 방금 만든 수령 표지를 거둔다 — 드롭된
// 묶음은 대화에 들어가지 않았으므로 적용 기록을 쓰면 제출되지 않은 답이 적용됨으로 나간다.
async function applyForm($: Dollar, sid: string, target: FormTarget, form: NonNullable<ScanOut['form']>): Promise<boolean> {
  if (target.hasDraft) return false
  const stdin = JSON.stringify({ session_id: sid, form: formArg(target) })
  const picked = (await seam($, 'form-pick', [form.reply_id], stdin)).trim()
  if (picked !== form.reply_id) return false
  const sender = form.kind === 'text' ? form.sender : undefined
  if (form.kind === 'text' && (typeof sender !== 'string' || !SENDER_RE.test(sender))) {
    await seam($, 'form-unpick', [form.reply_id], JSON.stringify({ session_id: sid }))
    return false
  }
  const delivered = await applyRemote($, target.form_id, form.picks, sender)
  if (delivered.consumed && delivered.dropped === undefined) {
    await seam($, 'form-record', [sid, form.reply_id], delivered.text)
    return true
  }
  await seam($, 'form-unpick', [form.reply_id], JSON.stringify({ session_id: sid }))
  return delivered.consumed
}

// 차례 넘김 봉투 하나: 아직 쉬고 있고 마지막 사람 입력이 그 사건보다 앞일 때만 수령하고,
// 적용 기록과 처리 표지를 먼저 남긴 뒤 사용자 차례로 제출한다. 수령이나 기록이 어긋나면
// 방금 만든 수령 표지를 거두고 아무것도 제출하지 않는다.
async function applyTurn($: Dollar, sid: string, turn: Turn): Promise<boolean> {
  if (typeof turn.reply_id !== 'string' || typeof turn.text !== 'string' || typeof turn.sender !== 'string') return false
  if (typeof turn.created_at_ms !== 'number' || !SENDER_RE.test(turn.sender)) return false
  if (!(await isIdle($, await $.clock.now())) || lastHumanAt >= turn.created_at_ms) return false
  const stdin = JSON.stringify({ session_id: sid })
  const picked = (await seam($, 'turn-pick', [turn.reply_id], stdin)).trim()
  if (picked !== turn.reply_id) return false
  const text = `${remoteMarkLine(turn.sender)}\n\n${turn.text}`
  const recorded = (await seam($, 'turn-record', [sid, turn.reply_id], text)).trim()
  if (recorded !== turn.reply_id) {
    await seam($, 'turn-unpick', [turn.reply_id], stdin)
    return false
  }
  await $.prompt.submit({ text, asUser: true })
  return true
}

async function wake($: Dollar, sid: string, one: Wake) {
  const line = (await seam($, 'wake-mark', [one.run_id, one.reply_id], JSON.stringify({ session_id: sid }))).replace(/\n$/, '')
  if (!WAKE_RE.test(line)) return
  await $.prompt.submit({ text: line })
}

// S-open 의 대기 자식에서 첫 줄을 읽는다. 자식이 줄 없이 끝나거나 뜨지 못하면 undefined.
async function firstLine(child: AsyncGenerator<{ stream: string; text: string }, unknown>): Promise<string | undefined> {
  let buffered = ''
  for (;;) {
    const piece = await child.next()
    if (piece.done) return undefined
    if (piece.value.stream !== 'stdout') continue
    buffered += piece.value.text
    const at = buffered.indexOf('\n')
    if (at >= 0) return buffered.slice(0, at)
  }
}

// 원격이 이긴 호출은 도구가 돌지 않아 하네스가 사후 도구 훅을 돌리지 않는다. 확정 직후 seam.sh
// 가 그 훅들을 하네스와 같은 꼴의 입력으로 다시 돌리고 남긴 추가 맥락 문자열을 돌려준다. 실패·
// 거절·해석할 수 없는 출력은 빈 목록이다 — 다시 돌리기는 답의 적용과 경합의 승자를 바꾸지 않는다.
async function replay($: Dollar, call: { session_id: string; tool_use_id: string; questions: Question[] }, answers: object): Promise<string[]> {
  try {
    const out: unknown = JSON.parse(await seam($, 'post-replay', [], JSON.stringify({ ...call, answers })))
    return Array.isArray(out) ? out.filter((one): one is string => typeof one === 'string' && one !== '') : []
  } catch {
    return []
  }
}

// 열린 질문 하나를 두고 로컬 대화창과 원격 봉투가 경합한다. 승자는 이 훅이 돌려준 값이다 —
// 확정을 시작하기 전에 로컬이 끝났으면 로컬 결과를 그대로 돌려주고 기록은 남지 않는다. 원격이
// 이기면 도구 결과는 답 맵 그대로이고, 사후 도구 훅을 다시 돌려 남은 추가 맥락(텍스트 답의 원격
// 표지 줄)이 있으면 그것을 결과와 다른 자리인 context 로 함께 돌려준다.
async function race($: Dollar, e: { tool_use_id: string; questions: Question[] }, local: Promise<unknown>): Promise<unknown> {
  let isLocalDone = false
  const localDone = local.then(
    () => {
      isLocalDone = true
      return { kind: 'local' as const }
    },
    () => {
      isLocalDone = true
      return { kind: 'local' as const }
    },
  )
  const sid = await $.session.id()
  const call = { session_id: sid, tool_use_id: e.tool_use_id, questions: e.questions }
  const rejected: string[] = []
  for (;;) {
    if (isLocalDone) return local
    const child = $.process.spawn({ argv: seamArgv($, 'wait', []), input: JSON.stringify({ ...call, rejected }) })
    const found = firstLine(child).then(
      line => ({ kind: 'found' as const, line }),
      () => ({ kind: 'found' as const, line: undefined }),
    )
    const first = await Promise.race([localDone, found])
    if (first.kind === 'local') {
      void child.return(undefined).catch(() => undefined)
      return local
    }
    const [addr, rid] = (first.line ?? '').split(' ')
    if (!addr || !rid) return local
    if (isLocalDone) return local
    let answers: unknown
    try {
      answers = JSON.parse(await seam($, 'commit', [addr, rid], JSON.stringify(call)))
    } catch {
      answers = undefined
    }
    if (answers && typeof answers === 'object' && !Array.isArray(answers)) {
      const context = await replay($, call, answers)
      return context.length > 0 ? { result: { questions: e.questions, answers }, context } : { result: { questions: e.questions, answers } }
    }
    rejected.push(rid)
  }
}

// 결정 도우미. 대기는 spawn 의 긴 호출 하나이고, 확정과 진단 기록은 짧은 run 이다.
const decideArgv = ($: Dollar, sub: string, args: readonly string[]) => ['bash', `${$.plugin.root}/hooks/session-permission-decide.sh`, sub, ...args]

async function decide($: Dollar, sub: string, args: readonly string[], stdin: string): Promise<string> {
  const r = await $.process.run(decideArgv($, sub, args), { stdin, timeoutMs: SEAM_TIMEOUT_MS })
  return r.exitCode === 0 ? r.stdout : ''
}

// 원격 결정을 적용하지 않고 끝난 사유 한 줄. 실패해도 결정 훅을 막지 않는다.
async function note($: Dollar, reason: string, stdin: string) {
  await decide($, 'note', [reason], stdin).catch(() => undefined)
}

type Permit = { session_id: string; tool_name: string; tool_input: unknown; tmpdir: string }
type Remote = { decision: { behavior: 'allow' } | { behavior: 'deny'; message: string } }

const hasDecision = (r: unknown) => !!r && typeof r === 'object' && (r as { decision?: unknown }).decision != null

// 권한 대화창 하나를 두고 아래 단계(대화창과 로컬 답)와 원격 결정 봉투가 경합한다. 아래
// 단계가 결정을 담고 끝났거나 중단 신호가 왔으면 원격 결정을 돌려주지 않는다 — 확정 전에도,
// 확정이 결정을 돌려준 뒤에도. 돌려준 undefined 는 아래 단계를 그대로 돌려주라는 뜻이다.
async function decideRace($: Dollar, call: Permit, below: Promise<unknown>, signal: AbortSignal): Promise<Remote | undefined> {
  let isBelowDecided = false
  const belowDecides = new Promise<{ kind: 'below' }>(resolve => {
    below.then(
      r => {
        if (!hasDecision(r)) return
        isBelowDecided = true
        resolve({ kind: 'below' })
      },
      () => {
        isBelowDecided = true
        resolve({ kind: 'below' })
      },
    )
  })
  const aborted = new Promise<{ kind: 'abort' }>(resolve => {
    if (signal.aborted) resolve({ kind: 'abort' })
    else signal.addEventListener('abort', () => resolve({ kind: 'abort' }), { once: true })
  })
  const stdin = JSON.stringify(call)
  const lost = async () => {
    await note($, signal.aborted ? '중단신호' : '로컬먼저', stdin)
    return undefined
  }
  const rejected: string[] = []
  for (;;) {
    if (isBelowDecided || signal.aborted) return lost()
    const child = $.process.spawn({ argv: decideArgv($, 'wait', []), input: JSON.stringify({ ...call, rejected }) })
    const found = firstLine(child).then(
      line => ({ kind: 'found' as const, line }),
      () => ({ kind: 'found' as const, line: undefined }),
    )
    const first = await Promise.race([belowDecides, aborted, found])
    if (first.kind !== 'found') {
      void child.return(undefined).catch(() => undefined)
      return lost()
    }
    const [addr, rid] = (first.line ?? '').split(' ')
    if (!addr || !rid) return undefined
    if (isBelowDecided || signal.aborted) return lost()
    let out: { behavior?: unknown; sender?: unknown } | undefined
    try {
      out = JSON.parse((await decide($, 'commit', [addr, rid], stdin)).split('\n')[0] ?? '') as typeof out
    } catch {
      out = undefined
    }
    if (out && typeof out === 'object' && (out.behavior === 'allow' || out.behavior === 'deny') && typeof out.sender === 'string') {
      // 확정 사이에 로컬이 이겼으면 적용 기록은 남았어도 결정은 돌려주지 않는다.
      if (isBelowDecided || signal.aborted) {
        await note($, '확정뒤로컬먼저', stdin)
        return undefined
      }
      return out.behavior === 'allow'
        ? { decision: { behavior: 'allow' } }
        : { decision: { behavior: 'deny', message: `원격 거부 — 발신=${out.sender}` } }
    }
    rejected.push(rid)
  }
}

export const register: Register = on => {
  // 대화형이고 표지 다섯이 모두 비어 있고 HOME 이 있을 때만 활성이 된다. /clear·재개로
  // 다시 오면 같은 판정을 다시 한다. 판정이나 시계가 실패해도 세션은 그대로 간다.
  on('session.start', { isInteractive: true }, async ($, e, next) => {
    try {
      scanTimer?.cancel()
      watchTimer?.cancel()
      scanTimer = undefined
      watchTimer = undefined
      isActive = false
      if (!(await pipelineMarked($))) {
        home = (await $.env.get('HOME')) ?? ''
        if (home !== '') {
          stateDir = ((await $.env.get('XDG_STATE_HOME')) || `${home}/.local/state`) + '/cc-cmds'
          const now = await $.clock.now()
          isActive = true
          isTurnRunning = false
          lastHumanAt = now
          lastScanKey = ''
          lastScanCallAt = 0
          ticks = 0
          armScan($, now)
          armWatch($, now)
          if (await isAwake($)) await seam($, 'cleanup', [], JSON.stringify({ session_id: await $.session.id() }))
        }
      }
    } catch {
      // 위 주석과 같다.
    }

    return next(e)
  })

  // 매처는 validate 가 소스에서 읽으므로 상수가 아니라 리터럴로 적는다. .catch 를 두지 않는다 —
  // 로컬 대화창이 거절로 끝나면 그 거절이 그대로 나가야 하고, 다시 next(e) 를 부르면 대화창이
  // 한 번 더 열린다. 그래서 next(e) 앞의 일은 거부를 스스로 삼킨다.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    if (e.agentId || !isActive) return next(e)
    await recover($).catch(() => undefined)
    const args = e as unknown as { tool_use_id: string; questions?: Question[]; answers?: unknown }
    if (args.answers !== undefined || !Array.isArray(args.questions)) return next(e)
    if (!(await isAwake($))) return next(e)
    const local = next(e)
    // 경합이 실패하면 로컬 결과만 기다린다.
    try {
      return (await race($, { tool_use_id: args.tool_use_id, questions: args.questions }, local)) as Awaited<typeof local>
    } catch {
      return local
    }
  })

  // 권한 대화창의 원격 결정. 원격 결정 스위치가 켜진 활성 세션의 메인 대화창에서만 경합하고,
  // 그 밖에는 next(e) 를 그대로 돌려준다. next(e) 는 어느 갈래에서도 한 번만 부른다 — 다시
  // 부르면 대화창이 한 번 더 열린다. 그래서 몸 전체의 거부는 스스로 삼키고, 아래 단계를 띄운
  // 뒤면 그것을, 띄우기 전이면 next(e) 를 돌려준다.
  on('classic.PermissionRequest', async ($, e, next) => {
    let below: ReturnType<typeof next> | undefined
    try {
      const input = e as unknown as { agent_id?: string; session_id?: string; tool_name?: string; tool_input?: unknown }
      if (!isActive || input.agent_id || input.tool_name === 'AskUserQuestion' || typeof input.tool_name !== 'string') return next(e)
      if ((await $.env.get('CC_CMDS_REMOTE_PERMISSION_DECISION')) !== '1') return next(e)
      if (typeof input.session_id !== 'string' || input.session_id === '' || !(await isAwake($))) return next(e)
      const tmpdir = (await $.env.get('TMPDIR')) || '/tmp'
      const call: Permit = { session_id: input.session_id, tool_name: input.tool_name, tool_input: input.tool_input, tmpdir }
      const local = next(e)
      below = local
      const remote = await decideRace($, call, local, next.signal)
      return remote ?? (await local)
    } catch {
      return below ?? next(e)
    }
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId || !isActive) return next(e)
    isTurnRunning = true
    await recover($)

    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    if (e.agentId || !isActive) return next(e)
    isTurnRunning = false
    await recover($)

    return next(e)
  }).catch(($, e, next) => next(e))

  // 사람 입력: 입력 칸 편집, 기록 불러오기·되돌리기, 사람이나 원격 제어의 제출.
  on('prompt.edit', async ($, e, next) => {
    await noteHuman($)

    return next(e)
  }).catch(($, e, next) => next(e))

  on('prompt.change', { origin: { kind: 'history' } }, async ($, e, next) => {
    await noteHuman($)

    return next(e)
  }).catch(($, e, next) => next(e))

  on('prompt.change', { origin: { kind: 'undo' } }, async ($, e, next) => {
    await noteHuman($)

    return next(e)
  }).catch(($, e, next) => next(e))

  // 플러그인 출처 제출(깨우기 자신, 질문지 묶음, 원격 새 지시)은 사람 입력이 아니므로 듣지
  // 않는다. 첫 줄이 원격 표지 줄인 제출도 원격 지시이므로 사람 입력으로 세지 않는다.
  on('prompt.submit', { origin: { kind: 'composer' } }, async ($, e, next) => {
    if (!isRemoteMarked(e.text)) await noteHuman($)

    return next(e)
  }).catch(($, e, next) => next(e))

  on('prompt.submit', { origin: { kind: 'bridge' } }, async ($, e, next) => {
    if (!isRemoteMarked(e.text)) await noteHuman($)

    return next(e)
  }).catch(($, e, next) => next(e))
}

async function noteHuman($: Dollar) {
  if (!isActive) return
  lastHumanAt = await $.clock.now()
  await recover($)
}
