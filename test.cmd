@echo off
setlocal
rem ============================================================
rem  Orca DSH Launcher -- 全量测试（改完代码跑这一个就行）
rem ============================================================
rem  1. 编译整个解决方案
rem  2. orca-cli 自检（9 项：版本 / 配置 / 端口 / 统计 / 图标 /
rem     快捷方式 / 登记文件 / 日志 / 环境探测）
rem  3. 用 node 加载一遍 plugin.js（确认 DSH 侧插件结构正确）
rem  4. quick-check 状态自检
rem  5. 真实 Cordis 加载 + 真调一次 /orca 状态（最接近 DSH 实际路径）
rem  注意：本文件必须保存为 GBK/ANSI 编码。
rem ============================================================

echo.
echo ======================================
echo   Orca DSH Launcher 全量测试
echo ======================================
echo.

call "%~dp0scripts\_find-dotnet.cmd"
if not defined DOTNET goto nosdk

set "FAILED=0"
set "CLI=%~dp0src\Orca.Cli\bin\Release\net8.0-windows\orca-cli.exe"

echo -- 1/5 编译解决方案 ...
"%DOTNET%" build "%~dp0src\Orca.sln" -c Release -v quiet -p:Version=%ORCA_VER%
if errorlevel 1 goto buildfail
echo    [OK] 编译通过
goto step2

:buildfail
echo    [失败] 编译不通过
set "FAILED=1"
goto summary

:step2
echo.
echo -- 2/5 orca-cli 自检 ...
"%CLI%" selftest
if errorlevel 1 goto selffail
goto step3

:selffail
echo    [失败] 自检有失败项
set "FAILED=1"

:step3
echo.
echo -- 3/5 plugin.js 可被 Node 加载 ...
where node >nul 2>&1
if errorlevel 1 goto nonode
pushd "%~dp0"
node --input-type=module -e "import('./plugin.js').then(m=>{const p=m.default||{};const a=p.apply||m.apply;if(typeof a!=='function'){process.exit(2)}const i=p.inject;if(!Array.isArray(i)||i.indexOf('commands')<0){process.exit(4)}}).catch(e=>{console.error(String(e));process.exit(3)})"
if errorlevel 1 goto jsfail
popd
echo    [OK] plugin.js 结构正确
goto step4

:jsfail
popd
echo    [失败] plugin.js 加载失败
set "FAILED=1"
goto step4

:nonode
echo    [跳过] 未安装 Node.js（不影响桌面端）

:step4
echo.
echo -- 4/5 状态自检 quick-check ...
"%CLI%" quick-check >nul
if errorlevel 1 goto qcfail
echo    [OK] quick-check 正常
goto step5

:qcfail
echo    [失败] quick-check 异常
set "FAILED=1"

:step5
echo.
echo -- 5/5 真实 Cordis 加载 ...
where node >nul 2>&1
if errorlevel 1 goto nonode2
pushd "%~dp0"
node tests\real-cordis-test.mjs
if errorlevel 1 goto cordisfail
popd
goto summary

:cordisfail
popd
echo    [失败] 真实 Cordis 加载测试未通过
set "FAILED=1"
goto summary

:nonode2
echo    [跳过] 未安装 Node.js

:summary
echo.
echo ======================================
if "%FAILED%"=="0" goto allok
echo   有失败项，请查看上面的 [失败] 信息
echo ======================================
echo.
exit /b 1

:allok
echo   全部通过，可以放心使用！
echo ======================================
echo.
exit /b 0

:nosdk
echo [错误] 找不到 .NET 8 SDK。
echo        请先安装：https://dotnet.microsoft.com/zh-cn/download/dotnet/8.0
exit /b 1