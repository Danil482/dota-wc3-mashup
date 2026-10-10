# Launch Warcraft III straight into a map, wait for the in-game test harness to
# log "TEST DONE", take window-only screenshots, then close the game.
# Usage: run_test.ps1 -Map <path.w3x> [-Timeout 160] [-Screenshot <png>] [-ShotTimes "30,60"] [-Keep]
param(
    [Parameter(Mandatory = $true)][string]$Map,
    [int]$Timeout = 300,
    [string]$Screenshot = "",
    [string]$ShotTimes = "",
    # "t:fx:fy" entries: at t seconds click the client point (fx, fy) given as
    # fractions. The defaults confirm the startup notice this install always
    # shows ("Please check your VPN" -> OK) and then pick "Play offline".
    [string]$Clicks = "",
    [switch]$Keep,
    [string]$Game = "C:\Program Files (x86)\by Decepticon\Warcraft III\_retail_\x86_64\Warcraft III.exe"
)
$ErrorActionPreference = "Stop"
$docs = [Environment]::GetFolderPath('MyDocuments')
$mapsDir = Join-Path $docs "Warcraft III\Maps\DotaVsCommander"
$logFile = Join-Path $docs "Warcraft III\CustomMapData\DotaVsCommander\log.txt"
New-Item -ItemType Directory -Force $mapsDir | Out-Null
$target = Join-Path $mapsDir (Split-Path $Map -Leaf)
Copy-Item $Map $target -Force
if (Test-Path $logFile) { Remove-Item $logFile -Force }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Wnd {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
    public struct RECT { public int Left, Top, Right, Bottom; }
    public struct POINT { public int X, Y; }
}
"@
Add-Type -AssemblyName System.Drawing
[Win32Wnd]::SetProcessDPIAware() | Out-Null

function Read-Log {
    if (-not (Test-Path $logFile)) { return @() }
    $raw = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return @() }
    $lines = @()
    foreach ($m in [regex]::Matches($raw, 'call Preload\( "(.*?)" \)')) { $lines += $m.Groups[1].Value }
    return $lines
}

# Captures only the game window's own content (PrintWindow with
# PW_RENDERFULLCONTENT), never whatever else is on screen.
function Save-Shot($proc, $path) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { Write-Host "no window to capture"; return }
    $r = New-Object Win32Wnd+RECT
    [Win32Wnd]::GetWindowRect($h, [ref]$r) | Out-Null
    $w = $r.Right - $r.Left; $hgt = $r.Bottom - $r.Top
    if ($w -lt 50 -or $hgt -lt 50) { Write-Host "window too small ($w x $hgt)"; return }
    $bmp = New-Object System.Drawing.Bitmap $w, $hgt
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [Win32Wnd]::PrintWindow($h, $hdc, 2)
    $g.ReleaseHdc($hdc)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "screenshot: $path ($w x $hgt, printwindow=$ok)"
}

# The game ignores posted mouse messages, so each click briefly brings the game
# window to the front, clicks with the real cursor, then restores the user's
# cursor position and foreground window.
function Click-At($proc, $fx, $fy) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { return $false }
    $r = New-Object Win32Wnd+RECT
    [Win32Wnd]::GetClientRect($h, [ref]$r) | Out-Null
    $pt = New-Object Win32Wnd+POINT
    $pt.X = [int](($r.Right - $r.Left) * $fx); $pt.Y = [int](($r.Bottom - $r.Top) * $fy)
    [Win32Wnd]::ClientToScreen($h, [ref]$pt) | Out-Null
    $prevWnd = [Win32Wnd]::GetForegroundWindow()
    $prevPos = New-Object Win32Wnd+POINT
    [Win32Wnd]::GetCursorPos([ref]$prevPos) | Out-Null
    [Win32Wnd]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)          # Alt lets us take the foreground
    [Win32Wnd]::SetForegroundWindow($h) | Out-Null
    [Win32Wnd]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 250
    [Win32Wnd]::SetCursorPos($pt.X, $pt.Y) | Out-Null
    Start-Sleep -Milliseconds 120
    [Win32Wnd]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [Win32Wnd]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 150
    [Win32Wnd]::SetCursorPos($prevPos.X, $prevPos.Y) | Out-Null
    if ($prevWnd -ne [IntPtr]::Zero -and $prevWnd -ne $h) { [Win32Wnd]::SetForegroundWindow($prevWnd) | Out-Null }
    Write-Host "click at screen ($($pt.X), $($pt.Y))"
    return $true
}

$shotList = @()
if ($ShotTimes) { $shotList = @($ShotTimes.Split(',') | ForEach-Object { [int]$_ }) }
$clickList = @()
if ($Clicks) {
    foreach ($entry in $Clicks.Split(',')) {
        $parts = $entry.Split(':')
        $clickList += , @([double]$parts[0], [double]$parts[1], [double]$parts[2])
    }
}

$gameRoot = Split-Path (Split-Path (Split-Path $Game -Parent) -Parent) -Parent
$gameArgs = @("-launch", "-windowmode", "windowed", "-nowfpause", "-loadfile", "`"$target`"")
$proc = Start-Process -FilePath $Game -ArgumentList $gameArgs -WorkingDirectory $gameRoot -PassThru
$start = Get-Date
$shotIndex = 0
$clickIndex = 0
$done = $false
while (((Get-Date) - $start).TotalSeconds -lt $Timeout) {
    Start-Sleep -Seconds 1
    $elapsed = ((Get-Date) - $start).TotalSeconds
    $log = @(Read-Log)
    if ($clickIndex -lt $clickList.Count -and $elapsed -ge $clickList[$clickIndex][0] -and $log.Count -eq 0) {
        $c = $clickList[$clickIndex]
        if (Click-At $proc $c[1] $c[2]) { $clickIndex++ }
    }
    if ($Screenshot -and $shotIndex -lt $shotList.Count -and $elapsed -ge $shotList[$shotIndex]) {
        Save-Shot $proc ($Screenshot -replace '\.png$', "_$($shotList[$shotIndex]).png")
        $shotIndex++
    }
    # keep a rolling snapshot so the last screen before an exit is visible
    if ($Screenshot -and ([int]$elapsed % 5 -eq 0) -and -not $proc.HasExited) {
        Save-Shot $proc ($Screenshot -replace '\.png$', "_last.png") | Out-Null
    }
    if ($log -match "TEST DONE") { $done = $true; break }
    if ($proc.HasExited) { Write-Host "game exited with code $($proc.ExitCode)"; break }
}
if ($Screenshot -and -not $proc.HasExited) { Save-Shot $proc $Screenshot }
$log = @(Read-Log)
Write-Host "---- in-game log ($($log.Count) lines) ----"
$log | ForEach-Object { Write-Host $_ }
if (-not $Keep -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
if (-not $done) { Write-Host "RESULT: NO TEST DONE within $Timeout s"; exit 2 }
if ($log -match "FAIL |ERROR") { Write-Host "RESULT: FAILED"; exit 1 }
Write-Host "RESULT: OK"
