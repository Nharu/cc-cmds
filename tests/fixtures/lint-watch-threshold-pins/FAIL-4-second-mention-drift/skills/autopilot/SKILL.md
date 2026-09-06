# Fixture consumer whose second mention went stale

Start the liveness watcher in the background:

```
bash <plugin root>/orchestrator/watch.sh --run-dir <RUN_DIR> --ledger <원장 경로> --stall 1200 --interval 60 --after-stage 120 --run-open 300 > <RUN_DIR>/watch.log 2>&1 < /dev/null &
```

All four thresholds are the script's own defaults. The launch line above agrees
with the script; this paragraph restates them independently — `--stall 1800`,
`--interval 60`, `--after-stage 120`, `--run-open 300` — and carries no script
name, so a scan that locates the launch line by the script it invokes never
reaches it. The launch line is what a run consumes, so rules 2 and 3 stay green
here and only the wider sweep sees the divergence.
