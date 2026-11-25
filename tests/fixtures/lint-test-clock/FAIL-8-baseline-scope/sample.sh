#!/usr/bin/env bash
# Fixture: a baseline entry under scripts/ is refused on its own and answers
# nothing; the line it names is fixed.
. "$repo_root/scripts/wait-fixture.sh"
wait_until test -f "$WORK/ready"
