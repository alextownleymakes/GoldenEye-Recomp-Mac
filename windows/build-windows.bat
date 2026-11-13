@echo off
rem Runs build-windows.ps1 (UNTESTED - see README). Usage: windows\build-windows.bat [path\to\XBLA-package]
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-windows.ps1" %*
if errorlevel 1 pause
