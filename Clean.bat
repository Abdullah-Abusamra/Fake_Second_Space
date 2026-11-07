@echo off
if exist "%~dp0pvault.exe" ("%~dp0pvault.exe" clean) else (python "%~dp0pvault.py" clean)
