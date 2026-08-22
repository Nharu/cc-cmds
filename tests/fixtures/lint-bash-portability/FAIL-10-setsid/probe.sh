#!/usr/bin/env bash
# Fixture: `setsid` is a Linux-only binary. darwin has the syscall but not the
# executable, so a detach path built on it never runs on the target platform.
set -euo pipefail

setsid ./driver.sh &
