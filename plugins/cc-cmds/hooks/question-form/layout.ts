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
  | { kind: 'editor'; key: string; qid: string; field: FormEditor['field']; value: string; placeholder: string; autoFocus: boolean }
  | { kind: 'spacer'; lines: number }
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

// 편집기 줄의 들여쓰기와, 같은 Input 줄 안에 그려지는 「 ⏎ 확정」 몫.
export const EDITOR_INDENT = 4
export const EDITOR_SUBMIT_WIDTH = displayWidth(` ⏎ ${EDITOR_SUBMIT_LABEL}`)

// 칸보다 긴 글을 치면 엔진은 칸 안을 말줄임으로 그리고 커서·조합 글자를 칸 아래 줄에
// 놓는다. 그 자리가 메모 줄을 덮지 않도록 편집기 줄 뒤에 넘칠 줄 수만큼 빈 줄을 둔다.
// 엔진이 감는 폭은 모르므로 들여쓰기와 확정 몫을 모두 뺀 좁은 폭으로 나누고, 조합 중인
// 한글 한 글자 몫 2칸을 더해 남는 쪽으로 어림한다.
export function spacerLines(text: string, bodyColumns: number): number {
  const width = Math.max(20, bodyColumns - EDITOR_INDENT - EDITOR_SUBMIT_WIDTH)
  return Math.max(0, Math.ceil((EDITOR_INDENT + displayWidth(text) + 2) / width) - 1)
}

// 편집기 줄과, 넘칠 글이면 그 뒤의 빈 줄. 앞말 라벨은 두지 않는다 — 바로 위 줄(기타·메모
// 줄이나 펼친 질문의 머리말)이 이미 그 칸이 무엇인지 말한다.
function editorRows(rec: FormRecord, qi: number, q: FormQuestion, field: FormEditor['field'], autoFocus: boolean, bodyColumns: number): Row[] {
  const ed = rec.editor
  if (!ed || ed.id !== q.id || ed.field !== field) return []
  const placeholder = field === 'note' ? NOTE_PLACEHOLDER : q.kind === 'text' ? q.placeholder ?? TEXT_PLACEHOLDER : OTHER_PLACEHOLDER
  const rows: Row[] = [{ kind: 'editor', key: editorKey(qi, field, ed.gen), qid: q.id, field, value: inputValue(ed.seed), placeholder, autoFocus }]
  const d = draftOf(rec.drafts, q.id)
  const lines = spacerLines(inputValue(field === 'note' ? d.note : d.other), bodyColumns)
  if (lines > 0) rows.push({ kind: 'spacer', lines })
  return rows
}

function currentRows(rec: FormRecord, qi: number, q: FormQuestion, focused: string | null, bodyColumns: number): Row[] {
  const d = draftOf(rec.drafts, q.id)
  const landing = landingKey(rec)
  const rows: Row[] = [{ kind: 'current', n: qi, header: q.header, question: q.question }]
  if (q.detail) rows.push({ kind: 'detail', text: q.detail })
  pushBlank(rows)
  if (q.kind === 'text') {
    const editor = editorRows(rec, qi, q, 'other', landing === editorKey(qi, 'other', rec.editor?.gen ?? 0), bodyColumns)
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
      rows.push({
        kind: 'other',
        key: otherKey(qi),
        hotkey: '0',
        glyph: glyphOf(q, other !== ''),
        text: other === '' ? OTHER_LABEL : `${OTHER_LABEL}: ${other}`,
        description: other === '' ? OTHER_PLACEHOLDER : '',
      })
      rows.push(...editorRows(rec, qi, q, 'other', landing === editorKey(qi, 'other', rec.editor?.gen ?? 0), bodyColumns))
    }
  }
  if (q.allowNote !== false) {
    const note = inputValue(d.note).trim()
    rows.push({ kind: 'note', key: noteKey(qi), hotkey: 'm', text: note === '' ? NOTE_ADD_LABEL : `${NOTE_LABEL}: ${note}` })
    rows.push(...editorRows(rec, qi, q, 'note', landing === editorKey(qi, 'note', rec.editor?.gen ?? 0), bodyColumns))
  }
  const ids = rec.form.questions.filter(x => isVisible(rec.form, rec.drafts, x)).map(x => x.id)
  const at = ids.indexOf(q.id)
  pushBlank(rows)
  rows.push({ kind: 'nav', prev: at > 0, next: at < ids.length - 1 ? 'question' : 'submit' })
  return rows
}

// bodyColumns 는 편집기 뒤 빈 줄 수를 어림할 본문 폭이다. 없으면 80 으로 어림한다.
export function layoutRows(rec: FormRecord, focused: string | null, bodyColumns = 80): Row[] {
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
      rows.push(...currentRows(rec, qi, q, focused, bodyColumns))
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

// 한 줄이 보이는 대로의 글. 크기를 재는 데만 쓴다.
export function rowText(row: Row): string {
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
      return `${' '.repeat(EDITOR_INDENT)}${row.value === '' ? row.placeholder : row.value} ⏎ ${EDITOR_SUBMIT_LABEL}`
    case 'spacer':
      return '\n'.repeat(row.lines - 1)
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
// 엔진이 한다. 엔진은 Input 을 한 줄로 그리므로 편집기 줄은 글 길이와 상관없이 한 줄로
// 세고, 넘친 몫은 그 뒤의 빈 줄(spacer)만 센다.
export function paneSize(rec: FormRecord, bodyColumns: number): { rows: number; columns: number } {
  const rows = layoutRows(rec, null, bodyColumns)
  const widest = rows
    .filter(r => !PROSE.includes(r.kind))
    .reduce((w, r) => Math.max(w, ...rowText(r).split('\n').map(displayWidth)), 0)
  const columns = Math.min(COLUMNS_MAX, Math.max(COLUMNS_MIN, widest + 4))
  const width = Math.max(20, bodyColumns)
  const lines = (s: string) => s.split('\n').reduce((n, line) => n + Math.max(1, Math.ceil(displayWidth(line) / width)), 0)
  let height = rows.reduce((n, r) => n + (r.kind === 'editor' ? 1 : lines(rowText(r))), 0)
  const q = questionOf(rec, rec.cursor)
  const previews = (q?.options ?? []).map(o => (o.preview === undefined ? 0 : lines(o.preview)))
  height += Math.max(0, ...previews)
  return { rows: Math.min(ROWS_MAX, Math.max(ROWS_MIN, height + 1)), columns }
}
