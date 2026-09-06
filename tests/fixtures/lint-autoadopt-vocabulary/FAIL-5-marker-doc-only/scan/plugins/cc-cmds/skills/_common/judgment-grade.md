# Fixture document side carrying a sixth marker the parser never reads

A stage that writes this one gets nothing absorbed — the convention is dead
prose, and naming which side a marker is missing from is part of the failure.

| marker | when | value |
| --- | --- | --- |
| `**판단 부류**:` | always | one token from the vocabulary, no spaces |
| `**판단 등급**:` | always | `0`, `1` or `2` |
| `**판단 기준**:` | always | the authored standard that chose the option |
| `**판단 되돌리는 법**:` | at grade 1 | the concrete command that undoes it |
| `**판단 근거**:` | always | what was observed, and why this option |
| `**판단 시점**:` | always | when the stage decided |
