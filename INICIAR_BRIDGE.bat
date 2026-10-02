@echo off
title Bridge - A la trompa
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo Necesitas Node.js 22 o superior. Descargalo en https://nodejs.org ^(version LTS^).
  pause
  exit /b 1
)
if not exist node_modules (
  echo Instalando dependencias...
  call npm install
)
rem La primera vez abre una ventana para el token; despues arranca directo
node server.js
pause
