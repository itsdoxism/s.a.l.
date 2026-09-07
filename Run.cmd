@echo off
title School Account Lockdown
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SchoolAccountLockdown.ps1"
