@echo off
if exist "%~dp0pvault.exe" ("%~dp0pvault.exe" stay) else (python "%~dp0pvault.py" stay)
