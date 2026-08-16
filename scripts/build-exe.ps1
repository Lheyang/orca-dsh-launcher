# ============================================================
#  Orca DSH Launcher - 一键打包引导器 EXE（build-exe.ps1）
# ============================================================
#  这个脚本会做这几件事：
#   1. 把插件文件（plugin.js + package.json + orca\ 全部）打成 zip 再转 Base64
#   2. 把 Base64 注入 orca-setup.ps1 模板（替换占位符），生成"打包版"脚本
#   3. 用 ps2exe 把打包版脚本编译成单文件 EXE（带虎鲸图标，无控制台窗口）
#   4. 产物在 dist\orca-setup.exe —— 把这个文件发到 GitHub Releases 即可
#
#  用法：powershell -NoProfile -ExecutionPolicy Bypass -File build-exe.ps1
#  首次运行会自动安装 ps2exe（需要能访问 PowerShell Gallery）。
#
#  注意：本文件必须保存为 UTF-8 带 BOM（PowerShell 5.1 才能
#        正确解析中文）。
# ============================================================
$ErrorActionPreference = 'Stop'

$proj = Split-Path -Parent $PSScriptRoot          # 项目根目录
$dist = Join-Path $proj 'dist'                    # 产物目录

Write-Host ""
Write-Host "======================================"
Write-Host "  Orca DSH Launcher - 打包 EXE"
Write-Host "======================================"
Write-Host ""

# ---------- 1. 检查 / 安装 ps2exe ----------
if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host "[1/5] 未安装 ps2exe，正在安装（需要访问 PowerShell Gallery）…"
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe -Force
Write-Host "[1/5] ps2exe 就绪"

# ---------- 2. 打包插件文件为 zip → Base64 ----------
$pluginFiles = @(
    (Join-Path $proj 'plugin.js'),
    (Join-Path $proj 'package.json'),
    (Join-Path $proj 'orca')
)
$zip = Join-Path $env:TEMP 'orca-plugin-payload.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $pluginFiles -DestinationPath $zip -CompressionLevel Optimal -Force
$b64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($zip))
Remove-Item $zip -Force
Write-Host ("[2/5] 插件文件已打包（Base64 长度：" + $b64.Length + " 字符）")

# ---------- 3. 注入模板，生成打包版脚本 ----------
$template = Join-Path $proj 'orca-setup.ps1'
$content = [System.IO.File]::ReadAllText($template, (New-Object System.Text.UTF8Encoding($true)))
if ($content -notmatch '__PLUGIN_PAYLOAD_B64__') {
    Write-Host "[错误] orca-setup.ps1 里找不到占位符 __PLUGIN_PAYLOAD_B64__，无法注入"
    exit 1
}

# 3.1 内联安装逻辑库（关键！ps2exe 打包后 $PSScriptRoot 为空，点源外部文件会失败，
#     必须把 orca-install.ps1 的内容直接嵌进打包版脚本，EXE 才真正自包含）
$installLib = Join-Path $proj 'orca\orca-install.ps1'
if (-not (Test-Path $installLib)) {
    Write-Host "[错误] 找不到安装逻辑库：$installLib"
    exit 1
}
$libContent = [System.IO.File]::ReadAllText($installLib, (New-Object System.Text.UTF8Encoding($true)))
$marker = ". (Join-Path `$PSScriptRoot 'orca\orca-install.ps1')"
if ($content -notmatch [regex]::Escape($marker)) {
    Write-Host "[错误] orca-setup.ps1 里找不到点源行（$marker），无法内联"
    exit 1
}
$content = $content.Replace($marker, $libContent)
Write-Host "[3/5] 安装逻辑库已内联（EXE 自包含）"

$packed = $content.Replace('__PLUGIN_PAYLOAD_B64__', $b64)
$packedFile = Join-Path $env:TEMP 'orca-setup-packed.ps1'
# 注意：必须带 BOM 写（PowerShell 5.1 解析中文用）
[System.IO.File]::WriteAllText($packedFile, $packed, (New-Object System.Text.UTF8Encoding($true)))
Write-Host "[3/5] 打包版脚本已生成（临时）"

# ---------- 4. ps2exe 编译 ----------
$version = '1.5.0'
try {
    # 注意：package.json 是 UTF-8 无 BOM，必须用 .NET 显式编码读（Get-Content 会按 GBK 读乱）
    $pkgRaw = [System.IO.File]::ReadAllText((Join-Path $proj 'package.json'), (New-Object System.Text.UTF8Encoding($false)))
    $pkg = $pkgRaw | ConvertFrom-Json
    if ($pkg.version) { $version = [string]$pkg.version }
} catch {}
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$exeOut = Join-Path $dist 'orca-setup.exe'
if (Test-Path $exeOut) { Remove-Item $exeOut -Force }
$ico = Join-Path $proj 'orca\dsh-tray.ico'
$ps2exeArgs = @{
    InputFile   = $packedFile
    OutputFile  = $exeOut
    NoConsole   = $true
    Title       = 'Orca DSH Launcher 一键安装'
    Description = 'Orca DSH Launcher - 一键安装 DeepSeek Harness 与配套插件'
    Product     = 'Orca DSH Launcher'
    Version     = $version
    Copyright   = 'MIT License'
}
if (Test-Path $ico) { $ps2exeArgs.IconFile = $ico }
Write-Host "[4/5] 正在编译 EXE（首次编译可能较慢）…"
Invoke-ps2exe @ps2exeArgs
if (-not (Test-Path $exeOut)) { throw 'ps2exe 编译失败：未生成 EXE' }
Write-Host "[4/5] EXE 编译完成"

# ---------- 5. 清理与校验 ----------
Remove-Item $packedFile -Force -ErrorAction SilentlyContinue
$exeInfo = Get-Item $exeOut
$sizeMb = [math]::Round($exeInfo.Length / 1MB, 2)
Write-Host ("[5/5] 产物：" + $exeOut + "（" + $sizeMb + " MB）")

Write-Host ""
Write-Host "======================================"
Write-Host "  打包完成！"
Write-Host "  发布到 GitHub Releases 时上传这个文件："
Write-Host "  dist\orca-setup.exe"
Write-Host "======================================"
Write-Host ""
