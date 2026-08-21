# ============================================================
#  start-dsh-server.ps1 —— 开机自启 DSH 服务器入口
# ============================================================
#  由 start-dsh-server.vbs（隐藏窗口）调用，或用启动文件夹的
#  快捷方式触发。逻辑复用公共库：读配置 + 启动服务器（带日志）。
#  注意：本文件必须保存为 UTF-8 带 BOM（PowerShell 5.1 才能
#        正确解析中文）。
# ============================================================
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'orca-common.ps1')
Initialize-OrcaCommon

# 若服务器已在运行则不重复启动；启动失败静默（不打扰登录）
if (-not (Test-ServerRunning)) {
    Start-DshServer
}
