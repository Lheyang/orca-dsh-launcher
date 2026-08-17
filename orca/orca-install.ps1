# ============================================================
#  Orca DSH Launcher - 安装核心逻辑库（orca-install.ps1）
# ============================================================
#  本文件被 orca-setup.ps1（独立安装向导）和 dsh-console.ps1
#  （图形控制台的「安装」页）用「点源」(.) 加载，提供安装 DSH
#  所需的一切逻辑：环境检测、网络检测、git clone、pnpm 安装、
#  npx 官方 Web 版启动、插件安装。改逻辑只改这一处。
#
#  提供的函数：
#   - Get-CommandVersion      查命令版本（node/git/pnpm）
#   - Test-HostPort           快速 TCP 探测（任意主机端口）
#   - Test-GithubNetwork      GitHub 网络体检（分档结果）
#   - Test-DshInstalled       检测 DSH 完整版是否已安装
#   - Test-NodeEnv            环境检测（node/git/pnpm 齐全性）
#   - Install-DshClone        git clone 最新版 DSH
#   - Install-DshDeps         pnpm install + pnpm run build
#   - Start-DshWebNpx         启动官方 Web 版（npx @deepseek-ai/dsh web）
#   - Start-DshFromDir        从已安装目录启动（pnpm dsh web）
#   - Wait-PortReady          等待端口就绪（最多 N 秒）
#   - Get-PluginSource        插件包来源（内嵌 payload 或脚本目录）
#   - Install-OrcaPlugin      把插件装进 DSH（复制+登记+写配置）
#   - New-DesktopShortcut     创建桌面图标
#   - Write-SetupLog          写安装日志（UTF-8 无 BOM）
#   - Get-SetupLogTail        读日志尾部
#
#  注意：本文件必须保存为 UTF-8 带 BOM（PowerShell 5.1 才能
#        正确解析中文）。
# ============================================================

# ---------- 安装日志文件（调用方可在点源前覆盖） ----------
if (-not $script:InstallLogFile) {
    $script:InstallLogFile = Join-Path $env:TEMP 'orca-install.log'
}

# 官方仓库与分支
$script:DshRepo   = 'deepseek-ai/deepseek-harness'
$script:DshBranch = 'master'

# ============================================================
#  一、工具函数
# ============================================================

# 写安装日志（UTF-8 无 BOM，追加）
function Write-SetupLog {
    param([string]$Text)
    try {
        $dir = Split-Path -Parent $script:InstallLogFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::AppendAllText($script:InstallLogFile, $Text + "`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

# 读日志尾部（供界面显示最新进度）
# 注意：安装进程（cmd 重定向）正持续写这个文件，必须用共享读模式
# （FileShare.ReadWrite），否则文件被独占锁定会读失败。
function Get-SetupLogTail {
    param([int]$Lines = 150)
    if (-not (Test-Path $script:InstallLogFile)) { return @('（日志还没开始）') }
    try {
        $fs = New-Object System.IO.FileStream($script:InstallLogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)))
        try { $all = $reader.ReadToEnd() } finally { $reader.Dispose(); $fs.Dispose() }
        $arr = $all -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 }
        if ($arr.Count -gt $Lines) { return @($arr[($arr.Count - $Lines)..($arr.Count - 1)]) }
        return @($arr)
    } catch { return @('（读日志失败）') }
}

# 查一个命令是否存在并返回版本号（失败返回 $null）
function Get-CommandVersion {
    param([string]$Name)
    try {
        $out = & $Name --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return ($out | Select-Object -First 1).Trim() }
    } catch {}
    return $null
}

# 快速测试一个主机端口通不通（3 秒超时）
function Test-HostPort {
    param([string]$HostName, [int]$Port = 443)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $client.BeginConnect($HostName, $Port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(3000)
            if ($ok -and $client.Connected) { return $true }
        } finally { $client.Close() }
    } catch {}
    return $false
}

# ============================================================
#  二、检测类
# ============================================================

# 环境检测：返回 { node, git, pnpm, missing[] , ok }
function Test-NodeEnv {
    $nodeVer = Get-CommandVersion 'node'
    $gitVer  = Get-CommandVersion 'git'
    $pnpmVer = Get-CommandVersion 'pnpm'

    # 有 Node 但没有 pnpm 时，尝试用 corepack 自动启用（Node 自带）
    if ($nodeVer -and -not $pnpmVer) {
        try {
            & corepack enable pnpm 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $pnpmVer = Get-CommandVersion 'pnpm' }
        } catch {}
    }

    $missing = @()
    if (-not $nodeVer) { $missing += 'Node.js（https://nodejs.org/zh-cn）' }
    if (-not $gitVer)  { $missing += 'Git（https://git-scm.com/download/win）' }
    if (-not $pnpmVer) { $missing += 'pnpm（装好 Node 后运行：npm install -g pnpm）' }

    return [pscustomobject]@{
        ok      = ($missing.Count -eq 0)
        node    = $nodeVer
        git     = $gitVer
        pnpm    = $pnpmVer
        missing = $missing
    }
}

# GitHub 网络体检：测 github.com / codeload / api，返回 { githubOk, detail, ... }
function Test-GithubNetwork {
    $r = [ordered]@{
        github   = Test-HostPort 'github.com' 443
        codeload = Test-HostPort 'codeload.github.com' 443
        api      = Test-HostPort 'api.github.com' 443
    }
    $httpOk = $false
    if ($r.github) {
        try {
            $resp = Invoke-WebRequest -Uri 'https://github.com' -Method Head -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) { $httpOk = $true }
        } catch {}
    }
    $okCount = @($r.Values | Where-Object { $_ }).Count
    $detail = ('github.com=' + $(if ($r.github) { '通' } else { '不通' }) +
               '，codeload=' + $(if ($r.codeload) { '通' } else { '不通' }) +
               '，api=' + $(if ($r.api) { '通' } else { '不通' }) +
               '，主站访问=' + $(if ($httpOk) { '正常' } else { '异常' }))
    return [pscustomobject]@{
        githubOk = ($okCount -ge 2 -and $httpOk)
        httpOk   = $httpOk
        github   = $r.github
        codeload = $r.codeload
        api      = $r.api
        detail   = $detail
    }
}

# 检测 DSH 完整版是否已安装（配置目录存在 + 有 package.json + 是 git 仓库）
function Test-DshInstalled {
    param([string]$DshDir)
    if (-not $DshDir -or -not (Test-Path $DshDir)) { return $false }
    if (-not (Test-Path (Join-Path $DshDir 'package.json'))) { return $false }
    if (-not (Test-Path (Join-Path $DshDir '.git'))) { return $false }
    return $true
}

# ============================================================
#  三、安装执行类（每个函数返回 { ok, error, proc }，
#  proc 是后台子进程，调用方轮询 proc.HasExited 判断完成）
# ============================================================

# git clone 最新版 DSH（--depth 1 只取最新，省流量）
# 目标目录已存在且是 git 仓库 → 跳过（ok=$true, skipped=$true）
function Install-DshClone {
    param([string]$DshDir)
    if (Test-Path $DshDir) {
        if (Test-Path (Join-Path $DshDir '.git')) {
            Write-SetupLog '检测到该目录已装过 DSH（有 .git），跳过下载。'
            return [pscustomobject]@{ ok = $true; error = $null; proc = $null; skipped = $true }
        }
        if ((Get-ChildItem $DshDir -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
            Write-SetupLog ('[错误] 目标文件夹非空且不是 DSH：' + $DshDir)
            return [pscustomobject]@{ ok = $false; error = '目标文件夹非空且不是 DSH，请换一个位置。'; proc = $null; skipped = $false }
        }
    }
    New-Item -ItemType Directory -Path $DshDir -Force | Out-Null
    Write-SetupLog '========================================'
    Write-SetupLog '第 1 步：下载 DSH 源码（git clone）'
    Write-SetupLog '========================================'
    Write-SetupLog ('目标目录：' + $DshDir)
    $cmd = "git clone --depth 1 https://github.com/$($script:DshRepo).git `"$DshDir`" >> `"$($script:InstallLogFile)`" 2>&1"
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -WindowStyle Hidden -PassThru
    return [pscustomobject]@{ ok = $true; error = $null; proc = $proc; skipped = $false }
}

# 安装依赖 + 构建（pnpm install → pnpm run build，官方完整流程）
# 返回当前这一步的 proc；内部按状态推进（installing → building）
function Install-DshDeps {
    param([string]$DshDir)
    if (-not (Test-Path (Join-Path $DshDir 'package.json'))) {
        return [pscustomobject]@{ ok = $false; error = '目录里没有 package.json，DSH 源码不完整。'; proc = $null }
    }
    Write-SetupLog ''
    Write-SetupLog '========================================'
    Write-SetupLog '第 2 步：安装依赖 + 构建（pnpm install + pnpm run build）'
    Write-SetupLog '========================================'
    Write-SetupLog '下载量较大，时间取决于网速，请耐心等待（通常 10~30 分钟）。'
    $cmd = "cd /d `"$DshDir`" && pnpm install >> `"$($script:InstallLogFile)`" 2>&1"
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -WindowStyle Hidden -PassThru
    return [pscustomobject]@{ ok = $true; error = $null; proc = $proc }
}

# 在已 clone 的目录里执行 pnpm run build（依赖装完后调用）
function Start-DshBuild {
    param([string]$DshDir)
    Write-SetupLog ''
    Write-SetupLog '========================================'
    Write-SetupLog '第 3 步：构建 DSH（pnpm run build）'
    Write-SetupLog '========================================'
    $cmd = "cd /d `"$DshDir`" && pnpm run build >> `"$($script:InstallLogFile)`" 2>&1"
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -WindowStyle Hidden -PassThru
    return $proc
}

# 等待端口就绪（最多 $TimeoutSeconds 秒，每 0.5 秒查一次）
function Wait-PortReady {
    param([int]$Port = 3080, [int]$TimeoutSeconds = 120)
    for ($i = 0; $i -lt ($TimeoutSeconds * 2); $i++) {
        if (Test-HostPort '127.0.0.1' $Port) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return Test-HostPort '127.0.0.1' $Port
}

# 启动官方 Web 版：npx @deepseek-ai/dsh web（无需本地安装，一条命令）
# 需要 Node.js（npx 随 npm 提供）。返回 { ok, error }，进程 detach 后台跑。
function Start-DshWebNpx {
    param([int]$Port = 3080)
    $nodeVer = Get-CommandVersion 'node'
    if (-not $nodeVer) {
        return [pscustomobject]@{ ok = $false; error = '电脑上没有 Node.js，无法启动官方 Web 版。请先安装 Node.js（https://nodejs.org/zh-cn）。' }
    }
    Write-SetupLog ''
    Write-SetupLog '========================================'
    Write-SetupLog '启动官方 Web 版：npx @deepseek-ai/dsh web'
    Write-SetupLog '========================================'
    Write-SetupLog '首次运行会自动下载官方包（需要网络），之后秒开。'
    $logFile = Join-Path $env:USERPROFILE '.dsh\orca-dsh-server.log'
    $cmd = "npx --yes @deepseek-ai/dsh web --port $Port >> `"$logFile`" 2>&1"
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -WindowStyle Hidden | Out-Null
    Write-SetupLog '已在后台启动，等待就绪…'
    return [pscustomobject]@{ ok = $true; error = $null }
}

# 从已安装目录启动完整版：pnpm dsh web
function Start-DshFromDir {
    param([string]$DshDir, [int]$Port = 3080)
    if (-not (Test-DshInstalled -DshDir $DshDir)) {
        return [pscustomobject]@{ ok = $false; error = 'DSH 未安装（找不到 ' + $DshDir + '），请先一键安装或改用官方 Web 版。' }
    }
    $logFile = Join-Path $env:USERPROFILE '.dsh\orca-dsh-server.log'
    Write-SetupLog ''
    Write-SetupLog '启动 DSH（完整版）…'
    $cmd = "cd /d `"$DshDir`" && pnpm dsh web --port $Port >> `"$logFile`" 2>&1"
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -WindowStyle Hidden | Out-Null
    return [pscustomobject]@{ ok = $true; error = $null }
}

# ============================================================
#  四、插件包来源与插件安装
# ============================================================

# 插件包内嵌 Base64（由 build-exe.ps1 注入；未注入时保持占位符）
$script:PluginPayloadB64 = '__PLUGIN_PAYLOAD_B64__'

# 拿到插件包所在目录：
#   打包版 → 把内嵌 Base64 解压到临时目录
#   开发版 → 直接用调用方脚本所在目录（脚本旁边的 plugin.js + orca\）
function Get-PluginSource {
    param([string]$FallbackDir)
    $payload = $script:PluginPayloadB64
    if ($payload -and $payload -notmatch '^__' -and $payload.Length -gt 100) {
        $tmp = Join-Path $env:TEMP ("orca-plugin-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $zip = Join-Path $tmp 'plugin.zip'
        try {
            [System.IO.File]::WriteAllBytes($zip, [System.Convert]::FromBase64String($payload))
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            Remove-Item $zip -Force
            return $tmp
        } catch { return $null }
    }
    # 开发模式：脚本旁边的 plugin.js + orca 目录
    if ($FallbackDir -and (Test-Path (Join-Path $FallbackDir 'plugin.js')) -and (Test-Path (Join-Path $FallbackDir 'orca'))) {
        return $FallbackDir
    }
    return $null
}

# 把插件装进 DSH：复制文件 + 登记 cordis.patch.yml + 写共享配置
# 返回 $true / $false（错误信息进日志）
function Install-OrcaPlugin {
    param([string]$PluginSource, [string]$DshDir)
    $homeDir     = $env:USERPROFILE
    $profileDir  = Join-Path $homeDir '.dsh\profiles\web'
    $nodeModules = Join-Path $profileDir 'node_modules'
    $targetDir   = Join-Path $nodeModules 'orca-dsh-launcher'
    $patchFile   = Join-Path $profileDir 'cordis.patch.yml'

    if (-not (Test-Path $nodeModules)) {
        Write-SetupLog ('[插件] 找不到 DSH 插件目录：' + $nodeModules)
        return $false
    }
    try {
        # 1) 复制插件文件
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        Copy-Item (Join-Path $PluginSource 'plugin.js') $targetDir -Force
        Copy-Item (Join-Path $PluginSource 'package.json') $targetDir -Force
        New-Item -ItemType Directory -Path (Join-Path $targetDir 'orca') -Force | Out-Null
        Copy-Item (Join-Path $PluginSource 'orca\*') (Join-Path $targetDir 'orca') -Recurse -Force
        Write-SetupLog '[插件] 文件已复制到 DSH 插件目录'

        # 2) 登记 cordis.patch.yml（UTF-8 无 BOM）
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        if (-not (Test-Path $patchFile)) {
            New-Item -ItemType File -Path $patchFile -Force | Out-Null
            [System.IO.File]::WriteAllText($patchFile, "# 由 Orca DSH Launcher 自动创建`n", $utf8NoBom)
        }
        $content = [System.IO.File]::ReadAllText($patchFile, $utf8NoBom)
        if ($content -notmatch 'orca-dsh-launcher') {
            $entry = @"

# --- orca-dsh-launcher 启动器插件 (自动安装，勿删此注释块) ---
- insert:
    - id: orca-dsh-launcher
      name: 'orca-dsh-launcher'
# --- end orca-dsh-launcher ---
"@
            [System.IO.File]::WriteAllText($patchFile, $content + $entry, $utf8NoBom)
            Write-SetupLog '[插件] 已在 DSH 配置中登记'
        } else {
            Write-SetupLog '[插件] 之前已登记过，跳过'
        }

        # 3) 写共享配置（dshDir 指向实际安装位置）
        $cfgFile = Join-Path $homeDir '.dsh\orca-dsh-launcher.json'
        $cfg = [ordered]@{
            dshDir         = $DshDir
            port           = 3080
            repo           = $script:DshRepo
            branch         = $script:DshBranch
            checkTimeoutMs = 8000
            trayAutoStart  = $true
            theme          = 'dark'
        }
        [System.IO.File]::WriteAllText($cfgFile, ($cfg | ConvertTo-Json), $utf8NoBom)
        Write-SetupLog ('[插件] 配置已写入（DSH 目录：' + $DshDir + '）')
        return $true
    } catch {
        Write-SetupLog ('[插件] 安装失败：' + $_.Exception.Message)
        return $false
    }
}

# 创建桌面图标（打开控制台管理窗口）
function New-DesktopShortcut {
    param([string]$PluginTargetDir)
    try {
        $desktopDir = [Environment]::GetFolderPath('Desktop')
        $consoleVbs = Join-Path $PluginTargetDir 'orca\start-console.vbs'
        $icoPath    = Join-Path $PluginTargetDir 'orca\dsh-tray.ico'
        $lnkPath    = Join-Path $desktopDir 'Orca DSH Launcher.lnk'
        if (-not (Test-Path $consoleVbs)) { return $false }
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnkPath)
        $sc.TargetPath = 'wscript.exe'
        $sc.Arguments = '"' + $consoleVbs + '"'
        $sc.WorkingDirectory = (Split-Path -Parent $consoleVbs)
        $sc.Description = 'Orca DSH Launcher 控制台（管理 DSH）'
        if (Test-Path $icoPath) { $sc.IconLocation = "$icoPath,0" }
        $sc.Save()
        return $true
    } catch { return $false }
}

# ============================================================
#  六、自定义对话框（深色圆角风格，替代系统 MessageBox）
# ============================================================
#  用法：
#    Show-OrcaDialog -Title '上一步' -Message '要回到上一步吗？...' -Type question -Buttons YesNo -Owner $window
#    → YesNo 返回 $true(是)/$false(否)；OK 返回 $true(好的)
#  需要 WPF 程序集已加载（调用方在主窗口加载之后调用）。

# ============================================================
#  七、强调色预设（弹窗/界面配色，可在控制台「设置」页自选）
# ============================================================
$script:OrcaAccentPresets = @{
    'green'  = @{ Name = '经典青绿'; Accent = '#3ED6A3'; AccentDark = '#2BBF87'; Bg = '#1C3A2E'; Line2 = '#2E4B3F' }
    'blue'   = @{ Name = '科技蓝';   Accent = '#5B9BFF'; AccentDark = '#3B74E8'; Bg = '#1B3A66'; Line2 = '#27405E' }
    'purple' = @{ Name = '蓝紫渐变'; Accent = '#8B7CF6'; AccentDark = '#6A5AE0'; Bg = '#2A2A5E'; Line2 = '#3A3570' }
    'amber'  = @{ Name = '琥珀暖橙'; Accent = '#F2B14B'; AccentDark = '#D9942E'; Bg = '#3A3222'; Line2 = '#4A3A22' }
    'rose'   = @{ Name = '玫红';     Accent = '#F27DA8'; AccentDark = '#D95F8E'; Bg = '#3A2440'; Line2 = '#4A2A45' }
    'slate'  = @{ Name = '银灰蓝';   Accent = '#9AA7BC'; AccentDark = '#7C8AA3'; Bg = '#2A3240'; Line2 = '#35404F' }
}

# 读取当前强调色预设（内存变量优先；否则读配置文件 accent 字段；默认科技蓝）
function Get-OrcaAccent {
    $name = $script:OrcaAccent
    if (-not $name) {
        try {
            $cfgFile = Join-Path $env:USERPROFILE '.dsh\orca-dsh-launcher.json'
            if (Test-Path $cfgFile) {
                $cfg = [System.IO.File]::ReadAllText($cfgFile, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
                if ($cfg.accent) { $name = [string]$cfg.accent }
            }
        } catch {}
    }
    if (-not $name -or -not $script:OrcaAccentPresets.ContainsKey($name)) { $name = 'blue' }
    return $script:OrcaAccentPresets[$name]
}

# 取虎鲸 logo 图像（供对话框品牌行用）
# EXE 打包版：用内嵌 Base64（$script:OrcaLogoB64，由 build-exe 注入）；
# 控制台/开发版：读脚本目录的 dsh-tray.ico
function Get-OrcaLogoImage {
    try {
        $logoStream = $null
        $logoB64 = $script:OrcaLogoB64
        if ($logoB64 -and $logoB64 -notmatch '^__' -and $logoB64.Length -gt 100) {
            $logoBytes = [System.Convert]::FromBase64String($logoB64)
            $logoStream = New-Object System.IO.MemoryStream(, $logoBytes)
        } else {
            $icoPath = Join-Path $PSScriptRoot 'dsh-tray.ico'
            if (Test-Path $icoPath) { $logoStream = [System.IO.File]::OpenRead($icoPath) }
        }
        if ($logoStream) {
            try {
                $decoder = New-Object System.Windows.Media.Imaging.IconBitmapDecoder(
                    $logoStream,
                    [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                    [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                $frame = $decoder.Frames | Where-Object { $_.PixelWidth -le 48 } | Sort-Object PixelWidth -Descending | Select-Object -First 1
                if (-not $frame) { $frame = $decoder.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1 }
                if ($frame) { $frame.Freeze(); return $frame }
            } finally { $logoStream.Dispose() }
        }
    } catch {}
    return $null
}

function Show-OrcaDialog {
    param(
        [string]$Title = 'Orca',
        [string]$Message = '',
        [ValidateSet('question','info','warning','error')][string]$Type = 'info',
        [ValidateSet('YesNo','OK')][string]$Buttons = 'OK',
        $Owner = $null
    )
    # 类型 → 图标/配色/副标题（Orca 青绿品牌色体系）
    # 类型 → 图标/配色/副标题（强调色跟随设置页自选；warning/error 用专用警示色）
    $acc = Get-OrcaAccent
    $typeInfo = switch ($Type) {
        'question' { [pscustomobject]@{ Char = '?'; Accent = $acc.Accent; AccentDark = $acc.AccentDark; Bg = $acc.Bg; Sub = '确认操作' } }
        'info'     { [pscustomobject]@{ Char = 'i'; Accent = $acc.Accent; AccentDark = $acc.AccentDark; Bg = $acc.Bg; Sub = '提示' } }
        'warning'  { [pscustomobject]@{ Char = '!'; Accent = '#F2B14B'; AccentDark = '#D9942E'; Bg = '#3A3222'; Sub = '注意' } }
        'error'    { [pscustomobject]@{ Char = '✕'; Accent = '#EF7F7F'; AccentDark = '#D05B5B'; Bg = '#3A2626'; Sub = '错误' } }
    }
    # 消息可能含路径等特殊字符，转义 XML 防 XAML 解析失败
    $msgSafe = [System.Security.SecurityElement]::Escape($Message)
    $titleSafe = [System.Security.SecurityElement]::Escape($Title)

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$titleSafe" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        SizeToContent="WidthAndHeight" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" FontFamily="Microsoft YaHei UI" Topmost="True"
        MaxWidth="520" MaxHeight="620">
  <Window.Resources>
    <!-- 次按钮：灰底描边 -->
    <Style x:Key="DlgGhost" TargetType="Button">
      <Setter Property="Background" Value="#262A33"/>
      <Setter Property="Foreground" Value="#C6C8D2"/>
      <Setter Property="BorderBrush" Value="#343947"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="22,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#303542"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1F222A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- 主按钮：品牌色渐变 -->
    <Style x:Key="DlgPrimary" TargetType="Button">
      <Setter Property="Foreground" Value="#0C120E"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="24,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="8">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                  <GradientStop Color="$($typeInfo.Accent)" Offset="0"/>
                  <GradientStop Color="$($typeInfo.AccentDark)" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.9"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.72"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="dlgRoot" CornerRadius="14">
    <Border.Effect>
      <DropShadowEffect BlurRadius="28" ShadowDepth="0" Opacity="0.65" Color="#000000"/>
    </Border.Effect>
    <Border CornerRadius="14" BorderThickness="1" BorderBrush="#2E3340">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#1D2027" Offset="0"/>
          <GradientStop Color="#15171C" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <StackPanel>
        <!-- 顶部品牌色线条 -->
        <Border Height="4" CornerRadius="2,2,0,0" Margin="1,1,1,0">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="$($typeInfo.Accent)" Offset="0"/>
              <GradientStop Color="$($acc.Line2)" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
        </Border>
        <!-- 品牌行 -->
        <DockPanel Margin="20,14,20,0">
          <Image x:Name="dlgLogo" Width="14" Height="14" Stretch="Uniform" VerticalAlignment="Center"/>
          <TextBlock Text="Orca DSH Launcher" FontSize="10.5" Foreground="#7A7E8C" Margin="6,0,0,0" VerticalAlignment="Center"/>
        </DockPanel>
        <!-- 内容区 -->
        <StackPanel Margin="20,16,20,0">
          <StackPanel Orientation="Horizontal">
            <Border Width="38" Height="38" CornerRadius="19" Background="$($typeInfo.Bg)">
              <TextBlock x:Name="dlgIco" Text="$($typeInfo.Char)" FontSize="17" FontWeight="Bold"
                         Foreground="$($typeInfo.Accent)" FontFamily="Segoe UI"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Margin="13,0,0,0" VerticalAlignment="Center">
              <TextBlock x:Name="dlgTitle" Text="$titleSafe" FontSize="17" FontWeight="Bold" Foreground="#F0F0F2"/>
              <TextBlock x:Name="dlgSub" Text="$($typeInfo.Sub)" FontSize="10.5" Foreground="#6E7180" Margin="0,3,0,0"/>
            </StackPanel>
          </StackPanel>
          <ScrollViewer MaxHeight="300" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,18,0,0">
            <TextBlock x:Name="dlgMsg" Text="$msgSafe" FontSize="13" Foreground="#A8AAB5" TextWrapping="Wrap"
                       MaxWidth="420" LineHeight="22"/>
          </ScrollViewer>
        </StackPanel>
        <!-- 按钮行 -->
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="20,22,20,20">
          <Button x:Name="btnNo" Style="{StaticResource DlgGhost}"/>
          <Button x:Name="btnYes" Style="{StaticResource DlgPrimary}" Margin="10,0,0,0"/>
        </StackPanel>
      </StackPanel>
    </Border>
  </Border>
</Window>
"@

    $script:dialogResult = $false
    try {
        $reader = New-Object System.Xml.XmlNodeReader($xaml)
        $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
        $btnYes = $dlg.FindName('btnYes')
        $btnNo  = $dlg.FindName('btnNo')
        # 品牌行 logo
        $dlgLogo = $dlg.FindName('dlgLogo')
        if ($dlgLogo) {
            $logoImg = Get-OrcaLogoImage
            if ($logoImg) { $dlgLogo.Source = $logoImg }
        }

        if ($Buttons -eq 'OK') {
            $btnNo.Visibility = 'Collapsed'
            $btnYes.Content = '好的'
            $btnYes.IsDefault = $true
            $dlg.Add_KeyDown({ if ($_.Key -eq 'Escape') { $script:dialogResult = $false; $dlg.Close() } })
        } else {
            $btnYes.Content = '是'
            $btnNo.Content = '否'
            $btnYes.IsDefault = $true   # 回车=是
            $btnNo.IsCancel = $true     # Esc=否
        }
        $btnYes.Add_Click({ $script:dialogResult = $true; $dlg.Close() })
        $btnNo.Add_Click({ $script:dialogResult = $false; $dlg.Close() })

        # 淡入动效
        $dlg.Add_Loaded({
            try {
                $rootEl = $dlg.FindName('dlgRoot')
                $rootEl.Opacity = 0
                $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
                $anim.From = 0; $anim.To = 1
                $anim.Duration = [TimeSpan]::FromMilliseconds(180)
                $rootEl.BeginAnimation([System.Windows.Controls.Control]::OpacityProperty, $anim)
            } catch {}
        })

        # 注意：PowerShell 里 $dlg.ShowDialog($Owner) 会找不到带参重载，
        # 必须先设置 Owner 属性，再调用无参 ShowDialog()
        if ($Owner) {
            try { $dlg.Owner = $Owner } catch {}
        }
        $null = $dlg.ShowDialog()
    } catch {
        Write-SetupLog ('[对话框] 弹出自定义对话框失败：' + $_.Exception.Message)
    }
    return $script:dialogResult
}
