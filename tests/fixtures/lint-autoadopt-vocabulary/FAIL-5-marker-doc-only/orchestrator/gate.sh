#!/usr/bin/env bash
# Fixture parser side. Only the marker spellings are read.
cls=$(printf '%s' "$txt"   | sed -n 's/.*\*\*판단 부류\*\*: *\([^ *`]*\).*/\1/p')
grade=$(printf '%s' "$txt" | sed -n 's/.*\*\*판단 등급\*\*: *\([0-9]\).*/\1/p')
std=$(printf '%s' "$txt"   | sed -n 's/.*\*\*판단 기준\*\*: *\(.*\)/\1/p')
undo=$(printf '%s' "$txt"  | sed -n 's/.*\*\*판단 되돌리는 법\*\*: *\(.*\)/\1/p')
why=$(printf '%s' "$txt"   | sed -n 's/.*\*\*판단 근거\*\*: *\(.*\)/\1/p')
