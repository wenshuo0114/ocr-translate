# 本地截屏识别翻译。一个窗口、一个进程，关掉就退出。
# Key 只在密码框内存里，不写文件、不写注册表、不写日志。
# 网络只打 https://api.deepseek.com 和 https://api.groq.com。
# 没有本机 HTTP 服务，没有常驻后台脚本。

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -ReferencedAssemblies System.dll,System.Windows.Forms.dll,System.Drawing.dll @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class OcrHotKeyForm : Form {
  public event EventHandler CaptureHotKey;
  public const int WM_HOTKEY = 0x0312;
  [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, int fsModifiers, int vk);
  [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  protected override void WndProc(ref Message m) {
    if (m.Msg == WM_HOTKEY && CaptureHotKey != null) CaptureHotKey(this, EventArgs.Empty);
    base.WndProc(ref m);
  }
}
"@
[OcrHotKeyForm]::SetProcessDPIAware() | Out-Null

$script:settingsPath = Join-Path $env:APPDATA "ocr-translate\settings.json"
$script:hotkeys = @{
  capture = "Ctrl+Shift+S"
  copyOrig = "Ctrl+Shift+C"
  copyTrans = "Ctrl+Shift+T"
  backOrig = "Ctrl+Shift+B"
}
$script:engine = "deepseek"
$script:target = "both"
$script:last = @{ original = ""; zh = ""; en = ""; ja = "" }
$script:transSide = "zh"
$script:recording = $null
$script:hotkeyId = 0x4F43
$script:ok = $false
$script:crop = $null
$script:dragging = $false
$script:startX = 0
$script:startY = 0
$script:capX = 0
$script:capY = 0
$script:capW = 0
$script:capH = 0
$script:vsLeft = 0
$script:vsTop = 0
$script:bubble = $null
$script:bubbleMode = "trans"

function Load-Settings {
  if (-not (Test-Path $script:settingsPath)) { return }
  $raw = Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8
  $obj = $raw | ConvertFrom-Json
  if ($obj.engine) { $script:engine = [string]$obj.engine }
  if ($obj.target) { $script:target = [string]$obj.target }
  foreach ($n in @("capture","copyOrig","copyTrans","backOrig")) {
    if ($obj.hotkeys -and $obj.hotkeys.$n) { $script:hotkeys[$n] = [string]$obj.hotkeys.$n }
  }
}

function Save-Settings {
  $dir = Split-Path $script:settingsPath
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $payload = @{
    engine = $script:engine
    target = $script:target
    hotkeys = $script:hotkeys
  } | ConvertTo-Json -Depth 4
  Set-Content -LiteralPath $script:settingsPath -Value $payload -Encoding UTF8
}

function Parse-Combo([string]$combo) {
  $mod = 0; $vk = 0; $key = $null
  foreach ($part in ($combo -split "\+")) {
    $p = $part.Trim().ToLower()
    if ($p -in @("ctrl","control")) { $mod = $mod -bor 2 }
    elseif ($p -eq "shift") { $mod = $mod -bor 4 }
    elseif ($p -eq "alt") { $mod = $mod -bor 1 }
    elseif ($p -in @("win","meta","cmd")) { $mod = $mod -bor 8 }
    else { $key = $part.Trim() }
  }
  if (-not $key) { return $null }
  if ($key -match "^[A-Za-z]$") { $vk = [int][char]$key.ToUpper() }
  elseif ($key -match "^[0-9]$") { $vk = [int][char]$key }
  elseif ($key -match "^F([1-9]|1[0-2])$") { $vk = 0x70 + ([int]$Matches[1] - 1) }
  else { return $null }
  return @{ mod = $mod; vk = $vk }
}

function Combo-FromKeyEvent($e) {
  $parts = @()
  if ($e.Control) { $parts += "Ctrl" }
  if ($e.Shift) { $parts += "Shift" }
  if ($e.Alt) { $parts += "Alt" }
  $k = $e.KeyCode.ToString()
  if ($k -in @("ControlKey","ShiftKey","Menu","LWin","RWin")) { return ($parts -join "+") }
  if ($k.Length -eq 1) { $k = $k.ToUpper() }
  $parts += $k
  return ($parts -join "+")
}

function Combo-Valid([string]$combo) {
  return $combo -match "^(Ctrl|Shift|Alt|Win)\+"
}

function Event-Matches($e, [string]$combo) {
  return (Combo-FromKeyEvent $e) -eq $combo
}

function Capture-Region {
  if (-not ("ScreenMetrics" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ScreenMetrics {
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
}
"@
  }
  $vsLeft = [ScreenMetrics]::GetSystemMetrics(76)
  $vsTop = [ScreenMetrics]::GetSystemMetrics(77)
  $vsW = [ScreenMetrics]::GetSystemMetrics(78)
  $vsH = [ScreenMetrics]::GetSystemMetrics(79)
  if ($vsW -le 0 -or $vsH -le 0) {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $vsLeft = $vs.X; $vsTop = $vs.Y; $vsW = $vs.Width; $vsH = $vs.Height
  }
  $script:vsLeft = $vsLeft
  $script:vsTop = $vsTop
  Close-InPlace
  $savedBounds = $form.Bounds
  $form.Location = New-Object System.Drawing.Point -20000, -20000
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 50

  $full = $null
  $tip = $null
  $boxForm = $null
  $script:ok = $false
  $script:crop = $null
  try {
    $full = New-Object System.Drawing.Bitmap $vsW, $vsH
    $g = [System.Drawing.Graphics]::FromImage($full)
    $g.CopyFromScreen($vsLeft, $vsTop, 0, 0, (New-Object System.Drawing.Size $vsW, $vsH))
    $g.Dispose()

    $tip = New-Object System.Windows.Forms.Form
    $tip.FormBorderStyle = "None"
    $tip.StartPosition = "Manual"
    $tip.Size = New-Object System.Drawing.Size 220, 28
    $tip.TopMost = $true
    $tip.ShowInTaskbar = $false
    $tip.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
    $tipLbl = New-Object System.Windows.Forms.Label
    $tipLbl.Text = "拖框选区，Esc 取消"
    $tipLbl.Dock = "Fill"
    $tipLbl.TextAlign = "MiddleCenter"
    $tipLbl.ForeColor = [System.Drawing.Color]::FromArgb(31, 42, 55)
    $tip.Controls.Add($tipLbl)
    $tip.Show()

    $boxForm = New-Object System.Windows.Forms.Form
    $boxForm.FormBorderStyle = "None"
    $boxForm.StartPosition = "Manual"
    $boxForm.TopMost = $true
    $boxForm.ShowInTaskbar = $false
    $boxForm.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $boxForm.Opacity = 0.35
    $boxForm.Enabled = $false
    $boxForm.Visible = $false

    function Key-Down($vk) {
      return ([ScreenMetrics]::GetAsyncKeyState([int]$vk) -band 0x8000) -ne 0
    }
    $t0 = [Environment]::TickCount
    while (Key-Down 0x01) {
      $p = [System.Windows.Forms.Cursor]::Position
      $tip.Location = New-Object System.Drawing.Point ($p.X + 18), ($p.Y + 18)
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 10
      if (([Environment]::TickCount - $t0) -gt 8000) { break }
    }
    $t0 = [Environment]::TickCount
    $got = $false
    while (-not $got) {
      if (Key-Down 0x1B) { return $null }
      $p = [System.Windows.Forms.Cursor]::Position
      $tip.Location = New-Object System.Drawing.Point ($p.X + 18), ($p.Y + 18)
      if (Key-Down 0x01) {
        $got = $true
        $script:startX = $p.X
        $script:startY = $p.Y
        $tip.Hide()
        $boxForm.Bounds = New-Object System.Drawing.Rectangle $p.X, $p.Y, 1, 1
        $boxForm.Show()
        break
      }
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 10
      if (([Environment]::TickCount - $t0) -gt 60000) { return $null }
    }
    while (Key-Down 0x01) {
      if (Key-Down 0x1B) { return $null }
      $p = [System.Windows.Forms.Cursor]::Position
      $x = [Math]::Min($script:startX, $p.X)
      $y = [Math]::Min($script:startY, $p.Y)
      $w = [Math]::Max(1, [Math]::Abs($p.X - $script:startX))
      $h = [Math]::Max(1, [Math]::Abs($p.Y - $script:startY))
      $boxForm.Bounds = New-Object System.Drawing.Rectangle $x, $y, $w, $h
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 10
    }
    $p = [System.Windows.Forms.Cursor]::Position
    $x = [Math]::Min($script:startX, $p.X)
    $y = [Math]::Min($script:startY, $p.Y)
    $w = [Math]::Abs($p.X - $script:startX)
    $h = [Math]::Abs($p.Y - $script:startY)
    if ($w -ge 8 -and $h -ge 8) {
      $rx = $x - $vsLeft
      $ry = $y - $vsTop
      if ($rx -lt 0) { $rx = 0 }
      if ($ry -lt 0) { $ry = 0 }
      if ($rx + $w -gt $vsW) { $w = $vsW - $rx }
      if ($ry + $h -gt $vsH) { $h = $vsH - $ry }
      if ($w -ge 8 -and $h -ge 8) {
        $script:crop = $full.Clone((New-Object System.Drawing.Rectangle $rx, $ry, $w, $h), $full.PixelFormat)
        $script:capX = $x
        $script:capY = $y
        $script:capW = $w
        $script:capH = $h
        $script:ok = $true
      }
    }
  } finally {
    try { if ($tip) { $tip.Close(); $tip.Dispose() } } catch {}
    try { if ($boxForm) { $boxForm.Close(); $boxForm.Dispose() } } catch {}
    $form.Bounds = $savedBounds
    if ($full) { $full.Dispose() }
  }
  if (-not $script:ok) { return $null }
  return $script:crop
}

function Bitmap-ToDataUrl($bmp) {
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $b64 = [Convert]::ToBase64String($ms.ToArray())
  $ms.Dispose()
  return "data:image/png;base64,$b64"
}

function Ocr-Prompt {
  return @'
You are a screenshot OCR engine for software UI, terminals, logs, and source code.
1) Transcribe EVERY visible character exactly into "original".
2) Bidirectional translation: "zh" Simplified Chinese, "en" English.
Hard rules for original: do NOT insert spaces into identifiers like getUserName, HttpResponse, FILE_NOT_FOUND.
Keep camelCase/PascalCase/snake_case/line breaks. Do not markdown.
Leave identifiers, paths, URLs, commands unchanged in zh and en.
Return JSON only: {"original":"...","zh":"...","en":"..."}
'@
}

function Call-Chat([string]$baseUrl, [string]$apiKey, [string[]]$models, [string]$dataUrl) {
  $prompt = Ocr-Prompt
  $lastErr = "no model"
  foreach ($model in $models) {
    $body = @{
      model = $model
      temperature = 0
      max_tokens = 4096
      response_format = @{ type = "json_object" }
      messages = @(
        @{
          role = "user"
          content = @(
            @{ type = "text"; text = $prompt }
            @{ type = "image_url"; image_url = @{ url = $dataUrl } }
          )
        }
      )
    } | ConvertTo-Json -Depth 8 -Compress
    try {
      $res = Invoke-RestMethod -Method Post -Uri ($baseUrl.TrimEnd("/") + "/chat/completions") -Headers @{
        Authorization = "Bearer $apiKey"
      } -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 90
      $text = $res.choices[0].message.content
      return @{ model = $model; text = $text }
    } catch {
      $lastErr = "$model : $($_.Exception.Message)"
    }
  }
  throw $lastErr
}

function Parse-Result([string]$text) {
  $s = $text.IndexOf("{"); $e = $text.LastIndexOf("}")
  if ($s -lt 0 -or $e -lt 0) { throw "模型没返回 JSON" }
  $o = $text.Substring($s, $e - $s + 1) | ConvertFrom-Json
  return @{
    original = [string]$o.original
    zh = [string]$o.zh
    en = [string]$o.en
    ja = [string]$o.ja
  }
}

Load-Settings

$uiBg = [System.Drawing.Color]::FromArgb(244, 247, 250)
$uiPaper = [System.Drawing.Color]::FromArgb(255, 255, 255)
$uiInk = [System.Drawing.Color]::FromArgb(31, 42, 55)
$uiMute = [System.Drawing.Color]::FromArgb(102, 112, 133)
$uiLine = [System.Drawing.Color]::FromArgb(208, 213, 221)
$uiBrand = [System.Drawing.Color]::FromArgb(37, 99, 235)
$uiHover = [System.Drawing.Color]::FromArgb(234, 240, 255)
$uiOk = [System.Drawing.Color]::FromArgb(15, 118, 110)
$uiErr = [System.Drawing.Color]::FromArgb(220, 38, 38)
$uiPreview = [System.Drawing.Color]::FromArgb(232, 238, 245)
$uiFont = New-Object System.Drawing.Font "Microsoft YaHei UI", 9

$form = New-Object OcrHotKeyForm
$form.Text = "截屏识别翻译"
$form.Size = New-Object System.Drawing.Size 1000, 800
$form.MinimumSize = New-Object System.Drawing.Size 960, 740
$form.StartPosition = "CenterScreen"
$form.KeyPreview = $true
$form.BackColor = $uiBg
$form.ForeColor = $uiInk
$form.Font = $uiFont

function New-Lbl($text, $x, $y, $w=120, $h=22) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $text; $l.Location = New-Object System.Drawing.Point $x, $y
  $l.Size = New-Object System.Drawing.Size $w, $h
  $l.ForeColor = $uiMute
  $l.BackColor = [System.Drawing.Color]::Transparent
  $form.Controls.Add($l); return $l
}
function New-Btn($text, $x, $y, $w=90, $h=28) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text; $b.Location = New-Object System.Drawing.Point $x, $y
  $b.Size = New-Object System.Drawing.Size $w, $h
  $b.FlatStyle = "Flat"
  $b.BackColor = $uiPaper
  $b.ForeColor = $uiInk
  $b.FlatAppearance.BorderColor = $uiLine
  $b.FlatAppearance.MouseOverBackColor = $uiHover
  $b.Cursor = [System.Windows.Forms.Cursors]::Hand
  $form.Controls.Add($b); return $b
}
function New-Box($x, $y, $w, $h, $multi=$false, $pwd=$false) {
  $t = New-Object System.Windows.Forms.TextBox
  $t.Location = New-Object System.Drawing.Point $x, $y
  $t.Size = New-Object System.Drawing.Size $w, $h
  $t.Multiline = $multi
  $t.ScrollBars = if ($multi) { "Vertical" } else { "None" }
  $t.UseSystemPasswordChar = $pwd
  $t.BackColor = $uiPaper
  $t.ForeColor = $uiInk
  $t.BorderStyle = "FixedSingle"
  if ($multi) { $t.Font = New-Object System.Drawing.Font "Microsoft YaHei UI", 10 }
  $form.Controls.Add($t); return $t
}

New-Lbl "本机单窗口。Key 不落盘。无后台进程。网络只打 DeepSeek / Groq 官网。关掉窗口即退出。" 12 8 960 20 | Out-Null
$btnShot = New-Btn "截屏识别" 12 36 108 32
$btnShot.BackColor = $uiBrand
$btnShot.ForeColor = [System.Drawing.Color]::White
$btnShot.FlatAppearance.BorderColor = $uiBrand
$btnShot.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
$btnFile = New-Btn "打开图片" 126 36 90 32
$cmbEngine = New-Object System.Windows.Forms.ComboBox
$cmbEngine.DropDownStyle = "DropDownList"
$cmbEngine.Location = New-Object System.Drawing.Point 222, 40
$cmbEngine.Size = New-Object System.Drawing.Size 168, 28
$cmbEngine.FlatStyle = "Flat"
$cmbEngine.BackColor = $uiPaper
$cmbEngine.ForeColor = $uiInk
[void]$cmbEngine.Items.Add("DeepSeek（便宜）")
[void]$cmbEngine.Items.Add("Groq（快）")
$cmbEngine.SelectedIndex = $(if ($script:engine -eq "groq") { 1 } else { 0 })
$form.Controls.Add($cmbEngine)
$cmbTarget = New-Object System.Windows.Forms.ComboBox
$cmbTarget.DropDownStyle = "DropDownList"
$cmbTarget.Location = New-Object System.Drawing.Point 396, 40
$cmbTarget.Size = New-Object System.Drawing.Size 148, 28
$cmbTarget.FlatStyle = "Flat"
$cmbTarget.BackColor = $uiPaper
$cmbTarget.ForeColor = $uiInk
[void]$cmbTarget.Items.AddRange(@("双向：中英都出","只译中文","只译英文"))
$cmbTarget.SelectedIndex = $(switch ($script:target) { "zh" { 1 } "en" { 2 } default { 0 } })
$form.Controls.Add($cmbTarget)
$lblHk = New-Lbl ("截屏快捷键：" + $script:hotkeys.capture) 552 44 420 22

$pic = New-Object System.Windows.Forms.PictureBox
$pic.Location = New-Object System.Drawing.Point 12, 76
$pic.Size = New-Object System.Drawing.Size 960, 92
$pic.SizeMode = "Zoom"
$pic.BorderStyle = "FixedSingle"
$pic.BackColor = $uiPreview
$form.Controls.Add($pic)
$status = New-Lbl "可以先不填 Key，先测截屏。要识字时再临时填。" 12 166 940 20

New-Lbl "原文（左边）" 12 190 200 20 | Out-Null
$btnCopyOrig = New-Btn "复制原文" 220 186 80 24
$orig = New-Box 12 212 470 280 $true
$orig.Font = New-Object System.Drawing.Font "Consolas", 10
New-Lbl "译文（右边，点这里回原文）" 498 190 260 20 | Out-Null
$btnZh = New-Btn "中文" 760 186 50 24
$btnEn = New-Btn "英文" 812 186 50 24
$btnBack = New-Btn "回到原文" 864 186 88 24
$btnCopyTrans = New-Btn "复制译文" 764 160 88 24
$trans = New-Box 498 212 454 280 $true
$trans.ReadOnly = $true

New-Lbl "DeepSeek Key（本次内存，不保存）" 12 500 280 20 | Out-Null
$txtDs = New-Box 12 522 460 26 $false $true
New-Lbl "Groq Key（选填，同样不保存）" 498 500 280 20 | Out-Null
$txtGq = New-Box 498 522 454 26 $false $true

New-Lbl "自定义快捷键：点录制再按组合，至少带 Ctrl/Shift/Alt。只存按键，不存 Key。" 12 556 700 20 | Out-Null
New-Lbl "截屏" 12 580 50 22 | Out-Null
$hkCap = New-Box 62 578 140 24
$btnRecCap = New-Btn "录制" 208 576 50 26
New-Lbl "复制原文" 270 580 70 22 | Out-Null
$hkCo = New-Box 340 578 140 24
$btnRecCo = New-Btn "录制" 486 576 50 26
New-Lbl "复制译文" 546 580 70 22 | Out-Null
$hkCt = New-Box 616 578 140 24
$btnRecCt = New-Btn "录制" 762 576 50 26
New-Lbl "回原文" 12 612 50 22 | Out-Null
$hkBo = New-Box 62 610 140 24
$btnRecBo = New-Btn "录制" 208 608 50 26

foreach ($c in @($form.Controls)) { $c.Top += 56 }
$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point 0, 0
$header.Size = New-Object System.Drawing.Size 1000, 56
$header.Anchor = "Top,Left,Right"
$header.BackColor = $uiPaper
$form.Controls.Add($header)
$headerTitle = New-Object System.Windows.Forms.Label
$headerTitle.Text = "截屏识别翻译"
$headerTitle.Font = New-Object System.Drawing.Font "Microsoft YaHei UI", 14, [System.Drawing.FontStyle]::Bold
$headerTitle.ForeColor = $uiInk
$headerTitle.Location = New-Object System.Drawing.Point 16, 6
$headerTitle.Size = New-Object System.Drawing.Size 360, 28
$header.Controls.Add($headerTitle)
$headerSub = New-Object System.Windows.Forms.Label
$headerSub.Text = "框选即译 · 复制免费 · Key 只留在本次窗口 · 关掉即退出"
$headerSub.ForeColor = $uiMute
$headerSub.Location = New-Object System.Drawing.Point 18, 32
$headerSub.Size = New-Object System.Drawing.Size 640, 20
$header.Controls.Add($headerSub)
$headerLine = New-Object System.Windows.Forms.Panel
$headerLine.BackColor = $uiBrand
$headerLine.Location = New-Object System.Drawing.Point 0, 54
$headerLine.Size = New-Object System.Drawing.Size 1000, 2
$headerLine.Anchor = "Top,Left,Right"
$header.Controls.Add($headerLine)

function Show-HotkeyBoxes {
  $hkCap.Text = $script:hotkeys.capture
  $hkCo.Text = $script:hotkeys.copyOrig
  $hkCt.Text = $script:hotkeys.copyTrans
  $hkBo.Text = $script:hotkeys.backOrig
  $lblHk.Text = "截屏快捷键：" + $script:hotkeys.capture
}
Show-HotkeyBoxes

function Current-Trans {
  if ($script:transSide -eq "en") { return $script:last.en }
  return $script:last.zh
}
function Show-Trans {
  $trans.Text = Current-Trans
}
function Back-ToOrig {
  $orig.Focus()
  $status.Text = "已回到原文"
  $status.ForeColor = $uiOk
}

function Close-InPlace {
  if ($script:bubble -and -not $script:bubble.IsDisposed) {
    $script:bubble.Close()
    $script:bubble.Dispose()
  }
  $script:bubble = $null
}

function Refresh-InPlaceText {
  if (-not $script:bubble -or $script:bubble.IsDisposed) { return }
  $box = $script:bubble.Controls["txtFloat"]
  if (-not $box) { return }
  if ($script:bubbleMode -eq "orig") { $box.Text = $script:last.original }
  else { $box.Text = (Current-Trans) }
}

function Show-InPlace($hint) {
  Close-InPlace
  if ($script:capW -lt 8) { return }
  $wa = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point $script:capX, $script:capY)).WorkingArea
  $w = [Math]::Max($script:capW, 280)
  $h = [Math]::Max($script:capH, 120) + 36
  if ($w -gt $wa.Width) { $w = $wa.Width }
  if ($h -gt [Math]::Min(420, $wa.Height)) { $h = [Math]::Min(420, $wa.Height) }
  $x = $script:capX
  $y = $script:capY
  if ($x + $w -gt $wa.Right) { $x = $wa.Right - $w }
  if ($y + $h -gt $wa.Bottom) { $y = $wa.Bottom - $h }
  if ($x -lt $wa.Left) { $x = $wa.Left }
  if ($y -lt $wa.Top) { $y = $wa.Top }

  $f = New-Object System.Windows.Forms.Form
  $f.FormBorderStyle = "None"
  $f.StartPosition = "Manual"
  $f.Bounds = New-Object System.Drawing.Rectangle $x, $y, $w, $h
  $f.TopMost = $true
  $f.ShowInTaskbar = $false
  $f.BackColor = $uiPaper
  $f.KeyPreview = $true
  $f.Padding = New-Object System.Windows.Forms.Padding 0

  $bar = New-Object System.Windows.Forms.Panel
  $bar.Dock = "Top"
  $bar.Height = 36
  $bar.BackColor = [System.Drawing.Color]::FromArgb(239, 246, 255)
  $f.Controls.Add($bar)

  function Add-BarBtn($text, $left, $click) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point $left, 5
    $b.Size = New-Object System.Drawing.Size 58, 26
    $b.FlatStyle = "Flat"
    $b.ForeColor = $uiInk
    $b.BackColor = $uiPaper
    $b.FlatAppearance.BorderColor = $uiLine
    $b.FlatAppearance.MouseOverBackColor = $uiHover
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Add_Click($click)
    $bar.Controls.Add($b)
    return $b
  }
  Add-BarBtn "译文" 4 { $script:bubbleMode = "trans"; Refresh-InPlaceText } | Out-Null
  Add-BarBtn "原文" 62 { $script:bubbleMode = "orig"; Refresh-InPlaceText } | Out-Null
  Add-BarBtn "复制" 120 {
    $t = $f.Controls["txtFloat"].Text
    if ($t) { [System.Windows.Forms.Clipboard]::SetText($t) }
  } | Out-Null
  $btnX = Add-BarBtn "关闭" ([Math]::Max(180, $w - 62)) { Close-InPlace }
  $btnX.Location = New-Object System.Drawing.Point ([Math]::Max(180, $w - 62)), 4

  $tip = New-Object System.Windows.Forms.Label
  $tip.Text = $hint
  $tip.Dock = "Top"
  $tip.Height = 18
  $tip.ForeColor = $uiMute
  $tip.BackColor = $uiPaper
  $f.Controls.Add($tip)

  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Name = "txtFloat"
  $tb.Multiline = $true
  $tb.ScrollBars = "Vertical"
  $tb.Dock = "Fill"
  $tb.ReadOnly = $true
  $tb.BorderStyle = "None"
  $tb.BackColor = $uiPaper
  $tb.ForeColor = $uiInk
  $tb.Font = New-Object System.Drawing.Font "Microsoft YaHei UI", 10
  $tb.Add_Click({
    if ($tb.SelectionLength -gt 0) { return }
    if ($script:bubbleMode -eq "trans") { $script:bubbleMode = "orig" } else { $script:bubbleMode = "trans" }
    Refresh-InPlaceText
  })
  $f.Controls.Add($tb)
  $tb.BringToFront()

  $f.Add_KeyDown({ if ($_.KeyCode -eq "Escape") { Close-InPlace } })
  $script:bubble = $f
  $script:bubbleMode = "trans"
  Refresh-InPlaceText
  $f.Show($form)
}

function Bind-CaptureHotkey {
  try { [OcrHotKeyForm]::UnregisterHotKey($form.Handle, $script:hotkeyId) | Out-Null } catch {}
  $p = Parse-Combo $script:hotkeys.capture
  if (-not $p) { return }
  $okHk = [OcrHotKeyForm]::RegisterHotKey($form.Handle, $script:hotkeyId, $p.mod, $p.vk)
  if (-not $okHk) { $status.Text = "截屏快捷键被占用：" + $script:hotkeys.capture }
}

function Apply-Engine {
  $script:engine = $(if ($cmbEngine.SelectedIndex -eq 1) { "groq" } else { "deepseek" })
  $script:target = $(switch ($cmbTarget.SelectedIndex) { 1 { "zh" } 2 { "en" } default { "both" } })
  Save-Settings
}

function Run-OcrFromBitmap($bmp, $inplace = $false) {
  if (-not $bmp) { $status.Text = "已取消截屏"; return }
  $pic.Image = $bmp
  $ds = $txtDs.Text.Trim(); $gq = $txtGq.Text.Trim()
  if (-not $ds -and -not $gq) {
    $orig.Text = ""; $trans.Text = ""
    $script:last = @{ original = ""; zh = "未填 Key。框已经在原处。要识字再临时填。"; en = "" }
    $status.Text = "框选可以。未填 Key，译文泡在原处，不调用识别。"
    $status.ForeColor = $uiMute
    if ($inplace) { Show-InPlace "未填 Key，只在原处出框" }
    return
  }
  Apply-Engine
  $status.ForeColor = $uiMute
  $status.Text = "识别中，只请求官方 API..."
  $form.Refresh()
  $dataUrl = Bitmap-ToDataUrl $bmp
  try {
    if ($script:engine -eq "groq") {
      if (-not $gq) { throw "还没填 Groq Key" }
      $r = Call-Chat "https://api.groq.com/openai/v1" $gq @("qwen/qwen3.6-27b","qwen/qwen3.8-27b","meta-llama/llama-4-scout-17b-16e-instruct") $dataUrl
    } else {
      if (-not $ds) { throw "还没填 DeepSeek Key" }
      $r = Call-Chat "https://api.deepseek.com" $ds @("deepseek-v4-flash-vision-exp","deepseek-vl2","deepseek-chat") $dataUrl
    }
    $script:last = Parse-Result $r.text
    $orig.Text = $script:last.original
    if ($script:target -eq "en") { $script:transSide = "en" } else { $script:transSide = "zh" }
    Show-Trans
    $status.Text = "完成，译文在框选原处。点浮层可回原文。"
    if ($inplace) { Show-InPlace "点文字可回原文" } else { Show-InPlace "打开图片的结果" }
  } catch {
    $status.Text = $_.Exception.Message
    $status.ForeColor = $uiErr
    if ($inplace) {
      $script:last = @{ original = ""; zh = $_.Exception.Message; en = "" }
      Show-InPlace "识别失败"
    }
  }
}

$btnShot.Add_Click({ Run-OcrFromBitmap (Capture-Region) $true })
$btnFile.Add_Click({
  $d = New-Object System.Windows.Forms.OpenFileDialog
  $d.Filter = "图片|*.png;*.jpg;*.jpeg;*.bmp;*.webp"
  if ($d.ShowDialog() -eq "OK") {
    $bmp = [System.Drawing.Image]::FromFile($d.FileName)
    $pt = [System.Windows.Forms.Cursor]::Position
    $script:capX = $pt.X; $script:capY = $pt.Y; $script:capW = 360; $script:capH = 160
    Run-OcrFromBitmap $bmp $true
  }
})
$btnCopyOrig.Add_Click({
  if (-not $orig.Text) { $status.Text = "没有可复制的原文"; return }
  [System.Windows.Forms.Clipboard]::SetText($orig.Text)
  $status.Text = "已复制原文"
})
$btnCopyTrans.Add_Click({
  $t = Current-Trans
  if (-not $t) { $status.Text = "没有可复制的译文"; return }
  [System.Windows.Forms.Clipboard]::SetText($t)
  $status.Text = "已复制译文"
})
$btnBack.Add_Click({ Back-ToOrig })
$btnZh.Add_Click({ $script:transSide = "zh"; Show-Trans })
$btnEn.Add_Click({ $script:transSide = "en"; Show-Trans })
$trans.Add_Click({
  if ($trans.SelectionLength -gt 0) { return }
  Back-ToOrig
})
$cmbEngine.Add_SelectedIndexChanged({ Apply-Engine })
$cmbTarget.Add_SelectedIndexChanged({ Apply-Engine })

function Start-Record($name) {
  $script:recording = $name
  $status.Text = "正在录制快捷键，按组合。Esc 取消。"
}
$btnRecCap.Add_Click({ Start-Record "capture" })
$btnRecCo.Add_Click({ Start-Record "copyOrig" })
$btnRecCt.Add_Click({ Start-Record "copyTrans" })
$btnRecBo.Add_Click({ Start-Record "backOrig" })

$form.Add_KeyDown({
  if ($script:recording) {
    if ($_.KeyCode -eq "Escape") {
      $script:recording = $null
      Show-HotkeyBoxes
      $status.Text = "已取消录制"
      return
    }
    $combo = Combo-FromKeyEvent $_
    if (-not (Combo-Valid $combo)) { return }
    $_.SuppressKeyPress = $true
    $script:hotkeys[$script:recording] = $combo
    $script:recording = $null
    Show-HotkeyBoxes
    Save-Settings
    Bind-CaptureHotkey
    $status.Text = "快捷键已更新：$combo"
    return
  }
  $onBox = [System.Windows.Forms.Form]::ActiveControl -is [System.Windows.Forms.TextBox]
  if ($onBox) { return }
  if (Event-Matches $_ $script:hotkeys.capture) { $_.SuppressKeyPress = $true; Run-OcrFromBitmap (Capture-Region) $true }
  elseif (Event-Matches $_ $script:hotkeys.copyOrig) { $btnCopyOrig.PerformClick() }
  elseif (Event-Matches $_ $script:hotkeys.copyTrans) { $btnCopyTrans.PerformClick() }
  elseif (Event-Matches $_ $script:hotkeys.backOrig) { Back-ToOrig }
})

$form.Add_CaptureHotKey({ Run-OcrFromBitmap (Capture-Region) $true })
$form.Add_Shown({ Bind-CaptureHotkey })
$form.Add_FormClosed({
  Close-InPlace
  try { [OcrHotKeyForm]::UnregisterHotKey($form.Handle, $script:hotkeyId) | Out-Null } catch {}
  $txtDs.Text = ""; $txtGq.Text = ""
})

[void]$form.ShowDialog()
