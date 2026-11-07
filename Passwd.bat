@echo off
if exist "%~dp0pvault.exe" ("%~dp0pvault.exe" passwd) else (python "%~dp0pvault.py" passwd)
