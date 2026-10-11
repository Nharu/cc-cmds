import { describe, expect, test } from 'claude-code/testing'

import { HEADER_RE, answerBody, bundleJson, bundleText, headerLine, inputValue, isAnswered, mintFormId, parseHeader } from './bundle'
import type { Draft } from './bundle'
import type { FormInput, FormQuestion } from './spec'

const opt = (label: string, recommended?: '추천' | '에이전트 추천') => ({ label, description: '', ...(recommended ? { recommended } : {}) })

const single: FormQuestion = { id: 's', header: '하나', question: '고르기', kind: 'single', options: [opt('가', '추천'), opt('나')] }
const multi: FormQuestion = { id: 'm', header: '여럿', question: '고르기', kind: 'multi', options: [opt('가'), opt('나', '에이전트 추천'), opt('다')] }
const text: FormQuestion = { id: 't', header: '글', question: '쓰기', kind: 'text' }
const follow: FormQuestion = { id: 'f', header: '꼬리', question: '왜 나?', kind: 'text', when: { id: 's', selected: ['나'] } }

const form: FormInput = { title: '시험', questions: [single, multi, text, follow] }
const d = (selected: string[] = [], other = '', note = ''): Draft => ({ selected, other, note })

describe('묶음', () => {
  test('id 모양은 f-<8hex>', () => {
    expect(mintFormId()).toMatch(/^f-[0-9a-f]{8}$/)
    expect(mintFormId(() => 0.999)).toBe('f-ffffffff')
  })

  test('머리줄 모양과 정규식의 왕복', () => {
    const line = headerLine('f-0a1b2c3d', '제출', 2, 3)
    expect(line).toBe('[cc-cmds 질문지 답] form=f-0a1b2c3d status=제출 답=2/3')
    expect(HEADER_RE.test(line)).toBe(true)
    expect(parseHeader(line)).toEqual({ form: 'f-0a1b2c3d', status: '제출' })
    expect(parseHeader(headerLine('f-0a1b2c3d', '취소', 0, 1))).toEqual({ form: 'f-0a1b2c3d', status: '취소' })
    expect(parseHeader('[cc-cmds 질문지 답] form=f-XYZ status=제출 답=1/1')).toBeUndefined()
  })

  test('답=<a>/<m> 은 보이는 질문만 센다', () => {
    const drafts = { s: d(['가']), m: d(['다']) }
    expect(bundleText('f-00000000', '제출', form, drafts).split('\n')[0]).toBe('[cc-cmds 질문지 답] form=f-00000000 status=제출 답=2/3')
    const shown = { s: d(['나']), f: d([], '이유') }
    expect(bundleText('f-00000000', '제출', form, shown).split('\n')[0]).toEndWith('답=2/4')
  })

  test('answer 본문: single 은 추천 접미 없는 라벨, 선택지 대신 쓴 자유 입력은 축자', () => {
    expect(answerBody(single, d(['가']))).toBe('가')
    expect(answerBody(single, d([], '셋째 길'))).toBe('셋째 길')
  })

  test('answer 본문: multi 는 한 줄에 하나, 라벨 옆 자유 입력은 「자유 입력:」 줄', () => {
    expect(answerBody(multi, d(['가', '나']))).toBe('가\n나')
    expect(answerBody(multi, d(['가'], '라'))).toBe('가\n자유 입력: 라')
    expect(answerBody(multi, d([], '라'))).toBe('라')
  })

  test('answer 본문: 메모는 마지막 「메모:」 줄, 답이 없으면 미답', () => {
    expect(answerBody(text, d([], '자유 글', '참고'))).toBe('자유 글\n메모: 참고')
    expect(answerBody(single, d())).toBe('미답')
    expect(answerBody(single, d([], '', '메모만'))).toBe('미답\n메모: 메모만')
  })

  test('JSON: 스키마·상태·받은 라벨 그대로·추천은 recommended, when 거짓은 해당 없음', () => {
    const j = bundleJson('f-00000000', '취소', form, { s: d(['가']), m: d([], '', '생각 중') })
    expect(j.schema).toBe('cc-form-answers/1')
    expect(j.status).toBe('취소')
    expect(j.answers.map(a => a.state)).toEqual(['답', '미답', '미답', '해당 없음'])
    expect(j.answers[0].options).toEqual(['가', '나'])
    expect(j.answers[0].selected).toEqual(['가'])
    expect(j.answers[0].recommended).toEqual([{ label: '가', by: '추천' }])
    expect(j.answers[1].recommended).toEqual([{ label: '나', by: '에이전트 추천' }])
    expect(j.answers[2].recommended).toBeUndefined()
    expect(j.answers[1].answer).toBe('미답\n메모: 생각 중')
    expect(j.answers[3].answer).toBe('')
  })

  test('제어 문자 든 초안: answer·other·note 를 거른 글로 싣는다', () => {
    const j = bundleJson('f-00000000', '제출', form, { s: d([], '셋\u001b째\n길'), t: d([], '자유\u0000 글', '참\t고\u009b') })
    expect(j.answers[0].other).toBe('셋째 길')
    expect(j.answers[0].answer).toBe('셋째 길')
    expect(j.answers[2].other).toBe('자유 글')
    expect(j.answers[2].note).toBe('참 고')
    expect(j.answers[2].answer).toBe('자유 글\n메모: 참 고')
    expect(JSON.stringify(j)).not.toMatch(/\\u00[01][0-9a-f]|[\u007f-\u009f]/)
  })

  test('기타가 제어 문자뿐이면 미답으로 세고 state 도 미답', () => {
    const drafts = { t: d([], '\u001b\u0000') }
    expect(isAnswered(text, drafts.t)).toBe(false)
    expect(bundleJson('f-00000000', '제출', form, drafts).answers[2].state).toBe('미답')
    expect(bundleText('f-00000000', '제출', form, drafts).split('\n')[0]).toEndWith('답=0/3')
  })

  test('묶음 본문은 머리줄 다음에 json 펜스', () => {
    const t = bundleText('f-00000000', '제출', form, {})
    const lines = t.split('\n')
    expect(lines[1]).toBe('```json')
    expect(lines[lines.length - 1]).toBe('```')
    expect(JSON.parse(lines.slice(2, -1).join('\n')).form).toBe('f-00000000')
  })
})

describe('inputValue', () => {
  test('CRLF·CR·LF·탭은 공백 하나로 바꾼다', () => {
    expect(inputValue('가\r\n나')).toBe('가 나')
    expect(inputValue('가\r나')).toBe('가 나')
    expect(inputValue('가\n나')).toBe('가 나')
    expect(inputValue('가\t나')).toBe('가 나')
  })

  test('NUL·ESC·DEL·NEL 은 뺀다', () => {
    expect(inputValue('가\u0000나')).toBe('가나')
    expect(inputValue('가\u001b[31m나')).toBe('가[31m나')
    expect(inputValue('가\u007f나')).toBe('가나')
    expect(inputValue('가\u0085나')).toBe('가나')
    expect(inputValue('보통 글')).toBe('보통 글')
  })
})
