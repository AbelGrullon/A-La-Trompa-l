@echo off
title Cambiar token - A la trompa
cd /d "%~dp0"
node server.js --token
echo.
echo Listo. Cierra y vuelve a abrir el bridge si estaba encendido.
pause
