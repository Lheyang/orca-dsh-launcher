@echo off
rem ============================================================
rem  找 .NET SDK + 读版本号（其它 .cmd 用 call 引入本文件）
rem  设置两个变量给调用方：
rem    DOTNET    可用的 dotnet.exe（带 SDK 的那个）
rem    ORCA_VER  package.json 里的版本号（唯一来源）
rem ============================================================

set "DOTNET="

rem 1) 先看 PATH 上的 dotnet 有没有 SDK
for /f "delims=" %%i in ('dotnet --list-sdks 2^>nul') do set "DOTNET=dotnet"

rem 2) 没有就看用户目录下的独立安装
if not defined DOTNET if exist "%USERPROFILE%\.dotnet\dotnet.exe" (
  for /f "delims=" %%i in ('"%USERPROFILE%\.dotnet\dotnet.exe" --list-sdks 2^>nul') do set "DOTNET=%USERPROFILE%\.dotnet\dotnet.exe"
)

rem 3) 读 package.json 的版本号（版本唯一来源）
set "ORCA_PKG=%~dp0..\package.json"
set "ORCA_VER="
if not exist "%ORCA_PKG%" goto :done
for /f "tokens=2 delims=:," %%a in ('findstr /r /c:"\"version\"" "%ORCA_PKG%"') do call :orca_setver %%a

:done
if not defined ORCA_VER set "ORCA_VER=0.0.0"
exit /b 0

rem 去掉引号和空格，得到干净的版本号
:orca_setver
set "ORCA_V=%~1"
set ORCA_V=%ORCA_V: =%
set ORCA_V=%ORCA_V:"=%
if not "%ORCA_V%"=="" set "ORCA_VER=%ORCA_V%"
exit /b 0
