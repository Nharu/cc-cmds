// 줄 모형: 답 요약, 포커스가 설 자리, 패널 크기 어림.
import { describe, expect, test } from 'claude-code/testing'

import {
  COLUMNS_MAX,
  COLUMNS_MIN,
  EDITOR_INDENT,
  EDITOR_SUBMIT_WIDTH,
  ROWS_MAX,
  answerSummary,
  displayWidth,
  landingKey,
  layoutRows,
  paneSize,
  rowText,
} from './layout'
import type { Row } from './layout'
import type { Draft } from './bundle'
import type { FormInput, FormQuestion } from './spec'
import { jump, openEditor, openRecord, typeText } from './transitions'

const opt = (label: string, extra: Record<string, unknown> = {}) => ({ label, description: `${label} 설명`, ...extra })
const single: FormQuestion = { id: 's', header: '하나', question: '고르기', kind: 'single', options: [opt('가', { recommended: '추천' }), opt('나')] }
const multi: FormQuestion = { id: 'm', header: '여럿', question: '고르기', kind: 'multi', options: [opt('가'), opt('나'), opt('다')] }
const text: FormQuestion = { id: 't', header: '글', question: '쓰기', kind: 'text' }
const form: FormInput = { title: '시험', questions: [single, multi, text] }
const d = (selected: string[] = [], other = '', note = ''): Draft => ({ selected, other, note })
// 선택지 줄은 설명을 다음 줄에 그리므로 한 행이 두 줄일 수 있다.
const lineCount = (rows: Row[]) => rows.reduce((n, r) => n + rowText(r).split('\n').length, 0)
const rec = (drafts = {}) => openRecord({ id: 'f-00000001', toolUseId: 'tu', form, drafts, sessionId: 'sid', now: 0 })

describe('답 요약', () => {
  test('미답·single 라벨(추천 접미 없음)·multi 나열·기타·메모 표시', () => {
    expect(answerSummary(single, d())).toBe('미답')
    expect(answerSummary(single, d(['가']))).toBe('가')
    expect(answerSummary(single, d([], '셋째'))).toBe('기타: 셋째')
    expect(answerSummary(multi, d(['가', '다'], '라'))).toBe('가 · 다 · 기타: 라')
    expect(answerSummary(text, d([], '자유 글', '참고'))).toBe('자유 글 · +메모')
    expect(answerSummary(single, d([], '', '메모만'))).toBe('미답 · +메모')
  })

  test('긴 요약은 48자에서 줄임표로 자른다', () => {
    const long = answerSummary(text, d([], '가'.repeat(60)))
    expect([...long]).toHaveLength(48)
    expect(long.endsWith('…')).toBe(true)
  })
})

describe('줄 모형', () => {
  test('커서 질문만 펼치고 나머지는 접힌 줄, 끝에 동작 줄과 안내 줄', () => {
    const kinds = layoutRows(rec(), null).map(r => r.kind)
    expect(kinds).toEqual(['title', 'blank', 'current', 'blank', 'option', 'option', 'other', 'note', 'blank', 'nav', 'blank', 'folded', 'folded', 'blank', 'actions', 'help'])
  })

  test('빈 줄: 그룹 제목 앞에 두되 그룹 제목과 펼친 질문 사이에는 두지 않고, 둘 겹치지 않는다', () => {
    const grouped: FormInput = { title: '묶음', questions: [{ ...single, group: '가' }, { ...multi, group: '나' }, { ...text, group: '나' }] }
    const r = openRecord({ id: 'f-00000006', toolUseId: 'tu', form: grouped, drafts: {}, sessionId: 'sid', now: 0 })
    const kinds = layoutRows(jump(r, 'm'), null).map(x => x.kind)
    expect(kinds.slice(0, 7)).toEqual(['title', 'blank', 'group', 'folded', 'blank', 'group', 'current'])
    expect(kinds.some((k, i) => k === 'blank' && kinds[i + 1] === 'blank')).toBe(false)
  })

  test('선택지 설명은 라벨 밑 줄에 단축키·표지 너비만큼 들여 쓰고, 추천은 괄호로 붙인다', () => {
    const option = layoutRows(rec(), null).find(x => x.kind === 'option')!
    expect(rowText(option)).toBe('  1: ○ 가  (추천)\n       가 설명')
  })

  test('포커스 자리: 첫 선택지, 열린 입력칸, text 의 답 줄', () => {
    expect(landingKey(rec())).toBe('q1-o1')
    expect(landingKey(openEditor(rec(), 's', 'note'))).toBe('q1-note-input-1')
    expect(landingKey(jump(rec(), 't'))).toBe('q3-other-input-1')
    expect(landingKey(jump(typeText(rec(), 't', 'other', '답'), 't'))).toBe('q3-answer')
  })

  test('선택지 열 번째부터는 단축키가 없고 기타는 0, 메모는 m', () => {
    const many: FormInput = {
      title: '많음',
      questions: [{ id: 'q', header: '열', question: '?', kind: 'single', options: Array.from({ length: 11 }, (_, i) => opt(`선택${i + 1}`)) }],
    }
    const rows = layoutRows(openRecord({ id: 'f-00000002', toolUseId: 'tu', form: many, drafts: {}, sessionId: 'sid', now: 0 }), null)
    const hotkeys = rows.map(r => ('hotkey' in r ? r.hotkey : undefined))
    expect(hotkeys.filter(h => h !== undefined)).toEqual(['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 'm'])
  })

  test('미리보기는 포커스가 그 선택지에 있을 때만 줄이 된다', () => {
    const withPreview: FormInput = { title: '미리', questions: [{ ...single, options: [opt('가', { preview: '가 미리보기' }), opt('나')] }] }
    const r = openRecord({ id: 'f-00000003', toolUseId: 'tu', form: withPreview, drafts: {}, sessionId: 'sid', now: 0 })
    expect(layoutRows(r, 'q1-o1').some(x => x.kind === 'preview' && x.text === '가 미리보기')).toBe(true)
    expect(layoutRows(r, 'q1-o2').some(x => x.kind === 'preview')).toBe(false)
    expect(layoutRows(r, null).some(x => x.kind === 'preview')).toBe(false)
  })
})

describe('입력칸', () => {
  const typed = (n: number) => typeText(openEditor(rec(), 's', 'other'), 's', 'other', '가'.repeat(n))
  const after = (rows: Row[]) => rows[rows.findIndex(x => x.kind === 'editor') + 1]

  test('편집기 줄에는 앞말 label 이 없고, 들여쓰기 뒤에 안내글과 확정 표시만 있다', () => {
    const editor = layoutRows(openEditor(rec(), 's', 'other'), null).find(x => x.kind === 'editor')!
    expect('label' in editor).toBe(false)
    expect(rowText(editor)).toBe(`${' '.repeat(EDITOR_INDENT)}직접 입력 ⏎ 확정`)
    expect(EDITOR_SUBMIT_WIDTH).toBe(displayWidth(' ⏎ 확정'))
  })

  test('글이 칸 안에 들어가면 빈 줄을 두지 않는다', () => {
    expect(after(layoutRows(typed(30), null, 80))?.kind).not.toBe('spacer')
    expect(layoutRows(typed(30), null, 80).some(x => x.kind === 'spacer')).toBe(false)
  })

  test('칸 폭을 넘는 글이면 편집기 줄 바로 뒤에 어림식대로 빈 줄을 둔다', () => {
    for (const [n, bodyColumns] of [[40, 80], [100, 80], [150, 80], [30, 40], [60, 40], [20, 10]] as const) {
      const width = Math.max(20, bodyColumns - EDITOR_INDENT - EDITOR_SUBMIT_WIDTH)
      const lines = Math.max(0, Math.ceil((EDITOR_INDENT + 2 * n + 2) / width) - 1)
      expect(lines, `${n}/${bodyColumns}`).toBeGreaterThan(0)
      expect(after(layoutRows(typed(n), null, bodyColumns)), `${n}/${bodyColumns}`).toEqual({ kind: 'spacer', lines })
    }
  })

  test('본문 폭이 없으면 80 으로 어림한다', () => {
    expect(layoutRows(typed(100), null)).toEqual(layoutRows(typed(100), null, 80))
  })

  test('메모 칸도 그 메모 글로 빈 줄을 어림한다', () => {
    const r = typeText(openEditor(rec(), 's', 'note'), 's', 'note', '가'.repeat(100))
    expect(after(layoutRows(r, null, 80))?.kind).toBe('spacer')
  })

  test('그리는 자리는 제어 문자를 거른 글을 쓴다', () => {
    const drafts = { s: d([], '셋\u001b째', '메\u0000모'), t: d([], '글\u009b\n줄') }
    const r = openEditor({ ...rec(), drafts }, 's', 'other')
    const rows = layoutRows(r, null)
    const of = <K extends Row['kind']>(kind: K) => rows.find(x => x.kind === kind) as Extract<Row, { kind: K }>
    expect(of('other').text).toBe('기타: 셋째')
    expect(of('note').text).toBe('메모: 메모')
    expect(of('editor').value).toBe('셋째')
    expect(rows.filter(x => x.kind === 'folded').map(x => (x as Extract<Row, { kind: 'folded' }>).summary)).toContain('글 줄')
    const onT = layoutRows(jump(r, 't'), null)
    expect((onT.find(x => x.kind === 'answer') as Extract<Row, { kind: 'answer' }>).text).toBe('글 줄')
    expect(answerSummary(text, d([], '\u001b\u0000'))).toBe('미답')
  })
})

describe('크기', () => {
  test('한글은 두 칸, 영문은 한 칸', () => {
    expect(displayWidth('abc')).toBe(3)
    expect(displayWidth('한글')).toBe(4)
    expect(displayWidth('a한')).toBe(3)
  })

  test('세로는 보이는 줄 수 더하기 하나, 가로는 산문을 뺀 가장 긴 줄에 맞춘다', () => {
    const r = rec()
    const rows = layoutRows(r, null)
    const { rows: h, columns } = paneSize(r, 120)
    expect(h).toBe(lineCount(rows) + 1)
    const widest = Math.max(...rows.filter(x => !['intro', 'detail', 'preview', 'help'].includes(x.kind)).map(x => displayWidth(rowText(x))))
    expect(columns).toBe(Math.min(COLUMNS_MAX, Math.max(COLUMNS_MIN, widest + 4)))
  })

  test('좁은 본문에서는 감기는 줄을 세고, 커서 질문의 미리보기 자리를 미리 더한다', () => {
    const withPreview: FormInput = { title: '미리', questions: [{ ...single, options: [opt('가', { preview: '한 줄\n두 줄' }), opt('나')] }] }
    const r = openRecord({ id: 'f-00000004', toolUseId: 'tu', form: withPreview, drafts: {}, sessionId: 'sid', now: 0 })
    const wide = paneSize(r, 200).rows
    const narrow = paneSize(r, 30).rows
    expect(wide).toBe(lineCount(layoutRows(r, null)) + 2 + 1)
    expect(narrow).toBeGreaterThan(wide)
  })

  test('편집기 줄은 글 길이와 상관없이 한 줄로 세고, 넘친 몫은 빈 줄만 센다', () => {
    // 긴 답을 씨앗으로 다시 열어 편집기 줄의 글 자체가 본문 폭을 넘게 한다.
    const r = openEditor(typeText(rec(), 's', 'other', '가'.repeat(100)), 's', 'other')
    const rows = layoutRows(r, null, 80)
    const editor = rows.find(x => x.kind === 'editor')!
    const spacer = rows.find(x => x.kind === 'spacer') as Extract<Row, { kind: 'spacer' }>
    expect(displayWidth(rowText(editor))).toBeGreaterThan(80)
    expect(spacer.lines).toBeGreaterThan(0)
    expect(rowText(spacer).split('\n')).toHaveLength(spacer.lines)
    const wrap = (s: string) => s.split('\n').reduce((n, l) => n + Math.max(1, Math.ceil(displayWidth(l) / 80)), 0)
    const expected = rows.reduce((n, x) => n + (x.kind === 'editor' ? 1 : x.kind === 'spacer' ? x.lines : wrap(rowText(x))), 0) + 1
    expect(paneSize(r, 80).rows).toBe(expected)
  })

  test('아주 긴 질문지도 세로 상한을 넘지 않는다', () => {
    const tall: FormInput = {
      title: '길다',
      questions: Array.from({ length: 50 }, (_, i) => ({ id: `q${i}`, header: `${i}`, question: '?', kind: 'text' as const })),
    }
    const r = openRecord({ id: 'f-00000005', toolUseId: 'tu', form: tall, drafts: {}, sessionId: 'sid', now: 0 })
    expect(paneSize(r, 80).rows).toBe(ROWS_MAX)
  })
})
