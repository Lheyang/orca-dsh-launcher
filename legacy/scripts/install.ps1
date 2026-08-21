# ============================================================
#  Orca DSH Launcher 一键安装脚本（双击运行即可）
# ============================================================
#  这个脚本会做这几件事：
#   1. 把插件文件夹复制到 DSH 的插件目录
#      (C:\Users\你的用户名\.dsh\profiles\web\node_modules\orca-dsh-launcher)
#   2. 在你的 DSH 配置里登记一行，让 DSH 启动时加载它
#   3. 检测到旧版 dsh-update-checker 插件时自动备份并卸载
#      （避免两套更新检查并存）
#   4. 在 Windows 启动文件夹放一个托盘快捷方式
#      （默认创建；加 -SkipStartupShortcut 参数跳过）
#   5. 在桌面放一个「Orca DSH Launcher」图标（打开控制台管理窗口）
#      （默认创建；加 -SkipDesktopShortcut 参数跳过）
#
#  全程自动、带备份、防重复，安全放心。
#  注意：本文件必须保存为 UTF-8 带 BOM（PowerShell 5.1 才能
#        正确解析中文）。
# ============================================================

$ErrorActionPreference = 'Stop'

# 可选参数：跳过开机自启快捷方式 / 跳过桌面图标
$skipStartupShortcut = $args -contains '-SkipStartupShortcut'
$skipDesktopShortcut = $args -contains '-SkipDesktopShortcut'

# ---------- 1. 定义关键路径 ----------
$projectRoot = Split-Path -Parent $PSScriptRoot          # 项目根目录（orca-dsh-launcher）
$homeDir      = $env:USERPROFILE                          # 用户主目录
$profileDir   = Join-Path $homeDir '.dsh\profiles\web'    # DSH web 配置目录
$nodeModules  = Join-Path $profileDir 'node_modules'      # 插件安装目录
$targetDir    = Join-Path $nodeModules 'orca-dsh-launcher'   # 本插件的安装位置
$patchFile    = Join-Path $profileDir 'cordis.patch.yml'  # DSH 插件登记配置文件
$oldPluginDir = Join-Path $nodeModules 'dsh-update-checker'  # 旧插件目录（迁移用）

Write-Host ""
Write-Host "======================================"
Write-Host "  Orca DSH Launcher - 一键安装"
Write-Host "======================================"
Write-Host ""

# ---------- 2. 检查插件目录是否存在 ----------
if (-not (Test-Path $nodeModules)) {
    Write-Host "[错误] 找不到 DSH 插件目录：$nodeModules"
    Write-Host "       请确认 DSH 已经安装并运行过至少一次。"
    Read-Host "按回车键退出"
    exit 1
}

# ---------- 3. 备份现有配置（防万一） ----------
$backupDir = Join-Path $projectRoot 'backup'
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupName = "cordis.patch.yml.bak-$stamp"
if (Test-Path $patchFile) {
    Copy-Item $patchFile (Join-Path $backupDir $backupName) -Force -ErrorAction SilentlyContinue
}
Write-Host "[1/6] 已备份原配置 -> backup\$backupName"

# ---------- 4. 复制插件到 DSH 插件目录 ----------
if (Test-Path $targetDir) {
    # 已装过：先备份旧的再覆盖（更新安装）
    $oldBackup = Join-Path $backupDir "orca-dsh-launcher.old-$stamp"
    Copy-Item $targetDir $oldBackup -Recurse -Force
    Write-Host "[2/6] 检测到旧版本，已备份 -> backup\"
}
# 复制插件文件（plugin.js、package.json、lib 客户端包和 orca 托盘资产）
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
Copy-Item (Join-Path $projectRoot 'plugin.js') $targetDir -Force
Copy-Item (Join-Path $projectRoot 'package.json') $targetDir -Force
if (Test-Path (Join-Path $projectRoot 'lib')) {
    New-Item -ItemType Directory -Path (Join-Path $targetDir 'lib') -Force | Out-Null
    Copy-Item (Join-Path $projectRoot 'lib\*') (Join-Path $targetDir 'lib') -Recurse -Force
}
New-Item -ItemType Directory -Path (Join-Path $targetDir 'orca') -Force | Out-Null
Copy-Item (Join-Path $projectRoot 'orca\*') (Join-Path $targetDir 'orca') -Recurse -Force
Write-Host "[2/6] 插件已复制到 DSH 插件目录"

# ---------- 5. 迁移旧版 dsh-update-checker（备份 + 删除 + 移除登记） ----------
# 注意：配置文件是 UTF-8 无 BOM，必须用 .NET 强制 UTF-8 读写，
#       不能用 Get-Content（PowerShell 5.1 默认按 GBK 读，会把中文读乱）
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$migrated = $false

# 5.1 备份并删除旧插件目录
if (Test-Path $oldPluginDir) {
    Copy-Item $oldPluginDir (Join-Path $backupDir "dsh-update-checker.migrated-$stamp") -Recurse -Force
    Remove-Item $oldPluginDir -Recurse -Force
    $migrated = $true
    Write-Host "[3/6] 已备份并移除旧插件 dsh-update-checker"
}

# 5.2 从配置里移除旧插件的登记块
if (Test-Path $patchFile) {
    $content = [System.IO.File]::ReadAllText($patchFile, $utf8NoBom)
    if ($content -match 'dsh-update-checker') {
        $lines = $content -split "`n"
        $newLines = @()
        $inBlock = $false
        foreach ($line in $lines) {
            if ($line -match 'dsh-update-checker 更新检查插件|# --- dsh-update-checker') {
                $inBlock = $true
            }
            if (-not $inBlock) {
                $newLines += $line
            }
            if ($inBlock -and $line -match '# --- end dsh-update-checker ---') {
                $inBlock = $false
            }
        }
        while ($newLines.Count -gt 0 -and $newLines[-1] -eq '') { $newLines = $newLines[0..($newLines.Count-2)] }
        [System.IO.File]::WriteAllText($patchFile, ($newLines -join "`n") + "`n", $utf8NoBom)
        $migrated = $true
        Write-Host "[3/6] 已从配置移除旧插件 dsh-update-checker 的登记"
    }
}
if (-not $migrated) {
    Write-Host "[3/6] 未发现旧插件 dsh-update-checker，跳过迁移"
}

# ---------- 6. 检查配置里是否已登记本插件 ----------
$alreadyRegistered = $false
if (Test-Path $patchFile) {
    $content = [System.IO.File]::ReadAllText($patchFile, $utf8NoBom)
    if ($content -match 'orca-dsh-launcher') {
        $alreadyRegistered = $true
    }
}

if (-not $alreadyRegistered) {
    # 在配置末尾追加登记（用 YAML 格式，和社区插件一模一样）
    $entry = @"

# --- orca-dsh-launcher 启动器插件 (自动安装，勿删此注释块) ---
- insert:
    - id: orca-dsh-launcher
      name: 'orca-dsh-launcher'
# --- end orca-dsh-launcher ---
"@
    $content = [System.IO.File]::ReadAllText($patchFile, $utf8NoBom)
    # 用无 BOM 的 UTF-8 整文件重写（保持和原文件编码一致）
    [System.IO.File]::WriteAllText($patchFile, $content + $entry, $utf8NoBom)
    Write-Host "[4/6] 已在 DSH 配置中登记插件"
} else {
    Write-Host "[4/6] 插件之前已登记过，跳过（不会重复登记）"
}

# ---------- 7. 可选：开机自启托盘快捷方式（默认创建） ----------
if ($skipStartupShortcut) {
    Write-Host "[5/6] 已按参数跳过开机自启快捷方式（托盘由插件在 DSH 启动时自动拉起）"
} else {
    try {
        $startupDir = [Environment]::GetFolderPath('Startup')
        $vbsPath = Join-Path $targetDir 'orca\start-tray.vbs'
        $icoPath = Join-Path $targetDir 'orca\dsh-tray.ico'
        $lnkPath = Join-Path $startupDir 'Orca DSH Launcher.lnk'
        if (Test-Path $vbsPath) {
            $ws = New-Object -ComObject WScript.Shell
            $sc = $ws.CreateShortcut($lnkPath)
            $sc.TargetPath = 'wscript.exe'
            $sc.Arguments = '"' + $vbsPath + '"'
            $sc.WorkingDirectory = (Split-Path -Parent $vbsPath)
            $sc.Description = 'Orca DSH Launcher 托盘（开机自启）'
            if (Test-Path $icoPath) { $sc.IconLocation = "$icoPath,0" }
            $sc.Save()
            Write-Host "[5/6] 已创建开机自启托盘快捷方式"
            Write-Host "       （如需取消：重跑安装加参数 -SkipStartupShortcut）"
        } else {
            Write-Host "[5/6] 托盘启动器缺失，跳过开机自启设置"
        }
    } catch {
        Write-Host "[5/6] 创建开机自启快捷方式失败（不影响插件安装）：$($_.Exception.Message)"
    }
}

# ---------- 8. 可选：桌面图标（打开控制台管理窗口，默认创建） ----------
if ($skipDesktopShortcut) {
    Write-Host "[6/6] 已按参数跳过桌面图标（控制台仍可从托盘菜单或 /orca 控制台 打开）"
} else {
    try {
        $desktopDir = [Environment]::GetFolderPath('Desktop')
        $consoleVbs = Join-Path $targetDir 'orca\start-console.vbs'
        $icoPath = Join-Path $targetDir 'orca\dsh-tray.ico'
        $lnkPath = Join-Path $desktopDir 'Orca DSH Launcher.lnk'
        if (Test-Path $consoleVbs) {
            $ws = New-Object -ComObject WScript.Shell
            $sc = $ws.CreateShortcut($lnkPath)
            $sc.TargetPath = 'wscript.exe'
            $sc.Arguments = '"' + $consoleVbs + '"'
            $sc.WorkingDirectory = (Split-Path -Parent $consoleVbs)
            $sc.Description = 'Orca DSH Launcher 控制台（管理 DSH）'
            if (Test-Path $icoPath) { $sc.IconLocation = "$icoPath,0" }
            $sc.Save()
            Write-Host "[6/6] 已创建桌面图标「Orca DSH Launcher」"
            Write-Host "       （双击打开控制台管理窗口；如需取消重跑安装加 -SkipDesktopShortcut）"
        } else {
            Write-Host "[6/6] 控制台启动器缺失，跳过桌面图标"
        }
    } catch {
        Write-Host "[6/6] 创建桌面图标失败（不影响插件安装）：$($_.Exception.Message)"
    }
}

# ---------- 9. 完成 ----------
Write-Host ""
Write-Host "======================================"
Write-Host "  安装完成！"
Write-Host ""
Write-Host "  下一步：重启 DSH 即可生效"
Write-Host "  - 启动时自动检查更新"
Write-Host "  - 自动拉起 Orca 托盘（可在"
Write-Host "    ~/.dsh/orca-dsh-launcher.json 关闭）"
Write-Host "  - 双击桌面「Orca DSH Launcher」"
Write-Host "    打开控制台管理窗口"
Write-Host "  - 在输入框敲 /orca 查看所有命令"
Write-Host "======================================"
Write-Host ""
Read-Host "按回车键退出"
