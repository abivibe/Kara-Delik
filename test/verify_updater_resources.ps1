param([string]$UpdaterPath = 'windows/updater/bin/Release/Updater.exe')
$ErrorActionPreference = 'Stop'
$assembly = [Reflection.Assembly]::LoadFile((Resolve-Path -LiteralPath $UpdaterPath).Path)
$stream = $assembly.GetManifestResourceStream('Updater.g.resources')
if (-not $stream) { throw 'Updater WPF resources missing.' }
$reader = [Resources.ResourceReader]::new($stream)
try {
    $keys = @($reader.GetEnumerator() | ForEach-Object { $_.Key })
    if ('app_icon.ico' -notin $keys) {
        throw 'Updater startup icon is not embedded as a WPF resource.'
    }
    'PASS: Standalone updater contains its WPF startup icon.'
} finally {
    $reader.Close()
    $stream.Dispose()
}
