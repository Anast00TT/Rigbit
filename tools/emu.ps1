# Сборка APK, установка на LDPlayer (adb 127.0.0.1:5555), запуск и скриншот.
# Пример: powershell -File tools\emu.ps1 -Build -Shot start
param([switch]$Build, [string]$Shot = "", [int]$Wait = 6)
$root = Split-Path -Parent $PSScriptRoot
$g = "$root\tools\godot\Godot_v4.7.2-stable_win64_console.exe"
$adb = "C:\LDPlayer\LDPlayer9\adb.exe"  # adb самого LDPlayer, иначе два сервера выбивают друг друга
$dev = ((& $adb devices) | Select-String "\tdevice$" | Select-Object -First 1).Line.Split("`t")[0]  # первое живое устройство
$apk = "$root\build\rigbit-debug.apk"
New-Item -ItemType Directory -Force "$root\build\emu" | Out-Null
if ($Build) {
	& $g --headless --path "$root\rigbit" --import 2>&1 | Out-Null
	& $g --headless --path "$root\rigbit" --export-debug "Android" ($apk -replace '\\', '/') 2>&1 | Select-String -Pattern 'ERROR|SCRIPT' | Select-Object -First 10
	& $adb -s $dev install -r $apk
	& $adb -s $dev shell am force-stop com.rigbit.app
	& $adb -s $dev logcat -c
	& $adb -s $dev shell monkey -p com.rigbit.app -c android.intent.category.LAUNCHER 1 | Out-Null
	Start-Sleep -Seconds $Wait
}
if ($Shot -ne "") {
	& $adb -s $dev shell screencap -p /sdcard/rb_shot.png | Out-Null
	& $adb -s $dev pull /sdcard/rb_shot.png "$root\build\emu\$Shot.png" | Out-Null
	Write-Output "shot: build\emu\$Shot.png"
}
& $adb -s $dev logcat -d -s godot:E godot:W AndroidRuntime:E 2>&1 | Select-Object -Last 15
