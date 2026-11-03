# Removes the shortcuts (and the Claude skill if installed). Your tasks.md / leaves.md are left untouched.
foreach ($p in (Join-Path ([Environment]::GetFolderPath('Programs')) 'Desk Buddy.lnk'),
               (Join-Path ([Environment]::GetFolderPath('Startup')) 'Desk Buddy.lnk')) {
  if (Test-Path $p) { Remove-Item $p; Write-Host "Removed $p" }
}
$skill = Join-Path $HOME '.claude\skills\desk-buddy'
if (Test-Path $skill) { Remove-Item -Recurse $skill; Write-Host "Removed the Claude skill" }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*widget.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId }
Write-Host "Desk Buddy removed. Delete this folder to remove everything."
