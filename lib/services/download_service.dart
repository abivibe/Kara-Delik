import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path_lib;
import 'package:path_provider/path_provider.dart';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'download_history_service.dart';
import 'localization_service.dart';
import 'mp4_fixer.dart';
import 'ytdlp_extra_service.dart';

enum DownloadQuality {
  mp4,
  mp3,
}

extension DownloadQualityExtension on DownloadQuality {
  String get label {
    switch (this) {
      case DownloadQuality.mp4:
        return AppLocalizations.tr('style_mp4');
      case DownloadQuality.mp3:
        return AppLocalizations.tr('style_mp3');
    }
  }

  String get cobaltQualityValue => 'max';

  bool get isAudioOnly => this == DownloadQuality.mp3;
}

typedef DownloadProgressCallback = void Function(
  double progress,
  String statusText, {
  String? speed,
  String? eta,
});

class SpeedTracker {
  int _lastBytes = 0;
  DateTime _lastTime = DateTime.now();
  double _smoothedSpeed = 0.0;
  String currentSpeed = '';
  String currentEta = '';

  SpeedTracker() {
    _lastTime = DateTime.now();
  }

  void update(int currentBytes, int totalBytes) {
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastTime).inMilliseconds;
    if (elapsedMs < 250) return; // Update up to 4 times a second

    final deltaBytes = currentBytes - _lastBytes;
    if (deltaBytes <= 0) {
      _lastBytes = currentBytes;
      _lastTime = now;
      return;
    }

    final instantSpeed = deltaBytes / (elapsedMs / 1000.0);
    if (_smoothedSpeed <= 0) {
      _smoothedSpeed = instantSpeed;
    } else {
      _smoothedSpeed = (_smoothedSpeed * 0.7) + (instantSpeed * 0.3);
    }

    _lastBytes = currentBytes;
    _lastTime = now;

    if (_smoothedSpeed > 0) {
      if (_smoothedSpeed < 1024 * 1024) {
        currentSpeed = '${(_smoothedSpeed / 1024).toStringAsFixed(1)} KB/s';
      } else {
        currentSpeed = '${(_smoothedSpeed / (1024 * 1024)).toStringAsFixed(1)} MB/s';
      }
    }

    if (totalBytes > 0 && currentBytes < totalBytes && _smoothedSpeed > 1024) {
      final remainingBytes = totalBytes - currentBytes;
      final remainingSecs = (remainingBytes / _smoothedSpeed).round();
      final prefix = AppLocalizations.tr('eta_remaining');
      final secLabel = AppLocalizations.tr('time_sec');
      final minLabel = AppLocalizations.tr('time_min');
      if (remainingSecs < 60) {
        currentEta = '$prefix$remainingSecs $secLabel';
      } else {
        final mins = remainingSecs ~/ 60;
        final secs = remainingSecs % 60;
        currentEta = '$prefix$mins $minLabel $secs $secLabel';
      }
    } else {
      currentEta = '';
    }
  }
}

class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal() {
    if (_dio.httpClientAdapter is IOHttpClientAdapter) {
      (_dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
        final client = HttpClient();
        client.badCertificateCallback = (cert, host, port) => true;
        client.maxConnectionsPerHost = 64;
        client.idleTimeout = const Duration(seconds: 60);
        client.connectionTimeout = const Duration(seconds: 20);
        return client;
      };
    }
  }

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(hours: 3), // Timeout engelleme (kesintisiz indirme)
      sendTimeout: const Duration(minutes: 5),
      headers: {
        'Accept': '*/*',
        'Connection': 'keep-alive',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
      },
    ),
  );

  
  

  CancelToken? _cancelToken;
  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;
  Duration? lastResolvedVideoDuration;

  /// Cobalt API aktif yedek sunucu havuzu (Cloudflare Turnstile engelsiz)
  final List<String> _cobaltInstances = [
    'https://rue-cobalt.xenon.zone',
    'https://cobaltapi.cjs.nz',
    'https://cobaltapi.kittycat.boo',
    'https://cobaltapi.squair.xyz',
    'https://dog.kittycat.boo',
    'https://api.cobalt.rpkiinval.id',
    'https://melon.clxxped.lol',
    'https://grapefruit.clxxped.lol',
    'https://lime.clxxped.lol',
  ];

  /// Invidious API havuzu (YouTube PoToken doğrulamalı, 403 engelsiz doğrudan CDN akışları)
  final List<String> _invidiousInstances = [
    'https://inv.nadeko.net',
    'https://yewtu.be',
    'https://invidious.nerdvpn.de',
    'https://inv-ygg.nadeko.net',
    'https://invidious.tiekoetter.com',
    'https://invidious.jing.rocks',
    'https://vid.puffyan.us',
    'https://invidious.drgns.space',
    'https://invidious.privacydev.net',
  ];

  String? customInstanceUrl;
  String? customDownloadPath;

  /// Desteklenen platformlar (YouTube, Instagram, TikTok, X/Twitter, Facebook) için kapsamlı Regex deseni
  static final RegExp _supportedUrlRegex = RegExp(
    r'(https?:\/\/(?:[a-zA-Z0-9\-]+\.)?(?:(?:youtube\.com\/(?:watch\?(?:[^\s]*&)?v=|shorts\/|embed\/|v\/|live\/)[a-zA-Z0-9_\-]+)|(?:youtu\.be\/[a-zA-Z0-9_\-]+)|(?:instagram\.com\/(?:(?:[a-zA-Z0-9_.]+\/)?(?:p|reel|reels|tv|stories|share(?:\/reel|\/p)?)\/[a-zA-Z0-9_\-]+(?:\/[a-zA-Z0-9_\-]+)?))|(?:(?:[a-zA-Z0-9\-]+\.)?(?:cdninstagram\.com|fbcdn\.net)\/[^\s]+)|(?:(?:vm\.|vt\.|www\.)?tiktok\.com\/(?:@?[a-zA-Z0-9_.]+\/video\/\d+|[a-zA-Z0-9_\-]+))|(?:(?:twitter\.com|x\.com)\/(?:[a-zA-Z0-9_]+\/)?status\/\d+)|(?:(?:facebook\.com|fb\.watch|fb\.com)\/[a-zA-Z0-9_\-\.\/?=&%+]+)))',
    caseSensitive: false,
  );

  /// İndirilen platform adını ayıklar (dosya adlandırma ve etiket için)
  String detectPlatformName(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('youtube.com') || lower.contains('youtu.be')) return 'YouTube';
    if (lower.contains('instagram.com') || lower.contains('cdninstagram.com') || lower.contains('fbcdn.net')) return 'Instagram';
    if (lower.contains('tiktok.com')) return 'TikTok';
    if (lower.contains('twitter.com') || lower.contains('x.com')) return 'X';
    if (lower.contains('facebook.com') || lower.contains('fb.watch') || lower.contains('fb.com')) return 'Facebook';
    return 'Media';
  }

  /// Metin içerisindeki geçerli indirme linkini ayıklar (Yalnızca 5 platform: YouTube, Instagram, TikTok, X, Facebook)
  String? extractSupportedUrl(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    final trimmed = text.trim();
    final match = _supportedUrlRegex.firstMatch(trimmed);
    if (match != null) return match.group(1);
    return null;
  }

  /// Cihaz panosunu denetler ve desteklenen link varsa döner
  Future<String?> checkClipboardForSupportedUrl() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData != null && clipboardData.text != null) {
        return extractSupportedUrl(clipboardData.text);
      }
    } catch (e) {
      debugPrint('Pano okunurken hata: $e');
    }
    return null;
  }

  

  /// Platforma uygun kayıt dizinini belirler
  Future<String> getDestinationDirectory() async {
    if (customDownloadPath != null &&
        customDownloadPath!.trim().isNotEmpty &&
        Directory(customDownloadPath!.trim()).existsSync()) {
      return customDownloadPath!.trim();
    }

    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null) {
        final winDownloads = Directory('$userProfile\\Downloads');
        if (await winDownloads.exists()) {
          return winDownloads.path;
        }
      }
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir != null) {
        return downloadsDir.path;
      }
      return Directory.current.path;
    } else {
      final defaultDir = await getDownloadsDirectory();
      return defaultDir?.path ?? Directory.current.path;
    }
  }

  

  

  

  /// Invidious ses akışları arasından yalnızca orijinal ses parçasını seçer (sonradan eklenen dublajları eler)
  List<dynamic> _filterOriginalInvidiousAudios(List<dynamic> audios) {
    if (audios.isEmpty) return audios;

    // 1. Orijinal ses parçası etiketini ara (acont=original)
    final originals = audios.where((f) {
      final u = (f['url']?.toString() ?? '').toLowerCase();
      final x = (f['xtags']?.toString() ?? '').toLowerCase();
      final at = (f['audioTrack']?.toString() ?? '').toLowerCase();
      return u.contains('acont=original') ||
          u.contains('acont%3doriginal') ||
          x.contains('acont=original') ||
          at.contains('original');
    }).toList();

    if (originals.isNotEmpty) {
      return originals;
    }

    // 2. Dublajlı (acont=dubbed) akışları hariç tut (tek dilli videolarda acont etiketi bulunmaz)
    final nonDubbed = audios.where((f) {
      final u = (f['url']?.toString() ?? '').toLowerCase();
      final x = (f['xtags']?.toString() ?? '').toLowerCase();
      final at = (f['audioTrack']?.toString() ?? '').toLowerCase();
      return !u.contains('acont=dubbed') &&
          !u.contains('acont%3ddubbed') &&
          !x.contains('acont=dubbed') &&
          !at.contains('dubbed');
    }).toList();

    if (nonDubbed.isNotEmpty) {
      return nonDubbed;
    }

    return audios;
  }

  /// YouTubeExplode ses akışları arasından orijinal ses parçasını seçer (sonradan eklenen dublajları eler)
  List<AudioOnlyStreamInfo> _filterOriginalYtExplodeAudios(Iterable<AudioOnlyStreamInfo> audios) {
    final list = audios.toList();
    if (list.isEmpty) return list;

    // 1. Orijinal/Varsayılan ses parçasını ara (audioIsDefault == true veya displayName içinde original/varsayılan)
    final originals = list.where((a) {
      final track = a.audioTrack;
      if (track == null) return false;
      if (track.audioIsDefault == true) return true;
      final name = track.displayName.toLowerCase();
      return name.contains('original') || name.contains('varsayılan') || name.contains('default');
    }).toList();

    if (originals.isNotEmpty) {
      return originals;
    }

    // 2. Dublajlı (audioIsDefault == false) olmayanları filtrele (tek dilli videolarda track null'dır)
    final nonDubbed = list.where((a) {
      final track = a.audioTrack;
      if (track == null) return true; // Tek dilli videolarda track null'dır
      if (track.audioIsDefault == false) return false;
      final name = track.displayName.toLowerCase();
      if (name.contains('dubbed') || name.contains('dublaj')) return false;
      return true;
    }).toList();

    if (nonDubbed.isNotEmpty) {
      return nonDubbed;
    }

    return list;
  }

  /// YouTubeExplode için en iyi orijinal ses akışını döndürür
  AudioOnlyStreamInfo _getBestOriginalYtExplodeAudio(
    Iterable<AudioOnlyStreamInfo> audios, {
    bool preferMp4 = false,
  }) {
    final filtered = _filterOriginalYtExplodeAudios(audios);
    if (preferMp4) {
      final mp4s = filtered.where((s) => s.container.name.toLowerCase() == 'mp4').toList();
      if (mp4s.isNotEmpty) {
        mp4s.sort((a, b) => b.bitrate.compareTo(a.bitrate));
        return mp4s.first;
      }
    }
    final sorted = filtered.toList()..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return sorted.first;
  }

  /// YouTube bağlantısını doğrudan yerel YouTubeExplode motoru ile çözer
  Future<String?> _resolveYouTubeUrl(
    String targetUrl,
    DownloadQuality quality,
  ) async {
    final yt = YoutubeExplode();
    try {
      final video = await yt.videos.get(targetUrl).timeout(const Duration(seconds: 12));
      lastResolvedVideoDuration = video.duration;
      final manifest = await yt.videos.streamsClient.getManifest(video.id).timeout(const Duration(seconds: 12));

      if (quality.isAudioOnly) {
        final audioStream = _getBestOriginalYtExplodeAudio(manifest.audioOnly);
        return audioStream.url.toString();
      }

      // Muxed stream (Ses ve görüntü birleşik - En yüksek kalite)
      final muxedStreams = manifest.muxed.sortByVideoQuality();
      if (muxedStreams.isNotEmpty) {
        return muxedStreams.first.url.toString();
      }
    } catch (e) {
      debugPrint('YouTubeExplode doğrudan çözümleme hatası: $e');
    } finally {
      yt.close();
    }
    return null;
  }

  /// X (Twitter) videosunu FxTwitter / FixupX / VxTwitter uç noktalarından en yüksek bit hızı ve çözünürlükle çözer
  Future<String?> _resolveTwitterUrl(String targetUrl, [DownloadQuality? quality]) async {
    try {
      final match = RegExp(
        r'(?:twitter\.com|x\.com)\/(?:([a-zA-Z0-9_]+)\/)?status\/(\d+)',
        caseSensitive: false,
      ).firstMatch(targetUrl);
      if (match == null) return null;
      final user = match.group(1);
      final tweetId = match.group(2)!;

      final endpoints = <String>[
        'https://api.fxtwitter.com/2/status/$tweetId',
        'https://api.fxtwitter.com/status/$tweetId',
        'https://api.fixupx.com/2/status/$tweetId',
        'https://api.fixupx.com/status/$tweetId',
        'https://api.vxtwitter.com/Twitter/status/$tweetId',
      ];
      if (user != null && user != 'i') {
        endpoints.add('https://api.fxtwitter.com/$user/status/$tweetId');
        endpoints.add('https://api.fixupx.com/$user/status/$tweetId');
        endpoints.add('https://api.vxtwitter.com/$user/status/$tweetId');
      }

      for (final ep in endpoints) {
        try {
          final response = await _dio.get(
            ep,
            options: Options(
              responseType: ResponseType.json,
              headers: {
                'Accept': 'application/json',
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
              },
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 8),
            ),
          );

          if (response.statusCode == 200 && response.data != null) {
            final data = response.data is String
                ? jsonDecode(response.data)
                : response.data;
            if (data is Map) {
              final tweet = (data['status'] is Map)
                  ? data['status'] as Map
                  : ((data['tweet'] is Map) ? data['tweet'] as Map : data);

              // 1. media.videos listesi (MP3 için en optimize/hafif akış, Video için en yüksek çözünürlük ve bit hızına sahip MP4 akışını seç)
              if (tweet['media'] is Map && tweet['media']['videos'] is List) {
                final videos = tweet['media']['videos'] as List;
                String? bestUrl;
                int selectedScore = (quality?.isAudioOnly == true) ? 999999999999 : 0;
                for (final v in videos) {
                  if (v is Map) {
                    // Süreyi kaydet (MP4 Başlık Onarıcı için)
                    if (v['duration'] is num) {
                      final dSec = (v['duration'] as num).round();
                      if (dSec > 0) {
                        lastResolvedVideoDuration = Duration(seconds: dSec);
                      }
                    }

                    // Eğer variants listesi varsa en yüksek bitrate MP4 varyantını tara
                    if (v['variants'] is List && quality?.isAudioOnly != true) {
                      for (final vr in (v['variants'] as List)) {
                        if (vr is Map && vr['url'] != null) {
                          final vu = vr['url'].toString();
                          final ct = (vr['content_type'] ?? '').toString().toLowerCase();
                          if (vu.startsWith('http') && (ct.contains('mp4') || vu.contains('.mp4'))) {
                            final br = (vr['bitrate'] is num) ? (vr['bitrate'] as num).toInt() : 0;
                            if (bestUrl == null || br > selectedScore) {
                              bestUrl = vu;
                              selectedScore = br;
                            }
                          }
                        }
                      }
                    }

                    if (v['url'] != null) {
                      final u = v['url'].toString();
                      if (u.isNotEmpty && u.startsWith('http')) {
                        final w = (v['width'] is num) ? (v['width'] as num).toInt() : 0;
                        final h = (v['height'] is num) ? (v['height'] as num).toInt() : 0;
                        final br = (v['bitrate'] is num) ? (v['bitrate'] as num).toInt() : 0;
                        final score = (w * h * 1000) + (br ~/ 1000);
                        if (quality?.isAudioOnly == true) {
                          if (bestUrl == null || (score > 0 && score < selectedScore)) {
                            bestUrl = u;
                            selectedScore = score;
                          }
                        } else {
                          if (bestUrl == null || score > selectedScore) {
                            bestUrl = u;
                            selectedScore = score;
                          }
                        }
                      }
                    }
                  }
                }
                if (bestUrl != null) return bestUrl;
              }

              // 2. media_extended listesi (VxTwitter formatı)
              if (tweet['media_extended'] is List) {
                final mediaList = tweet['media_extended'] as List;
                for (final item in mediaList) {
                  if (item is Map &&
                      (item['type'] == 'video' || item['type'] == 'gif') &&
                      item['url'] != null) {
                    if (item['duration_millis'] is num) {
                      final dMs = (item['duration_millis'] as num).toInt();
                      if (dMs > 0) {
                        lastResolvedVideoDuration = Duration(milliseconds: dMs);
                      }
                    }
                    final videoUrl = item['url'].toString();
                    if (videoUrl.isNotEmpty && videoUrl.startsWith('http')) return videoUrl;
                  }
                }
              }

              // 3. media.all listesi
              if (tweet['media'] is Map && tweet['media']['all'] is List) {
                final allMedia = tweet['media']['all'] as List;
                for (final item in allMedia) {
                  if (item is Map &&
                      item['type'] == 'video' &&
                      item['url'] != null) {
                    final videoUrl = item['url'].toString();
                    if (videoUrl.isNotEmpty && videoUrl.startsWith('http')) return videoUrl;
                  }
                }
              }

              // 4. video.url tekil alan
              if (tweet['video'] is Map && tweet['video']['url'] != null) {
                final vUrl = tweet['video']['url'].toString();
                if (vUrl.isNotEmpty && vUrl.startsWith('http')) return vUrl;
              }
            }
          }
        } catch (_) {
          continue;
        }
      }
    } catch (e) {
      debugPrint('Twitter çözümleme hatası: $e');
    }
    return null;
  }

  /// TikTok videosunu filigransız en yüksek HD (1080p) kalitede çözer (tüm orijinal ses ve konuşmaları içerir)
  Future<String?> _resolveTikTokUrl(String targetUrl, DownloadQuality quality) async {
    try {
      final response = await _dio.post(
        'https://www.tikwm.com/api/',
        data: {'url': targetUrl, 'hd': 1},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data is String ? jsonDecode(response.data) : response.data;
        if (data is Map && data['data'] != null) {
          final videoData = data['data'];
          if (videoData is Map) {
            // MP4 süre başlık onarıcı için süreyi kaydet
            if (videoData['duration'] is num) {
              final durSec = (videoData['duration'] as num).toInt();
              if (durSec > 0) {
                lastResolvedVideoDuration = Duration(seconds: durSec);
              }
            }

            // Video indirmelerinde en yüksek kaliteli filigransız 1080p HD akışı (hdplay) önceliklidir!
            // MP3 indirmelerinde ise videodaki tüm konuşma ve orijinal sesleri eksiksiz içeren
            // standart play akışı hız avantajıyla çekilip MP3'e dönüştürülür.
            final directUrl = quality.isAudioOnly
                ? (videoData['play'] ?? videoData['hdplay'] ?? videoData['wmplay']) as String?
                : (videoData['hdplay'] ?? videoData['play'] ?? videoData['wmplay']) as String?;
            if (directUrl != null && directUrl.isNotEmpty) {
              return directUrl.startsWith('http')
                  ? directUrl
                  : 'https://www.tikwm.com$directUrl';
            }
          }
        }
      }
    } catch (e) {
      debugPrint('TikTok çözümleme hatası: $e');
    }
    return null;
  }

  /// SnapSave üzerinden Instagram video akışını çözer
  Future<String?> _resolveSnapSaveInstagram(String targetUrl) async {
    try {
      final response = await _dio.post(
        'https://snapsave.app/action.php',
        data: 'url=${Uri.encodeQueryComponent(targetUrl)}',
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
            'Origin': 'https://snapsave.app',
            'Referer': 'https://snapsave.app/',
          },
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final body = response.data.toString();
        final evalRegex = RegExp(
          r'\(\s*"([^"]+)"\s*,\s*[^,]*\s*,\s*"([^"]+)"\s*,\s*(\d+)\s*,\s*(\d+)',
        );
        final match = evalRegex.firstMatch(body);
        if (match != null) {
          final h = match.group(1)!;
          final n = match.group(2)!;
          final t = int.tryParse(match.group(3)!) ?? 0;
          final e = int.tryParse(match.group(4)!) ?? 10;
          final rawHtml = _decodeSnapApp(h, n, t, e);
          final unpackedHtml = rawHtml.replaceAll(r'\"', '"').replaceAll(r"\'", "'");

          final hrefRegex = RegExp(r'href="([^"]+)"');
          final hrefMatches = hrefRegex.allMatches(unpackedHtml);
          for (final m in hrefMatches) {
            final link = m.group(1);
            if (link == null) continue;
            final lower = link.toLowerCase();
            // Kesinlikle görsel (JPEG/PNG/WEBP vb.) veya küçük resim linklerini ele
            if (lower.endsWith('.jpg') ||
                lower.endsWith('.jpeg') ||
                lower.endsWith('.png') ||
                lower.endsWith('.webp') ||
                lower.contains('/v/t51.') ||
                lower.contains('mime=image')) {
              continue;
            }
            if (lower.contains('.mp4') ||
                lower.contains('rapidcdn.app') ||
                lower.contains('snapcdn') ||
                lower.contains('download') ||
                lower.contains('mime=video') ||
                lower.contains('bytestart=')) {
              return link.replaceAll('&amp;', '&');
            }
          }

          // Alternatif doğrudan d.rapidcdn.app veya snapcdn bağlantısı
          final rapidMatch = RegExp(
            r'''(https?://[^\s"'<>]+(?:rapidcdn\.app|snapcdn)[^\s"'<>]+)''',
          ).firstMatch(unpackedHtml);
          if (rapidMatch != null) {
            final rLink = rapidMatch.group(1)!;
            final lowerR = rLink.toLowerCase();
            if (!lowerR.endsWith('.jpg') && !lowerR.endsWith('.jpeg') && !lowerR.endsWith('.png')) {
              return rLink.replaceAll('&amp;', '&');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('SnapSave çözümleme hatası: $e');
    }
    return null;
  }


  /// SnapSave JS Packer çözücü algoritması
  String _decodeSnapApp(String h, String n, int t, int e) {
    const alphabet =
        '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+/';
    final hCharset = e <= alphabet.length ? alphabet.substring(0, e) : alphabet;

    final buffer = StringBuffer();
    var i = 0;
    final len = h.length;
    final neChar = e < n.length ? n[e] : null;

    while (i < len) {
      var s = '';
      while (i < len && (neChar == null || h[i] != neChar)) {
        s += h[i];
        i++;
      }
      i++; // ayırıcıyı atla

      for (var j = 0; j < n.length; j++) {
        s = s.replaceAll(n[j], j.toString());
      }

      if (s.isNotEmpty) {
        var intVal = 0;
        final digits = s.split('').reversed.toList();
        for (var c = 0; c < digits.length; c++) {
          final char = digits[c];
          final idx = hCharset.indexOf(char);
          if (idx != -1) {
            intVal += idx * _intPow(e, c);
          }
        }
        final code = intVal - t;
        if (code > 0) {
          buffer.writeCharCode(code);
        }
      }
    }

    return utf8.decode(buffer.toString().codeUnits, allowMalformed: true);
  }

  int _intPow(int base, int exp) {
    var result = 1;
    for (var i = 0; i < exp; i++) {
      result *= base;
    }
    return result;
  }

  /// Instagram bağlantısını temizler ve standart reel/p formatına dönüştürür
  String _normalizeInstagramUrl(String url) {
    try {
      if (url.contains('cdninstagram.com') || url.contains('fbcdn.net')) {
        return url;
      }
      final codeMatch = RegExp(
        r'\/(p|reel|reels|tv|share\/reel|share\/p)\/([a-zA-Z0-9_-]{5,35})',
        caseSensitive: false,
      ).firstMatch(url);
      if (codeMatch != null) {
        final type = codeMatch.group(1)!.toLowerCase();
        final shortcode = codeMatch.group(2)!;
        if (type.contains('p')) {
          return 'https://www.instagram.com/p/$shortcode/';
        } else if (type.contains('tv')) {
          return 'https://www.instagram.com/tv/$shortcode/';
        } else {
          return 'https://www.instagram.com/reel/$shortcode/';
        }
      }
    } catch (_) {}
    return url.split('?').first;
  }

  /// Instagram doğrudan embed ve sayfa meta katmanları üzerinden en yüksek çözünürlüklü video bağlantısını arar
  Future<String?> _resolveInstagramEmbed(String targetUrl) async {
    try {
      final codeMatch = RegExp(
        r'(?:p|reel|reels|tv|share\/reel|share\/p|reels\/videos)\/([a-zA-Z0-9_-]{5,35})',
        caseSensitive: false,
      ).firstMatch(targetUrl) ?? RegExp(
        r'\/(?:reel|p)\/([a-zA-Z0-9_-]{5,35})',
        caseSensitive: false,
      ).firstMatch(targetUrl);
      if (codeMatch == null) return null;
      final shortcode = codeMatch.group(1)!;

      final endpoints = [
        'https://www.instagram.com/reel/$shortcode/embed/captioned/',
        'https://www.instagram.com/p/$shortcode/embed/captioned/',
        'https://www.instagram.com/reel/$shortcode/?__a=1&__d=dis',
      ];

      bool isValidVideoLink(String u) {
        final lower = u.toLowerCase();
        if (lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            lower.endsWith('.png') ||
            lower.endsWith('.webp') ||
            lower.contains('/v/t51.') ||
            lower.contains('mime=image')) {
          return false;
        }
        return u.startsWith('http');
      }

      for (final embedUrl in endpoints) {
        try {
          final response = await _dio.get(
            embedUrl,
            options: Options(
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              },
              followRedirects: true,
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
            ),
          );

          if (response.statusCode == 200 && response.data != null) {
            final content = response.data.toString();

            // 0. video_duration varsa yakala (MP4 Başlık Onarıcı için)
            final durMatch = RegExp(r'"video_duration"\s*:\s*([0-9.]+)').firstMatch(content) ??
                RegExp(r'video_duration\\":([0-9.]+)').firstMatch(content);
            if (durMatch != null) {
              final durVal = double.tryParse(durMatch.group(1)!) ?? 0;
              if (durVal > 0) {
                lastResolvedVideoDuration = Duration(milliseconds: (durVal * 1000).round());
              }
            }

            // 1. JSON escape video_url
            var videoMatch = RegExp(r'video_url\\":\\"([^"\\]+)\\"').firstMatch(content);
            if (videoMatch != null) {
              final cand = videoMatch.group(1)!.replaceAll(r'\u0026', '&').replaceAll(r'\/', '/');
              if (isValidVideoLink(cand)) return cand;
            }
            // 2. Düz JSON video_url
            videoMatch = RegExp(r'"video_url"\s*:\s*"([^"]+)"').firstMatch(content);
            if (videoMatch != null) {
              final cand = videoMatch.group(1)!.replaceAll(r'\u0026', '&').replaceAll(r'\/', '/');
              if (isValidVideoLink(cand)) return cand;
            }
            // 3. contentUrl JSON
            var contentMatch = RegExp(r'contentUrl\\":\\"([^"\\]+)\\"').firstMatch(content) ??
                RegExp(r'"contentUrl"\s*:\s*"([^"]+)"').firstMatch(content);
            if (contentMatch != null) {
              final cand = contentMatch.group(1)!.replaceAll(r'\u0026', '&').replaceAll(r'\/', '/');
              if (isValidVideoLink(cand)) return cand;
            }
            // 4. video src etiketi
            final videoTagMatch = RegExp(r'<video[^>]+src="([^"]+)"', caseSensitive: false).firstMatch(content);
            if (videoTagMatch != null) {
              final cand = videoTagMatch.group(1)!.replaceAll('&amp;', '&');
              if (isValidVideoLink(cand)) return cand;
            }
            // 5. og:video meta etiketi
            final ogMatch = RegExp(r'<meta\s+property="og:video"\s+content="([^"]+)"', caseSensitive: false).firstMatch(content);
            if (ogMatch != null) {
              final cand = ogMatch.group(1)!.replaceAll('&amp;', '&');
              if (isValidVideoLink(cand)) return cand;
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Instagram embed çözümleme hatası: $e');
    }
    return null;
  }


  /// Facebook video akışını en yüksek çözünürlükle (1080p FHD / HD öncelikli) çözer
  Future<String?> _resolveFacebookUrl(
    String targetUrl,
    DownloadQuality quality,
  ) async {
    // 0. fb.watch ve /share/ gibi yönlendirme bağlantılarını genişlet
    String effectiveUrl = targetUrl;
    if (targetUrl.contains('fb.watch') || targetUrl.contains('/share/')) {
      try {
        final headResp = await _dio.get(
          targetUrl,
          options: Options(
            followRedirects: true,
            maxRedirects: 5,
            validateStatus: (s) => true,
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
            },
          ),
        );
        final realUri = headResp.realUri.toString();
        if (realUri.isNotEmpty && !realUri.contains('/share/')) {
          effectiveUrl = realUri;
        }
      } catch (_) {}
    }

    // 1. Cobalt API yedek sunucuları ile çözme (max kalite)
    final cobaltResult = await _resolveCobaltInstanceUrl(
      targetUrl: effectiveUrl,
      quality: quality,
    );
    if (cobaltResult != null) return cobaltResult;

    if (quality.isAudioOnly) {
      final cobaltVideo = await _resolveCobaltInstanceUrl(
        targetUrl: effectiveUrl,
        quality: DownloadQuality.mp4,
      );
      if (cobaltVideo != null) return cobaltVideo;
    }

    // 2. SnapSave ile Facebook 1080p/HD çözme
    final snapResult = await _resolveSnapSaveInstagram(effectiveUrl) ??
        await _resolveSnapSaveInstagram(targetUrl);
    if (snapResult != null) return snapResult;

    // 3. Facebook doğrudan sayfa başlıkları ve meta etiketleri üzerinden HD öncelikli arama
    try {
      final response = await _dio.get(
        effectiveUrl,
        options: Options(
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Sec-Fetch-Mode': 'navigate',
          },
          followRedirects: true,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      if (response.statusCode == 200 && response.data != null) {
        final html = response.data.toString();
        // HD video akışı (1080p / 720p)
        final hdPatterns = [
          r'"playable_url_quality_hd":"([^"]+)"',
          r'"browser_native_hd_url":"([^"]+)"',
          r'"hd_src_no_ratelimit":"([^"]+)"',
          r'"hd_src":"([^"]+)"',
        ];
        for (final pat in hdPatterns) {
          final m = RegExp(pat).firstMatch(html);
          if (m != null && m.group(1) != null && m.group(1)! != 'null') {
            return m.group(1)!
                .replaceAll(r'\/', '/')
                .replaceAll(r'\u0026', '&')
                .replaceAll('&amp;', '&');
          }
        }
        // SD video akışı
        final sdPatterns = [
          r'"playable_url":"([^"]+)"',
          r'"browser_native_sd_url":"([^"]+)"',
          r'"sd_src_no_ratelimit":"([^"]+)"',
          r'"sd_src":"([^"]+)"',
        ];
        for (final pat in sdPatterns) {
          final m = RegExp(pat).firstMatch(html);
          if (m != null && m.group(1) != null && m.group(1)! != 'null') {
            return m.group(1)!
                .replaceAll(r'\/', '/')
                .replaceAll(r'\u0026', '&')
                .replaceAll('&amp;', '&');
          }
        }
      }
    } catch (e) {
      debugPrint('Facebook doğrudan çözümleme hatası: $e');
    }

    return null;
  }

  /// Cobalt API yedek sunucuları üzerinden akış bağlantısını çözer
  Future<String?> _resolveCobaltInstanceUrl({
    required String targetUrl,
    required DownloadQuality quality,
  }) async {
    final List<String> endpoints = [];
    if (customInstanceUrl != null && customInstanceUrl!.trim().isNotEmpty) {
      endpoints.add(customInstanceUrl!.trim());
    }
    endpoints.addAll(_cobaltInstances);

    final isNoAudioStreamPlatform = targetUrl.contains('facebook.com') ||
                 targetUrl.contains('fb.watch') ||
                 targetUrl.contains('fb.com') ||
                 targetUrl.contains('twitter.com') ||
                 targetUrl.contains('x.com') ||
                 targetUrl.contains('tiktok.com') ||
                 targetUrl.contains('instagram.com');
    final payload = <String, dynamic>{
      'url': targetUrl,
      'videoQuality': quality.cobaltQualityValue,
      'downloadMode': (quality.isAudioOnly && !isNoAudioStreamPlatform) ? 'audio' : 'auto',
      'audioFormat': 'mp3',
    };
    if (targetUrl.contains('youtube.com') || targetUrl.contains('youtu.be')) {
      payload['youtubeVideoCodec'] = 'h264';
    }

    for (final endpoint in endpoints) {
      try {
        final cleanEndpoint = endpoint.endsWith('/') ? endpoint : '$endpoint/';
        final response = await _dio.post(
          cleanEndpoint,
          data: payload,
          options: Options(
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            connectTimeout: const Duration(seconds: 6),
            receiveTimeout: const Duration(seconds: 10),
            validateStatus: (status) => status != null && status < 500,
          ),
        );

        if (response.statusCode == 200 && response.data != null) {
          final data = response.data;
          if (data is Map<String, dynamic>) {
            final status = data['status'];
            if (status == 'tunnel' || status == 'redirect' || status == 'stream') {
              final directUrl = data['url'] as String?;
              if (directUrl != null && directUrl.isNotEmpty) {
                return directUrl;
              }
            } else if (status == 'picker') {
              final pickerList = data['picker'] as List?;
              if (pickerList != null && pickerList.isNotEmpty) {
                final firstItem = pickerList.first;
                if (firstItem is Map && firstItem['url'] != null) {
                  return firstItem['url'] as String;
                }
              }
            } else if (status == 'error' && quality.isAudioOnly && payload['downloadMode'] == 'audio') {
              try {
                final fallbackPayload = Map<String, dynamic>.from(payload)..['downloadMode'] = 'auto';
                final fbResp = await _dio.post(
                  cleanEndpoint,
                  data: fallbackPayload,
                  options: Options(
                    headers: {
                      'Accept': 'application/json',
                      'Content-Type': 'application/json',
                    },
                    connectTimeout: const Duration(seconds: 4),
                    receiveTimeout: const Duration(seconds: 6),
                    validateStatus: (s) => s != null && s < 500,
                  ),
                );
                if (fbResp.statusCode == 200 && fbResp.data is Map<String, dynamic>) {
                  final fbData = fbResp.data as Map<String, dynamic>;
                  if (fbData['status'] == 'tunnel' || fbData['status'] == 'redirect' || fbData['status'] == 'stream') {
                    final dUrl = fbData['url'] as String?;
                    if (dUrl != null && dUrl.isNotEmpty) return dUrl;
                  }
                }
              } catch (_) {}
            }
          }
        } else if (quality.isAudioOnly && payload['downloadMode'] == 'audio') {
          // Cobalt bu platformda audio mode desteklemiyorsa, auto modunu deneyelim (daha sonra yerel olarak MP3'e çevrilir)
          try {
            final fallbackPayload = Map<String, dynamic>.from(payload)..['downloadMode'] = 'auto';
            final fbResp = await _dio.post(
              cleanEndpoint,
              data: fallbackPayload,
              options: Options(
                headers: {
                  'Accept': 'application/json',
                  'Content-Type': 'application/json',
                },
                connectTimeout: const Duration(seconds: 4),
                receiveTimeout: const Duration(seconds: 6),
                validateStatus: (s) => s != null && s < 500,
              ),
            );
            if (fbResp.statusCode == 200 && fbResp.data is Map<String, dynamic>) {
              final fbData = fbResp.data as Map<String, dynamic>;
              if (fbData['status'] == 'tunnel' || fbData['status'] == 'redirect' || fbData['status'] == 'stream') {
                final dUrl = fbData['url'] as String?;
                if (dUrl != null && dUrl.isNotEmpty) return dUrl;
              }
            }
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('Cobalt endpoint denemesi başarısız ($endpoint): $e');
      }
    }

    return null;
  }

  /// YouTube Video ID ayıklar
  String? _extractYouTubeVideoId(String url) {
    final regExp = RegExp(
      r'(?:youtube\.com\/(?:watch\?(?:[^\s]*&)?v=|shorts\/|embed\/|v\/|live\/)|youtu\.be\/)([a-zA-Z0-9_\-]+)',
      caseSensitive: false,
    );
    final match = regExp.firstMatch(url);
    return match?.group(1);
  }

  /// Invidious API üzerinden video veya ses akışını (PoToken ile 403 engelsiz) çözer
  Future<String?> _resolveInvidiousUrl(
    String targetUrl, {
    required bool audioOnly,
  }) async {
    final videoId = _extractYouTubeVideoId(targetUrl);
    if (videoId == null) return null;

    for (final inst in _invidiousInstances) {
      try {
        final res = await _dio.get(
          '$inst/api/v1/videos/$videoId',
          options: Options(
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 8),
            validateStatus: (s) => s != null && s < 500,
          ),
        );

        if (res.statusCode == 200 && res.data is Map) {
          final data = res.data as Map;
          if (audioOnly) {
            final af = data['adaptiveFormats'] as List?;
            if (af != null && af.isNotEmpty) {
              final audios = af
                  .where((f) => (f['type'] as String? ?? '').contains('audio'))
                  .toList();
              if (audios.isNotEmpty) {
                final originalAudios = _filterOriginalInvidiousAudios(audios);
                originalAudios.sort((a, b) {
                  final bitA = int.tryParse(a['bitrate']?.toString() ?? '0') ?? 0;
                  final bitB = int.tryParse(b['bitrate']?.toString() ?? '0') ?? 0;
                  return bitB.compareTo(bitA);
                });
                final url = originalAudios.first['url'] as String?;
                if (url != null && url.isNotEmpty) {
                  return url.startsWith('http') ? url : '$inst$url';
                }
              }
            }
          } else {
            final fs = data['formatStreams'] as List?;
            if (fs != null && fs.isNotEmpty) {
              final url = fs.first['url'] as String?;
              if (url != null && url.isNotEmpty) {
                return url.startsWith('http') ? url : '$inst$url';
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Invidious çözümleme hatası ($inst): $e');
      }
    }
    return null;
  }

  /// Tüm platformlar için çok katmanlı akış çözümleyici
  Future<String> resolveDownloadUrl({
    required String targetUrl,
    required DownloadQuality quality,
    required DownloadProgressCallback onProgress,
  }) async {
    final lowerUrl = targetUrl.toLowerCase();

    // 1. YouTube Çözümleme (Shorts dahil)
    if (lowerUrl.contains('youtube.com') || lowerUrl.contains('youtu.be')) {
      // YouTube video süresini önceden al (MP4 süre başlıklarını onarmak için)
      try {
        final yt = YoutubeExplode();
        final vInfo = await yt.videos.get(targetUrl).timeout(const Duration(seconds: 6));
        lastResolvedVideoDuration = vInfo.duration;
        yt.close();
      } catch (_) {}

      if (quality.isAudioOnly) {
        onProgress(0.12, 'YouTube ses akışı alınıyor (Invidious / Cobalt)...');
        final invAudio = await _resolveInvidiousUrl(targetUrl, audioOnly: true);
        if (invAudio != null) return invAudio;

        final cobaltYt = await _resolveCobaltInstanceUrl(
          targetUrl: targetUrl,
          quality: quality,
        );
        if (cobaltYt != null) return cobaltYt;

        final ytAudio = await _resolveYouTubeUrl(targetUrl, quality);
        if (ytAudio != null) return ytAudio;
      } else {
        // 1. Invidious video akışı (PoToken ile 403 engelsiz)
        onProgress(0.12, 'YouTube video akışı alınıyor (Invidious)...');
        final invVideo = await _resolveInvidiousUrl(targetUrl, audioOnly: false);
        if (invVideo != null) return invVideo;

        // 2. Cobalt Harici Motoru
        onProgress(0.16, 'YouTube sunucu akışı alınıyor (Cobalt)...');
        final cobaltYt = await _resolveCobaltInstanceUrl(
          targetUrl: targetUrl,
          quality: quality,
        );
        if (cobaltYt != null) return cobaltYt;

        // 3. Yerel YouTube doğrudan akışı (Son çare)
        onProgress(0.20, 'YouTube doğrudan video akışı alınıyor...');
        final ytResult = await _resolveYouTubeUrl(targetUrl, quality);
        if (ytResult != null) return ytResult;
      }
    }

    // 2. X (Twitter) Çözümleme
    if (lowerUrl.contains('twitter.com') || lowerUrl.contains('x.com')) {
      onProgress(0.12, 'X (Twitter) medya akışı çözümleniyor...');
      final twResult = await _resolveTwitterUrl(targetUrl, quality);
      if (twResult != null) return twResult;

      onProgress(0.18, 'X (Twitter) yedek sunucu deneniyor...');
      final twCobalt = await _resolveCobaltInstanceUrl(
        targetUrl: targetUrl,
        quality: quality,
      );
      if (twCobalt != null) return twCobalt;
    }

    // 3. TikTok Çözümleme
    if (lowerUrl.contains('tiktok.com')) {
      onProgress(0.12, 'TikTok videosu çözümleniyor...');
      final ttResult = await _resolveTikTokUrl(targetUrl, quality);
      if (ttResult != null) return ttResult;

      onProgress(0.18, 'TikTok yedek sunucu deneniyor...');
      final ttCobalt = await _resolveCobaltInstanceUrl(
        targetUrl: targetUrl,
        quality: quality,
      );
      if (ttCobalt != null) return ttCobalt;
    }

    // 4. Instagram Çözümleme (Reels, Posts, Stories, Direct CDN Streams)
    if (lowerUrl.contains('instagram.com') ||
        lowerUrl.contains('cdninstagram.com') ||
        lowerUrl.contains('fbcdn.net')) {
      if (lowerUrl.contains('cdninstagram.com') || lowerUrl.contains('fbcdn.net')) {
        return targetUrl;
      }
      final normalizedIg = _normalizeInstagramUrl(targetUrl);

      onProgress(0.12, 'Instagram medya bağlantısı alınıyor...');
      final embedResult = await _resolveInstagramEmbed(normalizedIg) ??
          await _resolveInstagramEmbed(targetUrl);
      if (embedResult != null) return embedResult;

      onProgress(0.16, 'Instagram doğrudan akış çözümleniyor...');
      final snapResult = await _resolveSnapSaveInstagram(normalizedIg) ??
          await _resolveSnapSaveInstagram(targetUrl);
      if (snapResult != null) return snapResult;

      onProgress(0.20, 'Instagram sunucu akışı alınıyor...');
      final igCobalt = await _resolveCobaltInstanceUrl(
        targetUrl: normalizedIg,
        quality: quality,
      ) ?? await _resolveCobaltInstanceUrl(
        targetUrl: targetUrl,
        quality: quality,
      );
      if (igCobalt != null) return igCobalt;
    }

    // 5. Facebook Çözümleme (Reels, Watch, Video)
    if (lowerUrl.contains('facebook.com') ||
        lowerUrl.contains('fb.watch') ||
        lowerUrl.contains('fb.com')) {
      onProgress(0.12, 'Facebook videosu çözümleniyor...');
      final fbResult = await _resolveFacebookUrl(targetUrl, quality);
      if (fbResult != null) return fbResult;
    }

    // 6. Genel Sunucu Katmanı
    onProgress(0.18, 'Sunucu üzerinden video akışı alınıyor...');
    final genericResult = await _resolveCobaltInstanceUrl(
      targetUrl: targetUrl,
      quality: quality,
    );
    if (genericResult != null) return genericResult;

    // 7. Harici Doğrudan Akış Çözümleme Katmanı (Universal yt-dlp Direct Stream Resolver)
    onProgress(0.20, 'Doğrudan akış çözümleniyor...');
    final ytdlpStream = await YtDlpExtraService().resolveDirectStreamUrl(
      targetUrl,
      quality: quality,
    );
    if (ytdlpStream != null) return ytdlpStream;

    throw Exception(
      'İçerik akışı çözümlenemedi. Video gizli, kaldırılmış veya geçici olarak erişilemiyor olabilir. Lütfen bağlantıyı kontrol edip tekrar deneyiniz.',
    );
  }

  /// Windows üzerinde FFmpeg yürütülebilir dosyasını arar
  Future<String?> _findFfmpegExecutable() async {
    if (!Platform.isWindows) return null;

    final exeDir = path_lib.dirname(Platform.resolvedExecutable);
    final possiblePaths = <String>[
      // 1. Uygulama çalışma dizini ve alt klasörleri
      path_lib.join(exeDir, 'ffmpeg.exe'),
      path_lib.join(exeDir, 'bin', 'ffmpeg.exe'),
      path_lib.join(exeDir, 'windows', 'bin', 'ffmpeg.exe'),
      // 2. Proje çalışma dizini
      path_lib.join(Directory.current.path, 'ffmpeg.exe'),
      path_lib.join(Directory.current.path, 'windows', 'bin', 'ffmpeg.exe'),
      path_lib.join(Directory.current.path, 'windows', 'ffmpeg.exe'),
      path_lib.join(Directory.current.path, 'ffmpeg_bin', 'ffmpeg.exe'),
      path_lib.join(Directory.current.path, 'build', 'windows', 'x64', 'runner', 'Release', 'ffmpeg.exe'),
      path_lib.join(Directory.current.path, 'build', 'windows', 'x64', 'runner', 'Debug', 'ffmpeg.exe'),
      // 3. Bilinen sabit geliştirici ve kurulum yolları
      r'C:\Users\Sensei\Desktop\KaraDelik2\windows\bin\ffmpeg.exe',
      r'C:\Users\Sensei\Desktop\KaraDelik2\build\windows\x64\runner\Release\ffmpeg.exe',
      r'C:\Users\Sensei\Desktop\KaraDelik2\build\windows\x64\runner\Debug\ffmpeg.exe',
      r'C:\Program Files\KaraDelik\ffmpeg.exe',
      r'C:\Program Files (x86)\KaraDelik\ffmpeg.exe',
    ];

    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null) {
      possiblePaths.add(path_lib.join(localAppData, 'KaraDelik', 'ffmpeg.exe'));
    }

    for (final p in possiblePaths) {
      if (await File(p).exists()) {
        return p;
      }
    }

    // 3. Windows PATH ortam değişkenini sorgula
    try {
      final res = await Process.run('where', ['ffmpeg']);
      if (res.exitCode == 0) {
        final line = res.stdout.toString().split('\r\n').firstWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => '',
        ).trim();
        if (line.isNotEmpty && await File(line).exists()) {
          return line;
        }
      }
    } catch (_) {}

    return null;
  }

  /// Windows üzerinde FFmpeg ile kayıpsız akış kopyalama (stream-copy mux)
  Future<bool> _muxWithFfmpegWindows({
    required String videoPath,
    required String audioPath,
    required String outputPath,
  }) async {
    final ffmpeg = await _findFfmpegExecutable();
    if (ffmpeg == null) {
      debugPrint('Windows FFmpeg bulunamadı, doğrudan akışa geçilecek.');
      return false;
    }

    try {
      // 1. Doğrudan kayıpsız akış kopyalama (stream-copy: kayıpsız ve ultra hızlı)
      var res = await Process.run(
        ffmpeg,
        [
          '-y',
          '-threads', '0',
          '-i', videoPath,
          '-i', audioPath,
          '-c', 'copy',
          '-strict', 'experimental',
          outputPath,
        ],
      );
      if (res.exitCode == 0 && await File(outputPath).exists() && (await File(outputPath).length()) > 1024) {
        return true;
      }
      debugPrint('FFmpeg stream-copy uyarısı: ${res.stderr}. Fallback uygulanıyor...');

      // 2. Görüntü kayıpsız kopyalanır (-c:v copy), ses AAC formatına dönüştürülür (-c:a aac)
      res = await Process.run(
        ffmpeg,
        [
          '-y',
          '-threads', '0',
          '-i', videoPath,
          '-i', audioPath,
          '-c:v', 'copy',
          '-c:a', 'aac',
          '-b:a', '192k',
          '-strict', 'experimental',
          outputPath,
        ],
      );
      if (res.exitCode == 0 && await File(outputPath).exists() && (await File(outputPath).length()) > 1024) {
        return true;
      }

      // 3. Container uyumsuzluğu durumunda ultra hızlı H.264 dönüştürme (VP9/AV1 -> MP4)
      res = await Process.run(
        ffmpeg,
        [
          '-y',
          '-threads', '0',
          '-i', videoPath,
          '-i', audioPath,
          '-c:v', 'libx264',
          '-preset', 'ultrafast',
          '-crf', '18',
          '-c:a', 'aac',
          '-b:a', '192k',
          outputPath,
        ],
      );
      if (res.exitCode == 0 && await File(outputPath).exists() && (await File(outputPath).length()) > 1024) {
        return true;
      }
      await _log('FFmpeg mux çıktısı: ${res.stderr}');
      return false;
    } catch (e) {
      debugPrint('FFmpeg çalıştırma hatası: $e');
      return false;
    }
  }
  Future<bool> _convertToMp3(String inputPath, String outputPath) async {
    if (Platform.isWindows) {
      final ffmpeg = await _findFfmpegExecutable();
      if (ffmpeg != null) {
        try {
          var res = await Process.run(ffmpeg, [
            '-y',
            '-threads', '0',
            '-i', inputPath,
            '-vn',
            '-c:a', 'libmp3lame',
            '-b:a', '320k',
            outputPath,
          ]);
          if (res.exitCode == 0 &&
              await File(outputPath).exists() &&
              (await File(outputPath).length()) > 1024) {
            return true;
          }

          final stderr = res.stderr.toString();
          debugPrint('FFmpeg MP3 dönüştürme uyarısı: $stderr');

          if (stderr.contains('does not contain any stream') ||
              stderr.contains('matches no streams') ||
              stderr.contains('Output file is empty')) {
            throw Exception('Bu videoda herhangi bir ses akışı bulunmamaktadır.');
          }

          // 2. Deneme: Esnek akış haritalama ve optimize ses parametreleri
          res = await Process.run(ffmpeg, [
            '-y',
            '-threads', '0',
            '-i', inputPath,
            '-vn',
            '-map', '0:a:0?',
            '-c:a', 'libmp3lame',
            '-q:a', '2',
            outputPath,
          ]);
          if (res.exitCode == 0 &&
              await File(outputPath).exists() &&
              (await File(outputPath).length()) > 1024) {
            return true;
          }
        } catch (e) {
          if (e.toString().contains('ses akışı bulunmamaktadır')) rethrow;
          debugPrint('FFmpeg çalıştırma hatası: $e');
        }
      }
    } 
    try {
      final inputFile = File(inputPath);
      if (await inputFile.exists()) {
        await inputFile.copy(outputPath);
        return (await File(outputPath).exists()) &&
            (await File(outputPath).length() > 1024);
      }
    } catch (e) {
      debugPrint('Dosya kopyalama hatası: $e');
    }
    return false;
  }

  /// En hızlı yanıt veren Invidious sunucusunu eşzamanlı sorgular
  Future<Map<String, dynamic>?> _resolveFastestInvidiousAudio(String videoId) async {
    final completer = Completer<Map<String, dynamic>?>();
    int pending = _invidiousInstances.length;

    for (final inst in _invidiousInstances) {
      _dio.get(
        '$inst/api/v1/videos/$videoId',
        options: Options(
          connectTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 6),
          validateStatus: (s) => s != null && s < 500,
        ),
      ).then((res) {
        if (!completer.isCompleted && res.statusCode == 200 && res.data is Map) {
          final af = res.data['adaptiveFormats'] as List?;
          if (af != null && af.isNotEmpty) {
            final audios = af.where((f) => (f['type'] as String? ?? '').contains('audio')).toList();
            if (audios.isNotEmpty) {
              final originalAudios = _filterOriginalInvidiousAudios(audios);
              originalAudios.sort((a, b) {
                final bitA = int.tryParse(a['bitrate']?.toString() ?? '0') ?? 0;
                final bitB = int.tryParse(b['bitrate']?.toString() ?? '0') ?? 0;
                return bitB.compareTo(bitA);
              });
              final rawUrl = originalAudios.first['url'] as String?;
              if (rawUrl != null && rawUrl.isNotEmpty) {
                final streamUrl = rawUrl.startsWith('http') ? rawUrl : '$inst$rawUrl';
                final clen = int.tryParse(originalAudios.first['clen']?.toString() ?? '') ?? 0;
                completer.complete({'url': streamUrl, 'clen': clen});
                return;
              }
            }
          }
        }
        pending--;
        if (pending <= 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      }).catchError((_) {
        pending--;
        if (pending <= 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }

    return completer.future.timeout(const Duration(seconds: 6), onTimeout: () => null);
  }

  /// En hızlı yanıt veren Invidious sunucusunu eşzamanlı sorgular (Tüm formatlar: video + ses)
  Future<Map<String, dynamic>?> _resolveFastestInvidiousStreams(String videoId) async {
    final completer = Completer<Map<String, dynamic>?>();
    int pending = _invidiousInstances.length;

    for (final inst in _invidiousInstances) {
      _dio.get(
        '$inst/api/v1/videos/$videoId',
        options: Options(
          connectTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 6),
          validateStatus: (s) => s != null && s < 500,
        ),
      ).then((res) {
        if (!completer.isCompleted && res.statusCode == 200 && res.data is Map) {
          final af = res.data['adaptiveFormats'] as List?;
          if (af != null && af.isNotEmpty) {
            completer.complete({'data': res.data, 'inst': inst});
            return;
          }
        }
        pending--;
        if (pending <= 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      }).catchError((_) {
        pending--;
        if (pending <= 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }

    return completer.future.timeout(const Duration(seconds: 6), onTimeout: () => null);
  }

  /// YouTube sesini (MP3) garantili çok katmanlı motor ile indirip MP3 formatına dönüştürür
  Future<String?> _downloadYouTubeAudio({
    required String targetUrl,
    required String targetDirectory,
    required String timeStamp,
    required DownloadProgressCallback onProgress,
  }) async {
    final fileName = 'KaraDelik_YouTube_$timeStamp.mp3';
    final savePath = Platform.isWindows
        ? '$targetDirectory\\$fileName'
        : '$targetDirectory/$fileName';

    // 0. KATMAN (Windows): yt-dlp & FFmpeg Stüdyo Kalitesinde MP3 Motoru
    if (Platform.isWindows) {
      try {
        final resultPath = await YtDlpExtraService().downloadWithProgress(
          targetUrl: targetUrl,
          quality: DownloadQuality.mp3,
          destinationPath: savePath,
          onProgress: onProgress,
        );
        if (await File(resultPath).exists() && (await File(resultPath).length()) > 1024) {
          return resultPath;
        }
      } catch (e) {
        if (_cancelToken?.isCancelled == true) rethrow;
        debugPrint('Windows yt-dlp MP3 indirme hatası: $e. Alternatif katmanlara geçiliyor...');
      }
    }

    final tempDir = await getTemporaryDirectory();
    final tempAudioPath = Platform.isWindows
        ? '${tempDir.path}\\temp_yt_audio_$timeStamp.bin'
        : '${tempDir.path}/temp_yt_audio_$timeStamp.bin';
    final tempAudioFile = File(tempAudioPath);

    final videoId = _extractYouTubeVideoId(targetUrl);

    // 1. KATMAN: Invidious Motoru (En Hızlı Sunucu + 6 Paralel Parça İndirme)
    if (videoId != null) {
      onProgress(0.10, 'YouTube ses akışı alınıyor...');
      final invAudio = await _resolveFastestInvidiousAudio(videoId);
      if (invAudio != null) {
        final streamUrl = invAudio['url'] as String;
        final totalBytes = invAudio['clen'] as int? ?? 0;

        final speedTracker = SpeedTracker();
        onProgress(0.15, '%0 Ses akışı süper hızda indiriliyor...');
        if (totalBytes > 0) {
          await _parallelChunkDownload(
            url: streamUrl,
            savePath: tempAudioPath,
            totalBytes: totalBytes,
            numChunks: 6,
            cancelToken: _cancelToken,
            onReceiveProgress: (received, total) {
              speedTracker.update(received, total);
              if (total > 0) {
                final p = received / total;
                final pct = (p * 100).toInt();
                final recMB = (received / (1024 * 1024)).toStringAsFixed(1);
                final totMB = (total / (1024 * 1024)).toStringAsFixed(1);
                onProgress(
                  0.15 + (p * 0.70),
                  '%$pct Ses indiriliyor ($recMB/$totMB MB)',
                  speed: speedTracker.currentSpeed,
                  eta: speedTracker.currentEta,
                );
              }
            },
          );
        } else {
          await _robustDownload(
            url: streamUrl,
            savePath: tempAudioPath,
            cancelToken: _cancelToken,
            onReceiveProgress: (received, total) {
              speedTracker.update(received, total);
              if (total > 0) {
                final p = received / total;
                final pct = (p * 100).toInt();
                final recMB = (received / (1024 * 1024)).toStringAsFixed(1);
                final totMB = (total / (1024 * 1024)).toStringAsFixed(1);
                onProgress(
                  0.15 + (p * 0.70),
                  '%$pct Ses indiriliyor ($recMB/$totMB MB)',
                  speed: speedTracker.currentSpeed,
                  eta: speedTracker.currentEta,
                );
              }
            },
          );
        }

        if (await tempAudioFile.exists() && await tempAudioFile.length() > 1024) {
          onProgress(0.88, 'Gerçek MP3 formatına dönüştürülüyor...');
          final converted = await _convertToMp3(tempAudioPath, savePath);
          if (converted && await File(savePath).exists() && await File(savePath).length() > 1024) {
            try {
              await tempAudioFile.delete();
            } catch (_) {}
            return savePath;
          }
        }
      }
    }

    // 2. KATMAN: Cobalt API (MP3 Hazır Tüneli)
    try {
      onProgress(0.20, 'YouTube alternatif ses motoru deneniyor (Cobalt)...');
      final cobaltUrl = await _resolveCobaltInstanceUrl(
        targetUrl: targetUrl,
        quality: DownloadQuality.mp3,
      );
      if (cobaltUrl != null && cobaltUrl.isNotEmpty) {
        final speedTracker = SpeedTracker();
        onProgress(0.30, '%0 MP3 indiriliyor...');
        await _fastDownload(
          url: cobaltUrl,
          savePath: tempAudioPath,
          cancelToken: _cancelToken,
          onReceiveProgress: (received, total) {
            speedTracker.update(received, total);
            if (total > 0) {
              final p = received / total;
              final pct = (p * 100).toInt();
              final recMB = (received / (1024 * 1024)).toStringAsFixed(1);
              final totMB = (total / (1024 * 1024)).toStringAsFixed(1);
              onProgress(
                0.30 + (p * 0.60),
                '%$pct MP3 indiriliyor ($recMB/$totMB MB)',
                speed: speedTracker.currentSpeed,
                eta: speedTracker.currentEta,
              );
            }
          },
        );

        if (await tempAudioFile.exists() && await tempAudioFile.length() > 1024) {
          final converted = await _convertToMp3(tempAudioPath, savePath);
          if (converted && await File(savePath).exists() && await File(savePath).length() > 1024) {
            try {
              await tempAudioFile.delete();
            } catch (_) {}
            return savePath;
          }
        }
      }
    } catch (e) {
      debugPrint('Cobalt MP3 motor hatası: $e');
    }

    // 3. KATMAN: YouTubeExplode yerel akış okuyucu (6 Paralel Parça İndirme)
    try {
      onProgress(0.25, 'YouTube yerel ses akışı alınıyor...');
      final yt = YoutubeExplode();
      final video = await yt.videos.get(targetUrl).timeout(const Duration(seconds: 12));
      final manifest = await yt.videos.streamsClient.getManifest(video.id).timeout(const Duration(seconds: 12));
      final audioStream = _getBestOriginalYtExplodeAudio(
        manifest.audioOnly,
        preferMp4: false,
      );
      final total = audioStream.size.totalBytes;
      yt.close();

      final speedTracker = SpeedTracker();
      onProgress(0.30, '%0 Ses akışı indiriliyor...');
      try {
        await _downloadStreamInChunks(
          url: audioStream.url.toString(),
          savePath: tempAudioPath,
          totalBytes: total,
          chunkSize: 4 * 1024 * 1024,
          cancelToken: _cancelToken,
          onProgress: (received, tot) {
            speedTracker.update(received, tot);
            if (tot > 0) {
              final p = received / tot;
              final pct = (p * 100).toInt();
              final recMB = (received / (1024 * 1024)).toStringAsFixed(1);
              final totMB = (tot / (1024 * 1024)).toStringAsFixed(1);
              onProgress(
                0.30 + (p * 0.58),
                '%$pct Ses indiriliyor ($recMB/$totMB MB)',
                speed: speedTracker.currentSpeed,
                eta: speedTracker.currentEta,
              );
            }
          },
        );
      } catch (e) {
        debugPrint('Yerel ses akışı streamsClient uyarısı: $e. Dio ile deneniyor...');
        await _robustDownload(
          url: audioStream.url.toString(),
          savePath: tempAudioPath,
          cancelToken: _cancelToken,
          onReceiveProgress: (received, tot) {
            final effectiveTot = tot > 0 ? tot : total;
            speedTracker.update(received, effectiveTot);
            if (effectiveTot > 0) {
              final p = received / effectiveTot;
              final pct = (p * 100).toInt();
              final recMB = (received / (1024 * 1024)).toStringAsFixed(1);
              final totMB = (effectiveTot / (1024 * 1024)).toStringAsFixed(1);
              onProgress(
                0.30 + (p * 0.58),
                '%$pct Ses indiriliyor ($recMB/$totMB MB)',
                speed: speedTracker.currentSpeed,
                eta: speedTracker.currentEta,
              );
            }
          },
        );
      }

      if (await tempAudioFile.exists() && await tempAudioFile.length() > 1024) {
        onProgress(0.92, 'MP3 formatına dönüştürülüyor...');
        final converted = await _convertToMp3(tempAudioPath, savePath);
        if (converted && await File(savePath).exists() && await File(savePath).length() > 1024) {
          try {
            await tempAudioFile.delete();
          } catch (_) {}
          return savePath;
        }
      }
    } catch (e) {
      debugPrint('YouTubeExplode yerel akış hatası: $e');
    } finally {
      try {
        if (await tempAudioFile.exists()) await tempAudioFile.delete();
      } catch (_) {}
    }

    return null;
  }

  bool _hqMuxFailed = false;

  /// Hata ayıklama için kalıcı günlük (uygulama veri klasöründe karadelik_log.txt)
  Future<void> _log(String message) async {
    debugPrint(message);
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File(path_lib.join(dir.path, 'karadelik_log.txt'));
      await f.writeAsString(
        '${DateTime.now().toIso8601String()}  $message\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  /// Invidious API üzerinden yüksek çözünürlüklü video ve sesi eşzamanlı indirip birleştirir (4K / 1440p / 1080p)
  Future<String?> _downloadYouTubeHighQualityInvidious({
    required String targetUrl,
    required DownloadQuality quality,
    required String targetDirectory,
    required String timeStamp,
    required DownloadProgressCallback onProgress,
  }) async {
    final videoId = _extractYouTubeVideoId(targetUrl);
    if (videoId == null) return null;

    try {
      onProgress(0.10, 'YouTube yüksek kalite akışları sorgulanıyor (Invidious)...');
      final invData = await _resolveFastestInvidiousStreams(videoId);
      if (invData == null) return null;

      final data = invData['data'] as Map;
      final inst = invData['inst'] as String;
      final af = data['adaptiveFormats'] as List?;
      if (af == null || af.isEmpty) return null;

      final allVideos = af.where((f) => (f['type'] as String? ?? '').contains('video')).toList();
      final allAudios = af.where((f) => (f['type'] as String? ?? '').contains('audio')).toList();
      if (allVideos.isEmpty || allAudios.isEmpty) return null;
      final List<dynamic> candidateVideos;
      {
        candidateVideos = allVideos;
      }

      int parseHeight(dynamic v) {
        final s = (v?['resolution'] ?? v?['qualityLabel'] ?? '').toString();
        final m = RegExp(r'(\d{3,4})').firstMatch(s);
        return m != null ? (int.tryParse(m.group(1)!) ?? 0) : 0;
      }

      candidateVideos.sort((a, b) {
        final hA = parseHeight(a);
        final hB = parseHeight(b);
        if (hB != hA) return hB.compareTo(hA);
        final bitA = int.tryParse(a['bitrate']?.toString() ?? '0') ?? 0;
        final bitB = int.tryParse(b['bitrate']?.toString() ?? '0') ?? 0;
        return bitB.compareTo(bitA);
      });

      // Ses akışlarını seç: Yalnızca orijinal ses parçası (sonradan eklenen dublajlar elenir, MP4/M4A öncelikli)
      final originalAudios = _filterOriginalInvidiousAudios(allAudios);
      final List<dynamic> candidateAudios;
      {
        candidateAudios = originalAudios;
      }

      candidateAudios.sort((a, b) {
        final bitA = int.tryParse(a['bitrate']?.toString() ?? '0') ?? 0;
        final bitB = int.tryParse(b['bitrate']?.toString() ?? '0') ?? 0;
        return bitB.compareTo(bitA);
      });

      final bestVideo = candidateVideos.first;
      final bestAudio = candidateAudios.first;

      final rawVUrl = bestVideo['url'] as String;
      final rawAUrl = bestAudio['url'] as String;
      final vUrl = rawVUrl.startsWith('http') ? rawVUrl : '$inst$rawVUrl';
      final aUrl = rawAUrl.startsWith('http') ? rawAUrl : '$inst$rawAUrl';

      final vQualityLabel = (bestVideo['qualityLabel'] ?? bestVideo['resolution'] ?? 'HD').toString();
      final totalVBytes = int.tryParse(bestVideo['clen']?.toString() ?? '') ?? 0;
      final totalABytes = int.tryParse(bestAudio['clen']?.toString() ?? '') ?? 0;

      final tempDir = await getTemporaryDirectory();
      final vExt = (bestVideo['container'] as String? ?? '').toLowerCase() == 'webm' ? 'webm' : 'mp4';
      final aExt = (bestAudio['container'] as String? ?? '').toLowerCase() == 'webm' ? 'webm' : 'm4a';
      final tempVideoPath = Platform.isWindows
          ? '${tempDir.path}\\temp_v_inv_$timeStamp.$vExt'
          : '${tempDir.path}/temp_v_inv_$timeStamp.$vExt';
      final tempAudioPath = Platform.isWindows
          ? '${tempDir.path}\\temp_a_inv_$timeStamp.$aExt'
          : '${tempDir.path}/temp_a_inv_$timeStamp.$aExt';

      final tempVideoFile = File(tempVideoPath);
      final tempAudioFile = File(tempAudioPath);

      int vReceived = 0;
      int aReceived = 0;
      final speedTracker = SpeedTracker();

      void updateProgress() {
        final total = (totalVBytes > 0 ? totalVBytes : 1) + (totalABytes > 0 ? totalABytes : 1);
        final received = vReceived + aReceived;
        speedTracker.update(received, total);
        final p = (received / total).clamp(0.0, 1.0);
        final pct = (p * 100).toInt();
        final recMB = (received / (1024 * 1024)).toStringAsFixed(1);
        final totMB = (total / (1024 * 1024)).toStringAsFixed(1);
        onProgress(
          0.15 + (p * 0.75),
          '%$pct Video ve Ses indiriliyor ($vQualityLabel - $recMB/$totMB MB)',
          speed: speedTracker.currentSpeed,
          eta: speedTracker.currentEta,
        );
      }

      onProgress(0.15, '%0 Video ve Ses eşzamanlı indiriliyor ($vQualityLabel)...');

      Future<void> downloadV() async {
        if (totalVBytes > 1024 * 512) {
          await _parallelChunkDownload(
            url: vUrl,
            savePath: tempVideoPath,
            totalBytes: totalVBytes,
            numChunks: 6,
            cancelToken: _cancelToken,
            onReceiveProgress: (rec, _) {
              vReceived = rec;
              updateProgress();
            },
          );
        } else {
          await _robustDownload(
            url: vUrl,
            savePath: tempVideoPath,
            cancelToken: _cancelToken,
            onReceiveProgress: (rec, tot) {
              vReceived = rec;
              updateProgress();
            },
          );
        }
      }

      Future<void> downloadA() async {
        if (totalABytes > 1024 * 512) {
          await _parallelChunkDownload(
            url: aUrl,
            savePath: tempAudioPath,
            totalBytes: totalABytes,
            numChunks: 4,
            cancelToken: _cancelToken,
            onReceiveProgress: (rec, _) {
              aReceived = rec;
              updateProgress();
            },
          );
        } else {
          await _robustDownload(
            url: aUrl,
            savePath: tempAudioPath,
            cancelToken: _cancelToken,
            onReceiveProgress: (rec, tot) {
              aReceived = rec;
              updateProgress();
            },
          );
        }
      }

      await Future.wait([downloadV(), downloadA()]);

      if (!await tempVideoFile.exists() || await tempVideoFile.length() <= 1024 ||
          !await tempAudioFile.exists() || await tempAudioFile.length() <= 1024) {
        return null;
      }

      final fileName = 'KaraDelik_YouTube_$timeStamp.mp4';
      final savePath = Platform.isWindows
          ? '$targetDirectory\\$fileName'
          : '$targetDirectory/$fileName';

      onProgress(0.92, 'En yüksek kalitede birleştiriliyor ($vQualityLabel)...');
      bool muxSuccess = false;
      if (Platform.isWindows) {
        muxSuccess = await _muxWithFfmpegWindows(
          videoPath: tempVideoPath,
          audioPath: tempAudioPath,
          outputPath: savePath,
        );
      } 

      try {
        if (await tempVideoFile.exists()) await tempVideoFile.delete();
      } catch (_) {}
      try {
        if (await tempAudioFile.exists()) await tempAudioFile.delete();
      } catch (_) {}

      if (muxSuccess && await File(savePath).exists() && (await File(savePath).length()) > 1024) {
        await _log('Invidious HQ indirme ve birleştirme başarılı: $vQualityLabel -> $savePath');
        return savePath;
      }
    } catch (e) {
      await _log('Invidious HQ indirme hatası: $e');
    }
    return null;
  }

  

  /// YouTube yüksek kalite video indirme:
  /// 1. Katman: Invidious (4K/1440p/1080p doğrudan PoToken akışı + birleştirme)
  /// 2. Katman: Cobalt API (Max kalite MP4)
  /// 3. Katman: YouTubeExplode (Bounded-chunk akış ayrıştırma + birleştirme)
  Future<String?> _downloadYouTubeHighQuality({
    required String targetUrl,
    required DownloadQuality quality,
    required String targetDirectory,
    required String timeStamp,
    required DownloadProgressCallback onProgress,
  }) async {
    _hqMuxFailed = false;

    // 0. KATMAN (Windows): yt-dlp & FFmpeg Yüksek Kalite Video Motoru (4K / 1080p HQ)
    if (Platform.isWindows) {
      try {
        final fileName = 'KaraDelik_YouTube_$timeStamp.mp4';
        final savePath = '$targetDirectory\\$fileName';
        final resultPath = await YtDlpExtraService().downloadWithProgress(
          targetUrl: targetUrl,
          quality: quality,
          destinationPath: savePath,
          onProgress: onProgress,
        );
        if (await File(resultPath).exists() && (await File(resultPath).length()) > 1024) {
          return resultPath;
        }
      } catch (e) {
        if (_cancelToken?.isCancelled == true) rethrow;
        debugPrint('Windows yt-dlp HQ indirme hatası: $e. Alternatif katmanlara geçiliyor...');
      }
    }

    // 1. KATMAN: Invidious Multi-Resolution Motoru (4K, 1440p, 1080p, 720p)
    final invResult = await _downloadYouTubeHighQualityInvidious(
      targetUrl: targetUrl,
      quality: quality,
      targetDirectory: targetDirectory,
      timeStamp: timeStamp,
      onProgress: onProgress,
    );
    if (invResult != null) return invResult;
    if (_cancelToken?.isCancelled == true) return null;

    // 2. KATMAN: Cobalt API Motoru (Max Kalite MP4)
    try {
      onProgress(0.12, 'YouTube alternatif motor deneniyor (Cobalt)...');
      final cobaltUrl = await _resolveCobaltInstanceUrl(
        targetUrl: targetUrl,
        quality: DownloadQuality.mp4,
      );
      if (cobaltUrl != null && cobaltUrl.isNotEmpty) {
        final fileName = 'KaraDelik_YouTube_$timeStamp.mp4';
        final savePath = Platform.isWindows
            ? '$targetDirectory\\$fileName'
            : '$targetDirectory/$fileName';
        final speedTracker = SpeedTracker();
        await _fastDownload(
          url: cobaltUrl,
          savePath: savePath,
          cancelToken: _cancelToken,
          onReceiveProgress: (rec, tot) {
            speedTracker.update(rec, tot);
            if (tot > 0) {
              final p = rec / tot;
              final pct = (p * 100).toInt();
              final recMB = (rec / (1024 * 1024)).toStringAsFixed(1);
              final totMB = (tot / (1024 * 1024)).toStringAsFixed(1);
              onProgress(
                0.15 + (p * 0.75),
                '%$pct Video indiriliyor ($recMB/$totMB MB)',
                speed: speedTracker.currentSpeed,
                eta: speedTracker.currentEta,
              );
            }
          },
        );
        if (await File(savePath).exists() && (await File(savePath).length()) > 1024) {
          return savePath;
        }
      }
    } catch (e) {
      debugPrint('Cobalt video motor hatası: $e');
    }
    if (_cancelToken?.isCancelled == true) return null;

    // 3. KATMAN: YouTubeExplode Bounded-Chunk Motoru (Yerel akış ayrıştırıcı)
    for (final rank in [0, 1]) {
      if (_cancelToken?.isCancelled == true) return null;
      final res = await _downloadYouTubeHighQualityOnce(
        targetUrl: targetUrl,
        quality: quality,
        targetDirectory: targetDirectory,
        timeStamp: timeStamp,
        onProgress: onProgress,
        rank: rank,
      );
      if (res != null) return res;
      if (_hqMuxFailed) break;
      await _log('YouTube HQ denemesi başarısız (rank=$rank), alternatif deneniyor...');
    }

    return null;
  }

  Future<String?> _downloadYouTubeHighQualityOnce({
    required String targetUrl,
    required DownloadQuality quality,
    required String targetDirectory,
    required String timeStamp,
    required DownloadProgressCallback onProgress,
    int rank = 0,
  }) async {
    final yt = YoutubeExplode();
    File? tempVideoFile;
    File? tempAudioFile;
    try {
      onProgress(0.08, 'YouTube video bilgileri alınıyor...');
      final video = await yt.videos.get(targetUrl).timeout(const Duration(seconds: 15));
      lastResolvedVideoDuration = video.duration;

      onProgress(0.12, 'Mevcut en yüksek çözünürlükler taranıyor...');
      StreamManifest? manifestOrNull;
      Object? manifestError;
      for (var i = 0; i < 3 && manifestOrNull == null; i++) {
        try {
          manifestOrNull = await yt.videos.streamsClient
              .getManifest(video.id)
              .timeout(const Duration(seconds: 15));
        } catch (e) {
          manifestError = e;
          await Future.delayed(Duration(milliseconds: 800 * (i + 1)));
        }
      }
      if (manifestOrNull == null) {
        await _log('Manifest alınamadı: $manifestError');
        return null;
      }
      final manifest = manifestOrNull;

      // 1. En yüksek kaliteli video akışını seç (4K, 1440p, 1080p, 720p)
      final allVideos = manifest.videoOnly.toList();
      if (allVideos.isEmpty) return null;
      final List<VideoStreamInfo> candidateVideos;
      {
        candidateVideos = allVideos;
      }

      candidateVideos.sort((a, b) {
        final cmp = b.videoResolution.height.compareTo(a.videoResolution.height);
        if (cmp != 0) return cmp;
        final containerCmp = (b.container.name.toLowerCase() == 'mp4' ? 1 : 0)
            .compareTo(a.container.name.toLowerCase() == 'mp4' ? 1 : 0);
        if (containerCmp != 0) return containerCmp;
        return b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);
      });
      final selectedVideo = () {
        final seenHeights = <int>[];
        final perHeight = <VideoStreamInfo>[];
        for (final s in candidateVideos) {
          final h = s.videoResolution.height;
          if (!seenHeights.contains(h)) {
            seenHeights.add(h);
            perHeight.add(s);
          }
        }
        return perHeight[rank < perHeight.length ? rank : perHeight.length - 1];
      }();

      // 2. En yüksek kaliteli ses akışını seç (Orijinal ses dili öncelikli, MP4/AAC öncelikli)
      final allAudios = manifest.audioOnly.toList();
      if (allAudios.isEmpty) return null;

      final selectedAudio = _getBestOriginalYtExplodeAudio(
        allAudios,
        preferMp4: false,
      );

      final videoQualityLabel = selectedVideo.qualityLabel;
      debugPrint('KaraDelik YouTube Seçimi: Video=$videoQualityLabel (${selectedVideo.videoResolution}), Ses=${selectedAudio.bitrate}');

      // 3. Geçici dosya yollarını hazırla
      final tempDir = await getTemporaryDirectory();
      final vExt = selectedVideo.container.name.toLowerCase() == 'webm' ? 'webm' : 'mp4';
      final aExt = selectedAudio.container.name.toLowerCase() == 'webm' ? 'webm' : 'm4a';
      final tempVideoPath = Platform.isWindows
          ? '${tempDir.path}\\temp_v_$timeStamp.$vExt'
          : '${tempDir.path}/temp_v_$timeStamp.$vExt';
      final tempAudioPath = Platform.isWindows
          ? '${tempDir.path}\\temp_a_$timeStamp.$aExt'
          : '${tempDir.path}/temp_a_$timeStamp.$aExt';

      tempVideoFile = File(tempVideoPath);
      tempAudioFile = File(tempAudioPath);

      // 4. Video ve Ses akışlarını EŞZAMANLI PARALEL İNDİR (%15 - %90)
      // Google Video CDN çoklu parça chunk bağlantısına 403 engeli koyduğu için video ve ses 1'er akışla eşzamanlı indirilir
      int videoReceived = 0;
      int videoTotal = selectedVideo.size.totalBytes;
      int audioReceived = 0;
      int audioTotal = selectedAudio.size.totalBytes;
      final speedTracker = SpeedTracker();

      void updateCombinedProgress() {
        final total = videoTotal + audioTotal;
        final received = videoReceived + audioReceived;
        speedTracker.update(received, total);
        if (total > 0) {
          final p = received / total;
          final pct = (p * 100).toInt();
          final recMB = (received / (1024 * 1024)).toStringAsFixed(1);
          final totMB = (total / (1024 * 1024)).toStringAsFixed(1);
          onProgress(
            0.15 + (p * 0.75),
            '%$pct Video ve Ses indiriliyor ($videoQualityLabel - $recMB/$totMB MB)',
            speed: speedTracker.currentSpeed,
            eta: speedTracker.currentEta,
          );
        }
      }

      onProgress(0.15, '%0 Video ve Ses eşzamanlı indiriliyor ($videoQualityLabel)...');

      Future<void> pipeStreamToFile({
        required StreamInfo streamInfo,
        required String savePath,
        required int chunkSize,
        required void Function(int received, int total) onRecProgress,
      }) async {
        await _downloadStreamInChunks(
          url: streamInfo.url.toString(),
          savePath: savePath,
          totalBytes: streamInfo.size.totalBytes,
          chunkSize: chunkSize,
          cancelToken: _cancelToken,
          onProgress: onRecProgress,
        );
      }

      final videoFuture = pipeStreamToFile(
        streamInfo: selectedVideo,
        savePath: tempVideoPath,
        chunkSize: 8 * 1024 * 1024,
        onRecProgress: (rec, tot) {
          videoReceived = rec;
          if (tot > 0) videoTotal = tot;
          updateCombinedProgress();
        },
      );

      final audioFuture = pipeStreamToFile(
        streamInfo: selectedAudio,
        savePath: tempAudioPath,
        chunkSize: 4 * 1024 * 1024,
        onRecProgress: (rec, tot) {
          audioReceived = rec;
          if (tot > 0) audioTotal = tot;
          updateCombinedProgress();
        },
      );

      await Future.wait([videoFuture, audioFuture]);

      // 5. Nihai çıktı yolu
      final fileName = 'KaraDelik_YouTube_$timeStamp.mp4';
      final savePath = Platform.isWindows
          ? '$targetDirectory\\$fileName'
          : '$targetDirectory/$fileName';

      // 6. Video ve Sesi Birleştir (Muxing)
      onProgress(0.92, 'En yüksek kalitede birleştiriliyor ($videoQualityLabel)...');
      bool muxSuccess = false;
      if (Platform.isWindows) {
        muxSuccess = await _muxWithFfmpegWindows(
          videoPath: tempVideoPath,
          audioPath: tempAudioPath,
          outputPath: savePath,
        );
      } 

      if (muxSuccess && await File(savePath).exists() && (await File(savePath).length()) > 1024) {
        return savePath;
      } else {
        
        _hqMuxFailed = true;
        await _log('Muxing tamamlanamadı (ffmpeg bulunamadı veya birleştirme hatası).');
        return null;
      }
    } catch (e) {
      await _log('YouTube yüksek kalite indirme hatası: $e');
      return null;
    } finally {
      yt.close();
      try {
        if (tempVideoFile != null && await tempVideoFile.exists()) {
          await tempVideoFile.delete();
        }
      } catch (_) {}
      try {
        if (tempAudioFile != null && await tempAudioFile.exists()) {
          await tempAudioFile.delete();
        }
      } catch (_) {}
    }
  }

  /// CDN ve platform engellerini aşmak için URL'ye özel HTTP başlıkları
  Map<String, dynamic> _getHeadersForUrl(String url) {
    final lower = url.toLowerCase();
    final headers = <String, dynamic>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
      'Accept': '*/*',
      'Connection': 'keep-alive',
      'Accept-Encoding': 'identity',
    };
    if (lower.contains('snapcdn') || lower.contains('snapsave')) {
      headers['Referer'] = 'https://snapsave.app/';
      headers['Origin'] = 'https://snapsave.app';
    } else if (lower.contains('fbcdn.net') || lower.contains('facebook.com')) {
      headers['Referer'] = 'https://www.facebook.com/';
    } else if (lower.contains('twimg.com') || lower.contains('twitter.com') || lower.contains('x.com')) {
      headers['Referer'] = 'https://x.com/';
    }
    return headers;
  }

  /// Yüksek hızlı akıllı indirme motoru: Dosya boyutu ve Range desteğini test eder,
  /// destekliyorsa 4-8 eşzamanlı paralel bağlantı ile bant genişliğini sonuna kadar kullanır.
  Future<void> _fastDownload({
    required String url,
    required String savePath,
    CancelToken? cancelToken,
    required void Function(int received, int total) onReceiveProgress,
  }) async {
    int totalBytes = 0;
    bool supportsRange = false;

    try {
      final probeHeaders = _getHeadersForUrl(url)..['Range'] = 'bytes=0-0';
      final probeResp = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: probeHeaders,
          followRedirects: true,
          validateStatus: (status) => status != null && status < 400,
        ),
      ).timeout(const Duration(seconds: 4));

      try {
        await probeResp.data?.stream.drain();
      } catch (_) {}

      final statusCode = probeResp.statusCode;
      final headers = probeResp.headers;

      if (savePath.toLowerCase().endsWith('.mp4')) {
        final ct = (headers.value('content-type') ?? '').toLowerCase();
        if (ct.startsWith('image/')) {
          throw Exception('Sunucu video akışı yerine görsel döndürdü ($ct).');
        }
      }

      if (statusCode == 206) {
        supportsRange = true;
        final cr = headers.value('content-range');
        if (cr != null && cr.contains('/')) {
          final totalStr = cr.split('/').last.trim();
          totalBytes = int.tryParse(totalStr) ?? 0;
        }
      }

      if (totalBytes <= 0) {
        final cl = headers.value('content-length');
        if (cl != null) {
          totalBytes = int.tryParse(cl) ?? 0;
        }
        if (headers.value('accept-ranges') == 'bytes') {
          supportsRange = true;
        }
      }
    } catch (e) {
      debugPrint('Hızlı indirme probe uyarısı: $e. Standart indirmeye geçiliyor.');
    }

    // Twitter/X CDN sunucuları (twimg.com) eşzamanlı parçalı (Range) bağlantıları kısıtlar.
    // Bu nedenle Twitter doğrudan tekil akışla kesintisiz indirilir (yeniden başlama hatası önlenir).
    final isTwitter = url.contains('twimg.com') ||
        url.contains('twitter.com') ||
        url.contains('x.com');

    // Dosya boyutu 1.5 MB'tan büyük ve Range destekleniyorsa paralel indirme yap
    if (!isTwitter && supportsRange && totalBytes > 1024 * 1024 * 1.5) {
      int numChunks = 6;
      if (totalBytes > 1024 * 1024 * 40) {
        numChunks = 8; // Büyük dosyalar (40 MB+) için 8 paralel bağlantı
      } else if (totalBytes < 1024 * 1024 * 8) {
        numChunks = 4; // Küçük dosyalar için 4 paralel bağlantı
      }

      try {
        debugPrint('KaraDelik Çok Kanallı Turbo İndirme: $numChunks kanal, ${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB');
        await _parallelChunkDownload(
          url: url,
          savePath: savePath,
          totalBytes: totalBytes,
          numChunks: numChunks,
          cancelToken: cancelToken,
          onReceiveProgress: onReceiveProgress,
        );
        return;
      } catch (e) {
        if (cancelToken?.isCancelled == true) rethrow;
        debugPrint('Çok kanallı indirme uyarısı: $e. Tekil akışa geri dönülüyor.');
      }
    }

    // Range desteklenmiyorsa veya paralel akış hata verirse kesintisiz tekil indirme
    await _robustDownload(
      url: url,
      savePath: savePath,
      cancelToken: cancelToken,
      onReceiveProgress: onReceiveProgress,
    );
  }

  /// Çok parçalı paralel akış indirme motoru (HTTP Range ile bant genişliğini sonuna kadar kullanır)
  Future<void> _parallelChunkDownload({
    required String url,
    required String savePath,
    required int totalBytes,
    int numChunks = 6,
    CancelToken? cancelToken,
    required void Function(int received, int total) onReceiveProgress,
  }) async {
    if (totalBytes <= 1024 * 512 || numChunks <= 1) {
      await _robustDownload(
        url: url,
        savePath: savePath,
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
      );
      return;
    }

    final chunkSize = (totalBytes / numChunks).ceil();
    final chunkFutures = <Future<void>>[];
    final receivedPerChunk = List<int>.filled(numChunks, 0);

    for (int i = 0; i < numChunks; i++) {
      final chunkIndex = i;
      final start = i * chunkSize;
      final end = (i == numChunks - 1) ? totalBytes - 1 : (start + chunkSize - 1);
      final partPath = '$savePath.part$i';

      chunkFutures.add(() async {
        await _robustDownload(
          url: url,
          savePath: partPath,
          cancelToken: cancelToken,
          rangeHeader: 'bytes=$start-$end',
          onReceiveProgress: (rec, _) {
            receivedPerChunk[chunkIndex] = rec;
            final currentTotalRec = receivedPerChunk.fold<int>(0, (sum, val) => sum + val);
            onReceiveProgress(currentTotalRec, totalBytes);
          },
        );
      }());
    }

    try {
      await Future.wait(chunkFutures);

      // Parçaları ultra hızlı 1 MB tamponlu blok aktarımıyla birleştir
      final outFile = File(savePath);
      if (await outFile.exists()) await outFile.delete();
      final outRaf = await outFile.open(mode: FileMode.write);
      final buffer = Uint8List(1024 * 1024); // 1 MB tampon

      for (int i = 0; i < numChunks; i++) {
        final partFile = File('$savePath.part$i');
        if (await partFile.exists()) {
          final inRaf = await partFile.open(mode: FileMode.read);
          int bytesRead;
          while ((bytesRead = inRaf.readIntoSync(buffer)) > 0) {
            outRaf.writeFromSync(buffer, 0, bytesRead);
          }
          await inRaf.close();
          try {
            await partFile.delete();
          } catch (_) {}
        }
      }
      await outRaf.flush();
      await outRaf.close();
    } catch (e) {
      for (int i = 0; i < numChunks; i++) {
        try {
          final partFile = File('$savePath.part$i');
          if (await partFile.exists()) await partFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Takılmaya ve 403 engeline dayanıklı kapalı aralıklı (bounded chunk) akış indirme motoru
  Future<void> _downloadStreamInChunks({
    required String url,
    required String savePath,
    required int totalBytes,
    int chunkSize = 8388608, // 8 MB varsayılan (önceki 2 MB yerine)
    CancelToken? cancelToken,
    required void Function(int received, int total) onProgress,
    int maxFailures = 8,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 60)
      ..maxConnectionsPerHost = 32
      ..autoUncompress = false;
    final file = File(savePath);
    if (await file.exists()) await file.delete();
    final sink = file.openWrite();
    int received = 0;
    int failures = 0;

    try {
      while (totalBytes <= 0 || received < totalBytes) {
        if (cancelToken?.isCancelled == true || _cancelToken?.isCancelled == true) {
          throw Exception('İptal edildi');
        }
        final start = received;
        final end = (totalBytes > 0 && start + chunkSize - 1 >= totalBytes)
            ? totalBytes - 1
            : start + chunkSize - 1;

        try {
          final req = await client.getUrl(Uri.parse(url));
          final customHeaders = _getHeadersForUrl(url);
          customHeaders.forEach((k, v) {
            req.headers.set(k, v);
          });
          req.headers.set('Range', 'bytes=$start-$end');

          final resp = await req.close().timeout(const Duration(seconds: 15));
          if (resp.statusCode != 200 && resp.statusCode != 206) {
            throw HttpException('HTTP ${resp.statusCode}');
          }

          int chunkBytes = 0;
          await for (final chunk in resp.timeout(const Duration(seconds: 20))) {
            if (cancelToken?.isCancelled == true || _cancelToken?.isCancelled == true) {
              throw Exception('İptal edildi');
            }
            sink.add(chunk);
            chunkBytes += chunk.length;
          }
          received += chunkBytes;
          failures = 0;
          onProgress(received, totalBytes);
          if (totalBytes <= 0 && chunkBytes == 0) break;
        } catch (e) {
          if (cancelToken?.isCancelled == true || _cancelToken?.isCancelled == true) rethrow;
          failures++;
          debugPrint('Akış parçası takıldı ($failures/$maxFailures): $e. Yeniden deneniyor...');
          if (failures >= maxFailures) rethrow;
          await Future.delayed(Duration(milliseconds: 300 * failures));
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
      client.close(force: true);
    }
  }

  /// Yüksek hızlı, kesintisiz ve otomatik yeniden denemeli akış indirme motoru
  Future<void> _robustDownload({
    required String url,
    required String savePath,
    CancelToken? cancelToken,
    String? rangeHeader,
    required void Function(int received, int total) onReceiveProgress,
    int maxRetries = 3,
  }) async {
    int attempts = 0;
    while (true) {
      attempts++;
      try {
        final headers = _getHeadersForUrl(url);
        if (rangeHeader != null) {
          headers['Range'] = rangeHeader;
        }

        await _dio.download(
          url,
          savePath,
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: true,
            maxRedirects: 10,
            headers: headers,
          ),
          onReceiveProgress: onReceiveProgress,
        );
        return;
      } catch (e) {
        if (cancelToken?.isCancelled == true) {
          rethrow;
        }
        if (e is DioException &&
            (e.response?.statusCode == 403 || e.response?.statusCode == 401)) {
          rethrow;
        }
        if (attempts >= maxRetries) {
          rethrow;
        }
        debugPrint('İndirme kesintisi (Deneme $attempts/$maxRetries): $e. Yeniden deneniyor...');
        await Future.delayed(Duration(milliseconds: 500 * attempts));
      }
    }
  }

  /// Videoyu veya sesi hedef klasöre indirir
  Future<String> startDownload({
    required String targetUrl,
    required DownloadQuality quality,
    required DownloadProgressCallback onProgress,
  }) async {
    if (_isDownloading) {
      debugPrint('KaraDelik: Zaten aktif bir indirme süreci yürütülüyor, mükerrer istek engellendi.');
      throw Exception('Zaten devam eden bir indirme işlemi bulunuyor.');
    }
    _isDownloading = true;
    _cancelToken = CancelToken();
    lastResolvedVideoDuration = null;

    try {
      // 1. Depolama İzinleri
      onProgress(0.05, 'Depolama izinleri denetleniyor...');
    

    final targetDirectory = await getDestinationDirectory();
    final timeStamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final isYouTube = targetUrl.toLowerCase().contains('youtube.com') ||
        targetUrl.toLowerCase().contains('youtu.be');

    // Keep platform extraction, signed request headers and conversion together.
    if (Platform.isWindows &&
        detectPlatformName(targetUrl) == 'Instagram' &&
        await YtDlpExtraService().findYtDlpExecutable() != null) {
      try {
        final result = await YtDlpExtraService().downloadWithProgress(
          targetUrl: targetUrl,
          quality: quality,
          destinationPath: path_lib.join(targetDirectory,
              'KaraDelik_Instagram_$timeStamp.${quality.isAudioOnly ? 'mp3' : 'mp4'}'),
          onProgress: onProgress,
        );
        if (_cancelToken?.isCancelled == true) {
          throw Exception('İndirme iptal edildi.');
        }
        try {
          await DownloadHistoryService().addItem(result, url: targetUrl);
        } catch (e) {
          debugPrint('Geçmişe eklenemedi: $e');
        }
        onProgress(1.0, 'Tamamlandı!');
        return result;
      } catch (e) {
        if (_cancelToken?.isCancelled == true) rethrow;
        debugPrint('Instagram yerel motor hatası: $e');
      }
    }

    // 2. YouTube için ses (MP3) doğrudan garantili çok katmanlı motor ile indirme ve dönüştürme
    if (isYouTube && quality.isAudioOnly) {
      final audioPath = await _downloadYouTubeAudio(
        targetUrl: targetUrl,
        targetDirectory: targetDirectory,
        timeStamp: timeStamp,
        onProgress: onProgress,
      );

      if (audioPath != null) {
        final savedFile = File(audioPath);
        if (await savedFile.exists() && await savedFile.length() > 1024) {
          // İndirilenler Geçmişine Kaydet
          try {
            await DownloadHistoryService().addItem(audioPath, url: targetUrl);
          } catch (e) {
            debugPrint('Geçmişe eklenemedi: $e');
          }
          

          onProgress(1.0, 'Tamamlandı!');
          return audioPath;
        }
      }
    }
    if (isYouTube && !quality.isAudioOnly) {
      final highQualityPath = await _downloadYouTubeHighQuality(
              targetUrl: targetUrl,
              quality: quality,
              targetDirectory: targetDirectory,
              timeStamp: timeStamp,
              onProgress: onProgress,
            );

      if (highQualityPath != null) {
        final savedFile = File(highQualityPath);
        if (await savedFile.exists() && await savedFile.length() > 1024) {
          // MP4 Süre Başlıklarını Onar
          onProgress(0.96, 'Video süresi ve başlıkları optimize ediliyor...');
          await Mp4Fixer.fixDurationIfNeeded(
            highQualityPath,
            expectedDuration: lastResolvedVideoDuration,
          );

          // İndirilenler Geçmişine Kaydet
          try {
            await DownloadHistoryService().addItem(highQualityPath, url: targetUrl);
          } catch (e) {
            debugPrint('Geçmişe eklenemedi: $e');
          }
          

          onProgress(1.0, 'Tamamlandı!');
          return highQualityPath;
        }
      }

      onProgress(0.20, 'Garantili doğrudan akışa geçiliyor...');
    }

    try {
      // 3. Genel ve Alternatif Akış Bağlantısını Çözümle
      final downloadStreamUrl = await resolveDownloadUrl(
        targetUrl: targetUrl,
        quality: quality,
        onProgress: onProgress,
      );

    // 4. Dosya Adı ve Klasörü Hazırla
    onProgress(0.25, 'Dosya yolu hazırlanıyor...');
    final extension = quality.isAudioOnly ? 'mp3' : 'mp4';
    final platform = detectPlatformName(targetUrl);
    final fileName = 'KaraDelik_${platform}_$timeStamp.$extension';
    final savePath = Platform.isWindows
        ? '$targetDirectory\\$fileName'
        : '$targetDirectory/$fileName';

    if (quality.isAudioOnly) {
      // 5. Ses/Medya Akışını Geçici Dosyaya İndir
      onProgress(0.30, 'Ses akışı indiriliyor...');
      final tempDir = await getTemporaryDirectory();
      final tempMediaPath = Platform.isWindows
          ? '${tempDir.path}\\temp_audio_dl_$timeStamp.mp4'
          : '${tempDir.path}/temp_audio_dl_$timeStamp.mp4';
      final tempMediaFile = File(tempMediaPath);

      final speedTracker = SpeedTracker();
      await _fastDownload(
        url: downloadStreamUrl,
        savePath: tempMediaPath,
        cancelToken: _cancelToken,
        onReceiveProgress: (received, total) {
          speedTracker.update(received, total);
          if (total > 0) {
            final percentage = received / total;
            final percentInt = (percentage * 100).toInt();
            onProgress(
              0.30 + (percentage * 0.55),
              '%$percentInt İndiriliyor... (${(received / (1024 * 1024)).toStringAsFixed(1)} MB / ${(total / (1024 * 1024)).toStringAsFixed(1)} MB)',
              speed: speedTracker.currentSpeed,
              eta: speedTracker.currentEta,
            );
          } else {
            onProgress(
              0.5,
              'İndiriliyor: ${(received / (1024 * 1024)).toStringAsFixed(1)} MB',
              speed: speedTracker.currentSpeed,
              eta: speedTracker.currentEta,
            );
          }
        },
      );

      if (!await tempMediaFile.exists() || await tempMediaFile.length() <= 1024) {
        try {
          if (await tempMediaFile.exists()) await tempMediaFile.delete();
        } catch (_) {}
        throw Exception('İndirilen medya boş veya geçersiz (0 bayt). Lütfen bağlantıyı kontrol ediniz.');
      }

      // Dosya zaten gerçek bir MP3 mü kontrol et (ilk 3 bayt "ID3" veya MPEG Audio sync word 0xFFE0)
      bool isPureMp3 = false;
      try {
        final bytes = await tempMediaFile.openRead(0, 10).first;
        if (bytes.length >= 3) {
          if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
            isPureMp3 = true; // ID3 tag
          } else if (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
            isPureMp3 = true; // MPEG Audio sync word
          }
        }
      } catch (_) {}

      if (isPureMp3) {
        // Zaten hazır MP3: doğrudan savePath'e kopyala
        final finalFile = File(savePath);
        if (await finalFile.exists()) await finalFile.delete();
        await tempMediaFile.copy(savePath);
        try { await tempMediaFile.delete(); } catch (_) {}
      } else {
        // MP4 video veya ses akışını gerçek MP3 formatına dönüştür!
        onProgress(0.88, 'Gerçek MP3 ses formatına dönüştürülüyor...');
        final converted = await _convertToMp3(tempMediaPath, savePath);
        try {
          if (await tempMediaFile.exists()) await tempMediaFile.delete();
        } catch (_) {}

        if (!converted || !await File(savePath).exists() || await File(savePath).length() <= 1024) {
          throw Exception('Ses MP3 formatına dönüştürülemedi.');
        }
      }

      // 6. İndirilenler Geçmişine Kaydet
      try {
        await DownloadHistoryService().addItem(savePath, url: targetUrl);
      } catch (e) {
        debugPrint('Geçmişe eklenemedi: $e');
      }
      

      onProgress(1.0, 'Tamamlandı!');
      return savePath;
    }

    // 5. Video Akışını İndir
    onProgress(0.30, 'İndirme başlıyor...');
    final speedTracker = SpeedTracker();
    await _fastDownload(
      url: downloadStreamUrl,
      savePath: savePath,
      cancelToken: _cancelToken,
      onReceiveProgress: (received, total) {
        speedTracker.update(received, total);
        if (total > 0) {
          final percentage = received / total;
          final percentInt = (percentage * 100).toInt();
          onProgress(
            percentage,
            '%$percentInt İndiriliyor... (${(received / (1024 * 1024)).toStringAsFixed(1)} MB / ${(total / (1024 * 1024)).toStringAsFixed(1)} MB)',
            speed: speedTracker.currentSpeed,
            eta: speedTracker.currentEta,
          );
        } else {
          onProgress(
            0.5,
            'İndiriliyor: ${(received / (1024 * 1024)).toStringAsFixed(1)} MB',
            speed: speedTracker.currentSpeed,
            eta: speedTracker.currentEta,
          );
        }
      },
    );

    // 6. Dosya Bütünlüğü ve 0 Bayt Kontrolü
    final savedFile = File(savePath);
    if (!await savedFile.exists() || await savedFile.length() <= 1024) {
      if (await savedFile.exists()) {
        try {
          await savedFile.delete();
        } catch (_) {}
      }
      throw Exception('İndirilen medya dosyası boş veya geçersiz (0 bayt). Lütfen bağlantıyı kontrol edip tekrar deneyiniz.');
    }

    // MP4 dosyalarında görsel (JPEG) indirilmediğini garantiye al (magic bytes kontrolü)
    if (savePath.toLowerCase().endsWith('.mp4')) {
      try {
        final headerBytes = await savedFile.openRead(0, 4).first;
        if (headerBytes.length >= 3 &&
            headerBytes[0] == 0xFF &&
            headerBytes[1] == 0xD8 &&
            headerBytes[2] == 0xFF) {
          try {
            await savedFile.delete();
          } catch (_) {}
          throw Exception('İndirilen dosya video akışı yerine görsel (JPEG). Alternatif motor deneniyor...');
        }
      } catch (e) {
        if (e.toString().contains('JPEG')) rethrow;
      }
    }

    // 7. MP4 Süre Başlıklarını Onar (Video zamanı ve süre eksikliği hatasını onarır)
    if (savePath.endsWith('.mp4')) {
      onProgress(0.96, 'Video süresi ve başlıkları optimize ediliyor...');
      await Mp4Fixer.fixDurationIfNeeded(
        savePath,
        expectedDuration: lastResolvedVideoDuration,
      );
    }

    // 8. İndirilenler Geçmişine Kaydet
    try {
      await DownloadHistoryService().addItem(savePath, url: targetUrl);
    } catch (e) {
      debugPrint('Geçmişe eklenemedi: $e');
    }
    

    onProgress(1.0, 'Tamamlandı!');
    return savePath;
    } catch (e) {
      if (_cancelToken?.isCancelled == true) rethrow;
      if (e.toString().contains('ses akışı bulunmamaktadır')) rethrow;

      // Standart motorlar yanıt vermezse yedek indirme motoru devreye girer
      onProgress(0.20, 'Alternatif indirme motoru devreye giriyor...');
      try {
        final ext = quality.isAudioOnly ? 'mp3' : 'mp4';
        final platform = detectPlatformName(targetUrl);
        final fileName = 'KaraDelik_${platform}_$timeStamp.$ext';
        final fallbackPath = Platform.isWindows
            ? '$targetDirectory\\$fileName'
            : '$targetDirectory/$fileName';

        final resultPath = await YtDlpExtraService().downloadWithProgress(
          targetUrl: targetUrl,
          quality: quality,
          destinationPath: fallbackPath,
          onProgress: onProgress,
        );

        if (await File(resultPath).exists() && await File(resultPath).length() > 1024) {
          if (resultPath.toLowerCase().endsWith('.mp4')) {
            onProgress(0.96, 'Video süresi ve başlıkları optimize ediliyor...');
            await Mp4Fixer.fixDurationIfNeeded(
              resultPath,
              expectedDuration: lastResolvedVideoDuration,
            );
          }

          try {
            await DownloadHistoryService().addItem(resultPath, url: targetUrl);
          } catch (_) {}

          

          onProgress(1.0, 'Tamamlandı!');
          return resultPath;
        }
      } catch (fallbackErr) {
        if (_cancelToken?.isCancelled == true) rethrow;
        debugPrint('Yedek indirme motoru kurtarma hatası: $fallbackErr');
        throw Exception('İndirme tamamlanamadı: $fallbackErr');
      }
      rethrow;
    }
  } finally {
    _isDownloading = false;
  }
}

  /// Aktif indirmeyi iptal eder
  void cancelDownload() {
    _cancelToken?.cancel('Kullanıcı tarafından iptal edildi.');
    YtDlpExtraService().cancel();
  }
}
