#!/usr/bin/env bash
# The emitter's title table never passes its strings through a `-title` argument
# in this file — the fire path hands them over in a variable — so they are read
# at their source instead. One arm here is swallowed.
cc_notify_title() {
  case "$1" in
    answer)       printf '[cc-cmds] 답 필요' ;;
    hands)        printf '손 필요' ;;
    status)       printf '자율 런' ;;
  esac
}
