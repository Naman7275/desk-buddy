# Desk Buddy installer: creates your task file, adds Start menu + startup shortcuts, and launches the widget.
#   powershell -ExecutionPolicy Bypass -File install.ps1              (basic)
#   powershell -ExecutionPolicy Bypass -File install.ps1 -WithClaude  (also installs the Claude Code skill)
#   powershell -ExecutionPolicy Bypass -File install.ps1 -WithLeaves  (also starts a leaves.md for a leave balance)
param([switch]$WithClaude, [switch]$WithLeaves, [switch]$NoStartup)

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Utf8 = New-Object System.Text.UTF8Encoding $false
$today = (Get-Date).ToString('yyyy-MM-dd')

$tasks = Join-Path $Root 'tasks.md'
if (-not (Test-Path $tasks)) {
  [IO.File]::WriteAllText($tasks, @"
# Work log

## Note from Claude
<!-- One line shown as a banner at the top of the desktop widget. -->
Welcome! Add a task below, or just tell Claude.

## Open (carry over until done)
<!-- One line per item: - [ ] task (added YYYY-MM-DD) (due YYYY-MM-DD) -->
- [ ] Try ticking me off (added $today)

## Daily log
<!-- Newest day first. Each day: ### YYYY-MM-DD (Day), then flat bullets: - Done: x / - Added: x / - Dropped: x / - Note: x -->
"@, $Utf8)
  Write-Host "Created tasks.md"
}

$leaves = Join-Path $Root 'leaves.md'
if ($WithLeaves -and -not (Test-Path $leaves)) {
  $y = (Get-Date).ToString('yyyy')
  [IO.File]::WriteAllText($leaves, @"
# Leaves

## Policy
<!-- The widget reads these lines. Credit is added automatically on the 1st of every month. -->
- Credit: 1.5 per month from $y-01
- Days off: Sat, Sun

## Taken
<!-- One line per leave day: - YYYY-MM-DD days note. 0.5 = half day. YYYY-MM when the exact days weren't noted.
     A future date counts as planned. A negative number gives days back (comp-off). -->
"@, $Utf8)
  Write-Host "Created leaves.md (edit the Credit line to match your policy)"
}

$sh = New-Object -ComObject WScript.Shell
function New-Link($path) {
  $l = $sh.CreateShortcut($path)
  $l.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
  $l.Arguments = '"' + (Join-Path $Root 'Start widget.vbs') + '"'
  $l.WorkingDirectory = $Root
  $l.IconLocation = "$env:WINDIR\System32\imageres.dll,112"
  $l.Save()
}
New-Link (Join-Path ([Environment]::GetFolderPath('Programs')) 'Desk Buddy.lnk')
Write-Host "Added 'Desk Buddy' to the Start menu"
if (-not $NoStartup) {
  New-Link (Join-Path ([Environment]::GetFolderPath('Startup')) 'Desk Buddy.lnk')
  Write-Host "Desk Buddy will start with Windows"
}

if ($WithClaude) {
  $dir = Join-Path $HOME '.claude\skills\desk-buddy'
  New-Item -ItemType Directory -Force $dir | Out-Null
  $skill = [IO.File]::ReadAllText((Join-Path $Root 'claude\skills\desk-buddy\SKILL.md'), $Utf8)
  [IO.File]::WriteAllText((Join-Path $dir 'SKILL.md'), $skill.Replace('{{INSTALL_DIR}}', $Root), $Utf8)
  Write-Host "Installed the Claude Code skill to $dir"
}

Start-Process wscript.exe ('"' + (Join-Path $Root 'Start widget.vbs') + '"')
Write-Host "Done. Look for the buddy at the bottom-right of your screen."
