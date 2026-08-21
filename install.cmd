@echo off
setlocal
rem ============================================================
rem  Orca DSH Launcher —— 安装到 DSH
rem ============================================================
rem  双击运行即可：编译 -> 组装插件包 -> 复制进 DSH 插件目录
rem  -> 在 cordis.patch.yml 登记 -> 建开机自启托盘 + 桌面图标。
rem
rem  可选参数（跟在命令后面）：
rem    --skip-startup    不创建开机自启托盘快捷方式
rem    --skip-desktop    不创建桌面图标
rem    --dsh-dir <路径>  指定 DSH 源码目录（默认沿用配置里的）
rem  注意：本文件必须保存为 GBK/ANSI 编码。
rem ============================================================

echo.
echo ======================================
echo   Orca DSH Launcher - 安装到 DSH
echo ======================================
echo.

call "%~dp0scripts\_find-dotnet.cmd"
if not defined DOTNET goto nosdk

echo [1/2] 正在编译并组装插件包（版本 %ORCA_VER%）...
"%DOTNET%" msbuild "%~dp0src\Orca.Package.proj" -t:StageOnly -v:minimal -p:Configuration=Release -p:Version=%ORCA_VER%
if errorlevel 1 goto fail

echo.
echo [2/2] 正在安装到 DSH ...
"%~dp0dist\stage\bin\orca-cli.exe" install-plugin --source "%~dp0dist\stage" %*
if errorlevel 1 goto fail

echo 重启 DSH 后生效（托盘与控制台立即可用）。
pause
exit /b 0

:nosdk
echo [错误] 找不到 .NET 8 SDK。
echo        请先安装：https://dotnet.microsoft.com/zh-cn/download/dotnet/8.0
pause
exit /b 1

:fail
echo.
echo [错误] 安装失败，请查看上面的错误信息。
pause
exit /b 1
