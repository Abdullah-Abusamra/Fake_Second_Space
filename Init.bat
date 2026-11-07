@echo off
if exist "%~dp0pvault.exe" ("%~dp0pvault.exe" init) else (python "%~dp0pvault.py" init)
