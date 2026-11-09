@echo off
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe /platform:x64 /optimize+ /out:"%~dp0TPA.Camera.exe" "%~dp0CameraTool.cs"
