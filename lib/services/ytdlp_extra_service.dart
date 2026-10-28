import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_lib;
import 'download_service.dart';

/// ytdlp_extra: yt-dlp tabanlı evrensel medya bilgisi
class YtDlpMediaInfo {
  final String title;
  final String? uploader;
  final String? extractor;
  final String? directStreamUrl;
  final int? durationSeconds;
  final int? fileSize;
  final String? thumbnail;
  final bool isDirectStream;

  const YtDlpMediaInfo({
    required this.title,
    this.uploader,
    this.extractor,
    this.directStreamUrl,
    this.durationSeconds,
    this.fileSize,
    this.thumbnail,
    this.isDirectStream = false,
  });
}

/// YtDlpExtraService: Windows ortamında yt-dlp ve FFmpeg tabanlı yüksek performanslı indirme motoru
/// Desteklenen platformlar: YouTube, Instagram, TikTok, X (Twitter), Facebook
class YtDlpExtraService {
  static final YtDlpExtraService _instance = YtDlpExtraService._internal();
  factory YtDlpExtraService() => _instance;
  YtDlpExtraService._internal();

  String? _cachedYtDlpPath;
  String? _cachedFfmpegPath;
  final Set<Process> _activeProcesses = <Process>{};
  bool _cancelled = false;

  Future<void> _stopProcess(Process process) async {
    if (Platform.isWindows) {
      await Process.run('taskkill.exe', ['/PID', '${process.pid}', '/T', '/F']);
    } else {
      process.kill();
    }
  }

  Future<ProcessResult> _runQuery(String executable, List<String> args) async {
    final process = await Process.start(executable, [
      '--encoding',
      'utf-8',
      '--socket-timeout',
      '10',
      '--retries',
      '1',
      ...args,
    ]);
    _activeProcesses.add(process);
    await process.stdin.close();
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 30));
      return ProcessResult(process.pid, code, await stdout, await stderr);
    } on TimeoutException {
      await _stopProcess(process);
      await Future.wait([stdout, stderr]);
      return ProcessResult(process.pid, -1, '', 'Zaman aşımı');
    } finally {
      _activeProcesses.remove(process);
    }
  }

  /// URL'yi platforma göre optimize eder
  static String normalizeUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri != null && _matchesHost(uri.host, 'instagram.com')) {
      final segments = uri.pathSegments;
      if (segments.length >= 2 &&
          const ['p', 'reel', 'reels', 'tv'].contains(segments[0])) {
        final type = segments[0] == 'reels' ? 'reel' : segments[0];
        return 'https://www.instagram.com/$type/${segments[1]}/';
      }
    }
    return url;
  }

  static bool _matchesHost(String host, String domain) =>
      host == domain || host.endsWith('.$domain');

  /// Platforma özel ek yt-dlp argümanları
  static List<String> getExtraArgsForUrl(String url) {
    if (getPlatformName(url) == 'YouTube') {
      final runtimeCandidates = [
        path_lib.join(
            path_lib.dirname(Platform.resolvedExecutable), 'node.exe'),
        path_lib.join(Directory.current.path, 'windows', 'bin', 'node.exe'),
      ];
      for (final candidate in runtimeCandidates) {
        if (File(candidate).existsSync()) {
          return ['--js-runtimes', 'node:$candidate'];
        }
      }
      return ['--js-runtimes', 'node'];
    }
    return <String>[];
  }

  /// Desteklenen 5 platform için Regex deseni
  static final RegExp supportedRegex = RegExp(
    r'(https?:\/\/(?:[a-zA-Z0-9\-]+\.)?(?:(?:youtube\.com\/(?:watch\?(?:[^\s]*&)?v=|shorts\/|embed\/|v\/|live\/)[a-zA-Z0-9_\-]+)|(?:youtu\.be\/[a-zA-Z0-9_\-]+)|(?:instagram\.com\/(?:(?:[a-zA-Z0-9_.]+\/)?(?:p|reel|reels|tv|stories|share(?:\/reel|\/p)?)\/[a-zA-Z0-9_\-]+(?:\/[a-zA-Z0-9_\-]+)?))|(?:(?:[a-zA-Z0-9\-]+\.)?(?:cdninstagram\.com|fbcdn\.net)\/[^\s]+)|(?:(?:vm\.|vt\.|www\.)?tiktok\.com\/(?:@?[a-zA-Z0-9_.]+\/video\/\d+|[a-zA-Z0-9_\-]+))|(?:(?:twitter\.com|x\.com)\/(?:[a-zA-Z0-9_]+\/)?status\/\d+)|(?:(?:facebook\.com|fb\.watch|fb\.com)\/[a-zA-Z0-9_\-\.\/?=&%+]+)))',
    caseSensitive: false,
  );

  /// Verilen URL'nin izin verilen 5 platformdan birine ait olup olmadığını doğrular
  static bool isSupportedPlatform(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !const ['http', 'https'].contains(uri.scheme)) {
      return false;
    }
    return const [
      'youtube.com',
      'youtu.be',
      'instagram.com',
      'cdninstagram.com',
      'fbcdn.net',
      'tiktok.com',
      'twitter.com',
      'x.com',
      'facebook.com',
      'fb.watch',
      'fb.com',
    ].any((domain) => _matchesHost(uri.host, domain));
  }

  /// Platform adını döndürür (yalnızca 5 platform için)
  static String? getPlatformName(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('youtube.com') || lower.contains('youtu.be')) {
      return 'YouTube';
    }
    if (lower.contains('instagram.com') ||
        lower.contains('cdninstagram.com') ||
        lower.contains('fbcdn.net')) {
      return 'Instagram';
    }
    if (lower.contains('tiktok.com')) return 'TikTok';
    if (lower.contains('twitter.com') || lower.contains('x.com')) return 'X';
    if (lower.contains('facebook.com') ||
        lower.contains('fb.watch') ||
        lower.contains('fb.com')) {
      return 'Facebook';
    }
    return null;
  }

  static final RegExp _progressRegex = RegExp(
    r'\[download\]\s+(\d+(?:\.\d+)?)%\s+of\s+(?:~\s*)?(\d+(?:\.\d+)?)\s*([A-Za-z]+)(?:\s+at\s+(\d+(?:\.\d+)?)\s*([A-Za-z]+)\/s)?(?:\s+ETA\s+(\d{2}:\d{2}(?::\d{2})?))?',
    caseSensitive: false,
  );

  static final RegExp _completedRegex = RegExp(
    r'\[download\]\s+100(?:\.0)?%',
    caseSensitive: false,
  );

  /// yt-dlp.exe yürütülebilir dosyasının yerini tespit eder
  Future<String?> findYtDlpExecutable() async {
    if (!Platform.isWindows) return null;

    if (_cachedYtDlpPath != null && await File(_cachedYtDlpPath!).exists()) {
      return _cachedYtDlpPath;
    }

    final exeDir = path_lib.dirname(Platform.resolvedExecutable);
    final candidatePaths = <String>[
      // 1. Uygulama çalışma klasörü ve alt dizinleri
      path_lib.join(exeDir, 'yt-dlp.exe'),
      path_lib.join(exeDir, 'bin', 'yt-dlp.exe'),
      path_lib.join(exeDir, 'windows', 'bin', 'yt-dlp.exe'),
      // 2. Proje çalışma klasörü
      path_lib.join(Directory.current.path, 'yt-dlp.exe'),
      path_lib.join(Directory.current.path, 'windows', 'bin', 'yt-dlp.exe'),
      path_lib.join(Directory.current.path, 'build', 'windows', 'x64', 'runner',
          'Release', 'yt-dlp.exe'),
      path_lib.join(Directory.current.path, 'build', 'windows', 'x64', 'runner',
          'Debug', 'yt-dlp.exe'),
      // 3. Bilinen sabit konumlar
      r'C:\Users\Sensei\Desktop\KaraDelik2\windows\bin\yt-dlp.exe',
      r'C:\Users\Sensei\Desktop\KaraDelik2\yt-dlp.exe',
      r'C:\Users\Sensei\Desktop\KaraDelik2\build\windows\x64\runner\Release\yt-dlp.exe',
      r'C:\Program Files\KaraDelik\yt-dlp.exe',
      r'C:\Program Files (x86)\KaraDelik\yt-dlp.exe',
    ];

    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null) {
      candidatePaths
          .add(path_lib.join(localAppData, 'KaraDelik', 'yt-dlp.exe'));
    }

    for (final p in candidatePaths) {
      if (await File(p).exists()) {
        _cachedYtDlpPath = p;
        return p;
      }
    }

    // 4. Windows PATH sorgulaması
    try {
      final res = await Process.run('where.exe', ['yt-dlp.exe']);
      if (res.exitCode == 0) {
        final line = res.stdout
            .toString()
            .split(RegExp(r'\r?\n'))
            .firstWhere(
              (l) => l.trim().isNotEmpty,
              orElse: () => '',
            )
            .trim();
        if (line.isNotEmpty && await File(line).exists()) {
          _cachedYtDlpPath = line;
          return line;
        }
      }
    } catch (_) {}

    return null;
  }

  /// FFmpeg yürütülebilir dosyasının yerini tespit eder
  Future<String?> findFfmpegExecutable() async {
    if (!Platform.isWindows) return null;

    if (_cachedFfmpegPath != null && await File(_cachedFfmpegPath!).exists()) {
      return _cachedFfmpegPath;
    }

    final exeDir = path_lib.dirname(Platform.resolvedExecutable);
    final candidatePaths = <String>[
      path_lib.join(exeDir, 'ffmpeg.exe'),
      path_lib.join(exeDir, 'bin', 'ffmpeg.exe'),
      path_lib.join(exeDir, 'windows', 'bin', 'ffmpeg.exe'),
      path_lib.join(Directory.current.path, 'ffmpeg.exe'),
      path_lib.join(Directory.current.path, 'windows', 'bin', 'ffmpeg.exe'),
      path_lib.join(Directory.current.path, 'windows', 'ffmpeg.exe'),
      path_lib.join(Directory.current.path, 'ffmpeg_bin', 'ffmpeg.exe'),
      path_lib.join(Directory.current.path, 'build', 'windows', 'x64', 'runner',
          'Release', 'ffmpeg.exe'),
      path_lib.join(Directory.current.path, 'build', 'windows', 'x64', 'runner',
          'Debug', 'ffmpeg.exe'),
      r'C:\Users\Sensei\Desktop\KaraDelik2\windows\bin\ffmpeg.exe',
      r'C:\Users\Sensei\Desktop\KaraDelik2\build\windows\x64\runner\Release\ffmpeg.exe',
      r'C:\Program Files\KaraDelik\ffmpeg.exe',
    ];

    for (final p in candidatePaths) {
      if (await File(p).exists()) {
        _cachedFfmpegPath = p;
        return p;
      }
    }

    try {
      final res = await Process.run('where.exe', ['ffmpeg.exe']);
      if (res.exitCode == 0) {
        final line = res.stdout
            .toString()
            .split(RegExp(r'\r?\n'))
            .firstWhere(
              (l) => l.trim().isNotEmpty,
              orElse: () => '',
            )
            .trim();
        if (line.isNotEmpty && await File(line).exists()) {
          _cachedFfmpegPath = line;
          return line;
        }
      }
    } catch (_) {}

    return null;
  }

  /// ytdlp_extra motoruyla medya başlığını, formatını, boyutunu ve akışını tam çözümler
  Future<YtDlpMediaInfo?> resolveMediaInfo(String targetUrl) async {
    if (!isSupportedPlatform(targetUrl)) return null;

    final ytdlp = await findYtDlpExecutable();
    if (ytdlp == null) return null;

    try {
      final normalizedUrl = normalizeUrl(targetUrl);
      final extraArgs = getExtraArgsForUrl(targetUrl);

      final res = await _runQuery(
        ytdlp,
        [
          '--dump-single-json',
          '--no-warnings',
          '--no-playlist',
          '--no-check-certificates',
          '--ignore-config',
          '--geo-bypass',
          ...extraArgs,
          normalizedUrl,
        ],
      );

      if (res.exitCode == 0 && res.stdout != null) {
        final raw = res.stdout.toString().trim();
        if (raw.isNotEmpty && raw.startsWith('{')) {
          final data = jsonDecode(raw);
          if (data is Map<String, dynamic>) {
            final title = data['title']?.toString() ?? 'Media';
            final uploader =
                data['uploader']?.toString() ?? data['channel']?.toString();
            final extractor = data['extractor']?.toString() ??
                data['extractor_key']?.toString();
            final directUrl = data['url']?.toString();
            final duration = (data['duration'] is num)
                ? (data['duration'] as num).toInt()
                : null;
            final thumbnail = data['thumbnail']?.toString();

            int? size;
            if (data['filesize'] is num) {
              size = (data['filesize'] as num).toInt();
            } else if (data['filesize_approx'] is num) {
              size = (data['filesize_approx'] as num).toInt();
            }

            return YtDlpMediaInfo(
              title: title,
              uploader: uploader,
              extractor: extractor,
              directStreamUrl: directUrl,
              durationSeconds: duration,
              fileSize: size,
              thumbnail: thumbnail,
              isDirectStream: directUrl != null && directUrl.startsWith('http'),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('ytdlp_extra resolveMediaInfo hatası: $e');
    }
    return null;
  }

  /// Doğrudan akış URL'sini çeker (-g veya dump-json)
  Future<String?> resolveDirectStreamUrl(
    String targetUrl, {
    required DownloadQuality quality,
  }) async {
    if (!isSupportedPlatform(targetUrl)) return null;

    final ytdlp = await findYtDlpExecutable();
    if (ytdlp == null) return null;

    try {
      final normalizedUrl = normalizeUrl(targetUrl);
      final extraArgs = getExtraArgsForUrl(targetUrl);

      final fmtArg = quality.isAudioOnly
          ? 'ba/bestaudio/best'
          : 'bv*+ba/bestvideo+bestaudio/best';

      final res = await _runQuery(
        ytdlp,
        [
          '-g',
          '-f',
          fmtArg,
          '--no-warnings',
          '--no-playlist',
          '--no-check-certificates',
          '--ignore-config',
          '--geo-bypass',
          ...extraArgs,
          normalizedUrl,
        ],
      );

      if (res.exitCode == 0 && res.stdout != null) {
        final lines = res.stdout.toString().trim().split(RegExp(r'\r?\n'));
        final validUrl = lines
            .firstWhere(
              (l) => l.trim().startsWith('http'),
              orElse: () => '',
            )
            .trim();
        if (validUrl.isNotEmpty) {
          return validUrl;
        }
      }
    } catch (e) {
      debugPrint('ytdlp_extra resolveDirectStreamUrl hatası: $e');
    }

    // Yedek: JSON dump üzerinden tara
    final info = await resolveMediaInfo(targetUrl);
    if (info != null &&
        info.directStreamUrl != null &&
        info.directStreamUrl!.startsWith('http')) {
      return info.directStreamUrl;
    }

    return null;
  }

  /// İndirme öncesi tahmini veya kesin dosya boyutunu bayt cinsinden çeker
  Future<int?> resolveMediaSize(
    String targetUrl, {
    required DownloadQuality quality,
  }) async {
    if (!isSupportedPlatform(targetUrl)) return null;

    final ytdlp = await findYtDlpExecutable();
    if (ytdlp == null) return null;

    try {
      final normalizedUrl = normalizeUrl(targetUrl);
      final extraArgs = getExtraArgsForUrl(targetUrl);

      final fmtArg =
          quality.isAudioOnly ? 'bestaudio/best' : 'bestvideo+bestaudio/best';

      final res = await _runQuery(
        ytdlp,
        [
          '-O',
          '%(filesize,filesize_approx)s',
          '-f',
          fmtArg,
          '--no-warnings',
          '--no-playlist',
          '--ignore-config',
          ...extraArgs,
          normalizedUrl,
        ],
      );

      if (res.exitCode == 0 && res.stdout != null) {
        final line = res.stdout.toString().trim();
        final bytes = int.tryParse(line);
        if (bytes != null && bytes > 0) {
          return bytes;
        }
      }
    } catch (_) {}

    final info = await resolveMediaInfo(targetUrl);
    return info?.fileSize;
  }

  /// ytdlp_extra motorunu doğrudan çalıştırarak tam indirme ve FFmpeg birleştirme yapar
  Future<String> downloadWithProgress({
    required String targetUrl,
    required DownloadQuality quality,
    required String destinationPath,
    required DownloadProgressCallback onProgress,
  }) async {
    _cancelled = false;
    for (var attempt = 0;; attempt++) {
      try {
        return await _downloadOnce(
          targetUrl: targetUrl,
          quality: quality,
          destinationPath: destinationPath,
          onProgress: onProgress,
        );
      } catch (e) {
        final message = e.toString().toLowerCase();
        final transient = [
          'decompressing data',
          'timed out',
          'connection reset',
          'remote end closed',
          'http error 502',
          'http error 503',
          'http error 504'
        ].any(message.contains);
        if (_cancelled || !transient || attempt >= 1) rethrow;
        onProgress(0.15, 'Geçici bağlantı hatası, yeniden deneniyor...');
        await Future<void>.delayed(const Duration(seconds: 1));
        if (_cancelled) throw Exception('İndirme iptal edildi.');
      }
    }
  }

  Future<String> _downloadOnce({
    required String targetUrl,
    required DownloadQuality quality,
    required String destinationPath,
    required DownloadProgressCallback onProgress,
  }) async {
    if (!isSupportedPlatform(targetUrl)) {
      throw Exception(
        'Bu platform desteklenmemektedir. (Desteklenenler: YouTube, Instagram, TikTok, X, Facebook)',
      );
    }

    final ytdlp = await findYtDlpExecutable();
    if (ytdlp == null) {
      throw Exception(
        'İndirme motoru (yt-dlp.exe) sistemde bulunamadı. Lütfen uygulamanın kurulu olduğu klasörü kontrol ediniz.',
      );
    }

    final ffmpeg = await findFfmpegExecutable();
    if (ffmpeg == null) {
      throw Exception(
          'Dönüştürme motoru (ffmpeg.exe) bulunamadı. Lütfen uygulamayı yeniden kurunuz.');
    }

    // Çıkış dizinini güvenceye al
    final destDir = path_lib.dirname(destinationPath);
    if (!await Directory(destDir).exists()) {
      await Directory(destDir).create(recursive: true);
    }

    // Hedef uzantıyı ayarla
    final ext = quality.isAudioOnly ? 'mp3' : 'mp4';
    var finalPath = destinationPath;
    if (!finalPath.toLowerCase().endsWith('.$ext')) {
      finalPath = '${path_lib.withoutExtension(destinationPath)}.$ext';
    }

    final normalizedUrl = normalizeUrl(targetUrl);
    final extraArgs = getExtraArgsForUrl(targetUrl);
    final staging = await Directory(destDir).createTemp('.karadelik-');
    try {
      // yt-dlp argümanları
      final args = <String>[
        '--newline',
        '--encoding',
        'utf-8',
        '--socket-timeout',
        '20',
        '--no-colors',
        '--no-playlist',
        '--ignore-config',
        '--geo-bypass',
        '--force-overwrites',
        '--retries',
        '3',
        '--fragment-retries',
        '3',
        '--abort-on-unavailable-fragments',
        '--buffer-size',
        '1024K',
        ...extraArgs,
      ];

      args.addAll(['--ffmpeg-location', path_lib.dirname(ffmpeg)]);

      if (quality.isAudioOnly) {
        args.addAll([
          '-f',
          'ba/bestaudio/best',
          '-x',
          '--audio-format',
          'mp3',
          '--audio-quality',
          '320K',
        ]);
      } else {
        args.addAll([
          '-f',
          'bv*+ba/bestvideo+bestaudio/best',
          '--merge-output-format',
          'mp4',
          '--remux-video',
          'mp4',
        ]);
      }

      args.addAll(
          ['-o', path_lib.join(staging.path, 'media.%(ext)s'), normalizedUrl]);

      onProgress(0.15, 'İndirme motoru bağlanıyor...');
      if (_cancelled) throw Exception('İndirme iptal edildi.');

      final process = await Process.start(
        ytdlp,
        args,
        mode: ProcessStartMode.normal,
      );
      _activeProcesses.add(process);

      try {
        process.stdin.close();
      } catch (_) {}

      final errorLines = <String>[];

      // stdout dinle
      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;

        // İlerleme yüzdesi ve hız analizi
        final match = _progressRegex.firstMatch(trimmed);
        if (match != null) {
          final percent = double.tryParse(match.group(1) ?? '0') ?? 0.0;
          final totalStr = match.group(2) ?? '';
          final totalUnit = match.group(3) ?? '';
          final speedVal = match.group(4) ?? '';
          final speedUnit = match.group(5) ?? '';
          final etaStr = match.group(6) ?? '';

          final normalizedProgress =
              (0.20 + (percent / 100.0) * 0.75).clamp(0.0, 0.98);
          final speedText =
              speedVal.isNotEmpty ? '$speedVal $speedUnit/s' : null;
          final etaText = etaStr.isNotEmpty ? 'Kalan: $etaStr' : null;

          onProgress(
            normalizedProgress,
            '%${percent.toInt()} indiriliyor... ($totalStr $totalUnit)',
            speed: speedText,
            eta: etaText,
          );
          return;
        }

        if (_completedRegex.hasMatch(trimmed)) {
          onProgress(0.95, 'İndirme tamamlandı, birleştiriliyor...');
          return;
        }

        if (trimmed.startsWith('[Merger]') ||
            trimmed.contains('Merging formats')) {
          onProgress(0.96, 'Ses ve görüntü birleştiriliyor (FFmpeg HQ)...');
          return;
        }

        if (trimmed.startsWith('[ExtractAudio]') ||
            trimmed.contains('Destination:')) {
          onProgress(
              0.96, 'Stüdyo kalitesinde MP3 formatına dönüştürülüyor...');
          return;
        }

        if (trimmed.startsWith('[Fixup') || trimmed.contains('Fixing')) {
          onProgress(0.97, 'Medya başlıkları optimize ediliyor...');
          return;
        }
      }).asFuture<void>();

      // stderr dinle
      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty && !trimmed.startsWith('WARNING')) {
          errorLines.add(trimmed);
        }
      }).asFuture<void>();

      late final int exitCode;
      try {
        exitCode = await process.exitCode.timeout(const Duration(minutes: 15));
      } on TimeoutException {
        await _stopProcess(process);
        throw TimeoutException(
            'İndirme işlemi 15 dakikalık zaman aşımına uğradı.');
      } finally {
        await Future.wait([stdoutDone, stderrDone]);
        _activeProcesses.remove(process);
      }
      if (_cancelled) throw Exception('İndirme iptal edildi.');

      if (exitCode != 0) {
        final err = errorLines.isNotEmpty
            ? errorLines.reversed.take(8).toList().reversed.join('\n')
            : 'Bilinmeyen hata (Kod $exitCode)';
        if (err.contains('Account authentication is required') ||
            err.contains('login')) {
          throw Exception(
              'Bu içerik hesap girişi veya yaş doğrulaması (18+) gerektiriyor.');
        }
        throw Exception('İndirme başarısız oldu: $err');
      }

      final resultFile = File(path_lib.join(staging.path, 'media.$ext'));
      if (!await resultFile.exists() || await resultFile.length() <= 1024) {
        throw Exception('İndirilen dosya doğrulanamadı veya boş (0 bayt).');
      }

      // Verify the requested streams before exposing a completed file.
      final validator = await Process.start(ffmpeg, [
        '-nostdin',
        '-v',
        'error',
        '-xerror',
        '-i',
        resultFile.path,
        '-map',
        quality.isAudioOnly ? '0:a:0' : '0:a:0?',
        if (!quality.isAudioOnly) ...['-map', '0:v:0'],
        '-t',
        '0.1',
        '-f',
        'null',
        '-',
      ]);
      _activeProcesses.add(validator);
      final validationOut = validator.stdout.drain<void>();
      final validationErr = validator.stderr.transform(utf8.decoder).join();
      try {
        final code =
            await validator.exitCode.timeout(const Duration(seconds: 30));
        await validationOut;
        final errors = await validationErr;
        if (code != 0) throw Exception('Medya doğrulanamadı: $errors');
      } on TimeoutException {
        await _stopProcess(validator);
        await validationOut;
        await validationErr;
        rethrow;
      } finally {
        _activeProcesses.remove(validator);
      }
      if (_cancelled) throw Exception('İndirme iptal edildi.');
      await resultFile.rename(finalPath);

      onProgress(1.0, 'Tamamlandı!');
      return finalPath;
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  /// Aktif süreçleri sonlandırır
  void cancel() {
    _cancelled = true;
    for (final p in _activeProcesses.toList()) {
      try {
        unawaited(_stopProcess(p));
      } catch (_) {}
    }
    _activeProcesses.clear();
  }
}
