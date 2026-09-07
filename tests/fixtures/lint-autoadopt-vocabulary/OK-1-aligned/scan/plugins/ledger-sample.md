# Fixture ledger rows

Every shape the scan is expected to walk past, plus one real value claim.

- `자동 채택` | 판단 부류=문서-신선도 | 상한=없음 | 심각도 상한=minor | 사유=x
- `자율 승인` | 판단 부류=- | 등급=- | 사유=값이 도착하지 않은 행
- schema placeholder: 판단 부류=<여덟 값 중 하나> | 상한=없음
- shell expansion: "판단 부류=$cls"
- parser pattern: `s/^ *판단 부류=//p`
