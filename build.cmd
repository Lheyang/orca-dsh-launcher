@echo off
setlocal
rem ============================================================
rem  Orca DSH Launcher —— 编译（C# / .NET 8）
rem ============================================================
rem  双击运行即可。产物在 src\*\bin\Release\net8.0-windows\
rem  需要 .NET 8 SDK（没有会给出下载指引）。
rem  注意：本文件必须保存为 GBK/ANSI 编码，cmd 才能正确显示中文。
rem ============================================================

echo.
echo ======================================
echo   Orca DSH Launcher - 编译
echo ======================================
echo.

call "%~dp0scripts\_find-dotnet.cmd"
if not defined DOTNET goto nosdk

echo [1/2] 版本号 %ORCA_VER%（取自 package.json）
"%DOTNET%" build "%~dp0src\Orca.sln" -c Release -v minimal -p:Version=%ORCA_VER%
if errorlevel 1 goto fail

echo.
echo [2/2] 编译完成：
echo        src\Orca.App\bin\Release\net8.0-windows\orca.exe
echo        src\Orca.Cli\bin\Release\net8.0-windows\orca-cli.exe
echo.
echo 下一步：install.cmd 安装到 DSH，或 publish.cmd 打分发包。
echo.
exit /b 0

:nosdk
echo [错误] 找不到 .NET 8 SDK。
echo        请先安装：https://dotnet.microsoft.com/zh-cn/download/dotnet/8.0
echo        安装后重新打开命令窗口再试。
exit /b 1

:fail
echo.
echo [错误] 编译失败，请查看上面的错误信息。
exit /b 1
