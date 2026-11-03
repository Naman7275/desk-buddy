# Read/write helpers for tasks.md. Dot-sourced by widget.ps1; expects $LogPath to be set.
# File format (shared with the scheduled Claude check-ins):
#   ## Note from Claude      -> first non-comment line is shown as a banner in the widget
#   ## Open (...)            -> "- [ ] task (added YYYY-MM-DD)" lines, optionally followed by " (due YYYY-MM-DD)"
#   ## Daily log             -> "### YYYY-MM-DD (Day)" blocks, newest first, with flat bullets:
#                               "- Done: x", "- Added: x", "- Dropped: x", "- Note: x"

$Utf8 = New-Object System.Text.UTF8Encoding $false
$ItemRx = '^\s*- \[ \] (.+?)(?:\s+\(added (\d{4}-\d{2}-\d{2})\))?(?:\s+\(due (\d{4}-\d{2}-\d{2})\))?\s*$'
$script:Undo = @{}

# "Today" for everything below. Set $script:TodayOverride (a [datetime]) to simulate another day.
function Get-Today { if ($script:TodayOverride) { $script:TodayOverride.Date } else { (Get-Date).Date } }

function Read-Lines {
  $l = New-Object 'System.Collections.Generic.List[string]'
  if (Test-Path $LogPath) { foreach ($x in [IO.File]::ReadAllLines($LogPath, $Utf8)) { $l.Add($x) } }
  return ,$l
}

function Save-Lines($lines) {
  [IO.File]::WriteAllLines($LogPath, $lines, $Utf8)
  $script:LastWrite = (Get-Item $LogPath).LastWriteTimeUtc
}

function Find-Header($lines, $prefix) {
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith($prefix)) { return $i } }
  return -1
}

# Index of the next "## " header after $start, or the end of the file.
function Get-SectionEnd($lines, $start) {
  for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^## ') { return $i } }
  return $lines.Count
}

function Get-TodayKey { (Get-Today).ToString('yyyy-MM-dd') }

function Get-State {
  $lines = Read-Lines
  $today = Get-Today
  $open = @(); $done = @(); $note = ''

  $o = Find-Header $lines '## Open'
  if ($o -ge 0) {
    $end = Get-SectionEnd $lines $o
    for ($i = $o + 1; $i -lt $end; $i++) {
      if ($lines[$i] -match $ItemRx) {
        $age = $null
        if ($Matches[2]) { $age = ($today - [datetime]::ParseExact($Matches[2], 'yyyy-MM-dd', $null)).Days }
        $due = $null
        if ($Matches[3]) { $due = ([datetime]::ParseExact($Matches[3], 'yyyy-MM-dd', $null) - $today).Days }
        $open += [pscustomobject]@{ Text = $Matches[1]; Age = $age; Due = $due; Line = $lines[$i] }
      }
    }
  }

  $n = Find-Header $lines '## Note'
  if ($n -ge 0) {
    $end = Get-SectionEnd $lines $n
    for ($i = $n + 1; $i -lt $end; $i++) {
      $t = $lines[$i].Trim()
      if ($t -and -not $t.StartsWith('<!--')) { $note = $t.TrimStart('>', ' ', '-'); break }
    }
  }

  $h = Find-Header $lines ('### ' + (Get-TodayKey))
  if ($h -ge 0) {
    for ($i = $h + 1; $i -lt $lines.Count -and $lines[$i] -notmatch '^#{2,3} '; $i++) {
      if ($lines[$i] -match '^\s*- Done:\s*(.+?)\s*$') { $done += $Matches[1] }
    }
  }

  [pscustomobject]@{ Open = $open; Done = $done; Note = $note }
}

# Appends "- <text>" to today's Daily log block, creating the block at the top if needed.
function Add-LogBullet($lines, $text) {
  $now = Get-Today
  $h = Find-Header $lines ('### ' + (Get-TodayKey))
  if ($h -lt 0) {
    $d = Find-Header $lines '## Daily log'
    if ($d -lt 0) { $lines.Add(''); $lines.Add('## Daily log'); $d = $lines.Count - 1 }
    $at = $d + 1
    while ($at -lt $lines.Count -and $lines[$at].Trim().StartsWith('<!--')) { $at++ }
    $lines.InsertRange($at, [string[]]@('', ('### ' + (Get-TodayKey) + ' (' + $now.DayOfWeek + ')')))
    $h = $at + 1
  }
  $i = $h + 1
  while ($i -lt $lines.Count -and $lines[$i] -match '^\s*- ') { $i++ }
  $lines.Insert($i, "- $text")
}

function Insert-OpenLine($lines, $line) {
  $o = Find-Header $lines '## Open'
  if ($o -lt 0) {
    $lines.InsertRange([Math]::Min(2, $lines.Count), [string[]]@('## Open (carry over until done)', ''))
    $o = Find-Header $lines '## Open'
  }
  $at = Get-SectionEnd $lines $o
  while ($at -gt $o + 1 -and $lines[$at - 1].Trim() -eq '') { $at-- }
  $lines.Insert($at, $line)
}

function Complete-Task($item) {
  $lines = Read-Lines
  $idx = $lines.IndexOf($item.Line)
  if ($idx -lt 0) { return }
  $lines.RemoveAt($idx)
  Add-LogBullet $lines "Done: $($item.Text)"
  $script:Undo[$item.Text] = $item.Line
  Save-Lines $lines
}

function Drop-Task($item) {
  $lines = Read-Lines
  $idx = $lines.IndexOf($item.Line)
  if ($idx -lt 0) { return }
  $lines.RemoveAt($idx)
  Add-LogBullet $lines "Dropped: $($item.Text)"
  Save-Lines $lines
}

# Pulls a date phrase out of typed text: "deck for next day", "tommorow mail the team", "report by Friday",
# "review next week", "in 3 days", "today". Work dates: tomorrow on Fri/Sat rolls to Monday.
# Returns @{ Text = <text without the phrase>; Due = <date or $null> }.
function Resolve-DueDate($text) {
  $today = Get-Today
  $pre = '(?:\b(?:for|by|on|due|before|till|until)\s+)?'
  $days = 'monday','tuesday','wednesday','thursday','friday','saturday','sunday'
  $due = $null; $rx = $null

  if ($text -match "$pre\b(tomorrow|tommorow|tommorrow|tomorow|tmrw|tmr|next\s+day)\b") {
    $rx = $Matches[0]; $due = $today.AddDays(1)
    while ($due.DayOfWeek -in 'Saturday','Sunday') { $due = $due.AddDays(1) }
  } elseif ($text -match "$pre\b(today|tonight|eod)\b") {
    $rx = $Matches[0]; $due = $today
  } elseif ($text -match "$pre\bnext\s+week\b") {
    $rx = $Matches[0]; $due = $today.AddDays(1)
    while ($due.DayOfWeek -ne 'Monday') { $due = $due.AddDays(1) }
  } elseif ($text -match "$pre\bin\s+(\d{1,2})\s+days?\b") {
    $rx = $Matches[0]; $due = $today.AddDays([int]$Matches[1])
  } elseif ($text -match "$pre\b(?:next\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri)\b") {
    $rx = $Matches[0]
    $want = $days | Where-Object { $_.StartsWith($Matches[1].ToLower().Substring(0, 3)) } | Select-Object -First 1
    $due = $today.AddDays(1)
    while ($due.DayOfWeek.ToString().ToLower() -ne $want) { $due = $due.AddDays(1) }
  }

  if ($rx) {
    $text = ($text.Replace($rx, ' ') -replace '\s{2,}', ' ').Trim(' ', ',', '-', '.')
    if ($text) { $text = $text.Substring(0, 1).ToUpper() + $text.Substring(1) }
  }
  @{ Text = $text; Due = $due }
}

function Add-Task($text) {
  $text = "$text".Trim()
  if (-not $text) { return }
  $parsed = Resolve-DueDate $text
  if ($parsed.Text) { $text = $parsed.Text }
  $line = "- [ ] $text (added $(Get-TodayKey))"
  if ($parsed.Due) { $line += " (due $($parsed.Due.ToString('yyyy-MM-dd')))" }
  $lines = Read-Lines
  Insert-OpenLine $lines $line
  Add-LogBullet $lines "Added: $text"
  Save-Lines $lines
}

# Reopens something ticked today: removes its "Done" bullet and puts it back in Open.
function Restore-Task($text) {
  $lines = Read-Lines
  $h = Find-Header $lines ('### ' + (Get-TodayKey))
  if ($h -lt 0) { return }
  for ($i = $h + 1; $i -lt $lines.Count -and $lines[$i] -notmatch '^#{2,3} '; $i++) {
    if ($lines[$i] -match '^\s*- Done:\s*(.+?)\s*$' -and $Matches[1] -eq $text) { $lines.RemoveAt($i); break }
  }
  $line = $script:Undo[$text]
  if (-not $line) { $line = "- [ ] $text (added $(Get-TodayKey))" }
  Insert-OpenLine $lines $line
  Save-Lines $lines
}

# ---- Leaves (leaves.md next to tasks.md; expects $LeavePath) ----
# "- Credit: 1.5 per month from 2026-01" under ## Policy accrues on the 1st of each month.
# "- YYYY-MM-DD days note" lines under ## Taken use leave (YYYY-MM = days not noted; future = planned; negative = days back).
$LeaveRx = '^\s*- (\d{4}-\d{2}(?:-\d{2})?)\s+(-?\d+(?:\.\d+)?)\b\s*(.*)$'
$Inv = [Globalization.CultureInfo]::InvariantCulture

function Format-Days($n) { $n.ToString('0.#', $Inv) }

function Get-LeaveState {
  if (-not $LeavePath -or -not (Test-Path $LeavePath)) { return $null }
  $lines = [IO.File]::ReadAllLines($LeavePath, $Utf8)
  $today = Get-Today
  $rate = 0; $from = $null
  foreach ($l in $lines) {
    if ($l -match 'Credit:\s*([\d.]+)\s*(?:days?\s+)?per\s+month\s+from\s+(\d{4})-(\d{2})') {
      $rate = [double]::Parse($Matches[1], $Inv); $from = New-Object datetime ([int]$Matches[2]), ([int]$Matches[3]), 1
    }
  }
  $entries = @()
  $t = Find-Header $lines '## Taken'
  if ($t -ge 0) {
    $end = Get-SectionEnd $lines $t
    for ($i = $t + 1; $i -lt $end; $i++) {
      if ($lines[$i] -match $LeaveRx) {
        $exact = $Matches[1].Length -eq 10
        $d = if ($exact) { [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null) } else { [datetime]::ParseExact($Matches[1], 'yyyy-MM', $null) }
        $planned = if ($exact) { $d -gt $today } else { $d -gt (New-Object datetime $today.Year, $today.Month, 1) }
        $entries += [pscustomobject]@{ Date = $d; Exact = $exact; Days = [double]::Parse($Matches[2], $Inv)
                                       Note = $Matches[3].Trim(); Line = $lines[$i]; Planned = $planned }
      }
    }
  }
  $months = 0
  if ($from) { $months = [Math]::Max(0, ($today.Year - $from.Year) * 12 + $today.Month - $from.Month + 1) }
  $earned = $months * $rate
  $used = ($entries | Where-Object { -not $_.Planned } | Measure-Object Days -Sum).Sum
  $planned = ($entries | Where-Object { $_.Planned } | Measure-Object Days -Sum).Sum
  if (-not $used) { $used = 0 }; if (-not $planned) { $planned = 0 }
  [pscustomobject]@{
    Earned = $earned; Used = $used; Planned = $planned; Balance = $earned - $used; Rate = $rate
    NextCredit = (New-Object datetime $today.Year, $today.Month, 1).AddMonths(1)
    CreditedToday = ($rate -gt 0 -and $today.Day -eq 1 -and $months -gt 0)
    Entries = @($entries | Sort-Object Date -Descending)
  }
}

# Understands: today, yesterday, tomorrow, Fri / last Fri, 12 Nov, Nov 12, 12-14 Nov, 30 Nov to 2 Dec, 2026-11-12, "half".
# Ranges skip the weekly days off ("- Days off: Sat, Sun" under ## Policy; default Sat, Sun). Returns @{ Dates; Days } or $null.
function Get-LeaveDaysOff {
  $off = @('Saturday', 'Sunday')
  if ($LeavePath -and (Test-Path $LeavePath)) {
    foreach ($l in [IO.File]::ReadAllLines($LeavePath, $Utf8)) {
      if ($l -match 'Days off:\s*(.+)$') {
        $names = 'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'
        $off = @($Matches[1] -split '[,\s/&]+' | Where-Object { $_ } | ForEach-Object {
          $p = $_.ToLower(); $names | Where-Object { $_.ToLower().StartsWith($p.Substring(0, [Math]::Min(3, $p.Length))) } })
      }
    }
  }
  $off
}

function Resolve-LeaveDates($text) {
  $today = Get-Today
  $off = Get-LeaveDaysOff
  $t = " $("$text".ToLower()) "
  $days = 1
  if ($t -match '\bhalf\b') { $days = 0.5; $t = $t -replace '\bhalf(\s*-?\s*day)?\b', ' ' }
  $mon = '(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*'
  $ord = '(?:st|nd|rd|th)?'
  $to = '\s*(?:-|to|till|until)\s*'
  $mi = { param($m) 1 + [array]::IndexOf(@('jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec'), $m) }
  # Dates more than 60 days back are taken to mean next year.
  $mk = { param($d, $m) $x = New-Object datetime $today.Year, $m, $d; if ($x -lt $today.AddDays(-60)) { $x = $x.AddYears(1) }; $x }
  $a = $null; $b = $null
  if ($t -match "(\d{4}-\d{2}-\d{2})(?:$to(\d{4}-\d{2}-\d{2}))?") {
    $a = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
    if ($Matches[2]) { $b = [datetime]::ParseExact($Matches[2], 'yyyy-MM-dd', $null) }
  } elseif ($t -match "\b(\d{1,2})$ord\s*$mon$to(\d{1,2})$ord\s*$mon") {
    $a = & $mk ([int]$Matches[1]) (& $mi $Matches[2]); $b = & $mk ([int]$Matches[3]) (& $mi $Matches[4])
  } elseif ($t -match "\b(\d{1,2})$ord$to(\d{1,2})$ord\s*$mon") {
    $m = & $mi $Matches[3]; $a = & $mk ([int]$Matches[1]) $m; $b = & $mk ([int]$Matches[2]) $m
  } elseif ($t -match "\b(\d{1,2})$ord\s*$mon") {
    $a = & $mk ([int]$Matches[1]) (& $mi $Matches[2])
  } elseif ($t -match "\b$mon\s*(\d{1,2})\b") {
    $a = & $mk ([int]$Matches[2]) (& $mi $Matches[1])
  } elseif ($t -match '\byesterday\b') {
    $a = $today.AddDays(-1); while ("$($a.DayOfWeek)" -in $off) { $a = $a.AddDays(-1) }
  } elseif ($t -match '\b(tomorrow|tommorow|tommorrow|tomorow|tmrw|tmr|next\s+day)\b') {
    $a = $today.AddDays(1); while ("$($a.DayOfWeek)" -in $off) { $a = $a.AddDays(1) }
  } elseif ($t -match '\b(today|eod)\b') {
    $a = $today
  } elseif ($t -match '\b(last\s+)?(mon|tue|wed|thu|fri|sat)[a-z]*\b') {
    $want = $Matches[2]; $step = if ($Matches[1]) { -1 } else { 1 }
    $a = $today.AddDays($step)
    while ($a.DayOfWeek.ToString().Substring(0, 3).ToLower() -ne $want) { $a = $a.AddDays($step) }
  }
  if (-not $a) { return $null }
  if (-not $b -or $b -lt $a) { $b = $a }
  $list = @()
  for ($d = $a; $d -le $b; $d = $d.AddDays(1)) { if ("$($d.DayOfWeek)" -notin $off -or $a -eq $b) { $list += $d } }
  @{ Dates = $list; Days = $days }
}

function Add-Leave($text) {
  $r = Resolve-LeaveDates $text
  if (-not $r) { return $false }
  $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($x in [IO.File]::ReadAllLines($LeavePath, $Utf8)) { $lines.Add($x) }
  $t = Find-Header $lines '## Taken'
  if ($t -lt 0) { $lines.Add(''); $lines.Add('## Taken'); $t = $lines.Count - 1 }
  foreach ($d in $r.Dates) {
    $key = $d.ToString('yyyy-MM-dd')
    $line = "- $key $(Format-Days $r.Days)"
    # Keep the list in date order.
    $end = Get-SectionEnd $lines $t
    $at = $t + 1
    for ($i = $t + 1; $i -lt $end; $i++) {
      if ($lines[$i] -match $LeaveRx) { if ($Matches[1] -le $key) { $at = $i + 1 } }
      elseif ($lines[$i].Trim().StartsWith('<!--') -or $lines[$i] -match '^\s+\S.*-->') { if ($at -le $i) { $at = $i + 1 } }
    }
    $lines.Insert($at, $line)
  }
  [IO.File]::WriteAllLines($LeavePath, $lines, $Utf8)
  return $true
}

function Remove-Leave($entry) {
  $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($x in [IO.File]::ReadAllLines($LeavePath, $Utf8)) { $lines.Add($x) }
  $idx = $lines.IndexOf($entry.Line)
  if ($idx -ge 0) { $lines.RemoveAt($idx); [IO.File]::WriteAllLines($LeavePath, $lines, $Utf8) }
}
