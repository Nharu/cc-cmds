import { describe, expect, test } from 'claude-code/testing'

import { validateForm } from './validate'

const opt = (label: string, extra: Record<string, unknown> = {}) => ({ label, description: `${label} 설명`, ...extra })

const good = () => ({
  title: '경계 질문',
  questions: [
    { id: 'scope', header: '범위', question: '어디까지?', kind: 'single', options: [opt('좁게', { recommended: '추천' }), opt('넓게')] },
    { id: 'parts', header: '부분', question: '무엇을?', kind: 'multi', options: [opt('가'), opt('나'), opt('다')] },
    { id: 'why', header: '이유', question: '왜?', kind: 'text', when: { id: 'scope', selected: ['넓게'] } },
  ],
})

const field = (r: string | undefined) => r?.replace(/^QUESTION_FORM_INVALID ([^:]+):.*$/s, '$1')

describe('validateForm', () => {
  test('정상 입력은 통과한다', () => {
    expect(validateForm(good(), undefined)).toBeUndefined()
  })

  test('거절은 QUESTION_FORM_INVALID <칸>: <사유> 문면이다', () => {
    const r = validateForm({ ...good(), title: '' }, undefined)
    expect(r).toMatch(/^QUESTION_FORM_INVALID title: .+/)
  })

  test('id 가 겹치면 거절', () => {
    const f = good()
    f.questions[1].id = 'scope'
    expect(field(validateForm(f, undefined))).toBe('questions[1].id')
  })

  test('선택지 수: single 1개 거절, text 에 선택지 거절', () => {
    const a = good()
    a.questions[0].options = [opt('하나')]
    expect(field(validateForm(a, undefined))).toBe('questions[0].options')
    const b = good()
    ;(b.questions[2] as Record<string, unknown>).options = [opt('가'), opt('나')]
    expect(field(validateForm(b, undefined))).toBe('questions[2].options')
  })

  test('라벨 안의 ← 는 거절', () => {
    const f = good()
    f.questions[1].options![0] = opt('가 ← 추천')
    expect(field(validateForm(f, undefined))).toBe('questions[1].options[0].label')
  })

  test('손으로 만든 기타 계열 라벨은 거절', () => {
    for (const label of ['기타', '직접 입력', '직접 지정', 'Other']) {
      const f = good()
      f.questions[1].options![2] = opt(label)
      expect(field(validateForm(f, undefined)), label).toBe('questions[1].options[2].label')
    }
  })

  test('예약 라벨은 거절', () => {
    for (const label of ['미답', '해당 없음', '메모: 무엇', '자유 입력: 무엇']) {
      const f = good()
      f.questions[1].options![2] = opt(label)
      expect(field(validateForm(f, undefined)), label).toBe('questions[1].options[2].label')
    }
  })

  test('single 에 추천 둘은 거절, multi 는 허용', () => {
    const a = good()
    a.questions[0].options![1] = opt('넓게', { recommended: '에이전트 추천' })
    expect(field(validateForm(a, undefined))).toBe('questions[0].options')
    const b = good()
    b.questions[1].options = [opt('가', { recommended: '추천' }), opt('나', { recommended: '추천' })]
    expect(validateForm(b, undefined)).toBeUndefined()
  })

  test('when 이 뒤쪽 질문이나 없는 라벨을 가리키면 거절', () => {
    const a = good()
    ;(a.questions[0] as Record<string, unknown>).when = { id: 'parts', selected: ['가'] }
    expect(field(validateForm(a, undefined))).toBe('questions[0].when')
    const b = good()
    b.questions[2].when = { id: 'scope', selected: ['없는 라벨'] }
    expect(field(validateForm(b, undefined))).toBe('questions[2].when')
  })

  test('replaces 가 열린 id 와 다르면 거절, 같으면 통과', () => {
    expect(field(validateForm({ ...good(), replaces: 'f-00000000' }, 'f-11111111'))).toBe('replaces')
    expect(field(validateForm({ ...good(), replaces: 'f-00000000' }, undefined))).toBe('replaces')
    expect(validateForm({ ...good(), replaces: 'f-11111111' }, 'f-11111111')).toBeUndefined()
  })

  test('경계값: header 12/13 코드포인트(NFC)', () => {
    const a = good()
    a.questions[0].header = '가'.repeat(12)
    expect(validateForm(a, undefined)).toBeUndefined()
    // 분해형 한글 12자는 NFC 로 12 코드포인트다.
    const b = good()
    b.questions[0].header = '가'.repeat(12).normalize('NFD')
    expect(validateForm(b, undefined)).toBeUndefined()
    const c = good()
    c.questions[0].header = '가'.repeat(13)
    expect(field(validateForm(c, undefined))).toBe('questions[0].header')
  })

  test('경계값: id 32/33자', () => {
    const a = good()
    a.questions[1].id = 'a'.repeat(32)
    expect(validateForm(a, undefined)).toBeUndefined()
    const b = good()
    b.questions[1].id = 'a'.repeat(33)
    expect(field(validateForm(b, undefined))).toBe('questions[1].id')
  })

  test('한 줄 칸 다섯은 줄바꿈과 ESC 를 그 칸 경로로 거절한다', () => {
    const cases: [string, (f: any, v: string) => void][] = [
      ['title', (f, v) => (f.title = `가${v}나`)],
      ['questions[0].header', (f, v) => (f.questions[0].header = `가${v}나`)],
      ['questions[0].group', (f, v) => (f.questions[0].group = `가${v}나`)],
      ['questions[2].placeholder', (f, v) => (f.questions[2].placeholder = `가${v}나`)],
      ['questions[0].options[1].label', (f, v) => (f.questions[0].options[1].label = `가${v}나`)],
    ]
    for (const [path, set] of cases) {
      for (const c of ['\n', '\u001b']) {
        const f = good()
        set(f, c)
        const r = validateForm(f, undefined)
        expect(field(r), `${path} ${JSON.stringify(c)}`).toBe(path)
        expect(r).toContain('제어 문자를 넣지 않습니다(줄바꿈·탭 포함). 한 줄로 그려지는 칸입니다')
      }
    }
  })

  test('여러 줄 칸 다섯은 줄바꿈·탭·CR 을 받고 ESC 는 그 칸 경로로 거절한다', () => {
    const cases: [string, (f: any, v: string) => void][] = [
      ['intro', (f, v) => (f.intro = `가${v}나`)],
      ['questions[0].question', (f, v) => (f.questions[0].question = `가${v}나`)],
      ['questions[0].detail', (f, v) => (f.questions[0].detail = `가${v}나`)],
      ['questions[0].options[0].description', (f, v) => (f.questions[0].options[0].description = `가${v}나`)],
      ['questions[0].options[0].preview', (f, v) => (f.questions[0].options[0].preview = `가${v}나`)],
    ]
    for (const [path, set] of cases) {
      for (const c of ['\n', '\t', '\r']) {
        const f = good()
        set(f, c)
        expect(validateForm(f, undefined), `${path} ${JSON.stringify(c)}`).toBeUndefined()
      }
      const f = good()
      set(f, '\u001b')
      const r = validateForm(f, undefined)
      expect(field(r), path).toBe(path)
      expect(r).toContain('줄바꿈·탭 말고는 제어 문자를 넣지 않습니다')
    }
  })

  test('경계값: 총량 90,000/90,001자', () => {
    // 셋째 질문의 detail 을 채워 모든 문자열의 글자 수 합을 n 으로 맞춘다.
    const fill = (n: number) => {
      const f = good()
      const q: Record<string, unknown> = { ...f.questions[2], detail: '' }
      f.questions[2] = q as (typeof f.questions)[number]
      q.detail = 'x'.repeat(n - countStrings(f))
      return f
    }
    expect(validateForm(fill(90000), undefined)).toBeUndefined()
    expect(field(validateForm(fill(90001), undefined))).toBe('input')
  })
})

function countStrings(v: unknown): number {
  if (typeof v === 'string') return [...v].length
  if (Array.isArray(v)) return v.reduce((n: number, x) => n + countStrings(x), 0)
  if (v && typeof v === 'object') return Object.values(v).reduce((n: number, x) => n + countStrings(x), 0)
  return 0
}
