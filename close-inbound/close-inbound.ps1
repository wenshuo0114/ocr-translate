$ErrorActionPreference = "Continue"
$log = Join-Path $PSScriptRoot "close-inbound-result.txt"
$utf8 = New-Object System.Text.UTF8Encoding $true
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("time=" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))

netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound | Out-Null
$lines.Add("policy=blockinbound,allowoutbound")

$groups = @(
  "文件和打印机共享",
  "文件和打印机共享(限制)",
  "网络发现",
  "远程桌面",
  "远程协助",
  "远程事件日志管理",
  "远程卷管理",
  "远程计划任务管理",
  "远程服务管理",
  "Windows Management Instrumentation (WMI)",
  "OpenSSH SSH Server",
  "OpenSSH SSH 服务器"
)
foreach ($g in $groups) {
  $r = netsh advfirewall firewall set rule group="$g" new enable=No 2>&1 | Out-String
  $r = $r.Trim()
  if ($r -match "没有与指定标准相匹配") { $r = "no-match" }
  $lines.Add("group " + $g + " => " + $r)
}

$n = 0
Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue | ForEach-Object {
  Disable-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue
  $n++
}
$left = @(Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue)
$lines.Add("disabled-inbound-allow=" + $n)
$lines.Add("inbound-allow-still-on=" + $left.Count)
[System.IO.File]::WriteAllLines($log, $lines, $utf8)
exit 0
