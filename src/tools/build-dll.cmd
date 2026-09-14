@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-dll.ps1" %*
