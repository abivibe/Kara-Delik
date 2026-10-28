$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$env:PATH = "C:\tools\nuget;C:\tools\flutter\bin;C:\tools\git\cmd;C:\tools\jdk17\bin;" + $env:PATH

if (-not (Test-Path "output")) {
    New-Item -ItemType Directory -Path "output" | Out-Null
}

Write-Host "=== [1/3] Windows Flutter Release Build ===" -ForegroundColor Cyan
flutter build windows --release --no-tree-shake-icons
if ($LASTEXITCODE -ne 0) { throw "Flutter release build failed ($LASTEXITCODE)." }

# Compile KaraDelikNotifier with embedded metadata and icon
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (Test-Path $csc) {
    Write-Host "Compiling KaraDelikNotifier.exe..." -ForegroundColor Gray
    & $csc /nologo /target:winexe /win32icon:"windows\runner\resources\app_icon.ico" /out:"windows\bin\KaraDelikNotifier.exe" /r:System.dll,System.Windows.Forms.dll,System.Drawing.dll "windows\notifier\KaraDelikNotifier.cs"
    if ($LASTEXITCODE -ne 0) { throw "Notifier compilation failed ($LASTEXITCODE)." }
    & $csc /nologo /target:exe /out:"windows\tools\IconChanger.exe" "windows\tools\IconChanger.cs"
    if ($LASTEXITCODE -ne 0) { throw "IconChanger compilation failed ($LASTEXITCODE)." }
}

# Compile C# WPF Updater.exe
$msbuild = "G:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
if (-not (Test-Path $msbuild)) {
    $msbuild = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe"
}
if (Test-Path $msbuild) {
    Write-Host "Compiling Updater.exe (C# WPF Standalone)..." -ForegroundColor Gray
    & $msbuild "windows\updater\Updater.csproj" /t:Rebuild /p:Configuration=Release /p:Platform="AnyCPU" /v:m
    if ($LASTEXITCODE -ne 0) { throw "Updater compilation failed ($LASTEXITCODE)." }
    & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "$ScriptDir\test\verify_updater_window.ps1" -UpdaterPath "$ScriptDir\windows\updater\bin\Release\Updater.exe"
    if ($LASTEXITCODE -ne 0) { throw "Updater startup resource verification failed ($LASTEXITCODE)." }
    & powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "$ScriptDir\test\verify_updater_progress.ps1" -UpdaterPath "$ScriptDir\windows\updater\bin\Release\Updater.exe"
    if ($LASTEXITCODE -ne 0) { throw "Updater progress verification failed ($LASTEXITCODE)." }
    if (Test-Path "windows\updater\bin\Release\Updater.exe") {
        Copy-Item "windows\updater\bin\Release\Updater.exe" -Destination "windows\bin\Updater.exe" -Force
    }
}

# Copy dependencies
$releaseDir = "build\windows\x64\runner\Release"
Copy-Item "THIRD_PARTY_NOTICES.md" -Destination $releaseDir -Force
Copy-Item "windows\FFmpeg-LICENSE.txt" -Destination $releaseDir -Force
Copy-Item "windows\Node-LICENSE.txt" -Destination $releaseDir -Force
Copy-Item "windows\bin\node.exe" -Destination $releaseDir -Force
if (Test-Path "windows\bin\ffmpeg.exe") {
    Copy-Item "windows\bin\ffmpeg.exe" -Destination "$releaseDir\ffmpeg.exe" -Force
}
if (Test-Path "windows\bin\ffprobe.exe") {
    Copy-Item "windows\bin\ffprobe.exe" -Destination "$releaseDir\ffprobe.exe" -Force
}
if (Test-Path "windows\bin\KaraDelikNotifier.exe") {
    Copy-Item "windows\bin\KaraDelikNotifier.exe" -Destination "$releaseDir\KaraDelikNotifier.exe" -Force
}
if (Test-Path "windows\bin\Updater.exe") {
    Copy-Item "windows\bin\Updater.exe" -Destination "$releaseDir\Updater.exe" -Force
}
if (Test-Path "windows\redist") {
    Copy-Item "windows\redist\*.dll" -Destination "$releaseDir\" -Force
}
if (Test-Path "windows\bin\*.mp3") {
    Copy-Item "windows\bin\*.mp3" -Destination "$releaseDir\" -Force
}
if (Test-Path "yt-dlp.exe") {
    Copy-Item "yt-dlp.exe" -Destination "$releaseDir\yt-dlp.exe" -Force
}

foreach ($requiredFile in @('karadelik.exe', 'ffmpeg.exe', 'ffprobe.exe', 'node.exe', 'yt-dlp.exe', 'Updater.exe', 'KaraDelikNotifier.exe')) {
    if (-not (Test-Path (Join-Path $releaseDir $requiredFile))) { throw "Missing release dependency: $requiredFile" }
}

Write-Host "`n=== [2/3] Compiling Inno Setup (KaraDelik_Setup.exe) ===" -ForegroundColor Cyan
$inno = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
if (Test-Path $inno) {
    & $inno "setup.iss"
    if ($LASTEXITCODE -ne 0) { throw "Installer compilation failed ($LASTEXITCODE)." }
    Write-Host "[OK] Inno Setup: output\KaraDelik_Setup.exe" -ForegroundColor Green
}
else { throw "Inno Setup compiler not found: $inno" }

Write-Host "`n=== [3/3] Compiling Standalone SFX (KaraDelik_Windows.exe) ===" -ForegroundColor Cyan
$7z = "C:\Program Files\7-Zip\7z.exe"
$7zSfx = "C:\Program Files\7-Zip\7z.sfx"

$configContent = ";!@Install@!UTF-8!`r`nTitle=`"KaraDelik Downloader`"`r`nRunProgram=`"karadelik.exe`"`r`n;!@InstallEnd@!`r`n"
[System.IO.File]::WriteAllText("$ScriptDir\config.txt", $configContent, [System.Text.Encoding]::UTF8)

if (Test-Path $7z) {
    if (Test-Path "output\app.7z") { Remove-Item "output\app.7z" -Force }
    & $7z a -mx9 "output\app.7z" ".\build\windows\x64\runner\Release\*" | Out-Null
    
    if (Test-Path $7zSfx) {
        Copy-Item $7zSfx -Destination "custom_7z.sfx" -Force
        if (Test-Path "windows\tools\IconChanger.exe") {
            & "windows\tools\IconChanger.exe" "custom_7z.sfx" "windows\runner\resources\app_icon.ico" | Out-Null
        }
        cmd /c "copy /b custom_7z.sfx + config.txt + `"output\app.7z`" `"output\KaraDelik_Windows.exe`"" | Out-Null
        if (Test-Path "custom_7z.sfx") { Remove-Item "custom_7z.sfx" -Force }
        Write-Host "[OK] Standalone EXE: output\KaraDelik_Windows.exe" -ForegroundColor Green
    }
    if (Test-Path "config.txt") { Remove-Item "config.txt" -Force }
    if (Test-Path "output\app.7z") { Remove-Item "output\app.7z" -Force }
}

Write-Host "`n========================================================" -ForegroundColor Green
Write-Host "       WINDOWS DERLEMESI BASARIYLA TAMAMLANDI!          " -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
