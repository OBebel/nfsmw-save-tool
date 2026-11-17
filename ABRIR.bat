@echo off
title NFSMW Save Tool
cd /d "%~dp0"
if not exist "%~dp0NFSMW-Save-Tool.ps1" (
  echo NFSMW-Save-Tool.ps1 was not found next to this file.
  echo Extract the whole ZIP first: right-click the ZIP, Extract All.
  echo Then open ABRIR.bat from inside the extracted folder.
  pause
  exit /b 1
)
echo Opening NFSMW Save Tool... the window shows up in a few seconds.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0NFSMW-Save-Tool.ps1" -Abrir
if errorlevel 4 if not errorlevel 5 (
  echo.
  echo The program could not open its own window. The reason is written above.
  echo Try opening it again. If it keeps happening, restart the PC. If it still
  echo does not open, an antivirus or a rule on this PC may be blocking it.
  echo.
  pause
  exit /b 1
)
if errorlevel 1 (
  echo.
  echo Windows did not let the program start. The reason is written above.
  echo This happens on school or work PCs, or with Smart App Control turned on:
  echo they block scripts downloaded from the internet. On this PC the program
  echo only opens if whoever manages it allows it.
  echo.
  pause
  exit /b 1
)
timeout /t 3 /nobreak >nul 2>nul
