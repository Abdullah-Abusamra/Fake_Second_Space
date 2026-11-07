@echo off
if exist "%~dp0pvault.exe" ("%~dp0pvault.exe" switch) else (python "%~dp0pvault.py" switch)
