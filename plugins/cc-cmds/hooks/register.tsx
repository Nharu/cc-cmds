// 플러그인의 진입 모듈. 서브 mod 의 register 를 부르기만 하고 훅은 갖지 않는다.
// 두 서브 mod 가 같은 이벤트를 매처 없이 필요로 할 때만 그 훅을 여기로 올린다.
// 런 상태 패널(autopilot-status.tsx)은 지금 싣지 않으므로 부르지 않는다.
import type { Register } from 'claude-code'

import { register as registerQuestionForm } from './question-form/index'

export const register: Register = (on, options) => {
  registerQuestionForm(on, options)
}
