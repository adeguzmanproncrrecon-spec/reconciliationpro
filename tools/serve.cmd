@echo off
rem I-double-click para buksan ang ReconciliationPro sa http://localhost:8080 (local web server).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1" %*
