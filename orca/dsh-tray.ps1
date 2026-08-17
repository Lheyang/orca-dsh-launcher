# ============================================================
#  Orca (虎鲸) — DSH 服务器托盘控制器
#  （Orca DSH Launcher 插件的桌面端组件，随插件打包在 orca/）
#  常驻右下角系统托盘，提供：打开界面 / 打开控制台 / 启动
#  服务器 / 关闭服务器 / 检查更新 / 退出
#
#  公共逻辑（配置/服务器/更新检查/窗口辅助）都在
#  orca-common.ps1，本文件只负责托盘本身。
#  注意：本文件必须保存为 UTF-8 带 BOM（PowerShell 5.1 才能
#        正确解析中文）。
# ============================================================
$ErrorActionPreference = 'Stop'

# 加载公共逻辑库（配置、服务器启停、更新检查、窗口辅助、图标）
. (Join-Path $PSScriptRoot 'orca-common.ps1')
Initialize-OrcaCommon

# 防止重复实例（同一会话内只有一个托盘）
$mutex = New-Object System.Threading.Mutex($false, 'Local\DSH-Tray-Single')
if (-not $mutex.WaitOne(0, $false)) {
    exit
}

$testMode = $false
foreach ($a in $args) { if ($a -eq '-Test') { $testMode = $true } }

# 弹气泡通知（Windows 右下角系统通知）
function Show-UpdateBalloon {
    param([string]$Title, [string]$Text)
    try {
        $notify.ShowBalloonTip(8000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Info)
    } catch {}
}

# 启动时检查：有更新且没通知过 → 弹气泡（只弹一次，不刷屏）
$lastNotifiedFile = Join-Path $env:TEMP 'dsh-tray-last-notified.txt'  # 记住"上次通知过的版本"
function Start-UpdateCheck {
    try {
        $result = Invoke-UpdateCheck
        if (-not $result.ok -or -not $result.hasUpdate) { return }  # 查不到/没更新 → 安静

        $remote = $result.remoteCommit
        # 有更新：检查是否已通知过这个版本（避免每次开机都弹）
        $already = $false
        if (Test-Path $lastNotifiedFile) {
            $notified = (Get-Content $lastNotifiedFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($notified -eq $remote) { $already = $true }
        }
        if (-not $already) {
            Show-UpdateBalloon -Title 'Orca：DSH 有新版本啦 🐋' -Text ("官方已更新到 " + $remote.Substring(0,10) + "，你当前是 " + $result.localCommit.Substring(0,10) + "。点开 DSH 界面可以继续使用，更新请咨询懂技术的人。")
            # 记下这个版本，下次就不重复弹了
            [System.IO.File]::WriteAllText($lastNotifiedFile, $remote, (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch {}
}

# 手动检查（右键菜单触发）：总是弹结果，不静默
function Invoke-ManualCheck {
    $result = Invoke-UpdateCheck
    if (-not $result.ok) {
        Show-UpdateBalloon -Title 'Orca：DSH 更新检查' -Text '检查失败（网络或本地版本读不到），请稍后再试。'
        return
    }
    if (-not $result.hasUpdate) {
        Show-UpdateBalloon -Title 'Orca：DSH 更新检查' -Text ('当前已是最新版本（' + $result.localCommit.Substring(0,10) + '）✅')
    } else {
        Show-UpdateBalloon -Title 'Orca：DSH 有新版本啦 🐋' -Text ('官方已更新到 ' + $result.remoteCommit.Substring(0,10) + '，你当前是 ' + $result.localCommit.Substring(0,10) + '。')
    }
}

# 打开控制台窗口（独立管理界面，走隐藏窗口启动器）
function Open-Console {
    $vbs = Join-Path $PSScriptRoot 'start-console.vbs'
    if (Test-Path $vbs) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$vbs`"" -WindowStyle Hidden
    } else {
        Show-UpdateBalloon -Title 'Orca' -Text '控制台启动器缺失，请重装插件。'
    }
}

# 当前版本（从 package.json 动态读取，单一来源）
$script:orcaVer = 'v?.?.?'
try {
    $pkgPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'package.json'
    if (Test-Path $pkgPath) {
        # package.json 是 UTF-8 无 BOM，必须用 .NET 显式编码读（Get-Content 会按 GBK 读乱）
        $pkgRaw = [System.IO.File]::ReadAllText($pkgPath, (New-Object System.Text.UTF8Encoding($false)))
        $pkg = $pkgRaw | ConvertFrom-Json
        if ($pkg.version) { $script:orcaVer = 'v' + $pkg.version }
    }
} catch {}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = New-TrayIcon -IconDir $PSScriptRoot
$notify.Text = 'Orca · DSH Launcher'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenu
$miStatus  = New-Object System.Windows.Forms.MenuItem
$miVer     = New-Object System.Windows.Forms.MenuItem
$miOpen    = New-Object System.Windows.Forms.MenuItem
$miConsole = New-Object System.Windows.Forms.MenuItem
$miCheck   = New-Object System.Windows.Forms.MenuItem
$miLog     = New-Object System.Windows.Forms.MenuItem
$miStart   = New-Object System.Windows.Forms.MenuItem
$miStop    = New-Object System.Windows.Forms.MenuItem
$miQuit    = New-Object System.Windows.Forms.MenuItem

$miStatus.Enabled = $false
$miVer.Enabled = $false
$miVer.Text = 'Orca ' + $script:orcaVer
$miOpen.Text    = '打开 DSH 界面'
$miConsole.Text = '打开管理界面'
$miCheck.Text   = '检查更新'
$miLog.Text     = '日志位置…'
$miStart.Text   = '启动服务器'
$miStop.Text    = '关闭服务器'
$miQuit.Text    = '退出程序'

$miOpen.add_Click({ Open-DshUi })
$miConsole.add_Click({ Open-Console })
$miCheck.add_Click({ Invoke-ManualCheck })
$miLog.add_Click({ Show-UpdateBalloon -Title 'Orca 日志' -Text (Get-ServerLogFile) })
$miStart.add_Click({
    if (Start-DshServer) {
        Refresh-Menu
    } else {
        Show-UpdateBalloon -Title 'Orca' -Text $script:orcaLastServerError
    }
})
$miStop.add_Click({
    if (Stop-DshServer) {
        Refresh-Menu
    } else {
        Show-UpdateBalloon -Title 'Orca' -Text $script:orcaLastServerError
    }
})
$miQuit.add_Click({
    # 退出程序：先关掉控制台窗口（如有），再退出托盘
    try {
        $closeEvt = [System.Threading.EventWaitHandle]::OpenExisting('Local\Orca-Console-Close')
        $null = $closeEvt.Set()
        $closeEvt.Dispose()
    } catch {}
    $notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

[void]$menu.MenuItems.Add($miStatus)
[void]$menu.MenuItems.Add($miVer)
[void]$menu.MenuItems.Add('-')
[void]$menu.MenuItems.Add($miOpen)
[void]$menu.MenuItems.Add($miConsole)
[void]$menu.MenuItems.Add($miCheck)
[void]$menu.MenuItems.Add($miLog)
[void]$menu.MenuItems.Add($miStart)
[void]$menu.MenuItems.Add($miStop)
[void]$menu.MenuItems.Add('-')
[void]$menu.MenuItems.Add($miQuit)

$notify.ContextMenu = $menu

function Refresh-Menu {
    $status = Get-PortStatus
    if ($status -eq 'running') {
        $miStatus.Text = '● 服务器运行中'
        $miStart.Enabled = $false
        $miStop.Enabled  = $true
        $miOpen.Enabled  = $true
        $notify.Text = 'Orca · DSH Launcher — 运行中'
    } elseif ($status -eq 'occupied') {
        $miStatus.Text = '⚠️ 端口被其他程序占用'
        $miStart.Enabled = $false
        $miStop.Enabled  = $false
        $miOpen.Enabled  = $false
        $notify.Text = 'Orca · DSH Launcher — 端口被占用'
    } else {
        $miStatus.Text = '○ 服务器未运行'
        $miStart.Enabled = $true
        $miStop.Enabled  = $false
        $miOpen.Enabled  = $true
        $notify.Text = 'Orca · DSH Launcher — 未运行'
    }
}

$menu.add_Popup({ Refresh-Menu })
$notify.add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Open-DshUi }
})

Refresh-Menu

# 统计：托盘启动次数 +1（测试模式不计）
if (-not $testMode) {
    Add-OrcaStat -Launch
    # 启动后自动检查一次更新（后台异步，不卡托盘；有更新且没通知过才弹气泡）
    Start-UpdateCheck
}

# 测试模式：5 秒后自动退出（仅用于验证，不干扰使用）
if ($testMode) {
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 5000
    $t.add_Tick({ $notify.Visible = $false; [System.Windows.Forms.Application]::Exit() })
    $t.Start()
}

[System.Windows.Forms.Application]::Run()
