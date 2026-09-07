# Fixture consumer whose launch line went unwritten for one arm

This is the shape the original defect had: an arm was added, its threshold was
never spelled out, and the configuration the run actually used became readable
nowhere.

```
bash <plugin root>/orchestrator/watch.sh --run-dir <RUN_DIR> --ledger <원장 경로> --stall 1200 --interval 60 --after-stage 120 > <RUN_DIR>/watch.log 2>&1 < /dev/null &
```
