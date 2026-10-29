@echo off
title Проверка сети
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_net.ps1"
pause