@echo off
if exist "%~dp0pvault.exe" ("%~dp0pvault.exe" unmount) else (python "%~dp0pvault.py" unmount)
