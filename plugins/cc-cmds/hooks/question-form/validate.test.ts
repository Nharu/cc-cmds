import { describe, expect, test } from 'claude-code/testing'

import { repairForm, validateForm } from './validate'

const opt = (label: string, extra: Record<string, unknown> = {}) => ({ label, description: `${label} 설명`, ...extra })

// 도구 호출과 같은 순서: 보정 뒤 검증.
const check = (input: unknown, openId?: string) => {
  const { input: fixed, fixes } = repairForm(input)
  return { fixed: fixed as any, fixes, invalid: validateForm(fixed, openId) }
}

const good = () => ({
  title: '경계 질문',
  questions: [
    { id: 'scope', header: '범위', question: '어디까지?', kind: 'single', options: [opt('좁게', { recommended: '추천' }), opt('넓게')] },
    { id: 'parts', header: '부분', question: '무엇을?', kind: 'multi', options: [opt('가'), opt('나'), opt('다')] },
    { id: 'why', header: '이유', question: '왜?', kind: 'text', when: { id: 'scope', selected: ['넓게'] } },
  ],
})

// 거절 결과 첫 줄의 칸.
const field = (r: string | undefined) => r?.split('\n')[0]?.replace(/^QUESTION_FORM_INVALID ([^:]+):.*$/, '$1')
// 거절 결과의 위반 줄들의 칸.
const fields = (r: string | undefined) =>
  (r ?? '')
    .split('\n')
    .filter(l => l.startsWith('QUESTION_FORM_INVALID '))
    .map(l => l.replace(/^QUESTION_FORM_INVALID ([^:]+):.*$/, '$1'))

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

  test('선택지 1개 single 은 위반이 없고, allowOther: false 를 두면 거절', () => {
    const a = good()
    a.questions[0].options = [opt('하나')]
    a.questions[2].when = { id: 'scope', selected: ['하나'] }
    expect(validateForm(a, undefined)).toBeUndefined()
    const b = good()
    b.questions[0].options = [opt('하나')]
    b.questions[2].when = { id: 'scope', selected: ['하나'] }
    ;(b.questions[0] as Record<string, unknown>).allowOther = false
    expect(field(validateForm(b, undefined))).toBe('questions[0].options')
    const c = good()
    c.questions[0].options = []
    delete (c.questions[2] as Record<string, unknown>).when
    expect(field(validateForm(c, undefined))).toBe('questions[0].options')
  })

  test('선택지 수: multi 1개 거절, text 에 선택지 거절', () => {
    const a = good()
    a.questions[1].options = [opt('하나')]
    expect(field(validateForm(a, undefined))).toBe('questions[1].options')
    const b = good()
    ;(b.questions[2] as Record<string, unknown>).options = [opt('가'), opt('나')]
    expect(field(validateForm(b, undefined))).toBe('questions[2].options')
  })

  test('라벨 끝 추천 화살표 세 꼬리는 라벨과 recommended 로 고쳐지고, 그 라벨을 가리키던 when 도 바뀐다', () => {
    for (const [label, rec] of [
      ['넓게 ← 추천', '추천'],
      ['넓게 ← 에이전트 추천', '에이전트 추천'],
      ['넓게 ← 에이전트추천', '에이전트 추천'],
      ['넓게 ← 기본값', '기본값'],
    ]) {
      const f = good()
      f.questions[0].options = [opt('좁게'), opt(label!)]
      f.questions[2].when = { id: 'scope', selected: [label!] }
      const r = check(f)
      expect(r.invalid, label).toBeUndefined()
      expect(r.fixed.questions[0].options[1], label).toMatchObject({ label: '넓게', recommended: rec })
      expect(r.fixed.questions[2].when.selected, label).toEqual(['넓게'])
      expect(r.fixes, label).toHaveLength(1)
      expect(r.fixes[0]).toStartWith('questions[0].options[1].label: ')
    }
    // 이미 recommended 가 있으면 그 값을 둔다.
    const g = good()
    g.questions[1].options![0] = opt('가 ← 추천', { recommended: '기본값' })
    expect(check(g).fixed.questions[1].options[0]).toMatchObject({ label: '가', recommended: '기본값' })
    // 입력은 제자리에서 바뀌지 않는다.
    expect(g.questions[1].options![0]!.label).toBe('가 ← 추천')
  })

  test('라벨 안의 ← 꼬리가 셋 밖이면 지금 사유로 거절', () => {
    const f = good()
    f.questions[1].options![0] = opt('가 ← 이유')
    const r = check(f)
    expect(r.fixes).toEqual([])
    expect(field(r.invalid)).toBe('questions[1].options[0].label')
    expect(r.invalid).toContain('라벨에 「←」를 넣지 않습니다')
  })

  test('손으로 만든 기타 계열 라벨 넷은 지워지고, allowOther: false 는 true 가 된다', () => {
    for (const label of ['기타', '직접 입력', '직접 지정', 'Other']) {
      const f = good()
      f.questions[1].options!.push(opt(label))
      ;(f.questions[1] as Record<string, unknown>).allowOther = false
      const r = check(f)
      expect(r.invalid, label).toBeUndefined()
      expect(r.fixed.questions[1].options.map((o: any) => o.label), label).toEqual(['가', '나', '다'])
      expect(r.fixed.questions[1].allowOther, label).toBe(true)
      expect(r.fixes, label).toEqual([
        `questions[1].options[3].label: 손으로 만든 「${label}」 선택지를 지웠습니다. 기타 입력은 allowOther 가 그립니다`,
        'questions[1].allowOther: false 를 true 로 바꿔 기타 입력을 켰습니다',
      ])
    }
  })

  test('기타 계열 선택지에 recommended 가 있거나, when 이 가리키거나, 지우면 하한 아래면 거절', () => {
    const a = good()
    a.questions[1].options![2] = opt('기타', { recommended: '추천' })
    expect(field(check(a).invalid)).toBe('questions[1].options[2].label')
    const b = good()
    b.questions[0].options = [opt('좁게'), opt('기타')]
    b.questions[2].when = { id: 'scope', selected: ['기타'] }
    expect(field(check(b).invalid)).toBe('questions[0].options[1].label')
    const c = good()
    c.questions[1].options = [opt('가'), opt('기타')]
    expect(field(check(c).invalid)).toBe('questions[1].options[1].label')
    // single 은 1개가 남으면 고친다.
    const d = good()
    d.questions[0].options = [opt('좁게'), opt('직접 입력')]
    d.questions[2].when = { id: 'scope', selected: ['좁게'] }
    const r = check(d)
    expect(r.invalid).toBeUndefined()
    expect(r.fixed.questions[0].options).toHaveLength(1)
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

  test('기본값 표시는 통과하고, single 에서 추천과 함께 달면 거절', () => {
    const a = good()
    a.questions[0].options = [opt('좁게', { recommended: '기본값' }), opt('넓게')]
    expect(validateForm(a, undefined)).toBeUndefined()
    const b = good()
    b.questions[0].options = [opt('좁게', { recommended: '추천' }), opt('넓게', { recommended: '기본값' })]
    expect(field(validateForm(b, undefined))).toBe('questions[0].options')
  })

  test('열거 밖의 recommended 는 허용 값으로 고쳐지고, 숫자는 거절', () => {
    const cases: [unknown, string | undefined][] = [
      ['권장', '추천'],
      [true, '추천'],
      ['에이전트 권장', '에이전트 추천'],
      [' ← 기본 ', '기본값'],
      [false, undefined],
      [null, undefined],
      ['', undefined],
    ]
    for (const [value, expected] of cases) {
      const a = good()
      a.questions[0].options![0] = opt('좁게', { recommended: value })
      const r = check(a)
      expect(r.invalid, String(value)).toBeUndefined()
      expect(r.fixed.questions[0].options[0].recommended, String(value)).toBe(expected)
      if (expected === undefined) expect('recommended' in r.fixed.questions[0].options[0], String(value)).toBe(false)
      expect(r.fixes, String(value)).toHaveLength(1)
      expect(r.fixes[0]).toStartWith('questions[0].options[0].recommended: ')
    }
    const n = good()
    n.questions[0].options![0] = opt('좁게', { recommended: 1 })
    const r = check(n)
    expect(r.fixes).toEqual([])
    expect(field(r.invalid)).toBe('questions[0].options[0].recommended')
  })

  test('when 이 있는 라벨과 없는 라벨을 함께 가리키면 없는 라벨이 빠지고, 없는 라벨만이면 거절', () => {
    const a = good()
    a.questions[2].when = { id: 'scope', selected: ['넓게', '없는 라벨'] }
    const r = check(a)
    expect(r.invalid).toBeUndefined()
    expect(r.fixed.questions[2].when.selected).toEqual(['넓게'])
    expect(r.fixes).toEqual(['questions[2].when.selected: 「scope」에 없는 라벨(「없는 라벨」)을 뺐습니다'])
    const b = good()
    b.questions[2].when = { id: 'scope', selected: ['없는 라벨'] }
    const s = check(b)
    expect(s.fixes).toEqual([])
    expect(field(s.invalid)).toBe('questions[2].when')
  })

  test('when 이 뒤쪽 질문을 가리키면 거절', () => {
    const a = good()
    ;(a.questions[0] as Record<string, unknown>).when = { id: 'parts', selected: ['가'] }
    const r = check(a)
    expect(r.fixes).toEqual([])
    expect(field(r.invalid)).toBe('questions[0].when')
  })

  test('replaces 가 열린 id 와 다르면 거절, 같으면 통과', () => {
    expect(field(validateForm({ ...good(), replaces: 'f-00000000' }, 'f-11111111'))).toBe('replaces')
    expect(field(validateForm({ ...good(), replaces: 'f-00000000' }, undefined))).toBe('replaces')
    expect(validateForm({ ...good(), replaces: 'f-11111111' }, 'f-11111111')).toBeUndefined()
  })

  test('경계값: header 12/13 코드포인트(NFC)', () => {
    const a = good()
    a.questions[0].header = '가'.repeat(12)
    expect(check(a)).toMatchObject({ invalid: undefined, fixes: [] })
    // 분해형 한글 12자는 NFC 로 12 코드포인트다.
    const b = good()
    b.questions[0].header = '가'.repeat(12).normalize('NFD')
    expect(check(b)).toMatchObject({ invalid: undefined, fixes: [] })
    const c = good()
    c.questions[0].header = '가'.repeat(13)
    const r = check(c)
    expect(r.invalid).toBeUndefined()
    expect(r.fixed.questions[0].header).toBe(`${'가'.repeat(11)}…`)
    expect(r.fixes).toHaveLength(1)
    expect(r.fixes[0]).toStartWith('questions[0].header: ')
  })

  test('경계값: title 40/41자', () => {
    const a = { ...good(), title: '가'.repeat(40) }
    expect(check(a)).toMatchObject({ invalid: undefined, fixes: [] })
    const r = check({ ...good(), title: '가'.repeat(41) })
    expect(r.invalid).toBeUndefined()
    expect(r.fixed.title).toBe(`${'가'.repeat(39)}…`)
    expect(r.fixes).toHaveLength(1)
    expect(r.fixes[0]).toStartWith('title: ')
  })

  test('일괄 보고: 흩어진 고칠 수 없는 위반 셋을 한 결과에 세 줄로', () => {
    const f = good()
    f.questions[1].id = 'scope'
    f.questions[1].options = [opt('하나')]
    ;(f.questions as any[]).push({ id: 'more', header: '더', question: '더?', kind: 'single', options: [opt('미답'), opt('나')] })
    const r = check(f).invalid
    expect(r).toMatch(/^QUESTION_FORM_INVALID /)
    expect(fields(r)).toEqual(['questions[1].id', 'questions[1].options', 'questions[3].options[0].label'])
    expect(r!.split('\n').at(-1)).toBe('위반 3건을 모두 적었습니다. 모두 고쳐 한 번만 다시 부르세요.')
  })

  test('일괄 보고: 고칠 수 있는 위반과 섞이면 고칠 수 없는 것만 나온다', () => {
    const f = good()
    f.questions[0].header = '가'.repeat(13)
    f.questions[1].options![0] = opt('가 ← 추천')
    f.questions[1].options![1] = opt('미답')
    const r = check(f)
    expect(r.fixes).toHaveLength(2)
    expect(fields(r.invalid)).toEqual(['questions[1].options[1].label'])
    expect(r.invalid!.split('\n').at(-1)).toContain('위반 1건')
  })

  test('일괄 보고: 위반 31개는 30줄과 남은 수 1', () => {
    const questions = Array.from({ length: 31 }, (_, i) => ({ id: `q${i}`, header: '', question: '?', kind: 'text' }))
    const r = check({ title: '많음', questions }).invalid!
    const lines = r.split('\n')
    expect(fields(r)).toHaveLength(30)
    expect(lines.at(-2)).toBe('… 외 1건')
    expect(lines.at(-1)).toBe('위반 31건을 모두 적었습니다. 모두 고쳐 한 번만 다시 부르세요.')
  })

  test('일괄 보고: 객체가 아닌 질문은 그 질문의 칸 위반을 따로 내지 않는다', () => {
    const f = good() as any
    f.questions[1] = 'parts'
    expect(fields(check(f).invalid)).toEqual(['questions[1]'])
  })

  test('일괄 보고: kind 가 틀린 질문을 가리키는 when 은 라벨 검사를 하지 않는다', () => {
    const f = good() as any
    f.questions[0].kind = 'choice'
    expect(fields(check(f).invalid)).toEqual(['questions[0].kind'])
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
