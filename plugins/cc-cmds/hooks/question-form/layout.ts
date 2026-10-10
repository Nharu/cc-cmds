// 질문지 패널의 줄 모형. 기록과 포커스에서 그릴 줄의 목록을 만들고(layoutRows), 같은
// 줄로 패널이 바랄 크기를 잰다(paneSize). render.tsx 는 줄을 요소로 옮길 뿐이다.
// `$` 를 쓰지 않는다.

import { counts, draftOf, inputValue, isAnswered, isVisible } from './bundle'
import {
  ANSWER_LABEL,
  CANCEL_LABEL,
  EDITOR_SUBMIT_LABEL,
  HELP_LINE,
  NEXT_LABEL,
  NOTE_ADD_LABEL,
  NOTE_LABEL,
  NOTE_PLACEHOLDER,
  OTHER_LABEL,
  OTHER_PLACEHOLDER,
  PREV_LABEL,
  SUBMIT_LABEL,
  SUMMARY_MAX,
  TEXT_PLACEHOLDER,
  TO_SUBMIT_LABEL,
  UNANSWERED,
  counterLine,
} from './spec'
import type { FormOption, FormQuestion } from './spec'
import { questionOf } from './transitions'
import type { FormEditor, FormRecord } from './transitions'
import type { Draft } from './bundle'

// 선택지·입력칸·버튼의 key. 미리보기는 포커스 값의 q<i>-o<j> 꼴에서 선택지를 찾는다.
export const foldedKey = (qi: number) => `q${qi}`
export const optionKey = (qi: number, oi: number) => `q${qi}-o${oi}`
export const otherKey = (qi: number) => `q${qi}-other`
export const noteKey = (qi: number) => `q${qi}-note`
export const answerKey = (qi: number) => `q${qi}-answer`
// 입력칸의 key 는 세대마다 다르다. 표면은 Enter 뒤 그 key 의 글을 비우고, 그려진 value 는
// 앞 그림과 값이 다를 때만 다시 적용하므로, 같은 key 로 다시 열면 빈 칸이 보인다.
export const editorKey = (qi: number, field: FormEditor['field'], gen: number) => `q${qi}-${field}-input-${gen}`
export const PREV_KEY = 'prev'
export const NEXT_KEY = 'next'
export const SUBMIT_KEY = 'submit'
export const CANCEL_KEY = 'cancel'

export type Row =
  | { kind: 'blank' }
  | { kind: 'title'; text: string; counter: string }
  | { kind: 'intro'; text: string }
  | { kind: 'group'; text: string }
  | { kind: 'folded'; key: string; n: number; header: string; summary: string; answered: boolean }
  | { kind: 'current'; n: number; header: string; question: string }
  | { kind: 'detail'; text: string }
  | { kind: 'option'; key: string; hotkey?: string; glyph: string; label: string; recommended?: string; description: string; autoFocus: boolean }
  | { kind: 'preview'; text: string }
  | { kind: 'other'; key: string; hotkey: string; glyph: string; text: string; description: string }
  | { kind: 'answer'; key: string; text: string; autoFocus: boolean }
  | { kind: 'editor'; key: string; qid: string; field: FormEditor['field']; value: string; text: string; placeholder: string; autoFocus: boolean }
  | { kind: 'note'; key: string; hotkey: string; text: string }
  | { kind: 'nav'; prev: boolean; next: 'question' | 'submit' | 'none' }
  | { kind: 'actions'; submit: string; cancel: string }
  | { kind: 'help'; text: string }

const glyphOf = (q: FormQuestion, on: boolean) => (q.kind === 'multi' ? (on ? '■' : '□') : on ? '●' : '○')

const cut = (s: string, max: number) => {
  const cps = [...s.replace(/\s+/g, ' ').trim()]
  return cps.length > max ? `${cps.slice(0, max - 1).join('')}…` : cps.join('')
}

// 선택지 설명 줄의 들여쓰기: 단축키·표지(`1: ● `) 너비만큼 라벨 밑으로 맞춘다.
export const descriptionIndent = (hotkey?: string) => (hotkey ? 5 : 2)

// 빈 줄은 둘 겹치지 않고, 맨 앞에도 두지 않는다.
function pushBlank(rows: Row[]) {
  const last = rows.at(-1)
  if (last && last.kind !== 'blank') rows.push({ kind: 'blank' })
}

// 접힌 질문 줄의 답 요약 한 줄. 라벨은 추천 접미 없이 보이고, 메모가 있으면 끝에 표시한다.
export function answerSummary(q: FormQuestion, d: Draft): string {
  const other = inputValue(d.other).trim()
  const parts: string[] = []
  if (!isAnswered(q, d)) parts.push(UNANSWERED)
  else if (q.kind === 'text') parts.push(other)
  else {
    for (const s of d.selected) parts.push(s)
    if (other !== '') parts.push(`${OTHER_LABEL}: ${other}`)
  }
  const line = cut(parts.join(' · '), SUMMARY_MAX)
  return inputValue(d.note).trim() === '' ? line : `${line} · +${NOTE_LABEL}`
}

// 포커스가 이 질문의 선택지 버튼에 있으면 그 선택지의 미리보기, 아니면 undefined.
export function previewFor(qi: number, q: FormQuestion, focused: string | null): string | undefined {
  const m = focused === null ? null : /^q(\d+)-o(\d+)$/.exec(focused)
  if (!m || Number(m[1]) !== qi) return undefined
  return (q.options ?? [])[Number(m[2]) - 1]?.preview
}

// 커서 질문이 열릴 때 포커스가 설 곳: 열린 입력칸, text 의 답 줄, 아니면 첫 선택지.
export function landingKey(rec: FormRecord): string {
  const qi = rec.form.questions.findIndex(q => q.id === rec.cursor) + 1
  const q = questionOf(rec, rec.cursor)
  if (!q || qi < 1) return SUBMIT_KEY
  if (rec.editor && rec.editor.id === rec.cursor) return editorKey(qi, rec.editor.field, rec.editor.gen)
  if (q.kind === 'text') return answerKey(qi)
  return (q.options ?? []).length > 0 ? optionKey(qi, 1) : otherKey(qi)
}

// 편집기 줄의 들여쓰기와, 같은 Input 줄 안에 그려지는 「 ⏎ 확정」 몫. 엔진은 들여쓰기와
// 상관없이 본문 폭 − 확정 몫 − 1 칸에서 글을 감고, 상자가 그보다 좁으면 감긴 첫 줄이
// 들어가지 않아 글 전체를 한 줄로 잘라 그린다. 상자 폭(본문 폭 − 들여쓰기 − 확정 몫)이
// 감는 폭과 같아지는 최대 들여쓰기가 1칸이다.
export const EDITOR_INDENT = 1
export const EDITOR_SUBMIT_WIDTH = displayWidth(` ⏎ ${EDITOR_SUBMIT_LABEL}`)

// 엔진이 입력칸의 글을 감는 대로 나눈 줄들. 칸 폭은 최소 12칸이고 감는 폭은 그보다 1칸
// 좁다. 공백 단위로 앞에서부터 채우고, 감는 폭보다 긴 한 단어는 글자 단위로 끊는다.
// 높이를 바라는 데만 쓴다 — 글과 커서를 놓는 것은 엔진이다.
export const editorWrapWidth = (bodyColumns: number) => Math.max(11, bodyColumns - EDITOR_SUBMIT_WIDTH - 1)

export function wrapEditorText(text: string, bodyColumns: number): string[] {
  if (text === '') return []
  const width = editorWrapWidth(bodyColumns)
  const lines: string[] = []
  let line: string | null = null
  for (const word of text.split(' ')) {
    if (line !== null && displayWidth(`${line} ${word}`) <= width) {
      line = `${line} ${word}`
      continue
    }
    if (line !== null) lines.push(line)
    line = ''
    for (const ch of word) {
      if (line !== '' && displayWidth(line + ch) > width) {
        lines.push(line)
        line = ''
      }
      line += ch
    }
  }
  if (line !== null) lines.push(line)
  return lines
}

// 편집기 줄. 앞말 라벨은 두지 않는다 — 바로 위 줄(기타·메모 줄이나 펼친 질문의 머리말)이
// 이미 그 칸이 무엇인지 말한다. value 는 입력칸에 넘기는 씨앗이고, text 는 높이를 셀 지금 글이다.
function editorRows(rec: FormRecord, qi: number, q: FormQuestion, field: FormEditor['field'], autoFocus: boolean): Row[] {
  const ed = rec.editor
  if (!ed || ed.id !== q.id || ed.field !== field) return []
  const placeholder = field === 'note' ? NOTE_PLACEHOLDER : q.kind === 'text' ? q.placeholder ?? TEXT_PLACEHOLDER : OTHER_PLACEHOLDER
  const d = draftOf(rec.drafts, q.id)
  const text = inputValue(field === 'note' ? d.note : d.other)
  return [{ kind: 'editor', key: editorKey(qi, field, ed.gen), qid: q.id, field, value: inputValue(ed.seed), text, placeholder, autoFocus }]
}

// 이 질문의 그 편집기가 열려 있고 포커스가 그 입력칸에 있는가. 그동안 위 줄은 라벨만 보인다.
function editing(rec: FormRecord, qi: number, q: FormQuestion, field: FormEditor['field'], focused: string | null): boolean {
  const ed = rec.editor
  return !!ed && ed.id === q.id && ed.field === field && focused === editorKey(qi, field, ed.gen)
}

function currentRows(rec: FormRecord, qi: number, q: FormQuestion, focused: string | null): Row[] {
  const d = draftOf(rec.drafts, q.id)
  const landing = landingKey(rec)
  const rows: Row[] = [{ kind: 'current', n: qi, header: q.header, question: q.question }]
  if (q.detail) rows.push({ kind: 'detail', text: q.detail })
  pushBlank(rows)
  if (q.kind === 'text') {
    const editor = editorRows(rec, qi, q, 'other', landing === editorKey(qi, 'other', rec.editor?.gen ?? 0))
    const answer = inputValue(d.other)
    if (editor.length > 0) rows.push(...editor)
    else rows.push({ kind: 'answer', key: answerKey(qi), text: answer.trim() === '' ? UNANSWERED : answer, autoFocus: landing === answerKey(qi) })
  } else {
    ;(q.options ?? []).forEach((o: FormOption, index) => {
      const key = optionKey(qi, index + 1)
      rows.push({
        kind: 'option',
        key,
        ...(index < 9 ? { hotkey: String(index + 1) } : {}),
        glyph: glyphOf(q, d.selected.includes(o.label)),
        label: o.label,
        ...(o.recommended ? { recommended: o.recommended } : {}),
        description: o.description,
        autoFocus: landing === key,
      })
    })
    const preview = previewFor(qi, q, focused)
    if (preview !== undefined) rows.push({ kind: 'preview', text: preview })
    if (q.allowOther !== false) {
      const other = inputValue(d.other).trim()
      const labelOnly = editing(rec, qi, q, 'other', focused)
      rows.push({
        kind: 'other',
        key: otherKey(qi),
        hotkey: '0',
        glyph: glyphOf(q, other !== ''),
        text: other === '' || labelOnly ? OTHER_LABEL : `${OTHER_LABEL}: ${other}`,
        description: other === '' && !labelOnly ? OTHER_PLACEHOLDER : '',
      })
      rows.push(...editorRows(rec, qi, q, 'other', landing === editorKey(qi, 'other', rec.editor?.gen ?? 0)))
    }
  }
  if (q.allowNote !== false) {
    const note = inputValue(d.note).trim()
    const text = editing(rec, qi, q, 'note', focused) ? NOTE_LABEL : note === '' ? NOTE_ADD_LABEL : `${NOTE_LABEL}: ${note}`
    rows.push({ kind: 'note', key: noteKey(qi), hotkey: 'm', text })
    rows.push(...editorRows(rec, qi, q, 'note', landing === editorKey(qi, 'note', rec.editor?.gen ?? 0)))
  }
  const ids = rec.form.questions.filter(x => isVisible(rec.form, rec.drafts, x)).map(x => x.id)
  const at = ids.indexOf(q.id)
  pushBlank(rows)
  rows.push({ kind: 'nav', prev: at > 0, next: at < ids.length - 1 ? 'question' : 'submit' })
  return rows
}

// focused 는 포커스 값(요소의 key)이다. 선택지 미리보기와, 입력칸 위 줄을 라벨만 둘지를 정한다.
export function layoutRows(rec: FormRecord, focused: string | null): Row[] {
  const { form, drafts } = rec
  const { answered, total } = counts(form, drafts)
  const rows: Row[] = [{ kind: 'title', text: form.title, counter: counterLine(answered, total) }]
  if (form.intro) rows.push({ kind: 'intro', text: form.intro })
  pushBlank(rows)
  let group: string | undefined
  form.questions.forEach((q, index) => {
    if (!isVisible(form, drafts, q)) return
    const qi = index + 1
    if (q.group && q.group !== group) {
      pushBlank(rows)
      rows.push({ kind: 'group', text: q.group })
    }
    group = q.group
    // 펼친 질문은 위아래 빈 줄로 접힌 줄들과 떼어 놓는다.
    if (q.id === rec.cursor) {
      if (rows.at(-1)?.kind !== 'group') pushBlank(rows)
      rows.push(...currentRows(rec, qi, q, focused))
      pushBlank(rows)
      return
    }
    const d = draftOf(drafts, q.id)
    rows.push({ kind: 'folded', key: foldedKey(qi), n: qi, header: q.header, summary: answerSummary(q, d), answered: isAnswered(q, d) })
  })
  pushBlank(rows)
  rows.push({ kind: 'actions', submit: SUBMIT_LABEL, cancel: CANCEL_LABEL })
  rows.push({ kind: 'help', text: HELP_LINE })
  return rows
}

// 한 줄이 그리는 Button·Input 의 key. render.tsx 의 drawForm 이 다는 key 와 같아야 한다.
function stopsOf(row: Row): string[] {
  switch (row.kind) {
    case 'folded':
    case 'option':
    case 'other':
    case 'answer':
    case 'editor':
    case 'note':
      return [row.key]
    case 'nav':
      return [...(row.prev ? [PREV_KEY] : []), ...(row.next !== 'none' ? [NEXT_KEY] : [])]
    case 'actions':
      return [SUBMIT_KEY, CANCEL_KEY]
    default:
      return []
  }
}

// ↑/↓ 가 거치는 정지점: 패널에 그려지는 Button·Input 의 key 를 화면 순서로. Tab 과 같다.
export const focusStops = (rows: Row[]): string[] => rows.flatMap(stopsOf)

// 보이게 하기의 대상 상자 key. 그리기와 보이게 하기가 같은 함수를 쓴다.
export const blockKey = (key: string) => `${key}-block`
export const headKey = (n: number) => `q${n}-head`

// 펼친 질문의 첫 정지점과 그 질문 번호. 펼친 질문이 없으면 undefined.
export function firstStopOfCurrent(rows: Row[]): { key: string; n: number } | undefined {
  const at = rows.findIndex(r => r.kind === 'current')
  const head = rows[at]
  if (!head || head.kind !== 'current') return undefined
  const key = focusStops(rows.slice(at + 1))[0]
  return key === undefined ? undefined : { key, n: head.n }
}

// key 로 포커스가 옮겨 갔을 때 차례대로 보이게 할 대상. 선택지는 설명까지 담은 바깥 상자를,
// 펼친 질문의 첫 정지점이면 머리말을 먼저, 항목을 나중에 — 창이 둘을 함께 담지 못하면
// 나중에 부른 항목이 이긴다.
export function revealKeys(rows: Row[], key: string): string[] {
  const row = rows.find(r => 'key' in r && r.key === key)
  const target = row?.kind === 'option' ? blockKey(key) : key
  const first = firstStopOfCurrent(rows)
  return first?.key === key ? [headKey(first.n), target] : [target]
}

// 지금 포커스에서 by 칸 옮긴 정지점. 양 끝에서 멈추고 돌지 않는다. 포커스가 목록에 없으면
// 아래로는 첫 정지점, 위로는 마지막 정지점이다. stops 는 비어 있지 않아야 한다.
export function stepStop(stops: string[], focused: string | null, by: number): string {
  const at = focused === null ? -1 : stops.indexOf(focused)
  if (at < 0) return (by > 0 ? stops[0] : stops[stops.length - 1]) as string
  return stops[Math.min(stops.length - 1, Math.max(0, at + by))] as string
}

// ui.scroll 입력 가운데 가로채기 판단에 쓰는 필드.
export type ArrowInput = { by: number; bodyRows: number; origin?: { kind: string }; pointer?: unknown }

// ↑/↓ 가로채기가 포커스를 옮길 정지점. null 이면 엔진의 스크롤로 넘긴다. 사람의 키보드 한
// 줄 이동만 가로챈다 — 휠에는 pointer 가 붙고, 페이지 키는 bodyRows, Home/End 는
// contentRows 만큼이다. 이미 끝에 있어 옮길 곳이 지금 자리와 같으면 넘겨, 포커스는 멈춘
// 채 남은 줄을 볼 수 있게 한다.
export function arrowTarget(rows: Row[], focused: string | null, input: ArrowInput): string | null {
  if (input.origin?.kind !== 'person' || input.pointer !== undefined) return null
  const step = Math.abs(input.by)
  if (!(step > 0 && step < input.bodyRows)) return null
  const stops = focusStops(rows)
  if (stops.length === 0) return null
  const target = stepStop(stops, focused, input.by)
  return target === focused ? null : target
}

// 감긴 편집기 글의 마지막 줄에 커서와 조합 글자 몫 2칸이 남지 않으면 엔진은 한 줄을 더 쓴다.
function editorText(row: Extract<Row, { kind: 'editor' }>, bodyColumns: number): string {
  const indent = ' '.repeat(EDITOR_INDENT)
  const lines = wrapEditorText(row.text, bodyColumns)
  if (lines.length === 0) return `${indent}${row.placeholder} ⏎ ${EDITOR_SUBMIT_LABEL}`
  if (displayWidth(lines.at(-1)!) + 2 > editorWrapWidth(bodyColumns)) lines.push('')
  return lines.map((line, i) => `${indent}${line}${i === 0 ? ` ⏎ ${EDITOR_SUBMIT_LABEL}` : ''}`).join('\n')
}

// 한 줄이 보이는 대로의 글. 크기를 재는 데만 쓴다. bodyColumns 는 편집기 글을 감을 본문
// 폭이고, 없으면 80 으로 어림한다.
export function rowText(row: Row, bodyColumns = 80): string {
  switch (row.kind) {
    case 'blank':
      return ''
    case 'title':
      return `${row.text}  ${row.counter}`
    case 'folded':
      return `  ${row.n} ${row.header}  ${row.summary}`
    case 'current':
      return `▸ ${row.n} ${row.header}  ${row.question}`
    case 'detail':
    case 'intro':
      return `  ${row.text}`
    case 'option':
      return (
        `  ${row.hotkey ? `${row.hotkey}: ` : ''}${row.glyph} ${row.label}${row.recommended ? `  (${row.recommended})` : ''}` +
        (row.description ? `\n${' '.repeat(2 + descriptionIndent(row.hotkey))}${row.description}` : '')
      )
    case 'preview':
      return `    │ ${row.text}`
    case 'other':
      return `  ${row.hotkey}: ${row.glyph} ${row.text}  ${row.description}`
    case 'answer':
      return `  ${ANSWER_LABEL}: ${row.text}`
    case 'editor':
      return editorText(row, bodyColumns)
    case 'note':
      return `  ${row.hotkey}: ${row.text}`
    case 'nav':
      return `  ${row.prev ? `p: ${PREV_LABEL}  ` : ''}${row.next === 'question' ? `n: ${NEXT_LABEL}` : row.next === 'submit' ? `n: ${TO_SUBMIT_LABEL}` : ''}`
    case 'actions':
      return `[ ${row.submit} ]  [ ${row.cancel} ]`
    case 'group':
    case 'help':
      return row.text
  }
}

// 터미널 칸 수: 한글·한중일 글자와 이모지는 두 칸, 나머지는 한 칸으로 어림한다.
export function displayWidth(s: string): number {
  let w = 0
  for (const ch of s) {
    const cp = ch.codePointAt(0) ?? 0
    if (cp < 0x20 || (cp >= 0x300 && cp <= 0x36f)) continue
    const wide =
      (cp >= 0x1100 && cp <= 0x115f) ||
      (cp >= 0x2e80 && cp <= 0xa4cf) ||
      (cp >= 0xac00 && cp <= 0xd7a3) ||
      (cp >= 0xf900 && cp <= 0xfaff) ||
      (cp >= 0xfe30 && cp <= 0xfe4f) ||
      (cp >= 0xff00 && cp <= 0xff60) ||
      (cp >= 0xffe0 && cp <= 0xffe6) ||
      (cp >= 0x1f300 && cp <= 0x1faff) ||
      (cp >= 0x20000 && cp <= 0x3fffd)
    w += wide ? 2 : 1
  }
  return w
}

export const ROWS_MIN = 6
export const ROWS_MAX = 40
export const COLUMNS_MIN = 60
export const COLUMNS_MAX = 100

// 감겨도 되는 산문 줄. 가로 크기를 잴 때 빼고, 세로를 잴 때는 감긴 줄 수로 센다.
const PROSE: Row['kind'][] = ['intro', 'detail', 'preview', 'help']

// 패널이 바랄 크기. 세로는 지금 보이는 줄이 bodyColumns 에서 감기는 줄 수에, 커서 질문의
// 가장 긴 미리보기 자리를 더한 것(포커스가 옮겨 미리보기가 나타나도 크기가 흔들리지
// 않게). 가로는 산문이 아닌 가장 긴 줄에 맞추되 60~100칸 안이다. 둘 다 요청일 뿐 결정은
// 엔진이 한다. 포커스가 있는 입력칸은 엔진이 감긴 대로 여러 줄로 그리므로 편집기 줄도
// 감긴 줄 수로 센다. 포커스 없이 줄을 만들어 위 줄의 전체 글까지 함께 세므로, 입력칸에
// 포커스가 있어 위 줄이 라벨만인 동안에는 남는 쪽이다.
export function paneSize(rec: FormRecord, bodyColumns: number): { rows: number; columns: number } {
  const rows = layoutRows(rec, null)
  const widest = rows
    .filter(r => !PROSE.includes(r.kind))
    .reduce((w, r) => Math.max(w, ...rowText(r, bodyColumns).split('\n').map(displayWidth)), 0)
  const columns = Math.min(COLUMNS_MAX, Math.max(COLUMNS_MIN, widest + 4))
  const width = Math.max(20, bodyColumns)
  const lines = (s: string) => s.split('\n').reduce((n, line) => n + Math.max(1, Math.ceil(displayWidth(line) / width)), 0)
  let height = rows.reduce((n, r) => n + lines(rowText(r, bodyColumns)), 0)
  const q = questionOf(rec, rec.cursor)
  const previews = (q?.options ?? []).map(o => (o.preview === undefined ? 0 : lines(o.preview)))
  height += Math.max(0, ...previews)
  return { rows: Math.min(ROWS_MAX, Math.max(ROWS_MIN, height + 1)), columns }
}
