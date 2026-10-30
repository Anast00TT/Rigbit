#!/usr/bin/env bash
# Ставит Godot 4.7.2 (Linux x86_64) в tools/godot для облачных сессий и CI.
# Повторный запуск ничего не качает, если бинарь уже на месте.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dst="$root/tools/godot"
bin="$dst/Godot_v4.7.2-stable_linux.x86_64"
if [ ! -x "$bin" ]; then
	mkdir -p "$dst"
	tmp="$(mktemp -d)"
	curl -fsSL -o "$tmp/godot.zip" https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip
	unzip -oq "$tmp/godot.zip" -d "$dst"
	rm -rf "$tmp"
	chmod +x "$bin"
fi
echo "$bin"
