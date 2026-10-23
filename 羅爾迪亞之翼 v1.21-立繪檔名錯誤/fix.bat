@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix.ps1" %*
if "%~1"=="" pause
