# Скриншоты Rigbit на компе в разных раскладках.
# Пример: powershell -File tools\shots.ps1 p_demo "--size=720x1560 --scale=2 --demo" l_sheet "--size=1600x720 --scale=2 --demo --menu=sheet"
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$pairs)
$root = Split-Path -Parent $PSScriptRoot
$g = "$root\tools\godot\Godot_v4.7.2-stable_win64_console.exe"
$p = "$root\rigbit"
$s = "$root\build\shots"
New-Item -ItemType Directory -Force $s | Out-Null
& $g --headless --path $p --import 2>&1 | Select-String -Pattern 'SCRIPT ERROR|Parse Error|ERROR: res://' | Select-Object -First 20
for ($i = 0; $i -lt $pairs.Count; $i += 2) {
	$name = $pairs[$i]
	$a = @("--path", $p, "--quit-after", "900", "--", "--shot=$s/$name.png") + $pairs[$i + 1].Split(" ")
	& $g @a 2>&1 | Select-String -Pattern 'SCRIPT ERROR|Parse Error|ERROR|at: ' | Select-Object -First 12
	Write-Output "shot: $name"
}
