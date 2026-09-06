#!/usr/bin/env bash
# The other half of the asymmetry. `-` is swallowed because the word looks like
# an option; a space in front stops it being a word at all, and the real binary
# renders this. Flagging it would be a false positive, so the rule checks `-` at
# position zero only.
terminal-notifier -title "cc-cmds 자율 런" -message " -p 를 빠뜨렸습니다" -execute ':'
