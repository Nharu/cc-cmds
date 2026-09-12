#!/usr/bin/env bash
# fixture — approval-row literals inside the vocabulary
printf -- '- `승인` | 승인 id=A1 | 상태=대기 | 절단점=배포 | prev=x\n'
printf -- '- `승인` | 승인 id=A1 | 상태=승인 | 해소 시각=x | prev=y\n'
printf -- '- `승인` | 승인 id=B1-0000 | 상태=철회 | 사유=조건 소멸 | prev=z\n'
# a segment row shares the key and is not an approval-row context
printf -- '- `segment` | id=S1 | 상태=실행중 | 워크트리=/x\n'
