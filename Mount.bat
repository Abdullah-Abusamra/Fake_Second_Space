@echo off
if exist "%~dp0pvault.exe" ("%~dp0pvault.exe" mount) else (python "%~dp0pvault.py" mount)
