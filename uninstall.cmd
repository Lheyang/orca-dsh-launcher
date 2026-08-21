@echo off
setlocal
rem ============================================================
rem  Orca DSH Launcher —— 从 DSH 卸载
rem ============================================================
rem  自动备份 -> 删除插件目录 -> 移除 cordis.patch.yml 登记
rem  -> 删除开机自启与桌面快捷方式。
rem
rem  可选参数：
rem    --kill-tray       顺带关闭正在运行的 Orca 托盘
rem    --keep-shortcut   保留开机自启 / 桌面快捷方式
rem  注意：本文件必须保存为 GBK/ANSI 编码。
rem ============================================================

echo.
echo ======================================
echo   Orca DSH Launcher - 卸载
echo ======================================
echo.

rem 优先用仓库里编译好的 CLI（不在安装目录里跑，才能把安装目录删干净）
set "CLI=%~dp0dist\stage\bin\orca-cli.exe"
if not exist "%CLI%" set "CLI=%~dp0src\Orca.Cli\bin\Release\net8.0-windows\orca-cli.exe"
if not exist "%CLI%" set "CLI=%USERPROFILE%\.dsh\profiles\web\node_modules\orca-dsh-launcher\bin\orca-cli.exe"
if not exist "%CLI%" goto nocli

rem 先让托盘/控制台退出，避免文件被占用删不掉
"%CLI%" run tray-stop >nul 2>&1

"%CLI%" uninstall-plugin %*
pause
exit /b 0

:nocli
echo [错误] 找不到 orca-cli.exe，无法执行卸载。
echo        请先运行 build.cmd 编译，或手动删除这个目录：
echo        %USERPROFILE%\.dsh\profiles\web\node_modules\orca-dsh-launcher
pause
exit /b 1
