---
name: active-notify
description: fixture
---

# active-notify

The model directly invokes four subcommands of this skill's dispatcher.

```bash
bash active-notify/scripts/notify.sh arm "<request_text>" "<context_hint>"
bash active-notify/scripts/notify.sh fire-now <workflow> <summary>
bash active-notify/scripts/notify.sh cancel
```
