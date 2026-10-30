#!/usr/bin/env bash
# Тесты ядра Rigbit на Linux (аналог tools/test.ps1). Любая SCRIPT ERROR = провал.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
g="$("$root/tools/setup_godot.sh")"
p="$root/rigbit"
"$g" --headless --path "$p" --import 2>&1 | grep -E 'SCRIPT ERROR|Parse Error|at: res' | head -10
out="$(timeout 400 "$g" --headless --path "$p" -s res://tests/run_tests.gd 2>&1)"
code=$?
echo "$out" | grep -E 'FAIL|passed|SCRIPT ERROR|Parse Error|at: res' | head -40
if [ $code -eq 124 ]; then echo "TIMEOUT"; exit 2; fi
errors=$(echo "$out" | grep -cE 'SCRIPT ERROR|Parse Error')
if [ "$errors" -gt 0 ]; then echo "RUNTIME ERRORS: $errors (считаются провалом)"; exit 1; fi
exit $code
