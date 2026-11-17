param([string]$UpdaterPath = 'windows/updater/bin/Release/Updater.exe')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$assembly = [Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $UpdaterPath).Path)
$type = $assembly.GetType('KaraDelik.Updater.MainWindow', $true)
$flags = [Reflection.BindingFlags]'NonPublic, Static'
$urlCheck = $type.GetMethod('ValidateSetupUrl', $flags)
$hashCheck = $type.GetMethod('MatchesSetupHash', $flags)

$officialUrl = 'https://github.com/abivibe/Kara-Delik/releases/download/v1.0.5/KaraDelik_Setup.exe'
if ($urlCheck.Invoke($null, @($officialUrl)).AbsoluteUri -ne $officialUrl) {
    throw 'Official installer URL rejected.'
}

foreach ($url in @(
    $officialUrl.Replace('https:', 'http:'),
    $officialUrl.Replace('github.com', 'github.com.example.com'),
    $officialUrl.Replace('/abivibe/', '/other/')
)) {
    $rejected = $false
    try {
        $null = $urlCheck.Invoke($null, @($url))
    } catch {
        $rejected = $_.Exception.InnerException -is [IO.InvalidDataException]
    }
    if (!$rejected) { throw "Untrusted installer URL accepted: $url" }
}

$fixture = $MyInvocation.MyCommand.Path
$expected = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant()
if (!$hashCheck.Invoke($null, @($fixture, $expected))) { throw 'Valid hash rejected.' }
if ($hashCheck.Invoke($null, @($fixture, ('0' * 64)))) { throw 'Incorrect hash accepted.' }
'PASS: Release URL validation and installer checksum validation.'
