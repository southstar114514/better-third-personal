@echo off
if "%~1"=="" (
  echo Usage: build_native.cmd PATH_TO_ZIG_EXE
  exit /b 2
)
"%~1" cc -target x86_64-windows-gnu -O2 -s -Wall -Wextra -Werror -shared "%~dp0TPA.Native.c" -lbcrypt -o "%~dp0TPA.Native.dll"
