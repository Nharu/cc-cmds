// 질문지 패널의 그리기. `$` 를 받지 않는다 — 요소 표와 줄 모형, 처리기 함수를 인자로
// 받는 순수 함수다. 처리기 안의 `$` 호출은 index.tsx 가 정의한다.

import { EDITOR_SUBMIT_LABEL, NEXT_LABEL, PREV_LABEL, TO_SUBMIT_LABEL, UNANSWERED } from './spec'
import { CANCEL_KEY, NEXT_KEY, PREV_KEY, SUBMIT_KEY, descriptionIndent } from './layout'
import type { Row } from './layout'
import type { FormEditor } from './transitions'

// $.ui.resolve(e) 가 돌려주는 요소 표 가운데 이 패널이 쓰는 것.
export type FormElements = { Box: any; Text: any; Button: any; Input: any }

export type FormHandlers = {
  choose: (qid: string, label: string) => void
  jump: (qid: string) => void
  openEditor: (qid: string, field: FormEditor['field']) => void
  typeText: (qid: string, field: FormEditor['field'], value: string) => void
  commitText: (qid: string, field: FormEditor['field'], value: string) => void
  next: () => void
  prev: () => void
  submit: () => void
  cancel: () => void
}

// 포커스를 받은 버튼은 엔진이 반전해 그리므로, 버튼에는 고르는 대상(번호·표지·라벨)만
// 담고 설명·추천·답 요약은 버튼 밖에 흐리게 둔다. 강조색은 펼친 질문의 머리말에만 쓴다.

// 접힌 질문 줄과 선택지 줄은 key 로 질문 번호를 되찾는다.
const qidOfKey = (key: string) => Number(/^q(\d+)/.exec(key)?.[1] ?? 0)

export function drawForm(el: FormElements, rows: Row[], ids: string[], on: FormHandlers) {
  const { Box, Text, Button, Input } = el
  const qid = (key: string) => ids[qidOfKey(key) - 1] ?? ''
  const auto = (on: boolean) => (on ? { autoFocus: true as const } : {})
  const drawn = rows.map(row => {
    switch (row.kind) {
      case 'blank':
        return <Text> </Text>
      case 'title':
        return (
          <Text>
            <Text bold>{row.text}</Text>
            <Text dimColor>{`  ${row.counter}`}</Text>
          </Text>
        )
      case 'intro':
      case 'detail':
        return (
          <Box paddingLeft={2}>
            <Text dimColor>{row.text}</Text>
          </Box>
        )
      case 'group':
        return <Text bold>{row.text}</Text>
      case 'folded':
        return (
          <Box paddingLeft={2} flexDirection="row" gap={2}>
            <Button key={row.key} plain onPress={() => on.jump(qid(row.key))}>
              {`${row.n} ${row.header}`}
            </Button>
            {row.answered ? <Text dimColor>{row.summary}</Text> : <Text color="warning">{row.summary}</Text>}
          </Box>
        )
      case 'current':
        return (
          <Text>
            <Text bold color="suggestion">{`▸ ${row.n} ${row.header}`}</Text>
            <Text bold>{`  ${row.question}`}</Text>
          </Text>
        )
      case 'option':
        return (
          <Box paddingLeft={2} flexDirection="column">
            <Box flexDirection="row" gap={2}>
              <Button key={row.key} plain {...(row.hotkey ? { hotkey: row.hotkey } : {})} {...auto(row.autoFocus)} onPress={() => on.choose(qid(row.key), row.label)}>
                {`${row.glyph} ${row.label}`}
              </Button>
              {row.recommended ? <Text dimColor>{`(${row.recommended})`}</Text> : ''}
            </Box>
            {row.description ? (
              <Box paddingLeft={descriptionIndent(row.hotkey)}>
                <Text dimColor>{row.description}</Text>
              </Box>
            ) : (
              ''
            )}
          </Box>
        )
      case 'preview':
        return (
          <Box paddingLeft={4} flexDirection="column">
            {row.text.split('\n').map(line => (
              <Text>
                <Text dimColor>{'│ '}</Text>
                {line}
              </Text>
            ))}
          </Box>
        )
      case 'other':
        return (
          <Box paddingLeft={2} flexDirection="row" gap={2}>
            <Button key={row.key} plain hotkey={row.hotkey} onPress={() => on.openEditor(qid(row.key), 'other')}>
              {`${row.glyph} ${row.text}`}
            </Button>
            {row.description ? <Text dimColor>{row.description}</Text> : ''}
          </Box>
        )
      case 'answer':
        return (
          <Box paddingLeft={2}>
            <Button key={row.key} plain {...auto(row.autoFocus)} onPress={() => on.openEditor(qid(row.key), 'other')}>
              {row.text === UNANSWERED ? <Text dimColor>{row.text}</Text> : row.text}
            </Button>
          </Box>
        )
      case 'editor':
        return (
          <Box paddingLeft={4}>
            <Input
              key={row.key}
              {...auto(row.autoFocus)}
              label={row.label}
              placeholder={row.placeholder}
              value={row.value}
              submitLabel={EDITOR_SUBMIT_LABEL}
              onInput={(v: string) => on.typeText(row.qid, row.field, v)}
              onSubmit={(v: string) => on.commitText(row.qid, row.field, v)}
            />
          </Box>
        )
      case 'note':
        return (
          <Box paddingLeft={2}>
            <Button key={row.key} plain hotkey={row.hotkey} dimColor onPress={() => on.openEditor(qid(row.key), 'note')}>
              {row.text}
            </Button>
          </Box>
        )
      case 'nav':
        return (
          <Box paddingLeft={2} flexDirection="row" gap={2}>
            {row.prev ? <Button key={PREV_KEY} plain hotkey="p" dimColor label={PREV_LABEL} onPress={() => on.prev()} /> : ''}
            {row.next !== 'none' ? (
              <Button key={NEXT_KEY} plain hotkey="n" dimColor label={row.next === 'submit' ? TO_SUBMIT_LABEL : NEXT_LABEL} onPress={() => on.next()} />
            ) : (
              ''
            )}
          </Box>
        )
      case 'actions':
        return (
          <Box flexDirection="row" gap={1}>
            <Button key={SUBMIT_KEY} variant="primary" label={row.submit} onPress={() => on.submit()} />
            <Button key={CANCEL_KEY} label={row.cancel} onPress={() => on.cancel()} />
          </Box>
        )
      case 'help':
        return <Text dimColor>{row.text}</Text>
    }
  })
  return <Box flexDirection="column">{drawn}</Box>
}
