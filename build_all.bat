@echo off
title KaraDelik - Otomatik Derleme ve Paketleme Araci
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_all.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [HATA] Derleme sirasinda bir hata olustu!
) else (
    echo.
    echo [BASARILI] Tum derlemeler tamamlandi. Cikti klasoru aciliyor...
    explorer "%~dp0output"
)
pause
