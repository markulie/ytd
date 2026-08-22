@echo off
rem y.cmd - Windows launcher. Runs ytd.py on the project's own Python, never a
rem system one, and fetches that Python the first time if it isn't here yet.
rem Double-clicking this file opens a console, which is the whole UI.
setlocal

set "PY_VERSION=3.14.7"
set "PY_RELEASE=20260805"

set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "PYTHON=%HERE%\python\python.exe"

if not exist "%PYTHON%" call :setup || exit /b 1

"%PYTHON%" "%HERE%\ytd.py" %*
exit /b %errorlevel%

rem A subroutine, not an if-block: batch expands %VARS% inside parentheses when
rem the block is parsed, so anything set and used in one block comes out empty.
:setup
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" (set "ARCH=aarch64") else (set "ARCH=x86_64")
rem %%2B is the "+" in the build tag; GitHub needs it percent-encoded
set "URL=https://github.com/astral-sh/python-build-standalone/releases/download/%PY_RELEASE%/cpython-%PY_VERSION%%%2B%PY_RELEASE%-%ARCH%-pc-windows-msvc-install_only.tar.gz"
set "STAGE=%HERE%\python.new"

echo Setting up the bundled Python %PY_VERSION% ^(one time^)...
if exist "%STAGE%" rmdir /s /q "%STAGE%"
mkdir "%STAGE%"
rem curl and tar both ship with Windows 10 1803+ and handle this archive
curl -fL --progress-bar -o "%STAGE%\python.tar.gz" "%URL%" || goto :failed
tar -xzf "%STAGE%\python.tar.gz" -C "%STAGE%" || goto :failed
if not exist "%STAGE%\python\python.exe" goto :failed
if exist "%HERE%\python" rmdir /s /q "%HERE%\python"
move "%STAGE%\python" "%HERE%\python" >nul || goto :failed
rmdir /s /q "%STAGE%"
exit /b 0

:failed
if exist "%STAGE%" rmdir /s /q "%STAGE%"
echo Could not set up Python - check your connection and try again.
pause
exit /b 1
