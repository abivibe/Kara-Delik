param([string]$UpdaterPath = 'windows/updater/bin/Release/Updater.exe')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$assembly = [Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $UpdaterPath).Path)
[Windows.Application]::ResourceAssembly = $assembly
$app = [Windows.Application]::new()
try {
    $constructor = $assembly.GetType('KaraDelik.Updater.MainWindow', $true).GetConstructor([type[]]@([string[]]))
    $window = $constructor.Invoke([object[]]@(,[string[]]@('http://127.0.0.1/unused', 'dark', 'tr', '')))
    $bar = $window.FindName('DownloadProgressBar')
    $null = $bar.ApplyTemplate()
    $track = $bar.Template.FindName('PART_Track', $bar)
    $indicator = $bar.Template.FindName('PART_Indicator', $bar)
    if (-not $track) { throw 'ProgressBar template is missing PART_Track.' }
    foreach ($percent in @(0, 25, 50, 100)) {
        $bar.Value = $percent
        $bar.Measure([Windows.Size]::new(300, 4))
        $bar.Arrange([Windows.Rect]::new(0, 0, 300, 4))
        $bar.UpdateLayout()
        $expected = $track.ActualWidth * $percent / 100
        if ([Math]::Abs($indicator.ActualWidth - $expected) -gt 1) {
            throw "Progress $percent percent: expected width $expected, actual $($indicator.ActualWidth)."
        }
    }
    if ($bar.Foreground -isnot [Windows.Media.SolidColorBrush] -or $bar.Foreground.Color.ToString() -ne '#FF3B82F6') {
        throw 'ProgressBar must use the requested blue foreground.'
    }
    if ($window.IsLoaded) { throw 'Progress test must not start the update pipeline.' }
    $window.Close()
    'PASS: Blue progress indicator fills correctly at 0/25/50/100 percent.'
} finally { $app.Shutdown() }
