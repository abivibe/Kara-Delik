using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("KaraDelik Notifier")]
[assembly: AssemblyDescription("KaraDelik Bildirim ve Klasör Yöneticisi")]
[assembly: AssemblyConfiguration("")]
[assembly: AssemblyCompany("KaraDelik")]
[assembly: AssemblyProduct("KaraDelik")]
[assembly: AssemblyCopyright("Copyright © 2026 KaraDelik. Tüm hakları saklıdır.")]
[assembly: AssemblyTrademark("KaraDelik")]
[assembly: AssemblyCulture("")]
[assembly: AssemblyVersion("1.0.2.0")]
[assembly: AssemblyFileVersion("1.0.2.0")]

namespace KaraDelikNotifier
{
    static class Program
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [STAThread]
        static void Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "/open")
            {
                string target = args.Length > 1 ? args[1] : "";
                if (!string.IsNullOrEmpty(target))
                {
                    FolderOpener.OpenFolderAndSelectItem(target);
                }
                return;
            }

            try { SetProcessDPIAware(); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            if (args.Length > 0 && (args[0] == "/prompt" || args[0] == "-prompt"))
            {
                string url = args.Length > 1 ? args[1] : "";
                string title = args.Length > 2 ? args[2] : "KaraDelik";
                string message = args.Length > 3 ? args[3] : "Kopyalanan bağlantıyı indirmek ister misiniz?";
                string btnText = args.Length > 4 ? args[4] : "İndir";
                string cancelText = args.Length > 5 ? args[5] : "Kapat";

                Application.Run(new PromptForm(url, title, message, btnText, cancelText));
                return;
            }

            if (args.Length > 0 && (args[0] == "/complete" || args[0] == "-complete"))
            {
                string cPath = args.Length > 1 ? args[1] : "";
                string cTitle = args.Length > 2 ? args[2] : "İndirme Tamamlandı";
                Application.Run(new NotificationForm(cPath, cTitle));
                return;
            }

            string filePath = args.Length > 0 ? args[0] : "";
            string notifTitle = args.Length > 1 ? args[1] : "İndirme Tamamlandı";

            Application.Run(new NotificationForm(filePath, notifTitle));
        }
    }

    public static class AudioPlayer
    {
        [DllImport("winmm.dll", EntryPoint = "mciSendStringW", CharSet = CharSet.Unicode)]
        private static extern int mciSendString(string command, StringBuilder returnValue, int returnLength, IntPtr winHandle);

        public static void Play(string fileName)
        {
            try
            {
                string soundPath = FindSoundFile(fileName);
                if (string.IsNullOrEmpty(soundPath) || !File.Exists(soundPath)) return;

                string alias = "kd_sound_" + Guid.NewGuid().ToString("N").Substring(0, 8);
                mciSendString("close " + alias, null, 0, IntPtr.Zero);
                mciSendString("open \"" + soundPath + "\" type mpegvideo alias " + alias, null, 0, IntPtr.Zero);
                mciSendString("setaudio " + alias + " volume to 500", null, 0, IntPtr.Zero); // %50 ses seviyesi
                mciSendString("play " + alias, null, 0, IntPtr.Zero);
            }
            catch { }
        }

        private static string FindSoundFile(string fileName)
        {
            try
            {
                string baseDir = AppDomain.CurrentDomain.BaseDirectory;
                string[] candidates = new string[]
                {
                    Path.Combine(baseDir, fileName),
                    Path.Combine(baseDir, "sounds", fileName),
                    Path.Combine(baseDir, "assets", fileName),
                    Path.Combine(baseDir, "assets", "sounds", fileName),
                    Path.Combine(baseDir, "data", "flutter_assets", "assets", "sounds", fileName),
                    Path.Combine(baseDir, "..", "..", "assets", "sounds", fileName),
                    Path.Combine(baseDir, "..", "..", "windows", "bin", fileName),
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", fileName)
                };

                for (int i = 0; i < candidates.Length; i++)
                {
                    if (File.Exists(candidates[i]))
                    {
                        return Path.GetFullPath(candidates[i]);
                    }
                }
            }
            catch { }
            return null;
        }
    }

    public static class KaraDelikHelper
    {
        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        private const int SW_RESTORE = 9;
        private const int SW_SHOW = 5;

        public static void BringKaraDelikToFront()
        {
            try
            {
                IntPtr targetHwnd = IntPtr.Zero;

                string[] procNames = new string[] { "karadelik", "KaraDelik", "runner" };
                for (int i = 0; i < procNames.Length; i++)
                {
                    Process[] procs = Process.GetProcessesByName(procNames[i]);
                    for (int j = 0; j < procs.Length; j++)
                    {
                        if (procs[j].MainWindowHandle != IntPtr.Zero)
                        {
                            targetHwnd = procs[j].MainWindowHandle;
                            break;
                        }
                    }
                    if (targetHwnd != IntPtr.Zero) break;
                }

                if (targetHwnd == IntPtr.Zero)
                {
                    targetHwnd = FindWindow(null, "KaraDelik Downloader");
                }
                if (targetHwnd == IntPtr.Zero)
                {
                    targetHwnd = FindWindow(null, "karadelik");
                }

                if (targetHwnd != IntPtr.Zero)
                {
                    if (IsIconic(targetHwnd))
                    {
                        ShowWindow(targetHwnd, SW_RESTORE);
                    }
                    else
                    {
                        ShowWindow(targetHwnd, SW_SHOW);
                    }
                    SetForegroundWindow(targetHwnd);
                }
            }
            catch { }
        }
    }

    /// <summary>
    /// Sağ alt köşede fade-in ile açılan "Bağlantıyı indirmek ister misiniz?" onay balonu.
    /// Geri sayım (5 sn) bittiğinde veya "İndir" tıklandığında: ExitCode = 101 (Arka planda sessiz indirme, pencere açılmaz).
    /// "Uygulamada Göster" tıklandığında: ExitCode = 102 (Pencere ekrana getirilir ve indirme başlatılır).
    /// Kapatıldığında: ExitCode = 0.
    /// </summary>
    public class PromptForm : Form
    {
        private readonly string _url;
        private readonly string _title;
        private readonly string _message;
        private readonly string _btnText;
        private readonly string _showInAppText;

        private readonly Timer _fadeTimer;
        private readonly Timer _countdownTimer;
        private double _targetOpacity = 0.98;
        private bool _isClosing = false;
        private bool _isHovered = false;
        private int _countdownSeconds = 5;

        private Rectangle _btnDownload;
        private Rectangle _btnShowInApp;
        private Rectangle _btnClose;
        private bool _isDownloadHovered = false;
        private bool _isShowInAppHovered = false;
        private bool _isCloseHovered = false;

        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

        private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        private const uint SWP_NOMOVE = 0x0002;
        private const uint SWP_NOSIZE = 0x0001;
        private const uint SWP_NOACTIVATE = 0x0010;
        private const uint SWP_SHOWWINDOW = 0x0040;

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
                cp.ClassStyle |= 0x00020000; // CS_DROPSHADOW
                return cp;
            }
        }

        public PromptForm(string url, string title, string message, string btnText, string cancelText)
        {
            _url = url ?? "";
            _title = string.IsNullOrEmpty(title) ? "KaraDelik" : title;
            _message = string.IsNullOrEmpty(message) ? "Kopyalanan bağlantıyı indirmek ister misiniz?" : message;
            _btnText = string.IsNullOrEmpty(btnText) ? "İndir" : btnText;
            _showInAppText = "Uygulamada Göster";

            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            DoubleBuffered = true;
            Width = 440;
            Height = 100;
            Opacity = 0.0;
            BackColor = Color.FromArgb(16, 16, 18);

            // Ekranın sağ alt köşesi
            Rectangle workArea = Screen.PrimaryScreen.WorkingArea;
            int margin = 20;
            Location = new Point(workArea.Right - Width - margin, workArea.Bottom - Height - margin);

            // Buton koordinatları
            _btnClose = new Rectangle(Width - 28, 8, 20, 20);
            _btnDownload = new Rectangle(Width - 110, 58, 98, 28);
            _btnShowInApp = new Rectangle(Width - 246, 58, 130, 28);

            _fadeTimer = new Timer { Interval = 15 };
            _fadeTimer.Tick += OnFadeTick;

            // 1 saniyelik geri sayım sayacı (5 sn)
            _countdownTimer = new Timer { Interval = 1000 };
            _countdownTimer.Tick += (s, e) =>
            {
                if (_isClosing) return;
                if (!_isHovered)
                {
                    _countdownSeconds--;
                    if (_countdownSeconds <= 0)
                    {
                        _countdownTimer.Stop();
                        Dismiss(false);
                        return;
                    }
                    Invalidate();
                }
            };

            MouseEnter += (s, e) => { _isHovered = true; };
            MouseLeave += (s, e) =>
            {
                _isHovered = false;
                _isDownloadHovered = false;
                _isShowInAppHovered = false;
                _isCloseHovered = false;
                Invalidate();
            };
            MouseMove += OnMouseMove;
            MouseClick += OnMouseClick;

            SetRoundedRegion();
        }

        private void SetRoundedRegion()
        {
            using (GraphicsPath path = GetRoundedRectPath(new Rectangle(0, 0, Width, Height), 12))
            {
                Region = new Region(path);
            }
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
            _targetOpacity = 0.98;
            _fadeTimer.Start();
            _countdownTimer.Start();

            // iPhone mesaj gönderme bildirim sesi
            AudioPlayer.Play("bildirimtetik.mp3");
        }

        private void OnFadeTick(object sender, EventArgs e)
        {
            if (!_isClosing)
            {
                Opacity += 0.05;
                if (Opacity >= _targetOpacity)
                {
                    Opacity = _targetOpacity;
                    _fadeTimer.Stop();
                }
            }
            else
            {
                Opacity -= 0.05;
                if (Opacity <= 0.0)
                {
                    Opacity = 0.0;
                    _fadeTimer.Stop();
                    Close();
                    Application.Exit();
                }
            }
        }

        private void OnMouseMove(object sender, MouseEventArgs e)
        {
            bool dlHover = _btnDownload.Contains(e.Location);
            bool appHover = _btnShowInApp.Contains(e.Location);
            bool closeHover = _btnClose.Contains(e.Location);

            if (dlHover != _isDownloadHovered || appHover != _isShowInAppHovered || closeHover != _isCloseHovered)
            {
                _isDownloadHovered = dlHover;
                _isShowInAppHovered = appHover;
                _isCloseHovered = closeHover;
                Cursor = (dlHover || appHover || closeHover) ? Cursors.Hand : Cursors.Default;
                Invalidate();
            }
        }

        private void OnMouseClick(object sender, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;

            if (_btnClose.Contains(e.Location))
            {
                Dismiss(false);
                return;
            }

            if (_btnShowInApp.Contains(e.Location))
            {
                ConfirmShowInApp();
                return;
            }

            if (_btnDownload.Contains(e.Location))
            {
                ConfirmBackgroundDownload();
                return;
            }
        }

        /// <summary>
        /// Arka planda sessiz indirme: Pencereyi ekrana getirme, ExitCode = 101 ile sonlan.
        /// </summary>
        private void ConfirmBackgroundDownload()
        {
            try
            {
                _countdownTimer.Stop();
                _fadeTimer.Stop();
                Environment.ExitCode = 101;
                Close();
                Application.Exit();
            }
            catch
            {
                Environment.ExitCode = 101;
                Application.Exit();
            }
        }

        /// <summary>
        /// Uygulamada Göster: KaraDelik penceresini öne getir, ExitCode = 102 ile sonlan.
        /// </summary>
        private void ConfirmShowInApp()
        {
            try
            {
                _countdownTimer.Stop();
                _fadeTimer.Stop();
                KaraDelikHelper.BringKaraDelikToFront();
                Environment.ExitCode = 102;
                Close();
                Application.Exit();
            }
            catch
            {
                Environment.ExitCode = 102;
                Application.Exit();
            }
        }

        private void Dismiss(bool confirmed)
        {
            if (_isClosing) return;
            _countdownTimer.Stop();
            _isClosing = true;
            _targetOpacity = 0.0;
            Environment.ExitCode = confirmed ? 101 : 0;
            _fadeTimer.Start();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);

            // Koyu AMOLED Şık Arka Plan
            using (LinearGradientBrush bgBrush = new LinearGradientBrush(
                rect,
                Color.FromArgb(20, 20, 24),
                Color.FromArgb(12, 12, 14),
                LinearGradientMode.Vertical))
            {
                using (GraphicsPath path = GetRoundedRectPath(rect, 12))
                {
                    g.FillPath(bgBrush, path);
                    using (Pen borderPen = new Pen(Color.FromArgb(46, 50, 60), 1.2f))
                    {
                        g.DrawPath(borderPen, path);
                    }
                }
            }

            // Sol İkon Rozeti (Mavi İndirme / Bağlantı İkonu)
            int iconX = 14;
            int iconY = 16;
            Rectangle iconRect = new Rectangle(iconX, iconY, 36, 36);

            using (SolidBrush iconBg = new SolidBrush(Color.FromArgb(16, 36, 56)))
            {
                g.FillEllipse(iconBg, iconRect);
            }
            using (Pen iconBorder = new Pen(Color.FromArgb(100, 181, 246), 1.5f))
            {
                g.DrawEllipse(iconBorder, iconRect);
            }

            // İndirme Oku İkonu (⬇)
            using (Font checkFont = new Font("Segoe UI", 15, FontStyle.Bold))
            using (SolidBrush checkBrush = new SolidBrush(Color.FromArgb(100, 181, 246)))
            {
                StringFormat sf = new StringFormat
                {
                    Alignment = StringAlignment.Center,
                    LineAlignment = StringAlignment.Center
                };
                g.DrawString("⬇", checkFont, checkBrush, iconRect, sf);
            }

            // Başlık: "KaraDelik"
            int textX = 58;
            using (Font titleFont = new Font("Segoe UI", 10.0f, FontStyle.Bold))
            using (SolidBrush titleBrush = new SolidBrush(Color.White))
            {
                g.DrawString(_title, titleFont, titleBrush, new PointF(textX, 12));
            }

            // Soru Mesajı: "Kopyalanan bağlantıyı indirmek ister misiniz?"
            using (Font subFont = new Font("Segoe UI", 8.8f, FontStyle.Regular))
            using (SolidBrush subBrush = new SolidBrush(Color.FromArgb(220, 220, 230)))
            {
                g.DrawString(_message, subFont, subBrush, new PointF(textX, 32));
            }

            // Geri Sayım / Link Önizlemesi
            using (Font linkFont = new Font("Segoe UI", 7.8f, FontStyle.Regular))
            using (SolidBrush linkBrush = new SolidBrush(Color.FromArgb(100, 181, 246)))
            {
                string infoText = _countdownSeconds > 0
                    ? string.Format("{0} sn içinde indirilecek...", _countdownSeconds)
                    : "İndiriliyor...";
                RectangleF linkRect = new RectangleF(textX, 64, Width - textX - 256, 20);
                StringFormat linkSf = new StringFormat
                {
                    Trimming = StringTrimming.EllipsisCharacter,
                    FormatFlags = StringFormatFlags.NoWrap
                };
                g.DrawString(infoText, linkFont, linkBrush, linkRect, linkSf);
            }

            // Kapat Butonu (✕)
            using (Font closeFont = new Font("Segoe UI", 9.0f, FontStyle.Bold))
            using (SolidBrush closeBrush = new SolidBrush(_isCloseHovered ? Color.White : Color.FromArgb(120, 120, 130)))
            {
                StringFormat sfClose = new StringFormat
                {
                    Alignment = StringAlignment.Center,
                    LineAlignment = StringAlignment.Center
                };
                g.DrawString("✕", closeFont, closeBrush, _btnClose, sfClose);
            }

            // "Uygulamada Göster" Butonu (Modern Minimalist Koyu Buton)
            using (GraphicsPath appPath = GetRoundedRectPath(_btnShowInApp, 6))
            {
                Color aBg = _isShowInAppHovered ? Color.FromArgb(42, 46, 58) : Color.FromArgb(24, 26, 34);
                Color aBorder = _isShowInAppHovered ? Color.FromArgb(100, 181, 246) : Color.FromArgb(50, 56, 70);
                using (SolidBrush aBrush = new SolidBrush(aBg))
                using (Pen aPen = new Pen(aBorder, 1f))
                {
                    g.FillPath(aBrush, appPath);
                    g.DrawPath(aPen, appPath);
                }

                using (Font appFont = new Font("Segoe UI", 8.0f, FontStyle.Regular))
                using (SolidBrush aText = new SolidBrush(_isShowInAppHovered ? Color.White : Color.FromArgb(200, 210, 225)))
                {
                    StringFormat sfBtn = new StringFormat
                    {
                        Alignment = StringAlignment.Center,
                        LineAlignment = StringAlignment.Center
                    };
                    g.DrawString(_showInAppText, appFont, aText, _btnShowInApp, sfBtn);
                }
            }

            // "Hemen İndir (X)" Butonu (Canlı Mavi Aksan + Geri Sayım Rozeti)
            using (GraphicsPath btnPath = GetRoundedRectPath(_btnDownload, 6))
            {
                Color btnBg = _isDownloadHovered ? Color.FromArgb(33, 150, 243) : Color.FromArgb(25, 118, 210);
                Color btnBorder = _isDownloadHovered ? Color.FromArgb(144, 202, 249) : Color.FromArgb(100, 181, 246);
                using (SolidBrush bBg = new SolidBrush(btnBg))
                using (Pen bPen = new Pen(btnBorder, 1f))
                {
                    g.FillPath(bBg, btnPath);
                    g.DrawPath(bPen, btnPath);
                }

                using (Font btnFont = new Font("Segoe UI", 8.5f, FontStyle.Bold))
                using (SolidBrush btnText = new SolidBrush(Color.White))
                {
                    StringFormat sfBtn = new StringFormat
                    {
                        Alignment = StringAlignment.Center,
                        LineAlignment = StringAlignment.Center
                    };
                    string dlLabel = _countdownSeconds > 0
                        ? string.Format("{0} ({1})", _btnText, _countdownSeconds)
                        : _btnText;
                    g.DrawString(dlLabel, btnFont, btnText, _btnDownload, sfBtn);
                }
            }
        }

        private static GraphicsPath GetRoundedRectPath(Rectangle bounds, int radius)
        {
            GraphicsPath path = new GraphicsPath();
            int diameter = radius * 2;
            Size size = new Size(diameter, diameter);
            Rectangle arc = new Rectangle(bounds.Location, size);

            path.AddArc(arc, 180, 90);
            arc.X = bounds.Right - diameter;
            path.AddArc(arc, 270, 90);
            arc.Y = bounds.Bottom - diameter;
            path.AddArc(arc, 0, 90);
            arc.X = bounds.Left;
            path.AddArc(arc, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    /// <summary>
    /// Sağ üst köşede fade-in ile açılan indirme tamamlandı bildirimi.
    /// Açıldığında completed.mp3 sesini çalar.
    /// </summary>
    public class NotificationForm : Form
    {
        private readonly string _filePath;
        private readonly string _title;
        private readonly string _fileName;
        private readonly Timer _fadeTimer;
        private readonly Timer _stayTimer;
        private double _targetOpacity = 1.0;
        private bool _isClosing = false;
        private bool _isHovered = false;

        private Rectangle _btnFolder;
        private Rectangle _btnClose;
        private bool _isFolderHovered = false;
        private bool _isCloseHovered = false;

        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

        private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        private const uint SWP_NOMOVE = 0x0002;
        private const uint SWP_NOSIZE = 0x0001;
        private const uint SWP_NOACTIVATE = 0x0010;
        private const uint SWP_SHOWWINDOW = 0x0040;

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
                cp.ClassStyle |= 0x00020000; // CS_DROPSHADOW
                return cp;
            }
        }

        public NotificationForm(string filePath, string title)
        {
            _filePath = filePath;
            _title = string.IsNullOrEmpty(title) ? "İndirme Tamamlandı" : title;
            _fileName = !string.IsNullOrEmpty(filePath) ? Path.GetFileName(filePath) : "Dosya kaydedildi.";

            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            DoubleBuffered = true;
            Width = 380;
            Height = 84;
            Opacity = 0.0;
            BackColor = Color.FromArgb(16, 16, 18);

            // Sağ üst köşe konumu
            Rectangle workArea = Screen.PrimaryScreen.WorkingArea;
            int margin = 20;
            Location = new Point(workArea.Right - Width - margin, workArea.Top + margin);

            // Buton bölgeleri
            _btnClose = new Rectangle(Width - 30, 8, 22, 22);
            _btnFolder = new Rectangle(Width - 132, 46, 120, 28);

            // Animasyon ve kalma zamanlayıcıları
            _fadeTimer = new Timer { Interval = 15 };
            _fadeTimer.Tick += OnFadeTick;

            _stayTimer = new Timer { Interval = 6000 };
            _stayTimer.Tick += (s, e) =>
            {
                if (!_isHovered && !_isClosing)
                {
                    _stayTimer.Stop();
                    _isClosing = true;
                    _targetOpacity = 0.0;
                    _fadeTimer.Start();
                }
            };

            MouseEnter += (s, e) => { _isHovered = true; };
            MouseLeave += (s, e) =>
            {
                _isHovered = false;
                _isFolderHovered = false;
                _isCloseHovered = false;
                Invalidate();
            };
            MouseMove += OnMouseMove;
            MouseClick += OnMouseClick;

            SetRoundedRegion();
        }

        private void SetRoundedRegion()
        {
            using (GraphicsPath path = GetRoundedRectPath(new Rectangle(0, 0, Width, Height), 12))
            {
                Region = new Region(path);
            }
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
            _targetOpacity = 0.98;
            _fadeTimer.Start();
            _stayTimer.Start();

            // Tamamlanma bildirim sesi
            AudioPlayer.Play("completed.mp3");
        }

        private void OnFadeTick(object sender, EventArgs e)
        {
            if (!_isClosing)
            {
                Opacity += 0.05;
                if (Opacity >= _targetOpacity)
                {
                    Opacity = _targetOpacity;
                    _fadeTimer.Stop();
                }
            }
            else
            {
                Opacity -= 0.05;
                if (Opacity <= 0.0)
                {
                    Opacity = 0.0;
                    _fadeTimer.Stop();
                    Close();
                    Application.Exit();
                }
            }
        }

        private void OnMouseMove(object sender, MouseEventArgs e)
        {
            bool folderHover = _btnFolder.Contains(e.Location);
            bool closeHover = _btnClose.Contains(e.Location);

            if (folderHover != _isFolderHovered || closeHover != _isCloseHovered)
            {
                _isFolderHovered = folderHover;
                _isCloseHovered = closeHover;
                Cursor = (folderHover || closeHover) ? Cursors.Hand : Cursors.Default;
                Invalidate();
            }
        }

        private void OnMouseClick(object sender, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;

            if (_btnClose.Contains(e.Location))
            {
                Dismiss();
                return;
            }

            if (_btnFolder.Contains(e.Location) || (!_btnFolder.Contains(e.Location) && !_btnClose.Contains(e.Location)))
            {
                OpenFolder();
                Dismiss();
            }
        }

        private void OpenFolder()
        {
            FolderOpener.OpenFolderAndSelectItem(_filePath);
        }

        private void Dismiss()
        {
            if (_isClosing) return;
            _stayTimer.Stop();
            _isClosing = true;
            _targetOpacity = 0.0;
            _fadeTimer.Start();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);

            // Arka plan gradyanı
            using (LinearGradientBrush bgBrush = new LinearGradientBrush(
                rect,
                Color.FromArgb(20, 20, 24),
                Color.FromArgb(12, 12, 14),
                LinearGradientMode.Vertical))
            {
                using (GraphicsPath path = GetRoundedRectPath(rect, 12))
                {
                    g.FillPath(bgBrush, path);
                    // Dış çerçeve
                    using (Pen borderPen = new Pen(Color.FromArgb(46, 46, 54), 1.2f))
                    {
                        g.DrawPath(borderPen, path);
                    }
                }
            }

            // Sol Yeşil Onay Rozeti
            int iconX = 14;
            int iconY = (Height - 38) / 2;
            Rectangle iconRect = new Rectangle(iconX, iconY, 38, 38);

            using (SolidBrush iconBg = new SolidBrush(Color.FromArgb(14, 42, 26)))
            {
                g.FillEllipse(iconBg, iconRect);
            }
            using (Pen iconBorder = new Pen(Color.FromArgb(0, 230, 118), 1.5f))
            {
                g.DrawEllipse(iconBorder, iconRect);
            }

            // Onay işareti (✓)
            using (Font checkFont = new Font("Segoe UI", 16, FontStyle.Bold))
            using (SolidBrush checkBrush = new SolidBrush(Color.FromArgb(0, 230, 118)))
            {
                StringFormat sf = new StringFormat
                {
                    Alignment = StringAlignment.Center,
                    LineAlignment = StringAlignment.Center
                };
                g.DrawString("✓", checkFont, checkBrush, iconRect, sf);
            }

            // Başlık: "İndirme Tamamlandı"
            int textX = iconX + 48;
            using (Font titleFont = new Font("Segoe UI", 10.5f, FontStyle.Bold))
            using (SolidBrush titleBrush = new SolidBrush(Color.White))
            {
                g.DrawString(_title, titleFont, titleBrush, new PointF(textX, 13));
            }

            // Dosya Adı
            using (Font subFont = new Font("Segoe UI", 8.5f, FontStyle.Regular))
            using (SolidBrush subBrush = new SolidBrush(Color.FromArgb(160, 160, 172)))
            {
                RectangleF subRect = new RectangleF(textX, 36, Width - textX - 145, 36);
                StringFormat subSf = new StringFormat
                {
                    Trimming = StringTrimming.EllipsisCharacter,
                    FormatFlags = StringFormatFlags.NoWrap
                };
                g.DrawString(_fileName, subFont, subBrush, subRect, subSf);
            }

            // Kapat Butonu (✕)
            using (Font closeFont = new Font("Segoe UI", 9.5f, FontStyle.Bold))
            using (SolidBrush closeBrush = new SolidBrush(_isCloseHovered ? Color.White : Color.FromArgb(120, 120, 130)))
            {
                StringFormat sfClose = new StringFormat
                {
                    Alignment = StringAlignment.Center,
                    LineAlignment = StringAlignment.Center
                };
                g.DrawString("✕", closeFont, closeBrush, _btnClose, sfClose);
            }

            // "Klasörde Göster" Butonu
            using (GraphicsPath btnPath = GetRoundedRectPath(_btnFolder, 6))
            {
                Color btnBg = _isFolderHovered ? Color.FromArgb(36, 40, 50) : Color.FromArgb(24, 26, 32);
                Color btnBorder = _isFolderHovered ? Color.FromArgb(100, 181, 246) : Color.FromArgb(50, 54, 64);
                using (SolidBrush bBg = new SolidBrush(btnBg))
                using (Pen bPen = new Pen(btnBorder, 1f))
                {
                    g.FillPath(bBg, btnPath);
                    g.DrawPath(bPen, btnPath);
                }

                using (Font btnFont = new Font("Segoe UI", 8.5f, FontStyle.Bold))
                using (SolidBrush btnText = new SolidBrush(Color.FromArgb(100, 181, 246)))
                {
                    StringFormat sfBtn = new StringFormat
                    {
                        Alignment = StringAlignment.Center,
                        LineAlignment = StringAlignment.Center
                    };
                    g.DrawString("Klasörde Göster", btnFont, btnText, _btnFolder, sfBtn);
                }
            }
        }

        private static GraphicsPath GetRoundedRectPath(Rectangle bounds, int radius)
        {
            GraphicsPath path = new GraphicsPath();
            int diameter = radius * 2;
            Size size = new Size(diameter, diameter);
            Rectangle arc = new Rectangle(bounds.Location, size);

            path.AddArc(arc, 180, 90);
            arc.X = bounds.Right - diameter;
            path.AddArc(arc, 270, 90);
            arc.Y = bounds.Bottom - diameter;
            path.AddArc(arc, 0, 90);
            arc.X = bounds.Left;
            path.AddArc(arc, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    public static class FolderOpener
    {
        [DllImport("shell32.dll", ExactSpelling = true)]
        public static extern void ILFree(IntPtr pidl);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern IntPtr ILCreateFromPathW(string pszPath);

        [DllImport("shell32.dll", ExactSpelling = true)]
        public static extern int SHOpenFolderAndSelectItems(IntPtr pidlFolder, uint cidl, IntPtr apidl, uint dwFlags);

        public static bool OpenFolderAndSelectItem(string path)
        {
            if (string.IsNullOrEmpty(path)) return false;

            // 1. Birincil Strateji (Windows Shell API: SHOpenFolderAndSelectItems & ILCreateFromPathW)
            try
            {
                if (File.Exists(path) || Directory.Exists(path))
                {
                    IntPtr pidl = ILCreateFromPathW(path);
                    if (pidl != IntPtr.Zero)
                    {
                        try
                        {
                            int hr = SHOpenFolderAndSelectItems(pidl, 0, IntPtr.Zero, 0);
                            if (hr == 0) // S_OK
                            {
                                return true;
                            }
                        }
                        finally
                        {
                            ILFree(pidl);
                        }
                    }
                }
            }
            catch { }

            // 2. İkincil Strateji (Doğrudan C:\Windows\explorer.exe - UseShellExecute = false)
            try
            {
                string windir = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
                string explorerPath = Path.Combine(windir, "explorer.exe");
                if (!File.Exists(explorerPath)) explorerPath = "explorer.exe";

                string args;
                if (File.Exists(path))
                {
                    args = "/select,\"" + path + "\"";
                }
                else
                {
                    string dir = Directory.Exists(path) ? path : Path.GetDirectoryName(path);
                    if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir))
                    {
                        dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
                    }
                    args = "\"" + dir + "\"";
                }

                ProcessStartInfo psi = new ProcessStartInfo(explorerPath, args)
                {
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                Process p = Process.Start(psi);
                if (p != null) return true;
            }
            catch { }

            // 3. Üçüncül Strateji (Standart Windows Shell Çalıştırma)
            try
            {
                string targetDir = path;
                if (File.Exists(path)) targetDir = Path.GetDirectoryName(path);
                if (string.IsNullOrEmpty(targetDir) || !Directory.Exists(targetDir))
                {
                    targetDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
                }

                ProcessStartInfo psiFolder = new ProcessStartInfo(targetDir)
                {
                    UseShellExecute = true
                };
                Process pFolder = Process.Start(psiFolder);
                if (pFolder != null) return true;
            }
            catch { }

            return false;
        }
    }
}
