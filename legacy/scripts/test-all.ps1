# ============================================================
#  Orca DSH Launcher - 一键全量测试（改完代码跑这一个就行）
# ============================================================
#  自动执行：语法检查 → 插件加载 → 状态自检 → 托盘自检 → 真实加载 → 引导器自检 → payload 链路
#  全部通过显示 ✅，任何一步失败显示 ❌ 并说明原因。
#  用法：双击运行，或
#    powershell -NoProfile -ExecutionPolicy Bypass -File test-all.ps1
#  注意：本文件必须保存为 UTF-8 带 BOM（PowerShell 5.1 才能
#        正确解析中文）。
# ============================================================

$ErrorActionPreference = 'Continue'
$proj = Split-Path -Parent $PSScriptRoot
$script:pass = 0
$script:fail = 0

function Test-Step {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ("── " + $Name + " …") -NoNewline
    try {
        & $Body
        Write-Host "  ✅"
        $script:pass++
    } catch {
        Write-Host ("  ❌ " + $_.Exception.Message)
        $script:fail++
    }
}

Write-Host ""
Write-Host "======================================"
Write-Host "  Orca DSH Launcher 全量测试"
Write-Host "======================================"
Write-Host ""

# 1. PowerShell 语法检查（所有 .ps1）
Test-Step '1/7 PowerShell 语法检查' {
    $files = @()
    $files += Get-ChildItem (Join-Path $proj 'orca') -Filter '*.ps1' -File
    $files += Get-ChildItem (Join-Path $proj 'scripts') -Filter '*.ps1' -File
    foreach ($f in $files) {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        if ($errs -and $errs.Count -gt 0) { throw ($f.Name + ': ' + $errs[0].Message) }
    }
}

# 2. 插件模块可加载（node import）
Test-Step '2/7 插件模块加载' {
    Push-Location $proj
    try {
        $code = node --input-type=module -e "import('./plugin.js').then(m=>{const a=m.default?.apply??m.apply;if(typeof a!=='function')process.exit(2);}).catch(()=>process.exit(3))"
        if ($LASTEXITCODE -ne 0) { throw "node import 失败 (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
}

# 3. 控制台状态自检（QuickCheck）
Test-Step '3/7 控制台状态自检' {
    $out = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $proj 'orca\dsh-console.ps1') -QuickCheck 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'QuickCheck 退出码非 0' }
    $joined = ($out | Out-String)
    if ($joined -notmatch '"ok":\s*true') { throw 'QuickCheck 返回 ok=false' }
}

# 4. 托盘自检（5 秒自动退出）
Test-Step '4/7 托盘自检' {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $proj 'orca\dsh-tray.ps1') -Test | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '托盘自检退出码非 0' }
}

# 5. 真实 Cordis 运行时加载（最接近 DSH 实际加载路径）
Test-Step '5/7 真实 Cordis 加载' {
    Push-Location (Join-Path $proj 'test')
    try {
        $code = node real-cordis-test.mjs 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '真实加载测试失败' }
    } finally { Pop-Location }
}

# 6. 引导器自检（orca-setup QuickCheck，不弹窗口）
Test-Step '6/7 引导器自检' {
    $out = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $proj 'orca-setup.ps1') -QuickCheck 2>&1
    if ($LASTEXITCODE -ne 0) { throw '引导器自检退出码非 0' }
    $joined = ($out | Out-String)
    if ($joined -notmatch '"ok":\s*true') { throw '引导器自检返回 ok=false' }
}

# 7. payload 链路测试（插件文件打包→注入→解压，一键安装依赖此链路）
Test-Step '7/7 payload 链路测试' {
    $code = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $proj 'test\payload-test.ps1') 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'payload 链路测试失败' }
}

Write-Host ""
Write-Host "======================================"
Write-Host ("  结果：通过 $script:pass 项 / 失败 $script:fail 项")
Write-Host ("  " + $(if ($script:fail -eq 0) { '🎉 全部通过，可以放心使用！' } else { '⚠️ 有失败项，请查看上面的 ❌ 信息' }))
Write-Host "======================================"
Write-Host ""
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
