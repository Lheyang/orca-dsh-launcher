# ============================================================
#  Orca DSH Launcher - 公共逻辑库（托盘 / 控制台共用）
# ============================================================
#  本文件被 dsh-tray.ps1 和 dsh-console.ps1 用「点源」(.) 加载，
#  提供两边都要用的函数：读配置、启停服务器、检查更新、窗口辅助。
#  改逻辑只改这一处，托盘和控制台同时生效。
#
#  注意：本文件必须保存为 UTF-8 带 BOM（PowerShell 5.1 才能
#        正确解析中文）。
# ============================================================

# ---------- 共享状态（脚本级变量，点源后两边都能读） ----------
$script:orcaConfigFile = Join-Path $env:USERPROFILE '.dsh\orca-dsh-launcher.json'

# 默认配置（用户可改 ~/.dsh/orca-dsh-launcher.json 覆盖）
$script:orcaCfgDshDir    = 'D:\deepseek harness'
$script:orcaCfgPort      = 3080
$script:orcaCfgRepo      = 'deepseek-ai/deepseek-harness'
$script:orcaCfgBranch    = 'master'
$script:orcaCfgTimeoutMs = 8000
$script:orcaCfgTrayAutoStart = $true
$script:orcaCfgTheme     = 'dark'
$script:orcaCfgAccent    = 'blue'

# ============================================================
# 一、配置读写
# ============================================================

# 读取配置（文件不存在/损坏 → 用默认值），并刷新全局 $script:orcaCfg*
function Read-OrcaConfig {
    $script:orcaCfgDshDir    = 'D:\deepseek harness'
    $script:orcaCfgPort      = 3080
    $script:orcaCfgRepo      = 'deepseek-ai/deepseek-harness'
    $script:orcaCfgBranch    = 'master'
    $script:orcaCfgTimeoutMs = 8000
    $script:orcaCfgTrayAutoStart = $true
    $script:orcaCfgTheme     = 'dark'
    $script:orcaCfgAccent    = 'blue'

    if (Test-Path $script:orcaConfigFile) {
        try {
            $cfg = Get-Content $script:orcaConfigFile -Raw | ConvertFrom-Json
            if ($cfg.dshDir)         { $script:orcaCfgDshDir    = [string]$cfg.dshDir }
            if ($cfg.port)           { $script:orcaCfgPort      = [int]$cfg.port }
            if ($cfg.repo)           { $script:orcaCfgRepo      = [string]$cfg.repo }
            if ($cfg.branch)         { $script:orcaCfgBranch    = [string]$cfg.branch }
            if ($cfg.checkTimeoutMs) { $script:orcaCfgTimeoutMs = [int]$cfg.checkTimeoutMs }
            if ($null -ne $cfg.trayAutoStart) { $script:orcaCfgTrayAutoStart = [bool]$cfg.trayAutoStart }
            if ($cfg.theme -eq 'light' -or $cfg.theme -eq 'dark') { $script:orcaCfgTheme = [string]$cfg.theme }
            if ($cfg.accent -in @('green','blue','purple','amber','rose','slate')) { $script:orcaCfgAccent = [string]$cfg.accent }
        } catch {}
    }
}

# 写入配置（UTF-8 无 BOM，与插件 node 写入的格式一致）
function Write-OrcaConfig {
    param(
        [int]$Port,
        [string]$DshDir,
        [bool]$TrayAutoStart,
        [string]$Theme = 'dark',
        [string]$Accent = 'blue'
    )
    if ($Theme -ne 'light' -and $Theme -ne 'dark') { $Theme = 'dark' }
    if ($Accent -notin @('green','blue','purple','amber','rose','slate')) { $Accent = 'blue' }
    $cfg = [ordered]@{
        dshDir         = $DshDir
        port           = $Port
        repo           = $script:orcaCfgRepo
        branch         = $script:orcaCfgBranch
        checkTimeoutMs = $script:orcaCfgTimeoutMs
        trayAutoStart  = $TrayAutoStart
        theme          = $Theme
        accent         = $Accent
    }
    # 保留配置文件里其它手动加的字段（如 peakWindows 时段自定义），防止保存时被清掉
    try {
        if (Test-Path $script:orcaConfigFile) {
            $old = Get-Content $script:orcaConfigFile -Raw | ConvertFrom-Json
            foreach ($prop in $old.PSObject.Properties) {
                if (-not $cfg.Contains($prop.Name)) { $cfg[$prop.Name] = $prop.Value }
            }
        }
    } catch {}
    try {
        $dir = Split-Path -Parent $script:orcaConfigFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json = $cfg | ConvertTo-Json
        # 用无 BOM 的 UTF-8 写入（和插件保持一致）
        [System.IO.File]::WriteAllText($script:orcaConfigFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        # 写完后刷新内存配置
        Read-OrcaConfig
        return $true
    } catch {
        return $false
    }
}

# 读取插件写的更新检查结果（~/.dsh/update-check-state.json），读不到返回 $null
function Get-UpdateState {
    $stateFile = Join-Path $env:USERPROFILE '.dsh\update-check-state.json'
    if (Test-Path $stateFile) {
        try {
            return Get-Content $stateFile -Raw | ConvertFrom-Json
        } catch {}
    }
    return $null
}

# ============================================================
# 二、DSH 服务器启停
# ============================================================

# 服务器是否在运行（看端口有没有监听）
# 服务器端口是否在监听（快速 TCP 探测，~1ms，比 Get-NetTCPConnection 快百倍）。
# 注意：端口被任何程序监听都算 true；区分"DSH/被占用/空闲"用 Get-PortStatus。
function Test-ServerRunning {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $client.BeginConnect('127.0.0.1', $script:orcaCfgPort, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(800)
            if ($ok -and $client.Connected) { return $true }
        } finally {
            $client.Close()
        }
    } catch {}
    return $false
}

# Orca 托盘是否在运行（查 dsh-tray.ps1 进程）。
# 用 WQL 在数据库端过滤（避免全量枚举进程，拖拽时更流畅）
function Test-TrayRunning {
    $t = Get-CimInstance -Query "SELECT ProcessId FROM Win32_Process WHERE Name='powershell.exe' AND CommandLine LIKE '%dsh-tray.ps1%'" -ErrorAction SilentlyContinue
    return ($null -ne $t)
}

# 拿到监听端口的进程 PID，没有返回 $null
function Get-ServerPid {
    $c = Get-NetTCPConnection -LocalPort $script:orcaCfgPort -State Listen -ErrorAction SilentlyContinue
    if ($null -ne $c) { return $c.OwningProcess }
    return $null
}

# 服务器日志文件（DSH 启动后的输出都写到这里，控制台「日志」页从这里读）
function Get-ServerLogFile {
    return Join-Path $env:USERPROFILE '.dsh\orca-dsh-server.log'
}

# 日志自动轮转：超过上限（默认 2MB）就把旧日志备份成 .1 再开新日志，
# 防止日志无限增长塞满硬盘。启动服务器前调用。
function Rotate-ServerLog {
    param([long]$MaxBytes = 2097152)   # 2MB
    $logFile = Get-ServerLogFile
    if (Test-Path $logFile) {
        try {
            $len = (Get-Item $logFile).Length
            if ($len -gt $MaxBytes) {
                $bak = "$logFile.1"
                Remove-Item $bak -Force -ErrorAction SilentlyContinue
                Rename-Item $logFile $bak -Force
                return $true
            }
        } catch {}
    }
    return $false
}

# 启动服务器（隐藏窗口跑 pnpm dsh web，输出重定向到日志文件）。
# 已在运行则不重复启动。返回 $true 表示发起启动（或已在运行），$false 失败。
# 端口被其他程序占用时不会强行启动，并会记录具体原因到 $script:orcaLastServerError。
function Start-DshServer {
    $script:orcaLastServerError = $null
    $status = Get-PortStatus
    if ($status -eq 'running') { return $true }
    if ($status -eq 'occupied') {
        $owner = Get-PortOwner
        $ownerName = if ($owner) { $owner.Name } else { '未知程序' }
        $script:orcaLastServerError = "端口 $($script:orcaCfgPort) 被 $ownerName 占用（非 DSH），不能启动"
        return $false
    }
    # 未安装 DSH（目录不存在或没有 package.json）→ 明确提示，别静默失败
    if (-not (Test-Path (Join-Path $script:orcaCfgDshDir 'package.json'))) {
        $script:orcaLastServerError = "未安装 DSH（找不到 $($script:orcaCfgDshDir)）。请到控制台「安装」页一键安装，或直接启动官方 Web 版。"
        return $false
    }
    try {
        # 日志轮转（防无限增长）
        Rotate-ServerLog
        # 统计：服务器启动次数 +1
        Add-OrcaStat -ServerStart
        $logFile = Get-ServerLogFile
        # cmd /c 内部重定向：追加模式，stdout+stderr 都进日志
        $cmd = "pnpm dsh web >> `"$logFile`" 2>&1"
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -WorkingDirectory $script:orcaCfgDshDir -WindowStyle Hidden
        return $true
    } catch {
        $script:orcaLastServerError = $_.Exception.Message
        return $false
    }
}

# 读服务器日志尾部（默认最近 200 行），日志不存在返回空字符串。
# 用 .NET StreamReader 读（比 Get-Content 快，大文件也不卡界面）
function Get-ServerLog {
    param([int]$Lines = 200)
    $logFile = Get-ServerLogFile
    if (-not (Test-Path $logFile)) { return @() }
    try {
        $reader = New-Object System.IO.StreamReader($logFile, [System.Text.Encoding]::UTF8)
        try {
            $all = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
        if ([string]::IsNullOrEmpty($all)) { return @() }
        $arr = $all -split "`n"
        if ($arr.Count -gt $Lines) { $arr = $arr[($arr.Count - $Lines)..($arr.Count - 1)] }
        return $arr
    } catch {
        return @()
    }
}

# 清空服务器日志
function Clear-ServerLog {
    $logFile = Get-ServerLogFile
    try {
        if (Test-Path $logFile) { Remove-Item $logFile -Force }
        return $true
    } catch { return $false }
}

# 端口状态检测：返回 'free'（空闲）/ 'running'（DSH 在跑）/ 'occupied'（被其他程序占用）
# 判断 DSH：只看命令行含 pnpm/dsh/deepseek/harness/tsx，避免误伤其他 Node 程序
function Get-PortStatus {
    $conn = Get-NetTCPConnection -LocalPort $script:orcaCfgPort -State Listen -ErrorAction SilentlyContinue
    if ($null -eq $conn) { return 'free' }
    $owner = Get-PortOwner
    if ($owner -and ($owner.CommandLine -match 'pnpm|dsh|deepseek|harness|tsx')) { return 'running' }
    return 'occupied'
}

# 拿到占用端口的进程信息（PID/名称/命令行），没有返回 $null
function Get-PortOwner {
    $conn = Get-NetTCPConnection -LocalPort $script:orcaCfgPort -State Listen -ErrorAction SilentlyContinue
    if ($null -eq $conn) { return $null }
    $procId = $conn.OwningProcess
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop
        return [pscustomobject]@{
            ProcessId   = $procId
            Name        = $proc.Name
            CommandLine = $proc.CommandLine
        }
    } catch { return $null }
}

# 关闭服务器（连子进程一起结束）。返回 $true 表示已关闭/本来就没开。
# 如果端口被其他程序占用，不会误杀，返回 $false。
function Stop-DshServer {
    $status = Get-PortStatus
    if ($status -eq 'occupied') {
        $script:orcaLastServerError = '端口被其他程序占用，已取消关闭'
        return $false
    }
    $p = Get-ServerPid
    if ($null -ne $p) {
        taskkill /PID $p /T /F 2>$null | Out-Null
    }
    # 统计：把本次运行时长累加进总时长
    try {
        $s = Get-OrcaStats
        if ($s.lastStartTime) {
            $start = [datetime]::Parse($s.lastStartTime)
            $secs = [int]((Get-Date) - $start).TotalSeconds
            if ($secs -gt 0) { $s.totalRunSeconds = [long]$s.totalRunSeconds + $secs }
            $s.lastStartTime = $null
            Save-OrcaStats $s
        }
    } catch {}
    return $true
}

# 一键更新 DSH 本体：在 DSH 目录执行 git pull（官方仓库）。
# 只读操作失败不影响现有版本（git 不会破坏文件）。
# 返回 { ok, output }
function Update-Dsh {
    try {
        $out = & git -C $script:orcaCfgDshDir pull 2>&1
        $code = $LASTEXITCODE
        return [pscustomobject]@{ ok = ($code -eq 0); output = (($out | Out-String).Trim()) }
    } catch {
        return [pscustomobject]@{ ok = $false; output = $_.Exception.Message }
    }
}

# 等待服务器就绪：最多等 $TimeoutSeconds 秒（每 0.5 秒查一次端口）。
# 返回 $true 就绪 / $false 超时。
function Wait-ServerUp {
    param([int]$TimeoutSeconds = 60)
    for ($i = 0; $i -lt ($TimeoutSeconds * 2); $i++) {
        if (Test-ServerRunning) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return Test-ServerRunning
}

# ============================================================
# 三.4、使用统计（~/.dsh/orca-stats.json）
# ============================================================

function Get-OrcaStatsFile {
    return Join-Path $env:USERPROFILE '.dsh\orca-stats.json'
}

# 读统计，不存在返回默认值
function Get-OrcaStats {
    $f = Get-OrcaStatsFile
    if (Test-Path $f) {
        try {
            $s = Get-Content $f -Raw | ConvertFrom-Json
            if ($null -eq $s.launchCount) { $s | Add-Member -NotePropertyName launchCount -NotePropertyValue 0 -Force }
            if ($null -eq $s.serverStarts) { $s | Add-Member -NotePropertyName serverStarts -NotePropertyValue 0 -Force }
            if ($null -eq $s.totalRunSeconds) { $s | Add-Member -NotePropertyName totalRunSeconds -NotePropertyValue 0 -Force }
            return $s
        } catch {}
    }
    return [pscustomobject]@{ launchCount = 0; serverStarts = 0; totalRunSeconds = 0; lastStartTime = $null }
}

function Save-OrcaStats($stats) {
    try {
        $f = Get-OrcaStatsFile
        $dir = Split-Path -Parent $f
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json = $stats | ConvertTo-Json
        # 原子写入：先写临时文件再移动，防止写入中途出错导致统计文件损坏/丢失
        $tmp = "$f.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -Force -Path $tmp -Destination $f
    } catch {}
}

# 记录一次使用（Launch=托盘/控制台打开计数，ServerStart=服务器启动计数）
function Add-OrcaStat {
    param([switch]$Launch, [switch]$ServerStart)
    try {
        $s = Get-OrcaStats
        if ($Launch) { $s.launchCount = [int]$s.launchCount + 1 }
        if ($ServerStart) {
            $s.serverStarts = [int]$s.serverStarts + 1
            $s.lastStartTime = (Get-Date).ToString('o')
        }
        Save-OrcaStats $s
    } catch {}
}

# 把秒数格式化成"X 小时 Y 分"
function Format-RunDuration([long]$TotalSeconds) {
    $h = [math]::Floor($TotalSeconds / 3600)
    $m = [math]::Floor(($TotalSeconds % 3600) / 60)
    if ($h -gt 0) { return "$h 小时 $m 分" }
    return "$m 分"
}

# ============================================================
# 三.5、开机自启 DSH 服务器（Windows 启动文件夹快捷方式）
# ============================================================

# 开机自启是否已开启
function Test-DshAutoStart {
    $startupDir = [Environment]::GetFolderPath('Startup')
    return (Test-Path (Join-Path $startupDir 'Orca DSH 服务器.lnk'))
}

# 开启开机自启：创建快捷方式 → start-dsh-server.vbs（隐藏窗口启动 DSH）
function Set-DshAutoStart {
    $vbs = Join-Path $PSScriptRoot 'start-dsh-server.vbs'
    if (-not (Test-Path $vbs)) { return $false }
    try {
        $startupDir = [Environment]::GetFolderPath('Startup')
        $lnk = Join-Path $startupDir 'Orca DSH 服务器.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath = 'wscript.exe'
        $sc.Arguments = '"' + $vbs + '"'
        $sc.WorkingDirectory = (Split-Path -Parent $vbs)
        $sc.Description = 'Orca DSH Launcher 开机自启 DSH 服务器'
        $sc.Save()
        return $true
    } catch { return $false }
}

# 关闭开机自启
function Remove-DshAutoStart {
    try {
        $startupDir = [Environment]::GetFolderPath('Startup')
        $lnk = Join-Path $startupDir 'Orca DSH 服务器.lnk'
        if (Test-Path $lnk) { Remove-Item $lnk -Force }
        return $true
    } catch { return $false }
}

# ============================================================
# 三、更新检查（git 对比本地 vs 官方）
# ============================================================

# 读本地 DSH 当前版本（git 提交号）
function Get-LocalCommit {
    try {
        $out = & git -C $script:orcaCfgDshDir rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return $out.Trim() }
    } catch {}
    return $null
}

# 查 GitHub 官方最新版本（git ls-remote 只读查询）
function Get-RemoteCommit {
    try {
        $repoUrl = "https://github.com/$($script:orcaCfgRepo).git"
        $out = & git ls-remote $repoUrl "refs/heads/$($script:orcaCfgBranch)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            $sha = ($out.Trim() -split '\s+')[0]
            if ($sha) { return $sha }
        }
    } catch {}
    return $null
}

# 执行一次更新检查，返回结果对象：
#   { ok, hasUpdate, localCommit, remoteCommit, error }
# ok=$false 表示本地/网络读不到（静默失败用）
function Invoke-UpdateCheck {
    $local = Get-LocalCommit
    $remote = Get-RemoteCommit
    if (-not $local -or -not $remote) {
        return [pscustomobject]@{ ok = $false; hasUpdate = $false; localCommit = $local; remoteCommit = $remote; error = '本地或网络不可用' }
    }
    return [pscustomobject]@{ ok = $true; hasUpdate = ($local -ne $remote); localCommit = $local; remoteCommit = $remote; error = $null }
}

# 拉取官方仓库最近几条 commit 的标题（用于展示"更新了什么"）。
# 返回字符串数组；网络不通/失败返回 $null（调用方安静降级）。
function Get-UpdateDetails {
    param([int]$Count = 5)
    try {
        $url = "https://api.github.com/repos/$($script:orcaCfgRepo)/commits?sha=$($script:orcaCfgBranch)&per_page=$Count"
        $headers = @{ 'User-Agent' = 'orca-dsh-launcher' }
        $result = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 8 -ErrorAction Stop
        if (-not $result) { return $null }
        $titles = @()
        foreach ($c in $result) {
            $msg = [string]$c.commit.message
            $firstLine = ($msg -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($firstLine) { $titles += $firstLine.Trim() }
        }
        if ($titles.Count -eq 0) { return $null }
        return $titles
    } catch {
        return $null
    }
}

# ============================================================
# 四、窗口辅助（浏览器最大化 + 打开 DSH 界面）
# ============================================================

# 窗口控制 API（user32）——定义一次，重复加载不报错
if (-not ('DshWin32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshWin32 {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@
}

# 把指定进程的主窗口最大化并置前
function Maximize-Window {
    param([int]$ProcessId)
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            [DshWin32]::ShowWindow($proc.MainWindowHandle, 3) | Out-Null   # 3 = SW_MAXIMIZE
            [DshWin32]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
            return $true
        }
    } catch {}
    return $false
}

# 打开 DSH 界面：
#   1. 未运行 → 启动服务器
#   2. 等待就绪（最多 60 秒）
#   3. 浏览器已有 DSH 页面 → 激活并最大化；没有 → 新开并等它最大化
# 返回 $true 已打开 / $false 失败
function Open-DshUi {
    $status = Get-PortStatus
    if ($status -eq 'occupied') { return $false }
    if ($status -ne 'running') {
        if (-not (Start-DshServer)) { return $false }
    }
    if (-not (Wait-ServerUp -TimeoutSeconds 60)) { return $false }

    # 浏览器里已有 DSH 页面 → 直接激活它并最大化，避免重复开标签
    $edge = @(Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match 'DeepSeek Harness' } | Select-Object -First 1)
    if ($edge.Count -gt 0) {
        [void](Maximize-Window -ProcessId $edge[0].Id)
        return $true
    }
    # 没有就新开一个，等页面加载后最大化
    $serverUrl = "http://127.0.0.1:$($script:orcaCfgPort)"
    Start-Process $serverUrl
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        $edge = @(Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match 'DeepSeek Harness' } | Select-Object -First 1)
        if ($edge.Count -gt 0) {
            [void](Maximize-Window -ProcessId $edge[0].Id)
            return $true
        }
    }
    return $true
}

# ============================================================
# 五、托盘图标（托盘用；控制台用它做窗口图标）
# ============================================================

# 加载虎鲸图标（透明背景多尺寸 ico），失败时兜底画一个蓝色 D。
# 调用方传入 ico 所在目录（托盘/控制台与 ico 同目录）。
function New-TrayIcon {
    param([string]$IconDir = $null)
    $icoPath = $null
    if ($IconDir) { $icoPath = Join-Path $IconDir 'dsh-tray.ico' }
    if (-not $icoPath -or -not (Test-Path $icoPath)) {
        $icoPath = Join-Path $env:USERPROFILE '.dsh\profiles\web\node_modules\orca-dsh-launcher\orca\dsh-tray.ico'
    }
    if (Test-Path $icoPath) {
        try {
            $icon = New-Object System.Drawing.Icon($icoPath)
            return $icon
        } catch {}
    }
    # 兜底：ico 缺失时用蓝色圆底白 D
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::DodgerBlue)
    $g.FillEllipse($brush, 0, 0, 15, 15)
    $font = New-Object System.Drawing.Font('Arial', 9, [System.Drawing.FontStyle]::Bold)
    $g.DrawString('D', $font, [System.Drawing.Brushes]::White, 4, 2)
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $g.Dispose(); $bmp.Dispose(); $brush.Dispose(); $font.Dispose()
    return $icon
}

# 初始化公共库（读取配置 + 加载 WinForms/Drawing 程序集）
function Initialize-OrcaCommon {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Read-OrcaConfig
}
