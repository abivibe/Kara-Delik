@echo off
chcp 65001 >nul
title KaraDelik - Sıfır Manuel Uğraş Otomatik Kurulum ve Hazırlık

echo ======================================================================
echo           KaraDelik - Otomatik Kurulum ve Yapılandırma Betiği
echo ======================================================================
echo.

set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

:: 1. Ortam Değişkenleri
set "PATH=C:\tools\nuget;C:\tools\flutter\bin;C:\tools\git\cmd;C:\tools\jdk17\bin;%PATH%"
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"
set "PUB_HOSTED_URL=https://pub.flutter-io.cn"

echo [*] Flutter ve Araçlar Denetleniyor...
where flutter >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo [BILGI] Flutter PATH içerisinde bulunamadı, C:\tools\flutter kontrol ediliyor...
    if exist "C:\tools\flutter\bin\flutter.bat" (
        set "PATH=C:\tools\flutter\bin;%PATH%"
    ) else (
        echo [UYARI] Flutter SDK bulunamadı! Lütfen Flutter kurulumunu tamamlayın.
        pause
        exit /b 1
    )
)

echo [*] Bağımlılıklar indiriliyor (flutter pub get)...
call flutter pub get

echo [*] Kod analizi yapılıyor (flutter analyze)...
call flutter analyze

echo.
echo ======================================================================
echo           Kurulum Tamamlandı! Proje Derlemeye Hazır.
echo ======================================================================
echo.
echo Şimdi 'build_all.bat' betiğini çalıştırarak Windows kurulum paketini
echo ve Windows tek .EXE dosyasını üretebilirsiniz!
echo.
set /p DO_BUILD="Şimdi otomatik derleme başlatılsın mı? (E/H): "
if /i "%DO_BUILD%"=="E" (
    call "%SCRIPT_DIR%build_all.bat"
) else (
    echo Tamamlandı. İstediğiniz zaman build_all.bat dosyasını çalıştırabilirsiniz.
    pause
)
