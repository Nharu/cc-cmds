# implement-unattended
`AskUserQuestion` and `EnterPlanMode` are deliberately NOT loaded — they are
absent from every headless process anyway. Never reach a notification surface:
no `PushNotification`, no `notify.sh`, no `terminal-notifier`.
The base skill calls ExitPlanMode after approval; this arm has no such step.
