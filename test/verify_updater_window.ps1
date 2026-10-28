param([string]$UpdaterPath = 'windows/updater/bin/Release/Updater.exe')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$assembly = [Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $UpdaterPath).Path)
[Windows.Application]::ResourceAssembly = $assembly
$app = [Windows.Application]::new()
try {
    $type = $assembly.GetType('KaraDelik.Updater.MainWindow', $true)
    $constructor = $type.GetConstructor([type[]]@([string[]]))
    $arguments = [object[]]@(,[string[]]@('http://127.0.0.1/unused', 'dark', 'tr', ''))
    # Construct only: do not Show/Run, so Loaded cannot download or launch setup.
    $window = $constructor.Invoke($arguments)
    if ($window.IsLoaded) { throw 'Unexpected Loaded event in constructor-only test.' }
    if (-not $window.Icon -or $window.Icon.Width -le 0) { throw 'Startup icon failed to decode.' }
    $window.Close()
    'PASS: Updater XAML constructor and startup icon load without starting update.'
} finally {
    $app.Shutdown()
}
