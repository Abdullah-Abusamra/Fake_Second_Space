@echo off
if exist "%~dp0pvault.exe" ("%~dp0pvault.exe" check) else (python "%~dp0pvault.py" check)
