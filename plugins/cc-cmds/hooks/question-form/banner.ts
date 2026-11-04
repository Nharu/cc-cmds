// 새로 연 질문지의 배너: 셸 훅 session-ask-notify.sh 를 AskUserQuestion 과
// 같은 PreToolUse stdin 모양으로 부르기 위한 인자를 만든다. `$` 를 쓰지 않으며
// 실제 실행은 index.tsx 가 한다. agent_id 는 넣지 않는다(주 세션의 질문지다).
//
// stdin 은 로컬 배너의 입력이라 질문 머리말과 질문만 싣는다. 원격 사건에만 쓰이는
// 질문지 id·질문 id·종류·조건 여부·선택지 라벨은 argv 셋째 원소의 JSON 하나로 넘기고,
// 훅이 그것으로 깔때기 첨부를 만든다.

import { TOOL_FULL_NAME } from './spec'
import type { FormInput } from './spec'

export const BANNER_TIMEOUT_MS = 5000

export function bannerCall(root: string, sessionId: string, form: FormInput, formId: string) {
  const stdin = JSON.stringify({
    hook_event_name: 'PreToolUse',
    session_id: sessionId,
    tool_name: TOOL_FULL_NAME,
    tool_input: { questions: form.questions.map(q => ({ header: q.header, question: q.question })) },
  })
  const detail = JSON.stringify({
    form_id: formId,
    questions: form.questions.map(q => ({
      id: q.id,
      header: q.header,
      question: q.question,
      kind: q.kind,
      conditional: q.when !== undefined,
      options: (q.options ?? []).map(o => ({ label: o.label })),
    })),
  })
  return {
    argv: ['/bin/bash', `${root}/hooks/session-ask-notify.sh`, detail],
    stdin,
    env: { CLAUDE_PLUGIN_ROOT: root },
    timeoutMs: BANNER_TIMEOUT_MS,
  }
}
