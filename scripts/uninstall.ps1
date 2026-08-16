# ============================================================
#  Orca DSH Launcher 一键卸载脚本（双击运行即可）
# ============================================================
#  这个脚本会做这几件事：
#   1. 从 DSH 插件目录删除本插件（卸载前自动备份）
#   2. 从 DSH 配置里移除登记（删除那一块）
#   3. 删除开机自启托盘快捷方式（如存在）
#   4. 删除桌面图标（如存在）
#
#  可选参数：
#    -KillTray    顺便关闭正在运行的 Orca 托盘
#    -KeepShortcut 保留开机自启快捷方式
#
#  注意：本文件必须保存为 UTF-8 带 BOM（PowerShell 5.1 才能
#        正确解析中文）。
# ============================================================

$ErrorActionPreference = 'Stop'

$killTray     = $args -contains '-KillTray'
$keepShortcut = $args -contains '-KeepShortcut'

$homeDir     = $env:USERPROFILE
$profileDir  = Join-Path $homeDir '.dsh\profiles\web'
$targetDir   = Join-Path $profileDir 'node_modules\orca-dsh-launcher'
$patchFile   = Join-Path $profileDir 'cordis.patch.yml'
$projectRoot = Split-Path -Parent $PSScriptRoot

Write-Host ""
Write-Host "======================================"
Write-Host "  Orca DSH Launcher - 一键卸载"
Write-Host "======================================"
Write-Host ""

# ---------- 1. 备份（卸载前先留底） ----------
$backupDir = Join-Path $projectRoot 'backup'
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (Test-Path $targetDir) {
    Copy-Item $targetDir (Join-Path $backupDir "orca-dsh-launcher.uninstalled-$stamp") -Recurse -Force
    Write-Host "[1/5] 已备份插件 -> backup\orca-dsh-launcher.uninstalled-$stamp"
}
if (Test-Path $patchFile) {
    Copy-Item $patchFile (Join-Path $backupDir "cordis.patch.yml.before-uninstall-$stamp") -Force -ErrorAction SilentlyContinue
}

# ---------- 2. 删除插件文件夹 ----------
if (Test-Path $targetDir) {
    Remove-Item $targetDir -Recurse -Force
    Write-Host "[2/5] 已从 DSH 插件目录删除"
} else {
    Write-Host "[2/5] 插件目录不存在（可能之前已卸载），跳过"
}

# ---------- 3. 从配置里移除登记 ----------
if (Test-Path $patchFile) {
    # 注意：配置文件是 UTF-8 无 BOM，必须用 .NET 强制 UTF-8 读取
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $raw = [System.IO.File]::ReadAllText($patchFile, $utf8NoBom)
    $lines = $raw -split "`n"
    # 找出登记块的范围（从 "# --- orca-dsh-launcher" 到 "# --- end orca-dsh-launcher ---"）
    $newLines = @()
    $inBlock = $false
    foreach ($line in $lines) {
        if ($line -match 'orca-dsh-launcher 启动器插件|# --- orca-dsh-launcher') {
            $inBlock = $true
        }
        if (-not $inBlock) {
            $newLines += $line
        }
        if ($inBlock -and $line -match '# --- end orca-dsh-launcher ---') {
            $inBlock = $false
        }
    }
    # 清理末尾多余空行
    while ($newLines.Count -gt 0 -and $newLines[-1] -eq '') { $newLines = $newLines[0..($newLines.Count-2)] }
    # 用无 BOM 的 UTF-8 整文件重写（保持和原文件编码一致）
    [System.IO.File]::WriteAllText($patchFile, ($newLines -join "`n") + "`n", $utf8NoBom)
    Write-Host "[3/5] 已从 DSH 配置移除插件登记"
} else {
    Write-Host "[3/5] 配置文件不存在，跳过"
}

# ---------- 4. 清理开机自启快捷方式 + 桌面图标 + 可选关闭托盘 ----------
if ($keepShortcut) {
    Write-Host "[4/5] 已按参数保留开机自启快捷方式"
} else {
    try {
        $startupDir = [Environment]::GetFolderPath('Startup')
        $lnkPath = Join-Path $startupDir 'Orca DSH Launcher.lnk'
        if (Test-Path $lnkPath) {
            Remove-Item $lnkPath -Force
            Write-Host "[4/5] 已删除开机自启快捷方式"
        } else {
            Write-Host "[4/5] 未发现开机自启快捷方式，跳过"
        }
    } catch {
        Write-Host "[4/5] 删除快捷方式失败（不影响卸载）：$($_.Exception.Message)"
    }
}

# 5. 删除桌面图标（控制台入口）
try {
    $desktopDir = [Environment]::GetFolderPath('Desktop')
    $desktopLnk = Join-Path $desktopDir 'Orca DSH Launcher.lnk'
    if (Test-Path $desktopLnk) {
        Remove-Item $desktopLnk -Force
        Write-Host "[5/5] 已删除桌面图标"
    } else {
        Write-Host "[5/5] 未发现桌面图标，跳过"
    }
} catch {
    Write-Host "[5/5] 删除桌面图标失败（不影响卸载）：$($_.Exception.Message)"
}

if ($killTray) {
    try {
        Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'dsh-tray\.ps1' } |
          ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        Write-Host "       （已按参数关闭运行中的 Orca 托盘）"
    } catch {}
}

Write-Host ""
Write-Host "======================================"
Write-Host "  卸载完成！重启 DSH 后插件将不再运行。"
Write-Host "  备份保留在项目 backup 文件夹，可随时恢复。"
Write-Host "======================================"
Write-Host ""
Read-Host "按回车键退出"
