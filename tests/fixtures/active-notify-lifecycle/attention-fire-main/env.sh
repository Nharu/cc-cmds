# The attention spool root exists for this fixture only, under its own tmpdir,
# so the fires below leave events where test.sh can read them. The hook's
# syntax check reads $SHELL; bash is named so the result does not depend on the
# login shell of the host running the suite.
mkdir -p "$FIXTURE_TMPDIR/attention-root"
export CC_CMDS_ATTENTION_ROOT="$FIXTURE_TMPDIR/attention-root"
export SHELL=/bin/bash
