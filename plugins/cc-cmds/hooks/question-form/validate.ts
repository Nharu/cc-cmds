// 질문지 입력 전체 검증. 엔진은 입력 스키마를 강제하지 않으므로 이 파일이
// 유일한 검사다. 모든 위반을 모아 돌려주고, 뜻이 분명한 위반은 먼저 고친다.
// 고친 뒤에도 사람이 보는 질문과 돌아오는 답의 뜻이 그대로인 위반만 고친다.

import {
  HANDMADE_OTHER_LABELS,
  HEADER_MAX,
  ID_RE,
  LINE_CONTROL_REASON,
  PROSE_CONTROL_REASON,
  RECOMMEND_ARROW,
  RESERVED_LABELS,
  RESERVED_PREFIXES,
  TITLE_MAX,
  TOTAL_MAX,
  invalidListResult,
} from './spec'
import type { FormInput, Violation } from './spec'

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)
const isStr = (v: unknown): v is string => typeof v === 'string'
const codePoints = (s: string) => [...s].length

const RECOMMENDED_VALUES = ['추천', '에이전트 추천', '기본값'] as const
const ARROW = RECOMMEND_ARROW.trim()
const ELLIPSIS = '…'

// 입력 안 모든 문자열의 글자 수 합.
export function totalChars(v: unknown): number {
  if (isStr(v)) return codePoints(v)
  if (Array.isArray(v)) return v.reduce((n: number, x) => n + totalChars(x), 0)
  if (isObj(v)) return Object.values(v).reduce((n: number, x) => n + totalChars(x), 0)
  return 0
}

// 한 줄로 그려지는 칸(제목·머리말·묶음·안내글·라벨)은 C0·DEL·C1 전부를, 여러 줄로
// 감기는 칸(안내 문단·질문 문장·설명·선택지 설명·미리보기)은 엔진이 받는 줄바꿈·탭·CR 을
// 뺀 나머지를 금한다. 뒤쪽 집합이 곧 엔진이 패널 전체를 거부하는 문자다.
const LINE_CONTROL_RE = /[\u0000-\u001f\u007f-\u009f]/
const PROSE_CONTROL_RE = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/

// 엔진이 거부하는 문자를 품은 칸이 하나라도 있는가. 보관에서 되살릴 기록은 이 검사가
// 생기기 전에 열렸을 수 있으므로 되살리기 전에 다시 건다. 한 줄 칸의 줄바꿈·탭은 엔진이
// 그리므로 여기서는 걸지 않는다.
export function holdsRefusedControl(form: FormInput): boolean {
  const refused = (s: string | undefined) => s !== undefined && PROSE_CONTROL_RE.test(s)
  if (refused(form.title) || refused(form.intro)) return true
  return form.questions.some(
    q =>
      refused(q.header) ||
      refused(q.question) ||
      refused(q.group) ||
      refused(q.detail) ||
      refused(q.placeholder) ||
      (q.options ?? []).some(o => refused(o.label) || refused(o.description) || refused(o.preview)),
  )
}

// JSON 모양 값의 깊은 복사. 입력 객체를 제자리에서 바꾸지 않으려고 쓴다.
function clone<T>(v: T): T {
  if (Array.isArray(v)) return v.map(clone) as T
  if (isObj(v)) return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, clone(x)])) as T
  return v
}

// 라벨 끝 추천 화살표의 꼬리에서 공백을 걷은 것 → recommended 값.
const ARROW_TAILS: Record<string, (typeof RECOMMENDED_VALUES)[number]> = {
  추천: '추천',
  에이전트추천: '에이전트 추천',
  기본값: '기본값',
}

// 허용 밖 recommended 값을 허용 값으로. undefined 는 칸을 지운다는 뜻이고, null 은 고치지 않는다는 뜻이다.
function repairedRecommended(v: unknown): string | undefined | null {
  if (v === true) return '추천'
  if (v === false || v === null) return undefined
  if (!isStr(v)) return null
  const s = v.trim().replace(new RegExp(`^${ARROW}+`), '').trim()
  if (s === '') return undefined
  if ((RECOMMENDED_VALUES as readonly string[]).includes(s)) return s
  if (s.includes('에이전트')) return '에이전트 추천'
  if (s.includes('기본')) return '기본값'
  return '추천'
}

const optionMinimum = (kind: unknown) => (kind === 'single' ? 1 : kind === 'multi' ? 2 : undefined)

// 뜻이 분명한 위반을 고친 복사본과 고친 것 목록(`<칸>: <무엇을 어떻게>`)을 돌려준다. 모양이
// 멀쩡한 자리만 고치고, 칸 경로는 고치기 전 입력의 번호로 적는다. 고친 결과로 생긴 새 위반은
// 고치지 않는다 — 검증이 보고한다.
export function repairForm(input: unknown): { input: unknown; fixes: string[] } {
  if (!isObj(input)) return { input, fixes: [] }
  const form = clone(input)
  const titleFixes: string[] = []
  if (isStr(form.title) && codePoints(form.title) > TITLE_MAX) {
    const cut = [...form.title].slice(0, TITLE_MAX - 1).join('') + ELLIPSIS
    titleFixes.push(`title: ${TITLE_MAX}자를 넘어 「${cut}」로 줄였습니다`)
    form.title = cut
  }
  if (!Array.isArray(form.questions)) return { input: form, fixes: titleFixes }
  const questions = form.questions as unknown[]
  const byQuestion: string[][] = questions.map(() => [])

  // 뒤쪽 질문 가운데 when 이 qid 를 가리키고 selected 가 배열인 것.
  const pointersTo = (qid: string, after: number) =>
    questions
      .slice(after + 1)
      .filter(isObj)
      .map(q => q.when)
      .filter((w): w is Record<string, unknown> & { selected: unknown[] } => isObj(w) && w.id === qid && Array.isArray(w.selected))

  for (let i = 0; i < questions.length; i++) {
    const q = questions[i]
    if (!isObj(q)) continue
    const at = `questions[${i}]`
    const fixes = byQuestion[i]!

    // 머리말 길이.
    if (isStr(q.header)) {
      const nfc = q.header.normalize('NFC')
      if (codePoints(nfc) > HEADER_MAX) {
        const cut = [...nfc].slice(0, HEADER_MAX - 1).join('') + ELLIPSIS
        fixes.push(`${at}.header: NFC 기준 ${HEADER_MAX} 코드포인트를 넘어 「${cut}」로 줄였습니다`)
        q.header = cut
      }
    }

    if (!Array.isArray(q.options)) continue
    const options = q.options as unknown[]
    const qid = isStr(q.id) ? q.id : undefined

    // 라벨 끝의 추천 화살표.
    for (let j = 0; j < options.length; j++) {
      const o = options[j]
      if (!isObj(o) || !isStr(o.label)) continue
      const old = o.label
      const idx = old.lastIndexOf(ARROW)
      if (idx < 0) continue
      const mapped = ARROW_TAILS[old.slice(idx + ARROW.length).replace(/\s/g, '')]
      const label = old.slice(0, idx).trim()
      if (mapped === undefined || label === '') continue
      const removed = old.slice(old.slice(0, idx).trimEnd().length)
      let fix = `${at}.options[${j}].label: 「${old}」에서 「${removed}」을 떼고 `
      if (o.recommended === undefined) {
        o.recommended = mapped
        fix += `recommended 를 「${mapped}」으로 옮겼습니다`
      } else {
        fix += 'recommended 는 그대로 두었습니다'
      }
      o.label = label
      let renamed = false
      if (qid !== undefined) {
        for (const w of pointersTo(qid, i)) {
          w.selected = w.selected.map(s => {
            if (s !== old) return s
            renamed = true
            return label
          })
        }
      }
      if (renamed) fix += '. 이 라벨을 가리키던 when.selected 도 같은 라벨로 바꿨습니다'
      fixes.push(fix)
    }

    // 손으로 만든 기타 계열 선택지.
    const min = optionMinimum(q.kind)
    if (min !== undefined) {
      const drop = options.flatMap((o, j) => {
        if (!isObj(o) || !isStr(o.label)) return []
        const label = o.label.trim()
        if (!HANDMADE_OTHER_LABELS.includes(label) || o.recommended !== undefined) return []
        if (qid !== undefined && pointersTo(qid, i).some(w => w.selected.some(s => s === o.label || s === label))) return []
        return [{ j, label }]
      })
      if (drop.length > 0 && options.length - drop.length >= min) {
        for (const { j, label } of drop) fixes.push(`${at}.options[${j}].label: 손으로 만든 「${label}」 선택지를 지웠습니다. 기타 입력은 allowOther 가 그립니다`)
        const gone = new Set(drop.map(d => d.j))
        q.options = options.filter((_, j) => !gone.has(j))
        if (q.allowOther === false) {
          q.allowOther = true
          fixes.push(`${at}.allowOther: false 를 true 로 바꿔 기타 입력을 켰습니다`)
        }
      }
    }

    // 허용 밖 recommended 값. 지운 선택지는 보지 않는다.
    for (let j = 0; j < options.length; j++) {
      const o = options[j]
      if (!isObj(o) || o.recommended === undefined || !(q.options as unknown[]).includes(o)) continue
      if ((RECOMMENDED_VALUES as readonly unknown[]).includes(o.recommended)) continue
      const next = repairedRecommended(o.recommended)
      if (next === null) continue
      const old = JSON.stringify(o.recommended)
      if (next === undefined) {
        delete o.recommended
        fixes.push(`${at}.options[${j}].recommended: 값 ${old} 는 표시가 아니므로 칸을 지웠습니다`)
      } else {
        o.recommended = next
        fixes.push(`${at}.options[${j}].recommended: 값 ${old} 를 「${next}」 표시로 바꿨습니다`)
      }
    }
  }

  // when.selected 의 없는 라벨. 위에서 고친 라벨로 본다.
  for (let k = 0; k < questions.length; k++) {
    const q = questions[k]
    if (!isObj(q) || !isObj(q.when)) continue
    const w = q.when
    if (!isStr(w.id) || !Array.isArray(w.selected) || w.selected.length === 0 || !w.selected.every(isStr)) continue
    const target = questions.slice(0, k).find(t => isObj(t) && t.id === w.id)
    if (!isObj(target) || (target.kind !== 'single' && target.kind !== 'multi') || !Array.isArray(target.options)) continue
    const labels = (target.options as unknown[]).filter(isObj).map(o => o.label).filter(isStr)
    const selected = w.selected as string[]
    const kept = selected.filter(s => labels.includes(s))
    if (kept.length === 0 || kept.length === selected.length) continue
    const missing = selected.filter(s => !labels.includes(s))
    w.selected = kept
    byQuestion[k]!.push(`questions[${k}].when.selected: 「${w.id}」에 없는 라벨(${missing.map(s => `「${s}」`).join('·')})을 뺐습니다`)
  }

  return { input: form, fixes: [...titleFixes, ...byQuestion.flat()] }
}

function labelProblem(label: string): string | undefined {
  if (label.includes(ARROW)) return '라벨에 「←」를 넣지 않습니다. 추천은 recommended 로 표시합니다'
  if (HANDMADE_OTHER_LABELS.includes(label.trim())) return `「${label.trim()}」 라벨은 만들지 않습니다. allowOther 가 기타 입력을 그립니다`
  if (RESERVED_LABELS.includes(label.trim())) return `「${label.trim()}」는 예약 라벨입니다`
  for (const p of RESERVED_PREFIXES) if (label.trim().startsWith(p)) return `「${p}」로 시작하는 라벨은 예약돼 있습니다`
  return undefined
}

// 고칠 수 없는 위반을 입력 순서(제목·안내·replaces·질문 순, 질문 안에서는 칸 순)로 모두 모은다.
// 위에서 깨지면 아래는 보지 않고, 다른 위반 때문에만 생기는 위반은 적지 않는다.
// openId: 지금 열린(제출·취소되지 않은) 질문지 id. 없으면 undefined.
export function collectViolations(input: unknown, openId: string | undefined): Violation[] {
  const out: Violation[] = []
  const bad = (field: string, reason: string) => {
    out.push({ field, reason })
  }
  if (!isObj(input)) return [{ field: 'input', reason: '객체가 아닙니다' }]
  if (!isStr(input.title) || input.title.trim() === '') bad('title', '필수입니다')
  else if (codePoints(input.title) > TITLE_MAX) bad('title', `${TITLE_MAX}자를 넘습니다`)
  else if (LINE_CONTROL_RE.test(input.title)) bad('title', LINE_CONTROL_REASON)
  if (input.intro !== undefined && !isStr(input.intro)) bad('intro', '문자열이 아닙니다')
  else if (input.intro !== undefined && PROSE_CONTROL_RE.test(input.intro)) bad('intro', PROSE_CONTROL_REASON)
  if (input.replaces !== undefined) {
    if (!isStr(input.replaces)) bad('replaces', '문자열이 아닙니다')
    else if (input.replaces !== openId) bad('replaces', openId ? `열린 질문지 id 는 ${openId} 입니다` : '열린 질문지가 없습니다')
  }
  if (!Array.isArray(input.questions) || input.questions.length === 0) {
    bad('questions', '1개 이상이어야 합니다')
  } else {
    // when 의 대상이 될 수 있는 앞쪽 질문. broken 이면 kind·options 에 위반이 있어 라벨을 대조하지 않는다.
    const seen = new Map<string, { kind: string; labels: string[]; broken: boolean }>()
    // id 가 규칙에 맞지 않거나 겹친 질문의 id. 그것을 가리키는 when 은 따로 보고하지 않는다.
    const badIds = new Set<string>()
    for (let i = 0; i < input.questions.length; i++) {
      const q = input.questions[i]
      const at = `questions[${i}]`
      if (!isObj(q)) {
        bad(at, '객체가 아닙니다')
        continue
      }
      let idOk = false
      if (!isStr(q.id) || !ID_RE.test(q.id)) {
        bad(`${at}.id`, '^[a-z0-9][a-z0-9_-]{0,31}$ 에 맞지 않습니다')
        if (isStr(q.id)) badIds.add(q.id)
      } else if (seen.has(q.id) || badIds.has(q.id)) {
        bad(`${at}.id`, `「${q.id}」가 겹칩니다`)
        badIds.add(q.id)
        seen.delete(q.id)
      } else {
        idOk = true
      }
      if (!isStr(q.header) || q.header.trim() === '') bad(`${at}.header`, '필수입니다')
      else if (codePoints(q.header.normalize('NFC')) > HEADER_MAX) bad(`${at}.header`, `NFC 기준 ${HEADER_MAX} 코드포인트를 넘습니다`)
      else if (LINE_CONTROL_RE.test(q.header)) bad(`${at}.header`, LINE_CONTROL_REASON)
      if (!isStr(q.question) || q.question.trim() === '') bad(`${at}.question`, '필수입니다')
      else if (PROSE_CONTROL_RE.test(q.question)) bad(`${at}.question`, PROSE_CONTROL_REASON)
      for (const k of ['group', 'detail', 'placeholder'] as const) {
        const v = q[k]
        if (v === undefined) continue
        if (!isStr(v)) {
          bad(`${at}.${k}`, '문자열이 아닙니다')
          continue
        }
        const prose = k === 'detail'
        if ((prose ? PROSE_CONTROL_RE : LINE_CONTROL_RE).test(v)) bad(`${at}.${k}`, prose ? PROSE_CONTROL_REASON : LINE_CONTROL_REASON)
      }
      for (const k of ['allowOther', 'allowNote'] as const) {
        if (q[k] !== undefined && typeof q[k] !== 'boolean') bad(`${at}.${k}`, '참·거짓 값이 아닙니다')
      }

      const before = out.length
      const labels: string[] = []
      let kindOk = true
      if (q.kind !== 'single' && q.kind !== 'multi' && q.kind !== 'text') {
        bad(`${at}.kind`, 'single · multi · text 가운데 하나여야 합니다')
        kindOk = false
      } else if (q.kind === 'text') {
        if (q.options !== undefined && (!Array.isArray(q.options) || q.options.length > 0)) bad(`${at}.options`, 'text 질문에는 선택지를 두지 않습니다')
      } else if (!Array.isArray(q.options)) {
        bad(`${at}.options`, `${q.kind} 질문의 선택지는 배열이어야 합니다`)
      } else {
        if (q.kind === 'single' && q.options.length < 1) bad(`${at}.options`, 'single 질문은 선택지가 1개 이상이어야 합니다')
        else if (q.kind === 'single' && q.options.length === 1 && q.allowOther === false) {
          bad(`${at}.options`, '선택지가 1개인 single 질문은 allowOther 를 끄지 않습니다. 제안값 하나에 기타 입력이 붙는 모양입니다')
        } else if (q.kind === 'multi' && q.options.length < 2) bad(`${at}.options`, 'multi 질문은 선택지가 2개 이상이어야 합니다')
        let recommended = 0
        for (let j = 0; j < q.options.length; j++) {
          const o = q.options[j]
          const oat = `${at}.options[${j}]`
          if (!isObj(o)) {
            bad(oat, '객체가 아닙니다')
            continue
          }
          if (!isStr(o.label) || o.label.trim() === '') bad(`${oat}.label`, '필수입니다')
          else if (LINE_CONTROL_RE.test(o.label)) bad(`${oat}.label`, LINE_CONTROL_REASON)
          else {
            const problem = labelProblem(o.label)
            if (problem) bad(`${oat}.label`, problem)
            else if (labels.includes(o.label)) bad(`${oat}.label`, `「${o.label}」가 겹칩니다`)
            else labels.push(o.label)
          }
          if (!isStr(o.description)) bad(`${oat}.description`, '필수입니다')
          else if (PROSE_CONTROL_RE.test(o.description)) bad(`${oat}.description`, PROSE_CONTROL_REASON)
          if (o.preview !== undefined && !isStr(o.preview)) bad(`${oat}.preview`, '문자열이 아닙니다')
          else if (isStr(o.preview) && PROSE_CONTROL_RE.test(o.preview)) bad(`${oat}.preview`, PROSE_CONTROL_REASON)
          if (o.recommended !== undefined) {
            if (!(RECOMMENDED_VALUES as readonly unknown[]).includes(o.recommended)) bad(`${oat}.recommended`, '「추천」·「에이전트 추천」·「기본값」 중 하나여야 합니다')
            else recommended++
          }
        }
        if (q.kind === 'single' && recommended > 1) bad(`${at}.options`, 'single 질문에 추천·기본값 표시가 둘 이상입니다')
      }
      const broken = !kindOk || out.length > before

      if (q.when !== undefined) {
        const w = q.when
        if (!isObj(w) || !isStr(w.id) || !Array.isArray(w.selected) || w.selected.length === 0 || !w.selected.every(isStr)) {
          bad(`${at}.when`, '{id, selected[]} 모양이어야 합니다')
        } else if (!badIds.has(w.id)) {
          const target = seen.get(w.id)
          if (!target) bad(`${at}.when`, `「${w.id}」는 앞쪽 질문이 아닙니다`)
          else if (target.broken) {
            // 대상 질문의 위반이 이미 보고됐다.
          } else if (target.kind === 'text') bad(`${at}.when`, `「${w.id}」는 single·multi 질문이 아닙니다`)
          else {
            const missing = (w.selected as string[]).filter(s => !target.labels.includes(s))
            if (missing.length > 0) bad(`${at}.when`, `「${w.id}」에 ${missing.map(s => `「${s}」`).join('·')} 라벨이 없습니다`)
          }
        }
      }
      if (idOk) seen.set(q.id as string, { kind: q.kind as string, labels, broken })
    }
  }

  if (totalChars(input) > TOTAL_MAX) bad('input', `글자 총량이 ${TOTAL_MAX}자를 넘습니다`)
  return out
}

// 고칠 수 없는 위반이 있으면 그 전부를 담은 거절 결과를, 없으면 undefined 를 돌려준다.
export function validateForm(input: unknown, openId: string | undefined): string | undefined {
  const violations = collectViolations(input, openId)
  return violations.length > 0 ? invalidListResult(violations) : undefined
}

// 검증을 통과한 입력에 기본값을 채운다.
export function normalizeForm(input: FormInput): FormInput {
  return {
    ...input,
    questions: input.questions.map(q => ({
      ...q,
      options: q.kind === 'text' ? [] : q.options ?? [],
      allowOther: q.allowOther ?? true,
      allowNote: q.allowNote ?? true,
    })),
  }
}
