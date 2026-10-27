#!/usr/bin/env bash
# A third suite that needs wrapper values and gets them by SOURCING the shared
# grammar, which is what the file-set rule asks of every file but two.
. "$root/plugins/cc-cmds/orchestrator/statusline-command.sh"
value=$(sl_desired_command "")
