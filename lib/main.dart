import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path_lib;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'services/download_history_service.dart';
import 'services/download_service.dart';
import 'services/localization_service.dart';
import 'services/update_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && Platform.isWindows) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(440, 780),
      minimumSize: Size(380, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      title: 'Kara Delik (Black Hole)',
      titleBarStyle: TitleBarStyle.hidden,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  runApp(const KaraDelikApp());
}

// Global tema yöneticisi
final ValueNotifier<ThemeMode> appThemeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.dark);

class KaraDelikApp extends StatefulWidget {
  const KaraDelikApp({super.key});

  @override
  State<KaraDelikApp> createState() => _KaraDelikAppState();
}

class _KaraDelikAppState extends State<KaraDelikApp> {
  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final configFile = File('${dir.path}/app_config.json');
      if (await configFile.exists()) {
        final data = jsonDecode(await configFile.readAsString());
        if (data is Map) {
          if (data['themeMode'] != null) {
            appThemeModeNotifier.value =
                data['themeMode'] == 'light' ? ThemeMode.light : ThemeMode.dark;
          }
          if (data['language'] != null) {
            appLanguageNotifier.value = data['language'] as String;
          }
          if (data['customDownloadPath'] != null &&
              (data['customDownloadPath'] as String).isNotEmpty) {
            DownloadService().customDownloadPath =
                data['customDownloadPath'] as String;
          }
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeModeNotifier,
      builder: (context, currentMode, _) {
        return ValueListenableBuilder<String>(
          valueListenable: appLanguageNotifier,
          builder: (context, currentLang, _) {
            return MaterialApp(
              title: AppLocalizations.tr('app_title'),
              debugShowCheckedModeBanner: false,
              themeMode: currentMode,
              // Açık Tema
              theme: ThemeData(
                brightness: Brightness.light,
                scaffoldBackgroundColor: const Color(0xFFF7F9FC),
                canvasColor: const Color(0xFFFFFFFF),
                cardColor: const Color(0xFFFFFFFF),
                colorScheme: const ColorScheme.light(
                  primary: Color(0xFF1E88E5),
                  secondary: Color(0xFF1976D2),
                  surface: Color(0xFFFFFFFF),
                ),
                fontFamily: 'Segoe UI',
                useMaterial3: true,
                appBarTheme: const AppBarTheme(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  iconTheme: IconThemeData(color: Colors.black87),
                  titleTextStyle: TextStyle(
                    color: Colors.black87,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              // Varsayılan Saf AMOLED Siyah Koyu Tema
              darkTheme: ThemeData(
                brightness: Brightness.dark,
                scaffoldBackgroundColor: const Color(0xFF000000),
                canvasColor: const Color(0xFF121212),
                cardColor: const Color(0xFF121212),
                colorScheme: const ColorScheme.dark(
                  primary: Color(0xFFE0E0E0),
                  secondary: Color(0xFF64B5F6),
                  surface: Color(0xFF121212),
                ),
                fontFamily: 'Segoe UI',
                useMaterial3: true,
                appBarTheme: const AppBarTheme(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  iconTheme: IconThemeData(color: Colors.white70),
                  titleTextStyle: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              home: const HomeScreen(),
            );
          },
        );
      },
    );
  }
}

enum DownloadState {
  checkingClipboard,
  waitingForLink,
  readyToDownload,
  downloading,
  completed,
  error,
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin, WindowListener {
  final DownloadService _downloadService = DownloadService();
  final DownloadHistoryService _historyService = DownloadHistoryService();
  final TextEditingController _urlController = TextEditingController();



  DownloadState _state = DownloadState.checkingClipboard;
  String _statusText = '';
  String? _detectedUrl;
  double _progress = 0.0;
  DownloadQuality _selectedQuality = DownloadQuality.mp4;
  String _downloadSpeed = '';
  String _downloadEta = '';
  bool _autoClipboardCheck = true;

  String? _notificationBannerFile;
  Timer? _notificationBannerTimer;
  Timer? _updateCheckTimer;

  // Uygulama Açılış & Kapanış Fade Efekti
  late AnimationController _windowFadeController;
  late Animation<double> _windowFadeAnimation;
  bool _isExiting = false;

  // Yerinde Değişen Fade Yukarı Label ve Pencere Başlığı Listesi
  final List<String> _rotatingPhrases = [
    'Kara Delik (Black Hole)',
    'a Video & MP3 Downloader',
    'YouTube',
    'Instagram',
    'TikTok',
    'X (Twitter)',
    'Facebook',
  ];
  int _currentPhraseIndex = 0;
  late AnimationController _rotatingLabelController;
  late Animation<double> _rotatingFadeAnimation;
  late Animation<Offset> _rotatingSlideAnimation;

  void _showNotificationBanner(String filePath) {
    _notificationBannerTimer?.cancel();
    setState(() {
      _notificationBannerFile = filePath;
    });
    _notificationBannerTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) {
        setState(() {
          _notificationBannerFile = null;
        });
      }
    });
  }

  void _hideNotificationBanner() {
    _notificationBannerTimer?.cancel();
    if (mounted) {
      setState(() {
        _notificationBannerFile = null;
      });
    }
  }

  String? _lastPromptedUrl;
  bool _isPrompting = false;

  /// WINDOWS İÇİN ÖZEL PANO ONAY BİLDİRİMİ (UYGULAMA KÜÇÜLTÜLMÜŞ/ARKA PLANDAYKEN SAĞ ALTA ÇIKAN FADE BALONCUK)
  Future<void> _showClipboardPromptNotification(String url) async {
    if (!_isWindows || _isPrompting) return;
    _isPrompting = true;
    try {
      final exeDir = path_lib.dirname(Platform.resolvedExecutable);
      String notifierPath = path_lib.join(exeDir, 'KaraDelikNotifier.exe');
      if (!File(notifierPath).existsSync()) {
        notifierPath = path_lib.join(Directory.current.path, 'windows', 'bin', 'KaraDelikNotifier.exe');
      }
      if (File(notifierPath).existsSync()) {
        final process = await Process.start(
          notifierPath,
          [
            '/prompt',
            url,
            AppLocalizations.tr('clipboard_prompt_title'),
            AppLocalizations.tr('clipboard_prompt_desc'),
            AppLocalizations.tr('clipboard_prompt_btn'),
            AppLocalizations.tr('clipboard_prompt_cancel'),
          ],
        );
        final exitCode = await process.exitCode;
        if ((exitCode == 101 || exitCode == 102 || exitCode == 100) && mounted) {
          if (exitCode == 102) {
            // Kullanıcı "Uygulamada Göster" seçti: KaraDelik penceresini ekrana getir ve bekle
            try {
              await windowManager.show();
              await windowManager.restore();
              await windowManager.focus();
            } catch (_) {}
            setState(() {
              _detectedUrl = url;
              _urlController.text = url;
              _state = DownloadState.readyToDownload;
              _statusText = AppLocalizations.tr('status_ready');
            });
            return;
          }
          // exitCode == 101: Kullanıcı bildirimdeki "İndir" butonuna tıkladı
          if (exitCode == 101) {
            if (_state == DownloadState.downloading) return;
            setState(() {
              _detectedUrl = url;
              _urlController.text = url;
            });
            await _handleDownload(directUrl: url);
          }
        }
      }
    } catch (e) {
      debugPrint('Windows pano bildirim hatası: $e');
    } finally {
      _isPrompting = false;
    }
  }

  /// WINDOWS İÇİN ÖZEL EKRAN BİLDİRİMİ (UYGULAMAYI ODAKLAMAYAN / ÖNE GETİRMEYEN CUSTOM BALONCUK)
  Future<void> _showWindowsScreenNotification(String filePath) async {
    if (!_isWindows) return;
    try {
      final exeDir = path_lib.dirname(Platform.resolvedExecutable);
      String notifierPath = path_lib.join(exeDir, 'KaraDelikNotifier.exe');
      if (!File(notifierPath).existsSync()) {
        notifierPath = path_lib.join(Directory.current.path, 'windows', 'bin', 'KaraDelikNotifier.exe');
      }
      if (File(notifierPath).existsSync()) {
        await Process.start(
          notifierPath,
          [filePath, AppLocalizations.tr('download_complete')],
          mode: ProcessStartMode.detached,
        );
      }
    } catch (e) {
      debugPrint('Windows ekran bildirim hatası: $e');
    }
  }

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  Timer? _clipboardPollingTimer;

  bool get _isWindows => !kIsWeb && Platform.isWindows;

  /// Yumuşak kapanış fade efekti ile çıkış
  Future<void> _handleAppExit() async {
    if (_isExiting) return;
    _isExiting = true;
    try {
      await _windowFadeController.reverse();
      await Future.delayed(const Duration(milliseconds: 60));
    } catch (_) {}
    if (_isWindows) {
      await windowManager.destroy();
    } else {
      exit(0);
    }
  }

  @override
  void onWindowClose() {
    _handleAppExit();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _statusText = AppLocalizations.tr('status_checking');

    // 1. Açılış Fade-in Animasyonu
    _windowFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _windowFadeAnimation = CurvedAnimation(
      parent: _windowFadeController,
      curve: Curves.easeInOut,
    );
    _windowFadeController.forward();

    // 2. Windows Kapanış Yakalama
    if (_isWindows) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }

    // 3. Nabız Buton Animasyonu
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // 4. Yerinde Değişen Fade Yukarı Label ve Başlık Döngüsü
    _rotatingLabelController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );

    _rotatingFadeAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 18,
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 64,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 18,
      ),
    ]).animate(_rotatingLabelController);

    _rotatingSlideAnimation = TweenSequence<Offset>([
      TweenSequenceItem(
        tween: Tween<Offset>(begin: const Offset(0, 0.45), end: Offset.zero).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 18,
      ),
      TweenSequenceItem(
        tween: ConstantTween<Offset>(Offset.zero),
        weight: 64,
      ),
      TweenSequenceItem(
        tween: Tween<Offset>(begin: Offset.zero, end: const Offset(0, -0.45)).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 18,
      ),
    ]).animate(_rotatingLabelController);

    _rotatingLabelController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          _currentPhraseIndex = (_currentPhraseIndex + 1) % _rotatingPhrases.length;
        });
        if (_isWindows) {
          windowManager.setTitle(_rotatingPhrases[_currentPhraseIndex]);
        }
        _rotatingLabelController.forward(from: 0.0);
      }
    });

    _rotatingLabelController.forward();
    if (_isWindows) {
      windowManager.setTitle(_rotatingPhrases.first);
    }

    appLanguageNotifier.addListener(_onLanguageChanged);

    if (_isWindows) {
      _historyService.loadHistory();
    }

    _loadConfig();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_autoClipboardCheck) {
        _checkClipboard();
      }
      if (_isWindows) {
        _updateCheckTimer = Timer(const Duration(milliseconds: 800), () {
          if (mounted) {
            UpdateService.checkForUpdates(
              context,
              themeMode: appThemeModeNotifier.value,
              languageCode: appLanguageNotifier.value,
            );
          }
        });
      }
    });

    // Pano denetleme döngüsü (Gecikmesiz anında yakalama için 300 ms)
    _clipboardPollingTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!_autoClipboardCheck) return;
      if (_state == DownloadState.waitingForLink ||
          _state == DownloadState.readyToDownload ||
          _state == DownloadState.completed ||
          _state == DownloadState.error) {
        _checkClipboard(silent: true);
      }
    });
  }

  @override
  void dispose() {
    if (_isWindows) {
      windowManager.removeListener(this);
    }
    _windowFadeController.dispose();
    _rotatingLabelController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    appLanguageNotifier.removeListener(_onLanguageChanged);
    _pulseController.dispose();
    _clipboardPollingTimer?.cancel();
    _notificationBannerTimer?.cancel();
    _urlController.dispose();
    _updateCheckTimer?.cancel();
    super.dispose();
  }

  void _onLanguageChanged() {
    if (!mounted) return;
    setState(() {
      switch (_state) {
        case DownloadState.checkingClipboard:
          _statusText = AppLocalizations.tr('status_checking');
          break;
        case DownloadState.waitingForLink:
          _statusText = AppLocalizations.tr('status_waiting');
          break;
        case DownloadState.readyToDownload:
          _statusText = AppLocalizations.tr('status_ready');
          break;
        case DownloadState.downloading:
          break;
        case DownloadState.completed:
          _statusText = AppLocalizations.tr('status_done');
          break;
        case DownloadState.error:
          _statusText = AppLocalizations.tr('download_failed');
          break;
      }
    });
  }

  Future<void> _loadConfig() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final configFile = File('${dir.path}/app_config.json');
      if (await configFile.exists()) {
        final data = jsonDecode(await configFile.readAsString());
        if (data is Map) {
          if (data['language'] != null) {
            appLanguageNotifier.value = data['language'] as String;
          }
          if (data['customDownloadPath'] != null &&
              (data['customDownloadPath'] as String).isNotEmpty) {
            _downloadService.customDownloadPath =
                data['customDownloadPath'] as String;
          }
          if (data['autoClipboardCheck'] != null) {
            _autoClipboardCheck = data['autoClipboardCheck'] as bool;
          }
        }
      }

    } catch (_) {}
  }

  Future<void> _saveConfig() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final configFile = File('${dir.path}/app_config.json');
      final data = {
        'language': appLanguageNotifier.value,
        'themeMode': appThemeModeNotifier.value == ThemeMode.light ? 'light' : 'dark',
        'customDownloadPath': _downloadService.customDownloadPath ?? '',
        'autoClipboardCheck': _autoClipboardCheck,
      };
      await configFile.writeAsString(jsonEncode(data));
    } catch (_) {}
  }






  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _autoClipboardCheck) {
      _checkClipboard();
    }
  }

  Future<void> _checkClipboard({bool silent = false}) async {
    if (_state == DownloadState.downloading) return;

    if (!silent) {
      setState(() {
        _statusText = AppLocalizations.tr('status_checking');
      });
    }

    final url = await _downloadService.checkClipboardForSupportedUrl();
    if (!mounted) return;

    if (url != null && url.isNotEmpty) {
      if (_lastPromptedUrl != url) {
        _lastPromptedUrl = url;

        // Kopyalanan bağlantı için gecikmesiz derhal Windows bildirimini tetikle
        if (_isWindows && !_isPrompting) {
          _showClipboardPromptNotification(url);
        }

        if (_detectedUrl != url) {
          setState(() {
            _detectedUrl = url;
            _urlController.text = url;
            _state = DownloadState.readyToDownload;
            _statusText = AppLocalizations.tr('status_ready');
          });
        }
      }
    } else {
      _lastPromptedUrl = null;
      if (_detectedUrl == null && _urlController.text.trim().isEmpty) {
        setState(() {
          _state = DownloadState.waitingForLink;
          _statusText = AppLocalizations.tr('status_waiting');
        });
      }
    }
  }

  void _onManualUrlChanged(String text) {
    final validUrl = _downloadService.extractSupportedUrl(text);
    if (validUrl != null) {
      setState(() {
        _detectedUrl = validUrl;
        _state = DownloadState.readyToDownload;
        _statusText = AppLocalizations.tr('status_ready');
      });
    } else {
      setState(() {
        _detectedUrl = null;
        _state = DownloadState.waitingForLink;
        _statusText = text.isEmpty
            ? AppLocalizations.tr('status_waiting')
            : AppLocalizations.tr('status_invalid');
      });
    }
  }

  Future<void> _handleDownload({String? directUrl}) async {
    if (_state == DownloadState.downloading) return;
    final targetUrl = directUrl ?? _detectedUrl ?? _urlController.text.trim();
    if (targetUrl.isEmpty) {
      _showSnackbar(AppLocalizations.tr('enter_valid_url'));
      return;
    }

    setState(() {
      _state = DownloadState.downloading;
      _progress = 0.0;
      _downloadSpeed = '';
      _downloadEta = '';
      _statusText = '${AppLocalizations.tr('step_resolving')}...';
    });

    try {
      final quality = _selectedQuality;

      final savedPath = await _downloadService.startDownload(
        targetUrl: targetUrl,
        quality: quality,
        onProgress: (progress, statusText, {speed, eta}) {
          if (!mounted) return;
          setState(() {
            _progress = progress;
            if (progress < 0.25) {
              _statusText = '${AppLocalizations.tr('step_resolving')}...';
            } else {
              final pct = (progress * 100).toInt();
              final speedInfo = (speed != null && speed.isNotEmpty) ? ' • $speed' : '';
              _statusText = '${AppLocalizations.tr('step_downloading')} (%$pct$speedInfo)';
            }
            _downloadSpeed = speed ?? '';
            _downloadEta = eta ?? '';
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _state = DownloadState.completed;
        _progress = 1.0;
        _downloadSpeed = '';
        _downloadEta = '';
        _statusText = AppLocalizations.tr('status_done');
      });

      // 3 Saniye sonra tamamlandı durumunu sıfırla, tekrar "İNDİR" butonuna dön
      Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        if (_state == DownloadState.completed) {
          setState(() {
            _progress = 0.0;
            _downloadSpeed = '';
            _downloadEta = '';
            if (_urlController.text.trim().isNotEmpty) {
              _state = DownloadState.readyToDownload;
              _statusText = AppLocalizations.tr('status_ready');
            } else {
              _state = DownloadState.waitingForLink;
              _statusText = AppLocalizations.tr('status_waiting');
            }
          });
        }
      });

      if (_isWindows) {
        bool isBackground = false;
        try {
          final isMin = await windowManager.isMinimized();
          final isFoc = await windowManager.isFocused();
          final isVis = await windowManager.isVisible();
          isBackground = isMin || !isFoc || !isVis;
        } catch (_) {}

        if (isBackground) {
          // Windows: Uygulama simge durumuna küçültülmüş veya arka plandaysa:
          // KESİNLİKLE pencereyi ekrana getirme / odaklama YAPMA!
          // Sadece Windows ekranının sağ üst köşesine özel custom bildirim baloncuğu çizdir.
          await _showWindowsScreenNotification(savedPath);
        } else {
          // Uygulama ekranda ve odakta ise custom bildirime gerek yok, sadece başarı diyaloğunu göster
          _showSuccessDialog(savedPath);
        }
      } else {
        _showNotificationBanner(savedPath);
        _showSuccessDialog(savedPath);
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().toLowerCase();
      if (msg.contains('iptal') || msg.contains('cancel')) {
        setState(() {
          _state = DownloadState.readyToDownload;
          _statusText = AppLocalizations.tr('status_ready');
          _progress = 0.0;
          _downloadSpeed = '';
          _downloadEta = '';
        });
        _showSnackbar('İndirme iptal edildi.');
        return;
      }
      setState(() {
        _state = DownloadState.error;
        _downloadSpeed = '';
        _downloadEta = '';
        _statusText = '${AppLocalizations.tr('retry')}: ${e.toString().replaceAll("Exception: ", "")}';
      });
      _showSnackbar('İndirme başarısız: $e');
    }
  }

  void _showSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        backgroundColor: const Color(0xFF1E1E1E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _showSuccessDialog(String filePath) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0)),
        ),
        title: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: Colors.greenAccent),
            const SizedBox(width: 8),
            Text(
              AppLocalizations.tr('download_complete'),
              style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 18),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizations.tr('media_saved'),
              style: TextStyle(color: isDark ? Colors.white70 : Colors.black54, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isDark ? Colors.black : const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: isDark ? const Color(0xFF222222) : const Color(0xFFE0E0E0)),
              ),
              child: SelectableText(
                filePath,
                style: TextStyle(
                  color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2),
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (_isWindows) ...[
            TextButton.icon(
              icon: Icon(
                Icons.play_arrow_rounded,
                color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2),
              ),
              label: Text(
                AppLocalizations.tr('play'),
                style: TextStyle(
                  color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2),
                ),
              ),
              onPressed: () {
                _historyService.playInDefaultPlayer(filePath);
              },
            ),
            TextButton.icon(
              icon: Icon(
                Icons.folder_open_outlined,
                color: isDark ? Colors.amberAccent : const Color(0xFFD97706),
              ),
              label: Text(
                AppLocalizations.tr('show_in_folder'),
                style: TextStyle(
                  color: isDark ? Colors.amberAccent : const Color(0xFFD97706),
                ),
              ),
              onPressed: () {
                _historyService.openContainingFolder(filePath);
              },
            ),
          ],

          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark ? const Color(0xFF222222) : const Color(0xFF1976D2),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _state = DownloadState.waitingForLink;
                _detectedUrl = null;
                _urlController.clear();
                _statusText = AppLocalizations.tr('status_waiting');
                _progress = 0.0;
              });
            },
            child: Text(AppLocalizations.tr('new_download')),
          ),
        ],
      ),
    );
  }
  void _showDownloadsDialog() async {
    await _historyService.loadHistory();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final items = _historyService.items;
          final isDark = Theme.of(context).brightness == Brightness.dark;

          return AlertDialog(
            backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
              ),
            ),
            title: Row(
              children: [
                Icon(
                  Icons.folder_open_rounded,
                  color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${AppLocalizations.tr('downloads_title')} (${items.length})',
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (items.isNotEmpty)
                  IconButton(
                    tooltip: AppLocalizations.tr('clear_all_history'),
                    icon: const Icon(Icons.delete_sweep_rounded, color: Colors.redAccent, size: 22),
                    onPressed: () async {
                      bool alsoDeleteFiles = true;
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (confirmCtx) => StatefulBuilder(
                          builder: (context, setConfirmState) => AlertDialog(
                            backgroundColor: isDark ? const Color(0xFF161616) : Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                              side: BorderSide(
                                color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
                              ),
                            ),
                            title: Row(
                              children: [
                                const Icon(Icons.delete_sweep_rounded, color: Colors.redAccent, size: 22),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    AppLocalizations.tr('clear_history_title'),
                                    style: TextStyle(
                                      color: isDark ? Colors.white : Colors.black87,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppLocalizations.tr('clear_history_confirm'),
                                  style: TextStyle(
                                    color: isDark ? Colors.white70 : Colors.black87,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                InkWell(
                                  onTap: () {
                                    setConfirmState(() {
                                      alsoDeleteFiles = !alsoDeleteFiles;
                                    });
                                  },
                                  borderRadius: BorderRadius.circular(8),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: Checkbox(
                                            value: alsoDeleteFiles,
                                            activeColor: Colors.redAccent,
                                            checkColor: Colors.white,
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            onChanged: (val) {
                                              setConfirmState(() {
                                                alsoDeleteFiles = val ?? true;
                                              });
                                            },
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            AppLocalizations.tr('delete_files_also'),
                                            style: TextStyle(
                                              color: isDark ? Colors.white : Colors.black87,
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(confirmCtx, false),
                                child: Text(
                                  AppLocalizations.tr('cancel'),
                                  style: TextStyle(color: isDark ? Colors.white54 : Colors.black54),
                                ),
                              ),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                onPressed: () => Navigator.pop(confirmCtx, true),
                                child: Text(AppLocalizations.tr('clear_all')),
                              ),
                            ],
                          ),
                        ),
                      );
                      if (confirm == true) {
                        await _historyService.clearAllHistory(
                          deleteFiles: alsoDeleteFiles,
                          customDownloadPath: _downloadService.customDownloadPath,
                        );
                        setModalState(() {});
                        _showSnackbar(AppLocalizations.tr('clear_history_success'));
                      }
                    },
                  ),
              ],
            ),
            content: SizedBox(
              width: 520,
              height: 400,
              child: items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Opacity(
                              opacity: 0.35,
                              child: Image.asset(
                                'assets/app_icon.png',
                                width: 52,
                                height: 52,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            AppLocalizations.tr('no_downloads'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: isDark ? Colors.white54 : Colors.black54,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, __) => Divider(
                        color: isDark ? const Color(0xFF222222) : const Color(0xFFEEEEEE),
                        height: 1,
                      ),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final isAudio = item.fileName.endsWith('.mp3');

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF0F4F8),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              isAudio ? Icons.audiotrack_rounded : Icons.videocam_rounded,
                              color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2),
                              size: 20,
                            ),
                          ),
                          title: Text(
                            item.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isDark ? Colors.white : Colors.black87,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            '${item.formattedSize}  •  ${item.date}',
                            style: TextStyle(
                              color: isDark ? Colors.white54 : Colors.black54,
                              fontSize: 11,
                            ),
                          ),
                          onTap: () {
                            if (_isWindows) {
                              _historyService.playInDefaultPlayer(item.filePath);
                            }
                          },
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [

                              // WINDOWS: OYNAT & KLASÖRDE GÖSTER
                              if (_isWindows) ...[
                                // OYNAT BUTONU
                                IconButton(
                                  tooltip: AppLocalizations.tr('play_tooltip'),
                                  icon: Icon(
                                    Icons.play_arrow_rounded,
                                    color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2),
                                  ),
                                  onPressed: () {
                                    _historyService.playInDefaultPlayer(item.filePath);
                                  },
                                ),
                                // KLASÖRDE GÖSTER BUTONU
                                IconButton(
                                  tooltip: AppLocalizations.tr('open_folder_tooltip'),
                                  icon: Icon(
                                    Icons.folder_open_outlined,
                                    color: isDark ? Colors.white60 : Colors.black54,
                                  ),
                                  onPressed: () {
                                    _historyService.openContainingFolder(item.filePath);
                                  },
                                ),
                              ],
                              // SİL (EKSİ TUŞU): Bilgisayardan ve listeden sil
                              IconButton(
                                tooltip: AppLocalizations.tr('delete_tooltip'),
                                icon: const Icon(
                                  Icons.remove_circle_outline_rounded,
                                  color: Colors.redAccent,
                                ),
                                onPressed: () async {
                                  final deleted = await _historyService.deleteItem(item);
                                  if (deleted) {
                                    setModalState(() {});
                                    _showSnackbar('"${item.fileName}" ${AppLocalizations.tr('deleted_msg')}');
                                  } else {
                                    _showSnackbar('"${item.fileName}" silinemedi: dosya başka bir program (medya oynatıcı) tarafından kullanılıyor. Oynatıcıyı kapatıp tekrar deneyin.');
                                  }
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              if (_isWindows)
                TextButton.icon(
                  icon: const Icon(Icons.folder_shared_outlined, size: 16),
                  label: Text(AppLocalizations.tr('open_downloads_folder')),
                  onPressed: () async {
                    final dir = await _downloadService.getDestinationDirectory();
                    _historyService.openContainingFolder(dir);
                  },
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  AppLocalizations.tr('close'),
                  style: TextStyle(color: isDark ? Colors.white70 : Colors.black87),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Windows Klasör Seçici (PowerShell üzerinden standart Windows Forms diyaloğu)
  Future<String?> _pickFolder() async {
    if (!_isWindows) return null;
    try {
      const psScript = r'''
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.FolderBrowserDialog
$f.Description = "KaraDelik için İndirme Klasörünü Seçin"
$f.ShowNewFolderButton = $true
if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    [Console]::Out.Write($f.SelectedPath)
}
''';
      final result = await Process.run('powershell', ['-NoProfile', '-Command', psScript]);
      if (result.exitCode == 0) {
        final path = result.stdout.toString().trim();
        if (path.isNotEmpty && Directory(path).existsSync()) {
          return path;
        }
      }
    } catch (e) {
      debugPrint('Klasör seçme hatası: $e');
    }
    return null;
  }

  Widget _buildInfoPlatformBadge(String title, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accent.withValues(alpha: 0.35), width: 1),
      ),
      child: Text(
        title,
        style: TextStyle(
          color: accent,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// BİLGİ VE YASAL UYARI DİYALOĞU
  void _showInfoDialog() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF121214) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isDark ? const Color(0xFF26262A) : const Color(0xFFE5E7EB),
          ),
        ),
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/app_icon.png',
                width: 36,
                height: 36,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'KaraDelik Downloader',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  Text(
                    'v${UpdateService.currentVersion} (AMOLED Edition)',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: isDark ? Colors.white54 : Colors.black54,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF0A0A0C) : const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isDark ? const Color(0xFF1E1E22) : const Color(0xFFE5E7EB),
                ),
              ),
              child: Text(
                AppLocalizations.tr('disclaimer'),
                style: TextStyle(
                  color: isDark ? const Color(0xFFB0B0B8) : const Color(0xFF4B5563),
                  fontSize: 11.5,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Desteklenen Platformlar:',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _buildInfoPlatformBadge('YouTube', const Color(0xFFFF4444)),
                _buildInfoPlatformBadge('Instagram', const Color(0xFFE1306C)),
                _buildInfoPlatformBadge('TikTok', const Color(0xFF00F2FE)),
                _buildInfoPlatformBadge('X (Twitter)', const Color(0xFF1DA1F2)),
                _buildInfoPlatformBadge('Facebook', const Color(0xFF1877F2)),
              ],
            ),
            const SizedBox(height: 16),
            Center(
              child: BuyMeACoffeeButton(isDark: isDark),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              AppLocalizations.tr('close'),
              style: const TextStyle(color: Color(0xFF64B5F6), fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  /// AYARLAR DİYALOĞU: TEMA, 9 DİL SEÇİMİ, İNDİRME KLASÖRÜ
  /// Kaydet butonuna basılmadan değişikliklerle çıkışa izin verilmez.
  void _showSettingsDialog() {
    final initialTheme = appThemeModeNotifier.value;
    final initialLang = appLanguageNotifier.value;
    final initialPath = _downloadService.customDownloadPath ?? '';
    final initialAutoClipboard = _autoClipboardCheck;

    var tempTheme = initialTheme;
    var tempLang = initialLang;
    var tempPath = initialPath;
    var tempAutoClipboard = initialAutoClipboard;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final hasChanges = tempTheme != initialTheme ||
              tempLang != initialLang ||
              tempPath != initialPath ||
              tempAutoClipboard != initialAutoClipboard;

          return PopScope(
            canPop: !hasChanges,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) {
                _showSnackbar(AppLocalizations.tr('unsaved_warning'));
              }
            },
            child: AlertDialog(
              backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
                ),
              ),
              title: Row(
                children: [
                  Icon(Icons.settings_outlined, color: isDark ? Colors.white70 : Colors.black87),
                  const SizedBox(width: 8),
                  Text(
                    AppLocalizations.tr('settings'),
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 480,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. TEMA SEÇİMİ
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0A0A0A) : const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isDark ? const Color(0xFF242424) : const Color(0xFFE0E0E0),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AppLocalizations.tr('theme_title'),
                              style: TextStyle(
                                color: isDark ? Colors.white : Colors.black87,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () {
                                      setDialogState(() {
                                        tempTheme = ThemeMode.dark;
                                      });
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      decoration: BoxDecoration(
                                        color: tempTheme == ThemeMode.dark
                                            ? (isDark ? const Color(0xFF262626) : const Color(0xFFE0E0E0))
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: tempTheme == ThemeMode.dark
                                              ? const Color(0xFF64B5F6)
                                              : Colors.transparent,
                                        ),
                                      ),
                                      child: Center(
                                        child: Text(
                                          AppLocalizations.tr('theme_dark'),
                                          style: TextStyle(
                                            color: isDark ? Colors.white : Colors.black87,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () {
                                      setDialogState(() {
                                        tempTheme = ThemeMode.light;
                                      });
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      decoration: BoxDecoration(
                                        color: tempTheme == ThemeMode.light
                                            ? (isDark ? const Color(0xFF262626) : const Color(0xFFE0E0E0))
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: tempTheme == ThemeMode.light
                                              ? const Color(0xFF1976D2)
                                              : Colors.transparent,
                                        ),
                                      ),
                                      child: Center(
                                        child: Text(
                                          AppLocalizations.tr('theme_light'),
                                          style: TextStyle(
                                            color: isDark ? Colors.white : Colors.black87,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // 2. DİL SEÇİMİ (9 DİL)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0A0A0A) : const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isDark ? const Color(0xFF242424) : const Color(0xFFE0E0E0),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AppLocalizations.tr('language_title'),
                              style: TextStyle(
                                color: isDark ? Colors.white : Colors.black87,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF161616) : Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isDark ? const Color(0xFF333333) : const Color(0xFFD1D5DB),
                                ),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  isExpanded: true,
                                  value: tempLang,
                                  dropdownColor: isDark ? const Color(0xFF181818) : Colors.white,
                                  style: TextStyle(
                                    color: isDark ? Colors.white : Colors.black87,
                                    fontSize: 13,
                                  ),
                                  icon: Icon(
                                    Icons.arrow_drop_down,
                                    color: isDark ? Colors.white70 : Colors.black54,
                                  ),
                                  items: AppLocalizations.supportedLanguages.entries.map((entry) {
                                    return DropdownMenuItem<String>(
                                      value: entry.key,
                                      child: Text(entry.value),
                                    );
                                  }).toList(),
                                  onChanged: (newLang) {
                                    if (newLang != null) {
                                      setDialogState(() {
                                        tempLang = newLang;
                                      });
                                    }
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // 3. İNDİRME KLASÖRÜ
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0A0A0A) : const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isDark ? const Color(0xFF242424) : const Color(0xFFE0E0E0),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AppLocalizations.tr('download_dir_title'),
                              style: TextStyle(
                                color: isDark ? Colors.white : Colors.black87,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            FutureBuilder<String>(
                              future: tempPath.isNotEmpty
                                  ? Future.value(tempPath)
                                  : _downloadService.getDestinationDirectory(),
                              builder: (context, snapshot) {
                                final currentPath = snapshot.data ?? '...';
                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: isDark ? const Color(0xFF161616) : Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isDark ? const Color(0xFF333333) : const Color(0xFFD1D5DB),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          currentPath,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2),
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isDark ? const Color(0xFF222222) : const Color(0xFFE5E7EB),
                                    foregroundColor: isDark ? Colors.white : Colors.black87,
                                    elevation: 0,
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  ),
                                  icon: const Icon(Icons.folder_open_rounded, size: 16),
                                  label: Text(AppLocalizations.tr('change_dir'), style: const TextStyle(fontSize: 12)),
                                  onPressed: () async {
                                    final picked = await _pickFolder();
                                    if (picked != null) {
                                      setDialogState(() {
                                        tempPath = picked;
                                      });
                                    }
                                  },
                                ),
                                if (tempPath.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  TextButton(
                                    onPressed: () {
                                      setDialogState(() {
                                        tempPath = '';
                                      });
                                    },
                                    child: Text(
                                      AppLocalizations.tr('reset_dir'),
                                      style: TextStyle(
                                        color: isDark ? Colors.white60 : Colors.black54,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      // 4. OTOMATİK PANO DENETLEME
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0A0A0A) : const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isDark ? const Color(0xFF242424) : const Color(0xFFE0E0E0),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    AppLocalizations.tr('auto_clipboard_title'),
                                    style: TextStyle(
                                      color: isDark ? Colors.white : Colors.black87,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    AppLocalizations.tr('auto_clipboard_desc'),
                                    style: TextStyle(
                                      color: isDark ? Colors.white54 : Colors.black54,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: tempAutoClipboard,
                              activeThumbColor: const Color(0xFF64B5F6),
                              activeTrackColor: const Color(0xFF64B5F6).withValues(alpha: 0.5),
                              onChanged: (val) {
                                setDialogState(() {
                                  tempAutoClipboard = val;
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                  },
                  child: Text(
                    hasChanges ? AppLocalizations.tr('cancel') : AppLocalizations.tr('close'),
                    style: TextStyle(color: isDark ? Colors.white54 : Colors.black54),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: hasChanges
                        ? (isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2))
                        : (isDark ? const Color(0xFF262626) : const Color(0xFFCCCCCC)),
                    foregroundColor: hasChanges && !isDark ? Colors.white : Colors.black,
                  ),
                  onPressed: () {
                    // Kaydet
                    appThemeModeNotifier.value = tempTheme;
                    appLanguageNotifier.value = tempLang;
                    _downloadService.customDownloadPath = tempPath.isNotEmpty ? tempPath : null;
                    _autoClipboardCheck = tempAutoClipboard;

                    _saveConfig();
                    Navigator.pop(ctx);
                    _showSnackbar(AppLocalizations.tr('saved_success'));
                  },
                  child: Text(
                    AppLocalizations.tr('save'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: hasChanges
                          ? (isDark ? Colors.black : Colors.white)
                          : (isDark ? Colors.white38 : Colors.black38),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _getPlatformBadge(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('youtube.com') || lower.contains('youtu.be')) return 'YouTube';
    if (lower.contains('instagram.com') || lower.contains('cdninstagram.com') || lower.contains('fbcdn.net')) return 'Instagram';
    if (lower.contains('tiktok.com')) return 'TikTok';
    if (lower.contains('twitter.com') || lower.contains('x.com')) return 'X / Twitter';
    if (lower.contains('facebook.com') || lower.contains('fb.watch') || lower.contains('fb.com')) return 'Facebook';
    return 'Medya';
  }

  Widget _buildTopRightNotificationBanner(bool isDark, String filePath) {
    final fileName = path_lib.basename(filePath);
    final screenWidth = MediaQuery.of(context).size.width;
    final bannerWidth = screenWidth < 380 ? screenWidth - 32 : 330.0;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: bannerWidth,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF141414) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.greenAccent.withValues(alpha: isDark ? 0.25 : 0.18),
              blurRadius: 18,
              spreadRadius: 2,
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.6 : 0.12),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppLocalizations.tr('download_complete'),
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: _hideNotificationBanner,
                  child: Padding(
                    padding: const EdgeInsets.all(2.0),
                    child: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (_isWindows) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: Icon(
                      Icons.folder_open_outlined,
                      size: 15,
                      color: isDark ? Colors.amberAccent : const Color(0xFFD97706),
                    ),
                    label: Text(
                      AppLocalizations.tr('show_in_folder'),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.amberAccent : const Color(0xFFD97706),
                      ),
                    ),
                    onPressed: () {
                      _historyService.openContainingFolder(filePath);
                      _hideNotificationBanner();
                    },
                  ),
                  const SizedBox(width: 6),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: Icon(
                      Icons.play_arrow_rounded,
                      size: 16,
                      color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2),
                    ),
                    label: Text(
                      AppLocalizations.tr('play'),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2),
                      ),
                    ),
                    onPressed: () {
                      _historyService.playInDefaultPlayer(filePath);
                    },
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRotatingLabel(bool isDark) {
    final phrase = _rotatingPhrases[_currentPhraseIndex];
    return ClipRect(
      child: SizedBox(
        height: 24,
        child: SlideTransition(
          position: _rotatingSlideAnimation,
          child: FadeTransition(
            opacity: _rotatingFadeAnimation,
            child: Center(
              child: Text(
                phrase,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isDark ? const Color(0xFFD1D5DB) : const Color(0xFF4B5563),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCustomTitleBar(bool isDark) {
    return Container(
      height: 34,
      color: isDark ? const Color(0xFF000000) : const Color(0xFFECEFF3),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: () async {
                if (await windowManager.isMaximized()) {
                  windowManager.unmaximize();
                } else {
                  windowManager.maximize();
                }
              },
              child: Padding(
                padding: const EdgeInsets.only(left: 12.0),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.asset(
                        'assets/app_icon.png',
                        width: 15,
                        height: 15,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ClipRect(
                        child: SlideTransition(
                          position: _rotatingSlideAnimation,
                          child: FadeTransition(
                            opacity: _rotatingFadeAnimation,
                            child: Text(
                              _rotatingPhrases[_currentPhraseIndex],
                              style: TextStyle(
                                color: isDark ? Colors.white60 : Colors.black54,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.3,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _WindowControlButton(
            icon: Icons.remove,
            tooltip: 'Küçült',
            isDark: isDark,
            onTap: () => windowManager.minimize(),
          ),
          _WindowControlButton(
            icon: Icons.crop_square_rounded,
            tooltip: 'Büyüt / Geri Yükle',
            isDark: isDark,
            onTap: () async {
              if (await windowManager.isMaximized()) {
                windowManager.unmaximize();
              } else {
                windowManager.maximize();
              }
            },
          ),
          _WindowControlButton(
            icon: Icons.close_rounded,
            tooltip: 'Kapat',
            isDark: isDark,
            isClose: true,
            onTap: _handleAppExit,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ValueListenableBuilder<String>(
      valueListenable: appLanguageNotifier,
      builder: (context, currentLang, _) {
        return FadeTransition(
          opacity: _windowFadeAnimation,
          child: Scaffold(
            backgroundColor: isDark ? const Color(0xFF000000) : const Color(0xFFF7F9FC),
            appBar: PreferredSize(
              preferredSize: Size.fromHeight(_isWindows ? 90 : 56),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isWindows) _buildCustomTitleBar(isDark),
                  AppBar(
                    title: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onPanStart: _isWindows ? (_) => windowManager.startDragging() : null,
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.asset(
                              'assets/app_icon.png',
                              width: 24,
                              height: 24,
                              fit: BoxFit.cover,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'KaraDelik',
                            style: TextStyle(
                              color: isDark ? Colors.white : Colors.black87,
                              fontWeight: FontWeight.w700,
                              fontSize: 18,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      IconButton(
                        tooltip: AppLocalizations.tr('info'),
                        icon: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isDark ? Colors.white : Colors.black87,
                              width: 1.8,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '?',
                            style: TextStyle(
                              color: isDark ? Colors.white : Colors.black87,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              height: 1.0,
                            ),
                          ),
                        ),
                        onPressed: _showInfoDialog,
                      ),
                      IconButton(
                        tooltip: AppLocalizations.tr('check_clipboard'),
                        icon: Icon(Icons.paste_rounded, color: isDark ? Colors.white : Colors.black87),
                        onPressed: () async {
                          final data = await Clipboard.getData(Clipboard.kTextPlain);
                          if (data?.text != null) {
                            _urlController.text = data!.text!;
                            _onManualUrlChanged(data.text!);
                          }
                        },
                      ),
                      IconButton(
                        tooltip: AppLocalizations.tr('downloads'),
                        icon: Icon(Icons.folder_open_rounded, color: isDark ? Colors.white : Colors.black87),
                        onPressed: _showDownloadsDialog,
                      ),
                      IconButton(
                        tooltip: AppLocalizations.tr('settings'),
                        icon: Icon(Icons.settings_outlined, color: isDark ? Colors.white : Colors.black87),
                        onPressed: _showSettingsDialog,
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ],
              ),
            ),
            body: SafeArea(
              child: Stack(
                children: [
                  Column(
                    children: [
                      // ÜST YASAL UYARI (DISCLAIMER)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF0A0A0A) : const Color(0xFFFFFFFF),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isDark ? const Color(0xFF1F1F1F) : const Color(0xFFE5E7EB),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('⚠️ ', style: TextStyle(fontSize: 14)),
                              Expanded(
                                child: Text(
                                  AppLocalizations.tr('disclaimer'),
                                  style: TextStyle(
                                    color: isDark ? const Color(0xFF9E9E9E) : const Color(0xFF6B7280),
                                    fontSize: 11,
                                    height: 1.35,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 6.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              AppLocalizations.tr('download_style'),
                              style: TextStyle(
                                color: isDark ? Colors.white60 : Colors.black54,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF141414) : Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFD1D5DB),
                                ),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<DownloadQuality>(
                                  value: _selectedQuality,
                                  dropdownColor: isDark ? const Color(0xFF141414) : Colors.white,
                                  style: TextStyle(
                                    color: isDark ? Colors.white : Colors.black87,
                                    fontSize: 12,
                                  ),
                                  icon: Icon(
                                    Icons.arrow_drop_down,
                                    color: isDark ? Colors.white70 : Colors.black54,
                                    size: 18,
                                  ),
                                  onChanged: (val) {
                                    if (val != null) {
                                      setState(() => _selectedQuality = val);
                                    }
                                  },
                                  items: DownloadQuality.values.map((q) {
                                    return DropdownMenuItem<DownloadQuality>(
                                      value: q,
                                      child: Text(q.label),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // MERKEZ KARADELİK BUTONU VE ANİMASYONU
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildRotatingLabel(isDark),
                              const SizedBox(height: 18),
                              GestureDetector(
                                onTap: _state == DownloadState.downloading
                                    ? null
                                    : () => _handleDownload(),
                                child: AnimatedBuilder(
                                  animation: _pulseAnimation,
                                  builder: (context, child) {
                                    final scale = _state == DownloadState.readyToDownload
                                        ? _pulseAnimation.value
                                        : 1.0;
                                    return Transform.scale(
                                      scale: scale,
                                      child: child,
                                    );
                                  },
                                  child: Container(
                                    width: 170,
                                    height: 170,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: isDark ? const Color(0xFF000000) : Colors.white,
                                      border: Border.all(
                                        color: _state == DownloadState.readyToDownload
                                            ? const Color(0xFF64B5F6)
                                            : (isDark ? const Color(0xFF2B2B2B) : const Color(0xFFE0E0E0)),
                                        width: 2.0,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: _state == DownloadState.readyToDownload
                                              ? const Color(0xFF64B5F6).withValues(alpha: 0.35)
                                              : (isDark
                                                  ? Colors.white.withValues(alpha: 0.04)
                                                  : Colors.black.withValues(alpha: 0.06)),
                                          blurRadius: 36,
                                          spreadRadius: 4,
                                        ),
                                      ],
                                    ),
                                    child: Center(
                                      child: _buildCenterWidget(isDark),
                                    ),
                                  ),
                                ),
                              ),
                        // İNDİRME SIRASINDA İPTAL ETME BUTONU
                        if (_state == DownloadState.downloading) ...[
                          const SizedBox(height: 14),
                          SizedBox(
                            width: 140,
                            height: 36,
                            child: OutlinedButton(
                              onPressed: () {
                                _downloadService.cancelDownload();
                                setState(() {
                                  _state = DownloadState.readyToDownload;
                                  _statusText = AppLocalizations.tr('status_ready');
                                  _progress = 0.0;
                                });
                                _showSnackbar('İndirme iptal edildi.');
                              },
                              style: OutlinedButton.styleFrom(
                                backgroundColor: isDark ? const Color(0xFF141414) : const Color(0xFFF3F4F6),
                                side: BorderSide(
                                  color: Colors.redAccent.withValues(alpha: 0.5),
                                  width: 1.0,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                padding: EdgeInsets.zero,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.close_rounded, size: 16, color: Colors.redAccent),
                                  const SizedBox(width: 6),
                                  Text(
                                    AppLocalizations.tr('cancel_download'),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.redAccent,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // DURUM VE YÜZDE ALANI (İNCE PARLAK PROGRESS BAR DAHİL)
                _buildStatusDisplay(isDark),

                const SizedBox(height: 12),

                // BUY ME A COFFEE (PARLAYAN MAVİ ÇİZGİLİ MİNİMALİST BUTON)
                BuyMeACoffeeButton(isDark: isDark),

                const SizedBox(height: 10),

                // ALT GİRDİ ÇUBUĞU
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
                  child: _buildUrlInputBar(isDark),
                ),
              ],
            ),
            // SAĞ ÜST KÖŞE BİLDİRİM BALONCUĞU
            if (_notificationBannerFile != null)
              Positioned(
                top: 10,
                right: 16,
                child: _buildTopRightNotificationBanner(isDark, _notificationBannerFile!),
              ),
          ],
        ),
      ),
    ),
  );
      },
    );
  }

  Widget _buildCenterWidget(bool isDark) {
    switch (_state) {
      case DownloadState.checkingClipboard:
      case DownloadState.waitingForLink:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.download_rounded,
              color: isDark ? Colors.white24 : Colors.black26,
              size: 38,
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.tr('waiting_link'),
              style: TextStyle(
                color: isDark ? Colors.white38 : Colors.black38,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
          ],
        );
      case DownloadState.readyToDownload:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.download_rounded,
              color: Color(0xFF64B5F6),
              size: 40,
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.tr('download'),
              style: const TextStyle(
                color: Color(0xFF64B5F6),
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ],
        );
      case DownloadState.downloading:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                value: _progress > 0 ? _progress : null,
                strokeWidth: 3.5,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                backgroundColor: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFE0E0E0),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '%${(_progress * 100).toInt()}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        );
      case DownloadState.completed:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_rounded, color: Colors.greenAccent, size: 36),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.tr('completed'),
              style: const TextStyle(
                color: Colors.greenAccent,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ],
        );
      case DownloadState.error:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.refresh_rounded, color: Colors.redAccent, size: 32),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.tr('retry'),
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
              ),
            ),
          ],
        );
    }
  }

  /// DURUM VE İNCE PARLAK PROGRESS BAR
  Widget _buildStatusDisplay(bool isDark) {
    final double glowFactor = _progress.clamp(0.0, 1.0);
    List<Shadow>? textShadows;
    if (_state == DownloadState.downloading) {
      final double alpha = (0.20 + 0.45 * glowFactor).clamp(0.0, 0.70);
      textShadows = [
        Shadow(
          color: Colors.white.withValues(alpha: alpha),
          blurRadius: 3.0 + 9.0 * glowFactor,
        ),
      ];
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        children: [
          Text(
            _statusText,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _state == DownloadState.error
                  ? Colors.redAccent
                  : (_state == DownloadState.completed
                      ? Colors.greenAccent
                      : (_state == DownloadState.downloading
                          ? Colors.white
                          : (isDark ? Colors.white70 : Colors.black87))),
              fontSize: 14,
              fontWeight: FontWeight.w500,
              shadows: textShadows,
            ),
          ),
          // İNCE PARLAK ÇUBUK PROGRESS BAR (SADECE İLERLEYEN ÇUBUĞA ARTAN PARLAKLIK)
          if (_state == DownloadState.downloading) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: 220,
              height: 6,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  // Parlamasız sade arka plan rayı
                  Container(
                    width: 220,
                    height: 4.5,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2.5),
                      color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFE5E7EB),
                    ),
                  ),
                  // Sadece ilerleyen doluluk çubuğu ve ona özel artan parlaklık
                  if (_progress > 0)
                    Container(
                      width: (220 * _progress.clamp(0.0, 1.0)).clamp(4.0, 220.0),
                      height: 4.5,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2.5),
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.white.withValues(alpha: (0.30 + 0.55 * glowFactor).clamp(0.0, 0.90)),
                            blurRadius: 4.0 + 14.0 * glowFactor,
                            spreadRadius: 0.8 + 2.0 * glowFactor,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (_downloadSpeed.isNotEmpty || _downloadEta.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                [_downloadSpeed, _downloadEta].where((s) => s.isNotEmpty).join(' • '),
                style: TextStyle(
                  color: isDark ? const Color(0xFFB0B0B0) : const Color(0xFF555555),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ],
          if (_detectedUrl != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF141414) : const Color(0xFFE8EEF5),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isDark ? const Color(0xFF242424) : const Color(0xFFD0D7DE),
                ),
              ),
              child: Text(
                _getPlatformBadge(_detectedUrl!),
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF0969DA),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUrlInputBar(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F0F0F) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF222222) : const Color(0xFFD1D5DB),
        ),
      ),
      child: TextField(
        controller: _urlController,
        style: TextStyle(
          color: isDark ? Colors.white : Colors.black87,
          fontSize: 13,
        ),
        onChanged: _onManualUrlChanged,
        decoration: InputDecoration(
          hintText: AppLocalizations.tr('input_hint'),
          hintStyle: TextStyle(
            color: isDark ? Colors.white30 : Colors.black38,
            fontSize: 13,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: InputBorder.none,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_urlController.text.isNotEmpty)
                IconButton(
                  icon: Icon(
                    Icons.clear,
                    color: isDark ? Colors.white38 : Colors.black38,
                    size: 18,
                  ),
                  onPressed: () {
                    _urlController.clear();
                    _onManualUrlChanged('');
                  },
                ),
              IconButton(
                icon: Icon(
                  Icons.content_paste_rounded,
                  color: isDark ? Colors.white70 : const Color(0xFF1976D2),
                  size: 20,
                ),
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) {
                    _urlController.text = data!.text!;
                    _onManualUrlChanged(data.text!);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Minimalist, hafif geniş, sürekli parlayan mavi hatlara sahip Buy Me a Coffee butonu
class BuyMeACoffeeButton extends StatefulWidget {
  final bool isDark;
  const BuyMeACoffeeButton({super.key, required this.isDark});

  @override
  State<BuyMeACoffeeButton> createState() => _BuyMeACoffeeButtonState();
}

class _BuyMeACoffeeButtonState extends State<BuyMeACoffeeButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _glowController;
  late Animation<double> _glowAnimation;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    )..repeat(reverse: true);

    _glowAnimation = CurvedAnimation(
      parent: _glowController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  Future<void> _launchBuyMeACoffee() async {
    const url = 'https://buymeacoffee.com/vibeabi';
    try {
      if (!kIsWeb && Platform.isWindows) {
        await Process.start(
          'cmd.exe',
          ['/c', 'start', '""', url],
          mode: ProcessStartMode.detached,
        );
      } else if (!kIsWeb && Platform.isLinux) {
        await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
      } else if (!kIsWeb && Platform.isMacOS) {
        await Process.start('open', [url], mode: ProcessStartMode.detached);
      }
    } catch (e) {
      debugPrint('BuyMeACoffee URL açılamadı: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _glowAnimation,
      builder: (context, _) {
        final t = _glowAnimation.value;
        // Dinamik ve sürekli parlayan canlı mavi / neon camgöbeği hatlar
        final borderColor = Color.lerp(
          const Color(0xFF1976D2), // Zengin elektrik mavisi
          const Color(0xFF00E5FF), // Parlak neon camgöbeği
          t,
        )!;
        final glowAlpha = _isHovered ? 0.70 : (0.25 + 0.45 * t);
        final glowBlur = _isHovered ? 14.0 : (5.0 + 7.0 * t);
        final glowSpread = _isHovered ? 1.4 : (0.4 + 0.8 * t);

        return Tooltip(
          message: 'Buy Me a Coffee (vibeabi)',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _isHovered = true),
            onExit: (_) => setState(() => _isHovered = false),
            child: GestureDetector(
              onTap: _launchBuyMeACoffee,
              child: AnimatedScale(
                scale: _isHovered ? 1.025 : 1.0,
                duration: const Duration(milliseconds: 150),
                child: Container(
                  width: 210,
                  height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: widget.isDark
                        ? (_isHovered ? const Color(0xFF121620) : const Color(0xFF080B10))
                        : (_isHovered ? const Color(0xFFF0F7FF) : const Color(0xFFFFFFFF)),
                    border: Border.all(
                      color: borderColor.withValues(
                        alpha: _isHovered ? 1.0 : (0.55 + 0.45 * t),
                      ),
                      width: _isHovered ? 1.6 : 1.35,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF00B0FF).withValues(alpha: glowAlpha),
                        blurRadius: glowBlur,
                        spreadRadius: glowSpread,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.coffee_rounded,
                        size: 16,
                        color: Color(0xFFFFDD00), // Buy Me a Coffee sarı/altın kahve bardağı
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Buy Me a Coffee',
                        style: TextStyle(
                          color: widget.isDark ? Colors.white : const Color(0xFF0F172A),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.arrow_outward_rounded,
                        size: 13,
                        color: borderColor,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Windows Özel Pencere Denetim Butonu (Minimize, Maximize, Close - Hover ve Tema Uyumlu)
class _WindowControlButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool isDark;
  final bool isClose;

  const _WindowControlButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.isDark,
    this.isClose = false,
  });

  @override
  State<_WindowControlButton> createState() => _WindowControlButtonState();
}

class _WindowControlButtonState extends State<_WindowControlButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    if (_isHovered) {
      if (widget.isClose) {
        bg = const Color(0xFFE81123);
        fg = Colors.white;
      } else {
        bg = widget.isDark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.08);
        fg = widget.isDark ? Colors.white : Colors.black87;
      }
    } else {
      bg = Colors.transparent;
      fg = widget.isDark ? Colors.white70 : Colors.black54;
    }

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 44,
            height: 34,
            color: bg,
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: widget.isClose ? 15 : 13.5,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

