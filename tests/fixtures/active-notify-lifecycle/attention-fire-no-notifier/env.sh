# No terminal-notifier anywhere: PATH is a directory holding only a link to jq
# (the hook and the attention tap need it) plus /usr/bin:/bin. The spool root
# exists for this fixture only, and the hook's syntax check reads bash.
jq_bin=$(command -v jq 2>/dev/null || true)
mkdir -p "$FIXTURE_TMPDIR/jq-only"
if [[ -n "$jq_bin" ]]; then
  ln -sf "$jq_bin" "$FIXTURE_TMPDIR/jq-only/jq"
fi
export PATH="$FIXTURE_TMPDIR/jq-only:/usr/bin:/bin"
mkdir -p "$FIXTURE_TMPDIR/attention-root"
export CC_CMDS_ATTENTION_ROOT="$FIXTURE_TMPDIR/attention-root"
export SHELL=/bin/bash
