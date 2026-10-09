// 질문지 패널과 영수증 패널의 그리기. `$` 를 받지 않는다 — 요소 표와 그릴 값,
// 처리기 함수를 인자로 받는 순수 함수다. 처리기 안의 `$` 호출은 index.tsx 가 정의한다.

import { answerBody, counts, draftOf, isAnswered, isVisible } from './bundle'
import {
  CANCEL_LABEL,
  HELP_LINE,
  NOTE_PLACEHOLDER,
  OTHER_LABEL,
  OTHER_PLACEHOLDER,
  RECEIPT_NOTE,
  SUBMIT_LABEL,
  TEXT_PLACEHOLDER,
  UNANSWERED,
  footerLine,
  presentedLabel,
} from './spec'
import type { FormOption, FormQuestion } from './spec'
import type { FormRecord } from './transitions'

// $.ui.resolve(e) 가 돌려주는 요소 표 가운데 이 패널이 쓰는 것.
export type FormElements = { Box: any; Text: any; Button: any; Input: any }

export type FormHandlers = {
  toggle: (qid: string, label: string) => void
  openOther: (qid: string) => void
  setOther: (qid: string, value: string) => void
  setNote: (qid: string, value: string) => void
  submit: () => void
  cancel: () => void
}

// 선택지·입력칸의 key. 미리보기는 포커스 값의 q<i>-o<j> 꼴에서 선택지를 찾는다.
export const optionKey = (qi: number, oi: number) => `q${qi}-o${oi}`
export const otherKey = (qi: number) => `q${qi}-other`
export const otherInputKey = (qi: number) => `q${qi}-other-input`
export const noteKey = (qi: number) => `q${qi}-note`
export const textKey = (qi: number) => `q${qi}-text`
export const SUBMIT_KEY = 'submit'
export const CANCEL_KEY = 'cancel'

export const questionLine = (n: number, q: FormQuestion, answered: boolean) =>
  `${n}. [${q.header}] ${q.question}${answered ? '' : ` · ${UNANSWERED}`}`

export function optionText(q: FormQuestion, o: FormOption, isOn: boolean): string {
  const glyph = q.kind === 'multi' ? (isOn ? '■' : '□') : isOn ? '●' : '○'
  return `${glyph} ${presentedLabel(o)}`
}

// 포커스가 이 질문의 선택지 버튼에 있으면 그 선택지의 미리보기, 아니면 undefined.
export function previewFor(qi: number, q: FormQuestion, focused: string | null): string | undefined {
  const m = focused === null ? null : /^q(\d+)-o(\d+)$/.exec(focused)
  if (!m || Number(m[1]) !== qi) return undefined
  return (q.options ?? [])[Number(m[2]) - 1]?.preview
}

// 영수증 한 줄의 답 요약: 메모 줄을 뺀 답 본문을 한 줄로.
export function receiptSummary(q: FormQuestion, rec: FormRecord): string {
  const d = draftOf(rec.drafts, q.id)
  if (!isAnswered(q, d)) return UNANSWERED
  return answerBody(q, d)
    .split('\n')
    .filter(line => !line.startsWith('메모: '))
    .join(' · ')
}

export function receiptLines(rec: FormRecord): string[] {
  return rec.form.questions
    .map((q, i) => ({ q, n: i + 1 }))
    .filter(({ q }) => isVisible(rec.form, rec.drafts, q))
    .map(({ q, n }) => `${n}. ${q.header}: ${receiptSummary(q, rec)}`)
}

export function drawForm(el: FormElements, rec: FormRecord, focused: string | null, on: FormHandlers) {
  const { Box, Text, Button, Input } = el
  const { form, drafts } = rec
  const { answered, total } = counts(form, drafts)
  // 포커스는 1번 질문의 첫 조작부에서 시작한다.
  let isFirst = true
  const auto = () => {
    if (!isFirst) return {}
    isFirst = false
    return { autoFocus: true as const }
  }
  const rows: unknown[] = []
  if (form.intro) rows.push(<Text>{form.intro}</Text>)
  let group: string | undefined
  form.questions.forEach((q, index) => {
    if (!isVisible(form, drafts, q)) return
    const qi = index + 1
    const d = draftOf(drafts, q.id)
    if (q.group && q.group !== group) rows.push(<Text bold>{q.group}</Text>)
    group = q.group
    rows.push(<Text bold>{questionLine(qi, q, isAnswered(q, d))}</Text>)
    if (q.detail) rows.push(<Text dimColor>{q.detail}</Text>)
    if (q.kind === 'text') {
      rows.push(
        <Input
          key={textKey(qi)}
          {...auto()}
          placeholder={q.placeholder ?? TEXT_PLACEHOLDER}
          value={d.other}
          onInput={(v: string) => on.setOther(q.id, v)}
          onSubmit={(v: string) => on.setOther(q.id, v)}
        />,
      )
    } else {
      ;(q.options ?? []).forEach((o, oindex) => {
        rows.push(
          <Button
            key={optionKey(qi, oindex + 1)}
            {...auto()}
            label={optionText(q, o, d.selected.includes(o.label))}
            onPress={() => on.toggle(q.id, o.label)}
          />,
        )
      })
      const preview = previewFor(qi, q, focused)
      if (preview !== undefined) {
        rows.push(
          <Box flexDirection="column">
            <Text color="suggestion">{preview}</Text>
          </Box>,
        )
      }
      if (q.allowOther !== false) {
        const hasOther = d.other.trim() !== ''
        rows.push(
          <Button
            key={otherKey(qi)}
            label={`${q.kind === 'multi' ? (hasOther ? '■' : '□') : hasOther ? '●' : '○'} ${OTHER_LABEL}`}
            onPress={() => on.openOther(q.id)}
          />,
        )
        if (hasOther || rec.otherOpen.includes(q.id)) {
          rows.push(
            <Input
              key={otherInputKey(qi)}
              placeholder={OTHER_PLACEHOLDER}
              value={d.other}
              onInput={(v: string) => on.setOther(q.id, v)}
              onSubmit={(v: string) => on.setOther(q.id, v)}
            />,
          )
        }
      }
    }
    if (q.allowNote !== false) {
      rows.push(
        <Input
          key={noteKey(qi)}
          placeholder={NOTE_PLACEHOLDER}
          value={d.note}
          onInput={(v: string) => on.setNote(q.id, v)}
          onSubmit={(v: string) => on.setNote(q.id, v)}
        />,
      )
    }
  })
  rows.push(<Text>{footerLine(answered, total)}</Text>)
  rows.push(<Button key={SUBMIT_KEY} label={SUBMIT_LABEL} onPress={() => on.submit()} />)
  rows.push(<Button key={CANCEL_KEY} label={CANCEL_LABEL} onPress={() => on.cancel()} />)
  rows.push(<Text dimColor>{HELP_LINE}</Text>)
  return <Box flexDirection="column">{rows}</Box>
}

export function drawReceipt(el: FormElements, rec: FormRecord) {
  const { Box, Text } = el
  return (
    <Box flexDirection="column">
      {receiptLines(rec).map(line => (
        <Text>{line}</Text>
      ))}
      <Text dimColor>{RECEIPT_NOTE}</Text>
    </Box>
  )
}
