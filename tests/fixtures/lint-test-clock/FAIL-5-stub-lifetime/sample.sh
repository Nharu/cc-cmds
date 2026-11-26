#!/usr/bin/env bash
# Fixture: background stubs whose lifetime is a number of seconds — the holders
# test-route and test-watch started before they were converted, in each form.
sleep 600 &
HOLDER=$!
tr_spawn() { ( sleep 600 >/dev/null 2>&1 & printf '%s' "$!" > "$WORK/spawn.pid" ); cat "$WORK/spawn.pid"; }
command sleep 120 &
sleep 0 &
DEAD=$!
cat > "$WORK/stub" <<'EOF'
#!/usr/bin/env bash
sleep 300 &
echo $! > "$WORK/poll.pid"
EOF
echo "$HOLDER $DEAD"
