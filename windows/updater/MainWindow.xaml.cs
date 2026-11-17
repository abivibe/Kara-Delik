using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace KaraDelik.Updater
{
    public partial class MainWindow : Window
    {
        private readonly string _downloadUrl;
        private readonly string _themeMode;
        private readonly string _langCode;
        private readonly string _mainAppPath;

        private readonly bool _isEn;
        private DispatcherTimer _fadeTimer;
        private int _phraseIndex = 0;
        private string[] _fadingPhrases;

        public MainWindow(string[] args)
        {
            InitializeComponent();

            // CLI arguments parsing:
            // [0] = downloadUrl
            // [1] = themeMode (dark/light)
            // [2] = langCode (tr/en)
            // [3] = mainAppPath
            _downloadUrl = args != null && args.Length > 0 && !string.IsNullOrWhiteSpace(args[0])
                ? args[0].Trim()
                : "https://github.com/abivibe/Kara-Delik/releases/latest/download/KaraDelik_Setup.exe";

            _themeMode = args != null && args.Length > 1 && !string.IsNullOrWhiteSpace(args[1])
                ? args[1].Trim().ToLowerInvariant()
                : "dark";

            _langCode = args != null && args.Length > 2 && !string.IsNullOrWhiteSpace(args[2])
                ? args[2].Trim().ToLowerInvariant()
                : "tr";

            _mainAppPath = args != null && args.Length > 3 && !string.IsNullOrWhiteSpace(args[3])
                ? args[3].Trim()
                : "";

            _isEn = _langCode.StartsWith("en");

            // Pencereyi fare ile sürüklenebilir yap
            MouseLeftButtonDown += (s, e) =>
            {
                if (e.ButtonState == MouseButtonState.Pressed)
                {
                    try { DragMove(); } catch { }
                }
            };

            ApplyTheme(_themeMode);
            InitializeLocalization();
            StartSpinnerAnimation();
            StartSequentialFadeAnimation();

            Loaded += MainWindow_Loaded;
        }

        private void ApplyTheme(string mode)
        {
            bool isLight = mode == "light";

            if (isLight)
            {
                // Açık Tema
                Resources["WindowBgBrush"] = new SolidColorBrush(Color.FromRgb(255, 255, 255));
                Resources["BorderBrush"] = new SolidColorBrush(Color.FromRgb(226, 232, 240));
                Resources["TextPrimaryBrush"] = new SolidColorBrush(Color.FromRgb(15, 23, 42));
                Resources["TextSecondaryBrush"] = new SolidColorBrush(Color.FromRgb(100, 116, 139));
                Resources["TrackBrush"] = new SolidColorBrush(Color.FromRgb(226, 232, 240));

                var accent = new LinearGradientBrush
                {
                    StartPoint = new Point(0, 0),
                    EndPoint = new Point(1, 1)
                };
                accent.GradientStops.Add(new GradientStop(Color.FromRgb(37, 99, 235), 0.0));
                accent.GradientStops.Add(new GradientStop(Color.FromRgb(29, 78, 216), 1.0));
                Resources["AccentBrush"] = accent;
            }
            else
            {
                // AMOLED Koyu Tema
                Resources["WindowBgBrush"] = new SolidColorBrush(Color.FromRgb(16, 17, 22));
                Resources["BorderBrush"] = new SolidColorBrush(Color.FromRgb(38, 40, 52));
                Resources["TextPrimaryBrush"] = new SolidColorBrush(Color.FromRgb(243, 244, 248));
                Resources["TextSecondaryBrush"] = new SolidColorBrush(Color.FromRgb(140, 144, 164));
                Resources["TrackBrush"] = new SolidColorBrush(Color.FromRgb(31, 33, 44));

                var accent = new LinearGradientBrush
                {
                    StartPoint = new Point(0, 0),
                    EndPoint = new Point(1, 1)
                };
                accent.GradientStops.Add(new GradientStop(Color.FromRgb(56, 189, 248), 0.0));
                accent.GradientStops.Add(new GradientStop(Color.FromRgb(59, 130, 246), 1.0));
                Resources["AccentBrush"] = accent;
            }
        }

        private void InitializeLocalization()
        {
            if (_isEn)
            {
                _fadingPhrases = new[]
                {
                    "Updating...",
                    "Refreshing required files..."
                };
                StepDetailTextBlock.Text = "Downloading...";
                PercentTextBlock.Text = "0%";
            }
            else
            {
                _fadingPhrases = new[]
                {
                    "Güncellemeler yapılıyor...",
                    "Gerekli dosyalar yenileniyor..."
                };
                StepDetailTextBlock.Text = "İndiriliyor...";
                PercentTextBlock.Text = "%0";
            }

            StatusTextBlock.Text = _fadingPhrases[0];
        }

        private void StartSpinnerAnimation()
        {
            var rotateAnim = new DoubleAnimation
            {
                From = 0,
                To = 360,
                Duration = new Duration(TimeSpan.FromSeconds(1.0)),
                RepeatBehavior = RepeatBehavior.Forever
            };
            SpinnerRotate.BeginAnimation(RotateTransform.AngleProperty, rotateAnim);
        }

        private void StartSequentialFadeAnimation()
        {
            _fadeTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromSeconds(2.6)
            };
            _fadeTimer.Tick += (s, e) =>
            {
                var fadeOut = new DoubleAnimation(1.0, 0.0, TimeSpan.FromMilliseconds(260));
                fadeOut.Completed += (s2, e2) =>
                {
                    _phraseIndex = (_phraseIndex + 1) % _fadingPhrases.Length;
                    StatusTextBlock.Text = _fadingPhrases[_phraseIndex];
                    var fadeIn = new DoubleAnimation(0.0, 1.0, TimeSpan.FromMilliseconds(260));
                    StatusTextBlock.BeginAnimation(OpacityProperty, fadeIn);
                };
                StatusTextBlock.BeginAnimation(OpacityProperty, fadeOut);
            };
            _fadeTimer.Start();
        }

        private void SmoothChangeStatus(string newText)
        {
            if (_fadeTimer != null) _fadeTimer.Stop();
            var fadeOut = new DoubleAnimation(1.0, 0.0, TimeSpan.FromMilliseconds(200));
            fadeOut.Completed += (s, e) =>
            {
                StatusTextBlock.Text = newText;
                var fadeIn = new DoubleAnimation(0.0, 1.0, TimeSpan.FromMilliseconds(200));
                StatusTextBlock.BeginAnimation(OpacityProperty, fadeIn);
            };
            StatusTextBlock.BeginAnimation(OpacityProperty, fadeOut);
        }

        private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
        {
            await RunUpdatePipelineAsync();
        }

        private async Task RunUpdatePipelineAsync()
        {
            string tempDirectory = Path.Combine(Path.GetTempPath(), "KaraDelik-" + Guid.NewGuid().ToString("N"));
            string tempSetupPath = Path.Combine(tempDirectory, "KaraDelik_Setup.exe");
            string errorMessage = "";

            try
            {
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
                var setupUri = ValidateSetupUrl(_downloadUrl);
                Directory.CreateDirectory(tempDirectory);
                string expectedHash = await DownloadExpectedHashAsync(new Uri(setupUri, "SHA256SUMS.txt"));

                // 1. İNDİRME AŞAMASI
                bool downloadSuccess = await DownloadSetupFileAsync(setupUri, tempSetupPath);
                if (!downloadSuccess)
                {
                    SmoothChangeStatus(_isEn ? "Download failed, retrying..." : "İndirme başarısız oldu, tekrar deneniyor...");
                    await Task.Delay(2000);
                    downloadSuccess = await DownloadSetupFileAsync(setupUri, tempSetupPath);
                }

                if (!downloadSuccess)
                {
                    SmoothChangeStatus(_isEn ? "Update could not be downloaded." : "Güncelleme indirilemedi.");
                    await Task.Delay(3000);
                    Application.Current.Shutdown();
                    return;
                }

                if (!MatchesSetupHash(tempSetupPath, expectedHash))
                    throw new InvalidDataException(_isEn ? "Installer checksum does not match." : "Kurulum dosyasi dogrulanamadi.");

                // 2. SESSİZ KURULUM AŞAMASI
                SmoothChangeStatus(_isEn ? "Installing new version..." : "Yeni sürüm kuruluyor...");
                StepDetailTextBlock.Text = _isEn ? "Installing..." : "Kuruluyor...";
                DownloadProgressBar.Value = 100;
                DownloadProgressBar.IsIndeterminate = false;
                PercentTextBlock.Text = _isEn ? "100%" : "%100";

                await Task.Delay(500);

                var startInfo = new ProcessStartInfo
                {
                    FileName = tempSetupPath,
                    Arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART",
                    UseShellExecute = true,
                    CreateNoWindow = true
                };

                if (!string.IsNullOrWhiteSpace(_mainAppPath))
                {
                    startInfo.Arguments += " /DIR=\"" + Path.GetDirectoryName(Path.GetFullPath(_mainAppPath)) + "\"";
                }
                using (var setupProcess = Process.Start(startInfo))
                {
                    if (setupProcess == null) throw new InvalidOperationException("Setup could not be started.");
                    await Task.Run(() => setupProcess.WaitForExit());
                    if (setupProcess.ExitCode != 0)
                        throw new InvalidOperationException("Setup failed (code " + setupProcess.ExitCode + ").");
                }

                // 3. TAMAMLANMA VE YENİDEN BAŞLATMA
                SmoothChangeStatus(_isEn ? "Application updated, launching in 3 seconds..." : "Uygulama güncellendi, 3 saniye sonra açılıyor...");
                StepDetailTextBlock.Text = _isEn ? "Completed" : "Tamamlandı";

                await Task.Delay(3000);

                // Ana uygulamayı (KaraDelik.exe) yeniden başlat
                try
                {
                    string targetExe = _mainAppPath;
                    if (string.IsNullOrWhiteSpace(targetExe) || !File.Exists(targetExe))
                    {
                        targetExe = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "karadelik.exe");
                    }

                    if (File.Exists(targetExe))
                    {
                        Process.Start(new ProcessStartInfo
                        {
                            FileName = targetExe,
                            UseShellExecute = true,
                            WorkingDirectory = Path.GetDirectoryName(targetExe)
                        });
                    }
                }
                catch { }

                // Updater.exe kendisini kapatsın
                Application.Current.Shutdown();
                return;
            }
            catch (Exception ex)
            {
                errorMessage = ex.Message;
            }

            finally
            {
                try { if (Directory.Exists(tempDirectory)) Directory.Delete(tempDirectory, true); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }

            SmoothChangeStatus(_isEn ? "Update error occurred." : "Güncelleme hatası oluştu.");
            StepDetailTextBlock.Text = errorMessage;
            await Task.Delay(4000);
            Application.Current.Shutdown();
        }

        private static Uri ValidateSetupUrl(string url)
        {
            Uri uri;
            if (!Uri.TryCreate(url, UriKind.Absolute, out uri) ||
                uri.Scheme != Uri.UriSchemeHttps || uri.Host != "github.com" ||
                !uri.IsDefaultPort || uri.UserInfo.Length != 0 ||
                uri.Query.Length != 0 || uri.Fragment.Length != 0 ||
                !Regex.IsMatch(uri.AbsolutePath,
                    @"^/abivibe/Kara-Delik/releases/(?:download/v[0-9]+\.[0-9]+\.[0-9]+|latest/download)/KaraDelik_Setup\.exe$"))
                throw new InvalidDataException("The installer URL must point to a Kara Delik GitHub release.");
            return uri;
        }

        private static async Task<HttpResponseMessage> GetReleaseAssetAsync(HttpClient client, Uri uri)
        {
            for (int redirects = 0; redirects <= 4; redirects++)
            {
                if (uri.Scheme != Uri.UriSchemeHttps || !uri.IsDefaultPort ||
                    uri.UserInfo.Length != 0 ||
                    (uri.Host != "github.com" && uri.Host != "release-assets.githubusercontent.com" &&
                     uri.Host != "objects.githubusercontent.com"))
                    throw new InvalidDataException("Untrusted GitHub release redirect.");

                var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead);
                int status = (int)response.StatusCode;
                if (status < 300 || status >= 400) return response;
                using (response)
                {
                    var location = response.Headers.Location;
                    if (location == null) throw new InvalidDataException("Missing release redirect URL.");
                    uri = new Uri(uri, location);
                }
                if (uri.Host == "github.com" &&
                    !Regex.IsMatch(uri.AbsolutePath,
                        @"^/abivibe/Kara-Delik/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/(?:KaraDelik_Setup\.exe|SHA256SUMS\.txt)$"))
                    throw new InvalidDataException("Untrusted GitHub release path.");
            }
            throw new InvalidDataException("Too many release redirects.");
        }

        private static async Task<string> DownloadExpectedHashAsync(Uri uri)
        {
            using (var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }))
            {
                client.Timeout = TimeSpan.FromSeconds(30);
                client.MaxResponseContentBufferSize = 4096;
                client.DefaultRequestHeaders.Add("User-Agent", "KaraDelik-App");
                using (var response = await GetReleaseAssetAsync(client, uri))
                {
                    response.EnsureSuccessStatusCode();
                    await response.Content.LoadIntoBufferAsync(4096);
                    var checksums = await response.Content.ReadAsStringAsync();
                    var match = Regex.Match(checksums,
                        @"^([a-fA-F0-9]{64})[ 	]+\*?KaraDelik_Setup\.exe?$",
                        RegexOptions.Multiline);
                    if (!match.Success) throw new InvalidDataException("Missing installer checksum.");
                    return match.Groups[1].Value;
                }
            }
        }

        private static bool MatchesSetupHash(string path, string expectedHash)
        {
            using (var sha = SHA256.Create())
            using (var file = File.OpenRead(path))
            {
                string actualHash = BitConverter.ToString(sha.ComputeHash(file)).Replace("-", "");
                return string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase);
            }
        }

        private async Task<bool> DownloadSetupFileAsync(Uri url, string destinationPath)
        {
            try
            {
                // GitHub HTTPS bağlantıları için modern TLS protokollerini etkinleştir
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | (SecurityProtocolType)3072;

                using (var handler = new HttpClientHandler { AllowAutoRedirect = false })
                using (var client = new HttpClient(handler))
                {
                    client.Timeout = TimeSpan.FromMinutes(10);
                    client.DefaultRequestHeaders.Add("User-Agent", "KaraDelik-App");
                    DownloadProgressBar.IsIndeterminate = false;
                    DownloadProgressBar.Value = 0;

                    using (var response = await GetReleaseAssetAsync(client, url))
                    {
                        response.EnsureSuccessStatusCode();

                        long? totalBytes = response.Content.Headers.ContentLength;

                        using (var contentStream = await response.Content.ReadAsStreamAsync())
                        using (var fileStream = new FileStream(destinationPath, FileMode.Create, FileAccess.Write, FileShare.None, 81920, true))
                        {
                            byte[] buffer = new byte[81920];
                            long totalRead = 0;
                            int bytesRead;

                            while ((bytesRead = await contentStream.ReadAsync(buffer, 0, buffer.Length)) > 0)
                            {
                                await fileStream.WriteAsync(buffer, 0, bytesRead);
                                totalRead += bytesRead;

                                if (totalBytes.HasValue && totalBytes.Value > 0)
                                {
                                    double progressRatio = (double)totalRead / totalBytes.Value;
                                    int percent = (int)(progressRatio * 100);
                                    if (percent > 100) percent = 100;

                                    Dispatcher.Invoke(() =>
                                    {
                                        DownloadProgressBar.IsIndeterminate = false;
                                        DownloadProgressBar.Value = percent;
                                        PercentTextBlock.Text = _isEn ? (percent.ToString() + "%") : ("%" + percent.ToString());
                                    });
                                }
                                else
                                {
                                    Dispatcher.Invoke(() =>
                                    {
                                        DownloadProgressBar.IsIndeterminate = true;
                                        PercentTextBlock.Text = "...";
                                    });
                                }
                            }
                        }
                    }
                }

                return File.Exists(destinationPath) && new FileInfo(destinationPath).Length > 0;
            }
            catch
            {
                return false;
            }
        }
    }
}
