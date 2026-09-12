# 本地截屏识别翻译。一个窗口、一个进程，关掉就退出。
# Key 只在密码框内存里，不写文件、不写注册表、不写日志。
# 网络只打 https://api.deepseek.com 和 https://api.groq.com。
# 没有本机 HTTP 服务，没有常驻后台脚本。

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
trap {
  try { [void][System.Windows.Forms.MessageBox]::Show([string]$_, "启动失败") } catch {}
  break
}

function New-UiFont([single]$size, [bool]$bold = $false) {
  $style = [System.Drawing.FontStyle]::Regular
  if ($bold) { $style = [System.Drawing.FontStyle]::Bold }
  foreach ($name in @("Microsoft YaHei", "微软雅黑", "Microsoft YaHei UI", "Segoe UI")) {
    try { return New-Object -TypeName System.Drawing.Font -ArgumentList @($name, $size, $style) } catch {}
  }
  return New-Object -TypeName System.Drawing.Font -ArgumentList @("Arial", $size)
}

# 下面这一小段 C# 只做一件事：让窗口能接收系统快捷键。
# ReferencedAssemblies = 引用本机已有的窗口库，不从网上拉包。
# @" ... "@ 是 PowerShell 多行字符串，把这段 C# 嵌进来编译。不是业务代码，也不是密钥。
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
    if (m.Msg == WM_HOTKEY) {
      int id = m.WParam.ToInt32();
      if (id == 0x4F43 && CaptureHotKey != null) CaptureHotKey(this, EventArgs.Empty);
      if (id == 0x4F44 && ShowHotKey != null) ShowHotKey(this, EventArgs.Empty);
    }
    base.WndProc(ref m);
  }
  public event EventHandler ShowHotKey;
}
"@
[OcrHotKeyForm]::SetProcessDPIAware() | Out-Null

$script:settingsPath = Join-Path $env:APPDATA "ocr-translate\settings.json"
$script:hotkeys = @{
  capture = "Ctrl+Shift+S"
  copyOrig = "Ctrl+Shift+C"
  copyTrans = "Ctrl+Shift+T"
  backOrig = "Ctrl+Shift+B"
  showWin = "Ctrl+Shift+H"
}
$script:engine = "deepseek"
$script:target = "zh"
$script:langList = @(
  @{ code = "zh"; menu = "译成中文"; prompt = "Simplified Chinese" },
  @{ code = "en"; menu = "译成英文"; prompt = "English" },
  @{ code = "ja"; menu = "译成日文"; prompt = "Japanese" },
  @{ code = "ko"; menu = "译成韩文"; prompt = "Korean" },
  @{ code = "fr"; menu = "译成法文"; prompt = "French" },
  @{ code = "de"; menu = "译成德文"; prompt = "German" },
  @{ code = "es"; menu = "译成西班牙文"; prompt = "Spanish" },
  @{ code = "ru"; menu = "译成俄文"; prompt = "Russian" },
  @{ code = "ar"; menu = "译成阿拉伯文"; prompt = "Arabic" },
  @{ code = "pt"; menu = "译成葡萄牙文"; prompt = "Portuguese" },
  @{ code = "vi"; menu = "译成越南文"; prompt = "Vietnamese" },
  @{ code = "th"; menu = "译成泰文"; prompt = "Thai" },
  @{ code = "id"; menu = "译成印尼文"; prompt = "Indonesian" },
  @{ code = "it"; menu = "译成意大利文"; prompt = "Italian" }
)
$script:last = @{ original = ""; trans = ""; zh = ""; en = "" }
$script:recording = $null
$script:hotkeyId = 0x4F43
$script:showHotkeyId = 0x4F44
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
  if ($obj.target) {
    $t = [string]$obj.target
    if ($t -eq "both") { $t = "zh" }
    $ok = $false
    foreach ($item in $script:langList) { if ($item.code -eq $t) { $ok = $true; break } }
    if ($ok) { $script:target = $t }
  }
  foreach ($n in @("capture","copyOrig","copyTrans","backOrig","showWin")) {
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
    # 同样是本机窗口库引用，用来读屏幕范围和鼠标按键。@"..."@ 仍是多行字符串。
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
  $edgeT = $null; $edgeB = $null; $edgeL = $null; $edgeR = $null
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
    $tip.Size = New-Object System.Drawing.Size 280, 36
    $tip.TopMost = $true
    $tip.ShowInTaskbar = $false
    $tip.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
    $tipLbl = New-Object System.Windows.Forms.Label
    $tipLbl.Text = "拖框选区，Esc 取消"
    $tipLbl.Dock = "Fill"
    $tipLbl.TextAlign = "MiddleCenter"
    $tipLbl.Font = New-UiFont 10
    $tipLbl.ForeColor = [System.Drawing.Color]::FromArgb(31, 42, 55)
    $tip.Controls.Add($tipLbl)
    function Place-CaptureTip([System.Drawing.Point]$p) {
      $wa = [System.Windows.Forms.Screen]::FromPoint($p).WorkingArea
      $tx = $wa.Left + [int](($wa.Width - $tip.Width) / 2)
      $ty = $wa.Top + 16
      $tip.Location = New-Object System.Drawing.Point $tx, $ty
    }
    Place-CaptureTip ([System.Windows.Forms.Cursor]::Position)
    $tip.Show()
    $tip.BringToFront()

    function New-EdgeForm {
      $e = New-Object System.Windows.Forms.Form
      $e.FormBorderStyle = "None"
      $e.StartPosition = "Manual"
      $e.TopMost = $true
      $e.ShowInTaskbar = $false
      $e.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
      $e.Opacity = 0.9
      $e.Enabled = $false
      return $e
    }
    $edgeT = New-EdgeForm
    $edgeB = New-EdgeForm
    $edgeL = New-EdgeForm
    $edgeR = New-EdgeForm
    $script:selThick = 3
    function Show-SelBox($x, $y, $w, $h) {
      $t = [int]$script:selThick
      if ($w -lt $t) { $w = $t }
      if ($h -lt $t) { $h = $t }
      $edgeT.Bounds = New-Object System.Drawing.Rectangle $x, $y, $w, $t
      $edgeB.Bounds = New-Object System.Drawing.Rectangle $x, ($y + $h - $t), $w, $t
      $edgeL.Bounds = New-Object System.Drawing.Rectangle $x, $y, $t, $h
      $edgeR.Bounds = New-Object System.Drawing.Rectangle ($x + $w - $t), $y, $t, $h
      foreach ($e in @($edgeT, $edgeB, $edgeL, $edgeR)) {
        if (-not $e.Visible) { $e.Show() }
      }
    }

    function Key-Down($vk) {
      return ([ScreenMetrics]::GetAsyncKeyState([int]$vk) -band 0x8000) -ne 0
    }
    $t0 = [Environment]::TickCount
    while (Key-Down 0x01) {
      $p = [System.Windows.Forms.Cursor]::Position
      Place-CaptureTip $p
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 10
      if (([Environment]::TickCount - $t0) -gt 8000) { break }
    }
    $t0 = [Environment]::TickCount
    $got = $false
    while (-not $got) {
      if (Key-Down 0x1B) { return $null }
      $p = [System.Windows.Forms.Cursor]::Position
      Place-CaptureTip $p
      if (Key-Down 0x01) {
        $got = $true
        $script:startX = $p.X
        $script:startY = $p.Y
        Show-SelBox $p.X $p.Y 3 3
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
      Show-SelBox $x $y $w $h
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
    foreach ($e in @($edgeT, $edgeB, $edgeL, $edgeR)) {
      try { if ($e) { $e.Close(); $e.Dispose() } } catch {}
    }
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

function Current-LangPrompt {
  foreach ($item in $script:langList) {
    if ($item.code -eq $script:target) { return $item.prompt }
  }
  return "Simplified Chinese"
}

function Ocr-Prompt {
  $lang = Current-LangPrompt
  return @"
You are a screenshot OCR engine for software UI, terminals, logs, and source code.
The user MUST verify AI-written code. Do not skip identifiers.

1) "original": copy EVERY visible character exactly. Do NOT insert spaces into identifiers (getUserName, HttpResponse, FILE_NOT_FOUND, PluginSalesStrategy). Keep camelCase/PascalCase/snake_case and line breaks. No markdown.

2) "trans": translate into $lang so a human can check meaning.
   - Natural-language sentences: normal translation.
   - Identifiers / program names / API names: split the glued words, then translate. Example: getUserName -> 获取用户名 ; PluginSalesStrategy -> 插件销售策略 ; FILE_NOT_FOUND -> 未找到文件.
   - After the translation, you may put the original identifier in parentheses once.
   - File names and bare paths (System Volume Information, FirPE.exe) are not sentences; trans may stay close to the original name.
   - Paths and URLs: keep the path symbols. Do not invent a sentence around a file name.

Never leave identifiers unchanged in trans just because they look like code.
Return JSON only: {"original":"...","trans":"..."}
"@
}

function Repair-Utf8Mojibake([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return $s }
  if ($s -match '[\u4e00-\u9fff]') { return $s }
  foreach ($cp in @(28591, 1252)) {
    try {
      $bytes = [System.Text.Encoding]::GetEncoding($cp).GetBytes($s)
      $fixed = [System.Text.Encoding]::UTF8.GetString($bytes)
      if ($fixed -match '[\u4e00-\u9fff]') { return $fixed }
    } catch {}
  }
  return $s
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
      $wr = Invoke-WebRequest -Method Post -Uri ($baseUrl.TrimEnd("/") + "/chat/completions") -Headers @{
        Authorization = "Bearer $apiKey"
      } -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 90
      $ms = New-Object System.IO.MemoryStream
      $wr.RawContentStream.Position = 0
      $wr.RawContentStream.CopyTo($ms)
      $raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
      $res = $raw | ConvertFrom-Json
      $text = [string]$res.choices[0].message.content
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
  $tr = Repair-Utf8Mojibake ([string]$o.trans)
  if (-not $tr) { $tr = Repair-Utf8Mojibake ([string]$o.zh) }
  if (-not $tr) { $tr = Repair-Utf8Mojibake ([string]$o.en) }
  return @{
    original = Repair-Utf8Mojibake ([string]$o.original)
    trans = $tr
    zh = $tr
    en = $tr
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
$uiFont = New-UiFont 10.5

$form = New-Object OcrHotKeyForm
$form.Text = "截屏识别翻译"
$form.Size = New-Object System.Drawing.Size 1100, 1020
$form.MinimumSize = New-Object System.Drawing.Size 1040, 960
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
  $b.FlatAppearance.BorderSize = 2
  $b.FlatAppearance.MouseOverBackColor = $uiHover
  $b.Cursor = [System.Windows.Forms.Cursors]::Hand
  $form.Controls.Add($b); return $b
}
function New-Box($x, $y, $w, $h, $multi=$false, $pwd=$false) {
  $frame = New-Object System.Windows.Forms.Panel
  $frame.Location = New-Object System.Drawing.Point $x, $y
  $frame.Size = New-Object System.Drawing.Size $w, $h
  $frame.BackColor = $uiLine
  $frame.Padding = New-Object System.Windows.Forms.Padding 2
  $form.Controls.Add($frame)
  $t = New-Object System.Windows.Forms.TextBox
  $t.Dock = "Fill"
  $t.Multiline = $multi
  $t.ScrollBars = if ($multi) { "Vertical" } else { "None" }
  $t.UseSystemPasswordChar = $pwd
  $t.BackColor = $uiPaper
  $t.ForeColor = $uiInk
  $t.BorderStyle = "None"
  if ($multi) { $t.Font = New-UiFont 11 }
  $frame.Controls.Add($t)
  return $t
}

New-Lbl "本机单窗口。Key 不落盘。无后台进程。网络只打 DeepSeek / Groq 官网。关掉窗口即退出。" 16 16 980 24 | Out-Null
$btnShot = New-Btn "截屏识别" 16 52 120 34
$btnShot.BackColor = $uiBrand
$btnShot.ForeColor = [System.Drawing.Color]::White
$btnShot.FlatAppearance.BorderColor = $uiBrand
$btnShot.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
$btnFile = New-Btn "打开图片" 148 52 100 34
$cmbEngine = New-Object System.Windows.Forms.ComboBox
$cmbEngine.DropDownStyle = "DropDownList"
$cmbEngine.Location = New-Object System.Drawing.Point 264, 56
$cmbEngine.Size = New-Object System.Drawing.Size 168, 28
$cmbEngine.FlatStyle = "Flat"
$cmbEngine.BackColor = $uiPaper
$cmbEngine.ForeColor = $uiInk
[void]$cmbEngine.Items.Add("DeepSeek")
[void]$cmbEngine.Items.Add("Groq")
$cmbEngine.SelectedIndex = $(if ($script:engine -eq "groq") { 1 } else { 0 })
$form.Controls.Add($cmbEngine)
$cmbTarget = New-Object System.Windows.Forms.ComboBox
$cmbTarget.DropDownStyle = "DropDownList"
$cmbTarget.Location = New-Object System.Drawing.Point 448, 56
$cmbTarget.Size = New-Object System.Drawing.Size 168, 28
$cmbTarget.FlatStyle = "Flat"
$cmbTarget.BackColor = $uiPaper
$cmbTarget.ForeColor = $uiInk
$ti = 0
for ($i = 0; $i -lt $script:langList.Count; $i++) {
  [void]$cmbTarget.Items.Add($script:langList[$i].menu)
  if ($script:langList[$i].code -eq $script:target) { $ti = $i }
}
$cmbTarget.SelectedIndex = $ti
$form.Controls.Add($cmbTarget)
$lblHk = New-Lbl ("截屏快捷键：" + $script:hotkeys.capture) 640 60 360 22

$picFrame = New-Object System.Windows.Forms.Panel
$picFrame.Location = New-Object System.Drawing.Point 16, 102
$picFrame.Size = New-Object System.Drawing.Size 972, 88
$picFrame.BackColor = $uiLine
$picFrame.Padding = New-Object System.Windows.Forms.Padding 2
$form.Controls.Add($picFrame)
$pic = New-Object System.Windows.Forms.PictureBox
$pic.Dock = "Fill"
$pic.SizeMode = "Zoom"
$pic.BorderStyle = "None"
$pic.BackColor = $uiPreview
$picFrame.Controls.Add($pic)
$status = New-Lbl "可以先不填 Key，先测截屏。要识字时再临时填。" 16 204 700 22

$lblOrigTitle = New-Lbl "原文（左边）" 16 236 300 26
$lblOrigTitle.AutoSize = $true
$btnCopyOrig = New-Btn "复制原文" 16 266 120 30
$orig = New-Box 16 304 520 240 $true
try {
  $orig.Font = New-Object -TypeName System.Drawing.Font -ArgumentList @("Cascadia Mono", [single]11)
} catch {
  $orig.Font = New-Object -TypeName System.Drawing.Font -ArgumentList @("Consolas", [single]11)
}
$lblTransTitle = New-Lbl "译文（右边）" 556 236 300 26
$lblTransTitle.AutoSize = $true
$btnCopyTrans = New-Btn "复制译文" 556 266 120 30
$btnBack = New-Btn "回到原文" 688 266 120 30
$trans = New-Box 556 304 520 240 $true
$trans.ReadOnly = $true

New-Lbl "DeepSeek Key（本次内存，不保存）" 16 560 360 22 | Out-Null
$txtDs = New-Box 16 586 520 30 $false $true
New-Lbl "Groq Key（选填，同样不保存）" 556 560 360 22 | Out-Null
$txtGq = New-Box 556 586 520 30 $false $true

New-Lbl "自定义快捷键：点录制再按组合，至少带 Ctrl/Shift/Alt。只存按键，不存 Key。" 16 640 1060 24 | Out-Null
New-Lbl "截屏" 16 680 56 24 | Out-Null
$hkCap = New-Box 76 678 180 30
$btnRecCap = New-Btn "录制" 264 676 60 32
New-Lbl "复制原文" 356 680 80 24 | Out-Null
$hkCo = New-Box 440 678 180 30
$btnRecCo = New-Btn "录制" 628 676 60 32
New-Lbl "复制译文" 16 732 80 24 | Out-Null
$hkCt = New-Box 96 730 180 30
$btnRecCt = New-Btn "录制" 284 728 60 32
New-Lbl "回原文" 356 732 70 24 | Out-Null
$hkBo = New-Box 430 730 180 30
$btnRecBo = New-Btn "录制" 618 728 60 32
New-Lbl "呼出" 16 784 56 24 | Out-Null
$hkShow = New-Box 76 782 180 30
$btnRecShow = New-Btn "录制" 264 780 60 32

foreach ($c in @($form.Controls)) { $c.Top += 88 }
$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point 0, 0
$header.Size = New-Object System.Drawing.Size 1100, 88
$header.Anchor = "Top,Left,Right"
$header.BackColor = $uiPaper
$form.Controls.Add($header)
$headerTitle = New-Object System.Windows.Forms.Label
$headerTitle.Text = "截屏识别翻译"
$headerTitle.Font = New-UiFont 16 $true
$headerTitle.ForeColor = $uiInk
$headerTitle.AutoSize = $true
$headerTitle.Location = New-Object System.Drawing.Point 18, 14
$header.Controls.Add($headerTitle)
$headerSub = New-Object System.Windows.Forms.Label
$headerSub.Text = "框选即译 · 复制免费 · Key 只留在本次窗口 · 关掉即退出"
$headerSub.ForeColor = $uiMute
$headerSub.AutoSize = $true
$headerSub.Location = New-Object System.Drawing.Point 18, 52
$header.Controls.Add($headerSub)
$headerLine = New-Object System.Windows.Forms.Panel
$headerLine.BackColor = $uiBrand
$headerLine.Location = New-Object System.Drawing.Point 0, 85
$headerLine.Size = New-Object System.Drawing.Size 1100, 3
$headerLine.Anchor = "Top,Left,Right"
$header.Controls.Add($headerLine)

function Show-HotkeyBoxes {
  $hkCap.Text = $script:hotkeys.capture
  $hkCo.Text = $script:hotkeys.copyOrig
  $hkCt.Text = $script:hotkeys.copyTrans
  $hkBo.Text = $script:hotkeys.backOrig
  $hkShow.Text = $script:hotkeys.showWin
  $lblHk.Text = "截屏快捷键：" + $script:hotkeys.capture
}
Show-HotkeyBoxes

function Current-Trans {
  if ($script:last.trans) { return $script:last.trans }
  if ($script:last.zh) { return $script:last.zh }
  return $script:last.en
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
  $w = [Math]::Max($script:capW, 340)
  $h = [Math]::Max($script:capH, 120) + 76
  if ($w -gt $wa.Width) { $w = $wa.Width }
  if ($h -gt [Math]::Min(460, $wa.Height)) { $h = [Math]::Min(460, $wa.Height) }
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

  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Name = "txtFloat"
  $tb.Multiline = $true
  $tb.ScrollBars = "Vertical"
  $tb.Dock = "Fill"
  $tb.ReadOnly = $true
  $tb.BorderStyle = "None"
  $tb.BackColor = $uiPaper
  $tb.ForeColor = $uiInk
  $tb.Font = New-UiFont 11
  $tb.Add_Click({
    if ($tb.SelectionLength -gt 0) { return }
    if ($script:bubbleMode -eq "trans") { $script:bubbleMode = "orig" } else { $script:bubbleMode = "trans" }
    Refresh-InPlaceText
  })
  $f.Controls.Add($tb)

  $bar = New-Object System.Windows.Forms.Panel
  $bar.Dock = "Top"
  $bar.Height = 40
  $bar.BackColor = [System.Drawing.Color]::FromArgb(239, 246, 255)
  $f.Controls.Add($bar)

  $titleBar = New-Object System.Windows.Forms.Panel
  $titleBar.Dock = "Top"
  $titleBar.Height = 36
  $titleBar.BackColor = $uiPaper
  $f.Controls.Add($titleBar)

  $title = New-Object System.Windows.Forms.Label
  $title.Text = "截屏识别翻译"
  $title.Font = New-UiFont 12 $true
  $title.ForeColor = $uiInk
  $title.AutoSize = $true
  $title.Location = New-Object System.Drawing.Point 10, 8
  $titleBar.Controls.Add($title)

  $hintLbl = New-Object System.Windows.Forms.Label
  $hintLbl.Text = $hint
  $hintLbl.ForeColor = $uiMute
  $hintLbl.AutoSize = $true
  $hintLbl.Location = New-Object System.Drawing.Point 130, 10
  $titleBar.Controls.Add($hintLbl)

  function Add-BarBtn($text, $left, $click) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point $left, 6
    $b.Size = New-Object System.Drawing.Size 58, 26
    $b.FlatStyle = "Flat"
    $b.ForeColor = $uiInk
    $b.BackColor = $uiPaper
    $b.FlatAppearance.BorderColor = $uiLine
    $b.FlatAppearance.BorderSize = 2
    $b.FlatAppearance.MouseOverBackColor = $uiHover
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Add_Click($click)
    $bar.Controls.Add($b)
    return $b
  }
  Add-BarBtn "译文" 8 { $script:bubbleMode = "trans"; Refresh-InPlaceText } | Out-Null
  Add-BarBtn "原文" 70 { $script:bubbleMode = "orig"; Refresh-InPlaceText } | Out-Null
  Add-BarBtn "复制" 132 {
    $t = $f.Controls["txtFloat"].Text
    if ($t) { [System.Windows.Forms.Clipboard]::SetText($t) }
  } | Out-Null
  Add-BarBtn "关闭" ([Math]::Max(194, $w - 66)) { Close-InPlace } | Out-Null

  $f.Add_KeyDown({ if ($_.KeyCode -eq "Escape") { Close-InPlace } })
  $script:bubble = $f
  $script:bubbleMode = "trans"
  Refresh-InPlaceText
  $f.Show($form)
}

function Bind-Hotkeys {
  try { [OcrHotKeyForm]::UnregisterHotKey($form.Handle, $script:hotkeyId) | Out-Null } catch {}
  try { [OcrHotKeyForm]::UnregisterHotKey($form.Handle, $script:showHotkeyId) | Out-Null } catch {}
  $p = Parse-Combo $script:hotkeys.capture
  if ($p) {
    $okHk = [OcrHotKeyForm]::RegisterHotKey($form.Handle, $script:hotkeyId, $p.mod, $p.vk)
    if (-not $okHk) { $status.Text = "截屏快捷键被占用：" + $script:hotkeys.capture }
  }
  $p2 = Parse-Combo $script:hotkeys.showWin
  if ($p2) {
    $okShow = [OcrHotKeyForm]::RegisterHotKey($form.Handle, $script:showHotkeyId, $p2.mod, $p2.vk)
    if (-not $okShow) { $status.Text = "呼出快捷键被占用：" + $script:hotkeys.showWin }
  }
}

function Show-MainWindow {
  if ($form.WindowState -eq "Minimized") { $form.WindowState = "Normal" }
  $form.Show()
  $form.TopMost = $true
  $form.Activate()
  $form.BringToFront()
  $form.TopMost = $false
  $status.Text = "已呼出窗口"
  $status.ForeColor = $uiOk
  if ($script:bubble -and -not $script:bubble.IsDisposed) {
    $script:bubble.TopMost = $true
    $script:bubble.Activate()
  } elseif ($script:capW -ge 8 -and ($script:last.original -or $script:last.trans -or $script:last.zh)) {
    Show-InPlace "已呼出"
  }
}

function Apply-Engine {
  $script:engine = $(if ($cmbEngine.SelectedIndex -eq 1) { "groq" } else { "deepseek" })
  $idx = $cmbTarget.SelectedIndex
  if ($idx -ge 0 -and $idx -lt $script:langList.Count) { $script:target = $script:langList[$idx].code }
  Save-Settings
}

function Run-OcrFromBitmap($bmp, $inplace = $false) {
  if (-not $bmp) { $status.Text = "已取消截屏"; return }
  $pic.Image = $bmp
  $ds = $txtDs.Text.Trim(); $gq = $txtGq.Text.Trim()
  if (-not $ds -and -not $gq) {
    $orig.Text = ""; $trans.Text = ""
    $script:last = @{ original = ""; trans = "未填 Key。框已经在原处。要识字再临时填。"; zh = ""; en = "" }
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
    Show-Trans
    $status.Text = "完成，译文在框选原处。点浮层可回原文。"
    if ($inplace) { Show-InPlace "点文字可回原文" } else { Show-InPlace "打开图片的结果" }
  } catch {
    $status.Text = $_.Exception.Message
    $status.ForeColor = $uiErr
    if ($inplace) {
      $script:last = @{ original = ""; trans = $_.Exception.Message; zh = ""; en = "" }
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
$btnRecShow.Add_Click({ Start-Record "showWin" })

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
    Bind-Hotkeys
    $status.Text = "快捷键已更新：$combo"
    return
  }
  $onBox = [System.Windows.Forms.Form]::ActiveControl -is [System.Windows.Forms.TextBox]
  if ($onBox) { return }
  if (Event-Matches $_ $script:hotkeys.capture) { $_.SuppressKeyPress = $true; Run-OcrFromBitmap (Capture-Region) $true }
  elseif (Event-Matches $_ $script:hotkeys.copyOrig) { $btnCopyOrig.PerformClick() }
  elseif (Event-Matches $_ $script:hotkeys.copyTrans) { $btnCopyTrans.PerformClick() }
  elseif (Event-Matches $_ $script:hotkeys.backOrig) { Back-ToOrig }
  elseif (Event-Matches $_ $script:hotkeys.showWin) { $_.SuppressKeyPress = $true; Show-MainWindow }
})

$form.Add_CaptureHotKey({ Run-OcrFromBitmap (Capture-Region) $true })
$form.Add_ShowHotKey({ Show-MainWindow })
$form.Add_Shown({ Bind-Hotkeys })
$form.Add_FormClosed({
  Close-InPlace
  try { [OcrHotKeyForm]::UnregisterHotKey($form.Handle, $script:hotkeyId) | Out-Null } catch {}
  try { [OcrHotKeyForm]::UnregisterHotKey($form.Handle, $script:showHotkeyId) | Out-Null } catch {}
  $txtDs.Text = ""; $txtGq.Text = ""
})

[void]$form.ShowDialog()
