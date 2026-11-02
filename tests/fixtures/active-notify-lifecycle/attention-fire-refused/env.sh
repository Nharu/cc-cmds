# The attention spool root exists for this fixture only, under its own tmpdir,
# so a refused ticket can be told from a missing spool. The hook's syntax check
# reads bash.
mkdir -p "$FIXTURE_TMPDIR/attention-root"
export CC_CMDS_ATTENTION_ROOT="$FIXTURE_TMPDIR/attention-root"
export SHELL=/bin/bash
