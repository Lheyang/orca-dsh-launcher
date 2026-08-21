@echo off
setlocal
rem ============================================================
rem  Orca DSH Launcher —— 打分发包
rem ============================================================
rem  产物（dist\）：
rem    stage\                    可直接安装的插件包（install.cmd 用的就是它）
rem    orca-plugin-payload.zip   插件包压缩件（被安装器内嵌）
rem    orca-setup.exe            单文件安装器：自包含 .NET 运行时，
rem                              全新电脑双击即用，发布 Releases 就发它
rem  注意：本文件必须保存为 GBK/ANSI 编码。
rem ============================================================

echo.
echo ======================================
echo   Orca DSH Launcher - 打分发包
echo ======================================
echo.

call "%~dp0scripts\_find-dotnet.cmd"
if not defined DOTNET goto nosdk

echo 版本号 %ORCA_VER%（取自 package.json）
echo 首次打包需要下载自包含运行时文件，可能要几分钟 ...
echo.

"%DOTNET%" msbuild "%~dp0src\Orca.Package.proj" -t:All -v:minimal -p:Configuration=Release -p:Version=%ORCA_VER%
if errorlevel 1 goto fail

echo.
echo ======================================
echo   打包完成！发布时上传 dist\orca-setup.exe
echo ======================================
echo.
dir /b "%~dp0dist"
exit /b 0

:nosdk
echo [错误] 找不到 .NET 8 SDK。
echo        请先安装：https://dotnet.microsoft.com/zh-cn/download/dotnet/8.0
exit /b 1

:fail
echo.
echo [错误] 打包失败，请查看上面的错误信息。
exit /b 1
