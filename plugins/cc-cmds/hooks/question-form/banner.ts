// 새로 연 질문지의 배너: 셸 훅 session-ask-notify.sh 를 AskUserQuestion 과
// 같은 PreToolUse stdin 모양으로 부르기 위한 인자를 만든다. `$` 를 쓰지 않으며
// 실제 실행은 index.tsx 가 한다. agent_id 는 넣지 않는다(주 세션의 질문지다).

import { TOOL_FULL_NAME } from './spec'
import type { FormInput } from './spec'

export const BANNER_TIMEOUT_MS = 5000

export function bannerCall(root: string, sessionId: string, form: FormInput) {
  const stdin = JSON.stringify({
    hook_event_name: 'PreToolUse',
    session_id: sessionId,
    tool_name: TOOL_FULL_NAME,
    tool_input: { questions: form.questions.map(q => ({ header: q.header, question: q.question })) },
  })
  return {
    argv: ['/bin/bash', `${root}/hooks/session-ask-notify.sh`],
    stdin,
    env: { CLAUDE_PLUGIN_ROOT: root },
    timeoutMs: BANNER_TIMEOUT_MS,
  }
}
