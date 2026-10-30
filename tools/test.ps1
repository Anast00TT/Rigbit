# Тесты ядра Rigbit: импорт классов, прогон с таймаутом. Любая SCRIPT ERROR = провал
# (ошибки выполнения GDScript раннер сам поймать не может).
$root = Split-Path -Parent $PSScriptRoot
$g = "$root\tools\godot\Godot_v4.7.2-stable_win64_console.exe"
$p = "$root\rigbit"
& $g --headless --path $p --import 2>&1 | Select-String 'SCRIPT ERROR|Parse Error|at: res' | Select-Object -First 10
$j = Start-Job { param($g, $p) & $g --headless --path $p -s res://tests/run_tests.gd 2>&1 } -ArgumentList $g, $p
if (-not (Wait-Job $j -Timeout 400)) { Stop-Job $j; Get-Process | Where-Object Name -like 'Godot*' | Stop-Process -Force; Write-Output "TIMEOUT"; exit 2 }
$out = Receive-Job $j | ForEach-Object { "$_" }
$errors = $out | Select-String 'SCRIPT ERROR|Parse Error'
$out | Select-String 'FAIL|passed|SCRIPT ERROR|Parse Error|at: res' | Select-Object -First 40
if ($errors) { Write-Output "RUNTIME ERRORS: $($errors.Count) (считаются провалом)"; exit 1 }
