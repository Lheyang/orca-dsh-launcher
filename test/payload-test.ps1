# ============================================================
#  payload 链路测试：验证「插件文件打包成 Base64 → 注入模板 →
#  解压还原」整个链路可用（orca-setup 一键安装依赖这条链路）
# ============================================================
#  运行：powershell -NoProfile -ExecutionPolicy Bypass -File test\payload-test.ps1
#  注意：本文件必须保存为 UTF-8 带 BOM（PowerShell 5.1 才能
#        正确解析中文）。
# ============================================================
$ErrorActionPreference = 'Stop'
$proj = Split-Path -Parent $PSScriptRoot

Write-Host "── payload 链路测试 …" -NoNewline
try {
    # 1) 打包插件文件（和 build-exe.ps1 完全相同的文件清单）
    $files = @(
        (Join-Path $proj 'plugin.js'),
        (Join-Path $proj 'package.json'),
        (Join-Path $proj 'orca')
    )
    foreach ($f in $files) {
        if (-not (Test-Path $f)) { throw '缺少插件文件：' + $f }
    }
    $zip = Join-Path $env:TEMP 'orca-payload-test.zip'
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path $files -DestinationPath $zip -CompressionLevel Optimal -Force
    $b64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($zip))
    Remove-Item $zip -Force
    if ($b64.Length -lt 100) { throw 'Base64 过短，打包异常' }

    # 2) 注入模板（模拟 build-exe 的替换）
    $template = [System.IO.File]::ReadAllText((Join-Path $proj 'orca-setup.ps1'), (New-Object System.Text.UTF8Encoding($true)))
    if ($template -notmatch '__PLUGIN_PAYLOAD_B64__') { throw '模板里找不到占位符' }
    $packed = $template.Replace('__PLUGIN_PAYLOAD_B64__', $b64)
    if ($packed -match '__PLUGIN_PAYLOAD_B64__') { throw '占位符替换不彻底' }

    # 3) 模拟 Get-PluginSource 的解压分支（payload 已注入 → 解压）
    $tmp = Join-Path $env:TEMP ("orca-plugin-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip2 = Join-Path $tmp 'plugin.zip'
    [System.IO.File]::WriteAllBytes($zip2, [System.Convert]::FromBase64String($b64))
    Expand-Archive -Path $zip2 -DestinationPath $tmp -Force
    Remove-Item $zip2 -Force

    # 4) 验证解压后的文件齐全
    $need = @(
        (Join-Path $tmp 'plugin.js'),
        (Join-Path $tmp 'package.json'),
        (Join-Path $tmp 'orca\orca-common.ps1'),
        (Join-Path $tmp 'orca\dsh-tray.ps1'),
        (Join-Path $tmp 'orca\dsh-console.ps1'),
        (Join-Path $tmp 'orca\dsh-tray.ico'),
        (Join-Path $tmp 'orca\start-tray.vbs'),
        (Join-Path $tmp 'orca\start-console.vbs'),
        (Join-Path $tmp 'orca\start-dsh-server.ps1'),
        (Join-Path $tmp 'orca\start-dsh-server.vbs'),
        (Join-Path $tmp 'orca\orca-icon.ico')
    )
    foreach ($n in $need) {
        if (-not (Test-Path $n)) { throw '解压后缺少文件：' + $n }
    }

    # 5) 验证解压出的 plugin.js 可被 node 加载
    Push-Location $tmp
    try {
        $code = node --input-type=module -e "import('./plugin.js').then(m=>{if(typeof (m.default?.apply??m.apply)!=='function')process.exit(2)}).catch(()=>process.exit(3))" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '解压出的 plugin.js 无法加载' }
    } finally { Pop-Location }

    Remove-Item $tmp -Recurse -Force
    Write-Host "  ✅"
    exit 0
} catch {
    Write-Host ("  ❌ " + $_.Exception.Message)
    exit 1
}
