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
  wrapEditorText,
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
  const typedText = (text: string, field: 'other' | 'note' = 'other') => typeText(openEditor(rec(), 's', field), 's', field, text)
  const typed = (n: number) => typedText('가'.repeat(n))
  const editorOf = (rows: Row[]) => rows.find(x => x.kind === 'editor')!
  // 엔진 실측 표본: 본문 폭 96 에서 엔진이 감은 줄의 끝 낱말.
  const EN =
    'alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen'
  const KO =
    '기존 저장소들은 모두 1.0일걸? 서버 접속해서 2.0을 모두 받아온 후 신규 저장소 생성 필요. 그리고 개발서버 구축을 위해 널리 쓰이는 방식으로 정리하고 배포 스크립트를 함께 손봐야 한다고 생각합니다 가나다라마바사아자차카타파하'
  const lastWords = (lines: string[]) => lines.map(l => l.split(' ').at(-1))

  test('편집기 줄에는 앞말 label 이 없고, 들여쓰기 뒤에 안내글과 확정 표시만 있다', () => {
    const editor = layoutRows(openEditor(rec(), 's', 'other'), null).find(x => x.kind === 'editor')!
    expect('label' in editor).toBe(false)
    expect(rowText(editor)).toBe(`${' '.repeat(EDITOR_INDENT)}직접 입력 ⏎ 확정`)
    expect(EDITOR_SUBMIT_WIDTH).toBe(displayWidth(' ⏎ 확정'))
    // 상자 폭(본문 폭 − 들여쓰기 − 확정 몫)이 엔진이 감는 폭(본문 폭 − 확정 몫 − 1)과 같다.
    expect(EDITOR_INDENT).toBe(1)
  })

  test('줄 모형에 빈 줄 어림(spacer)이 어떤 길이에서도 없다', () => {
    for (const n of [0, 30, 40, 100, 150, 400]) {
      const kinds = layoutRows(typed(n), null).map(x => x.kind as string)
      expect(kinds.includes('spacer'), `${n}`).toBe(false)
      expect(kinds.filter(k => k === 'editor'), `${n}`).toHaveLength(1)
    }
    expect(layoutRows(typedText('가'.repeat(100), 'note'), null).some(x => (x.kind as string) === 'spacer')).toBe(false)
  })

  test('감는 함수는 엔진 실측 두 표본을 엔진과 같은 줄로 나눈다', () => {
    expect(lastWords(wrapEditorText(EN, 96))).toEqual(['november', 'two', 'sixteen', 'seventeen'])
    expect(lastWords(wrapEditorText(KO, 96))).toEqual(['필요.', '손봐야', '가나다라마바사아자차카타파하'])
    expect(wrapEditorText(EN, 96).map(displayWidth)).toEqual([86, 84, 88, 9])
    expect(wrapEditorText(KO, 96).map(displayWidth)).toEqual([87, 85, 46])
    expect(wrapEditorText('', 96)).toEqual([])
  })

  test('감는 폭보다 긴 한 단어는 글자 단위로 끊긴다', () => {
    // 본문 폭 30 이면 감는 폭은 30 − 7 − 1 = 22칸.
    expect(wrapEditorText('a'.repeat(30), 30)).toEqual(['a'.repeat(22), 'a'.repeat(8)])
    expect(wrapEditorText(`짧은 ${'가'.repeat(15)}`, 30)).toEqual(['짧은', '가'.repeat(11), '가'.repeat(4)])
    // 아주 좁아도 감는 폭은 11칸 아래로 내려가지 않는다.
    expect(wrapEditorText('a'.repeat(12), 5)).toEqual(['a'.repeat(11), 'a'])
  })

  test('편집기 줄은 감긴 줄 수만큼이고, 마지막 줄에 2칸 여유가 없으면 한 줄 더', () => {
    const lines = (r: ReturnType<typeof rec>, bodyColumns: number) => rowText(editorOf(layoutRows(r, null)), bodyColumns).split('\n')
    const en = lines(typedText(EN), 96)
    expect(en).toHaveLength(4)
    expect(en[0]!.endsWith('november ⏎ 확정')).toBe(true)
    expect(en.every(l => l.startsWith(' '.repeat(EDITOR_INDENT)))).toBe(true)
    // 감는 폭 88: 86칸이면 커서·조합 몫 2칸이 들어가고, 87칸이면 한 줄이 더 생긴다.
    expect(lines(typedText('a'.repeat(86)), 96)).toHaveLength(1)
    expect(lines(typedText('a'.repeat(87)), 96)).toHaveLength(2)
    expect(lines(typedText('a'.repeat(88)), 96)).toHaveLength(2)
    // 지금 글로 세고, 입력칸에 넘기는 value 는 씨앗 그대로다.
    const editor = editorOf(layoutRows(typedText(EN), null)) as Extract<Row, { kind: 'editor' }>
    expect(editor.value).toBe('')
    expect(editor.text).toBe(EN)
  })

  test('본문 폭이 없으면 80 으로 감는다', () => {
    const editor = editorOf(layoutRows(typed(100), null))
    expect(rowText(editor)).toBe(rowText(editor, 80))
    expect(rowText(editor, 80)).not.toBe(rowText(editor, 120))
  })

  test('입력칸에 포커스가 있으면 위 줄은 라벨만 보인다', () => {
    const drafts = { s: d([], '셋째', '메모글') }
    const onOther = openEditor({ ...rec(), drafts }, 's', 'other')
    const onNote = openEditor(onOther, 's', 'note')
    const of = <K extends Row['kind']>(rows: Row[], kind: K) => rows.find(x => x.kind === kind) as Extract<Row, { kind: K }>
    // 기타 입력칸에 포커스: 기타 줄은 라벨만, 설명도 없다. 표지는 글이 있으므로 켜진 쪽이다.
    const a = layoutRows(onOther, landingKey(onOther))
    expect(landingKey(onOther)).toBe('q1-other-input-1')
    expect(of(a, 'other')).toMatchObject({ text: '기타', description: '', glyph: '●' })
    expect(of(a, 'note').text).toBe('메모: 메모글')
    // 메모 입력칸에 포커스: 메모 줄은 라벨만.
    const b = layoutRows(onNote, landingKey(onNote))
    expect(landingKey(onNote)).toBe('q1-note-input-2')
    expect(of(b, 'note').text).toBe('메모')
    expect(of(b, 'other').text).toBe('기타: 셋째')
    // 포커스가 다른 key 에 있으면 두 줄 모두 전체 글이다.
    for (const r of [onOther, onNote]) {
      const c = layoutRows(r, 'q1-o1')
      expect(of(c, 'other').text).toBe('기타: 셋째')
      expect(of(c, 'note').text).toBe('메모: 메모글')
    }
    // 빈 기타에 포커스가 있어도 안내글을 위 줄에 두지 않는다.
    const empty = openEditor(rec(), 's', 'other')
    expect(of(layoutRows(empty, landingKey(empty)), 'other')).toMatchObject({ text: '기타', description: '' })
    expect(of(layoutRows(empty, null), 'other')).toMatchObject({ text: '기타', description: '직접 입력' })
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

  test('편집기 줄은 감긴 줄 수로 세고, 위 줄은 포커스 없이 전체 글로 센다', () => {
    // 가 100자는 200칸이라 감는 폭 72 에서 36·36·28자 세 줄이다.
    const r = typeText(openEditor(rec(), 's', 'other'), 's', 'other', '가'.repeat(100))
    const rows = layoutRows(r, null)
    const editor = rows.find(x => x.kind === 'editor')!
    expect(rowText(editor, 80).split('\n')).toHaveLength(3)
    expect((rows.find(x => x.kind === 'other') as Extract<Row, { kind: 'other' }>).text).toBe(`기타: ${'가'.repeat(100)}`)
    const wrap = (s: string) => s.split('\n').reduce((n, l) => n + Math.max(1, Math.ceil(displayWidth(l) / 80)), 0)
    const expected = rows.reduce((n, x) => n + wrap(rowText(x, 80)), 0) + 1
    expect(paneSize(r, 80).rows).toBe(expected)
    // 짧은 글보다 정확히 감긴 줄 수의 차만큼 크다.
    const short = typeText(openEditor(rec(), 's', 'other'), 's', 'other', '가')
    const otherLines = Math.ceil(displayWidth(`  0: ● 기타: ${'가'.repeat(100)}  `) / 80)
    expect(paneSize(r, 80).rows - paneSize(short, 80).rows).toBe(2 + otherLines - 1)
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
