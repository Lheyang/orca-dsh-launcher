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
function Get-SetupLogTail {
    param([int]$Lines = 150)
    if (-not (Test-Path $script:InstallLogFile)) { return @('（日志还没开始）') }
    try {
        $all = [System.IO.File]::ReadAllText($script:InstallLogFile, (New-Object System.Text.UTF8Encoding($false)))
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
