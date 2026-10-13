# Fixture consumer

Start the liveness watcher in the background:

```
bash <plugin root>/orchestrator/watch.sh --run-dir <RUN_DIR> --ledger <원장 경로> --stall 1200 --interval 60 --after-stage 120 --run-open 300 > <RUN_DIR>/watch.log 2>&1 < /dev/null &
```

All four thresholds are the script's own defaults and none of them is an attempt
to change anything. They are pinned here because the status line has to decide
whether a heartbeat is fresh, and a threshold it cannot read from a contract is
a threshold it invents.
