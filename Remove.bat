@echo off
if exist "%~dp0pvault.exe" ("%~dp0pvault.exe" remove) else (python "%~dp0pvault.py" remove)
