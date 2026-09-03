#!/usr/bin/env bash
# Fixture: the self-skip sentinel is the FINAL line of a file that ends without
# a terminating newline. It still has to suppress the idiom on the line above —
tac /etc/hostname >/dev/null 2>&1 || true
# lint-bash-portability: self-skip