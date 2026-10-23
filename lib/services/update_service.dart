import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path_lib;
import 'localization_service.dart';

class UpdateService {
  // Mevcut uygulama sürümü (v1.0.2)
  static const String currentVersion = '1.0.2';

  static const String _apiEndpoint =
      'https://api.github.com/repos/abivibe/Kara-Delik/releases/latest';

  static bool _hasChecked = false;
  static bool _dialogVisible = false;

  /// Arka planda GitHub Releases API sorgusu yapar.
  /// Tarayıcı açmaz, tamamen arka planda HTTP GET ile çalışır.
  static Future<void> checkForUpdates(
    BuildContext context, {
    required ThemeMode themeMode,
    required String languageCode,
    bool isManual = false,
  }) async {
    if (!kIsWeb && !Platform.isWindows) return;
    if (_hasChecked && !isManual) return;
    _hasChecked = true;

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);

      final request = await client.getUrl(Uri.parse(_apiEndpoint));
      request.headers.set('User-Agent', 'KaraDelik-App');
      request.headers.set('Accept', 'application/vnd.github.v3+json');

      final response = await request.close();
      if (response.statusCode != 200) {
        client.close();
        return;
      }

      final responseBody = await response.transform(utf8.decoder).join();
      client.close();

      final data = jsonDecode(responseBody);
      if (data is! Map<String, dynamic>) return;

      final tagName = data['tag_name'] as String?;
      if (tagName == null || tagName.isEmpty) return;

      // Assets içindeki .exe uzantılı Setup dosyasının browser_download_url adresini al
      String? downloadUrl;
      final assets = data['assets'] as List<dynamic>? ?? [];
      for (final asset in assets) {
        if (asset is Map<String, dynamic>) {
          final name = (asset['name'] as String? ?? '').toLowerCase();
          if (name.endsWith('.exe')) {
            downloadUrl = asset['browser_download_url'] as String?;
            break;
          }
        }
      }

      if (downloadUrl == null || downloadUrl.isEmpty) return;

      // Sürüm karşılaştırması yap (örn: v1.0.1 > 1.0.0)
      if (isNewerVersion(tagName, currentVersion)) {
        if (context.mounted && !_dialogVisible) {
          _dialogVisible = true;
          _showUpdateDialog(
            context,
            tagName: tagName,
            downloadUrl: downloadUrl,
            themeMode: themeMode,
            languageCode: languageCode,
          );
        }
      }
    } catch (e) {
      debugPrint('Otomatik güncelleme denetimi hatası: $e');
    }
  }

  /// Semver sürüm karşılaştırması
  static bool isNewerVersion(String remoteTag, String localVersion) {
    try {
      String cleanRemote = remoteTag.replaceAll(RegExp(r'^[vV]'), '').trim();
      String cleanLocal = localVersion.replaceAll(RegExp(r'^[vV]'), '').trim();

      cleanRemote = cleanRemote.split('+').first.split('-').first;
      cleanLocal = cleanLocal.split('+').first.split('-').first;

      List<int> remoteParts =
          cleanRemote.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      List<int> localParts =
          cleanLocal.split('.').map((e) => int.tryParse(e) ?? 0).toList();

      while (remoteParts.length < 3) {
        remoteParts.add(0);
      }
      while (localParts.length < 3) {
        localParts.add(0);
      }

      for (int i = 0; i < 3; i++) {
        if (remoteParts[i] > localParts[i]) return true;
        if (remoteParts[i] < localParts[i]) return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Uygulamanın temasına ve diline uygun modern AMOLED/Açık güncelleme penceresi
  static void _showUpdateDialog(
    BuildContext context, {
    required String tagName,
    required String downloadUrl,
    required ThemeMode themeMode,
    required String languageCode,
  }) {
    final isDark = themeMode == ThemeMode.dark;
    final isTr = languageCode.toLowerCase().startsWith('tr');

    final title = AppLocalizations.tr('update_available_title');
    final desc = isTr
        ? 'Yeni bir sürüm mevcut ($tagName).\nİndirmek ve güncellemek ister misiniz?'
        : 'A new version is available ($tagName).\nWould you like to download and update?';
    final btnDownload = AppLocalizations.tr('update_btn_download');
    final btnLater = AppLocalizations.tr('update_btn_later');

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Container(
            width: 360,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF14151B) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark ? const Color(0xFF2B2D3A) : const Color(0xFFE2E8F0),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.6 : 0.15),
                  blurRadius: 28,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // İkon Rozeti
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2563EB).withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.system_update_alt_rounded,
                      color: Color(0xFF3B82F6),
                      size: 26,
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Başlık
                Text(
                  title,
                  style: TextStyle(
                    color: isDark ? const Color(0xFFF1F3F9) : const Color(0xFF0F172A),
                    fontSize: 16.5,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),

                // Açıklama
                Text(
                  desc,
                  style: TextStyle(
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                    fontSize: 13,
                    height: 1.45,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),

                // Butonlar
                Row(
                  children: [
                    // Vazgeç / Daha Sonra
                    Expanded(
                      child: TextButton(
                        onPressed: () {
                          _dialogVisible = false;
                          Navigator.of(ctx).pop();
                        },
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(
                              color: isDark
                                  ? const Color(0xFF2D303E)
                                  : const Color(0xFFCBD5E1),
                            ),
                          ),
                        ),
                        child: Text(
                          btnLater,
                          style: TextStyle(
                            color: isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF64748B),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),

                    // İndir / Şimdi Güncelle
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          _dialogVisible = false;
                          Navigator.of(ctx).pop();
                          await triggerUpdaterAndExit(
                            downloadUrl: downloadUrl,
                            themeMode: themeMode,
                            languageCode: languageCode,
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: Text(
                          btnDownload,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Updater.exe dosyasını CLI argümanlarıyla başlatır ve hemen exit(0) ile ana uygulamayı kapatır.
  static Future<void> triggerUpdaterAndExit({
    required String downloadUrl,
    required ThemeMode themeMode,
    required String languageCode,
  }) async {
    try {
      final exeDir = path_lib.dirname(Platform.resolvedExecutable);
      String updaterPath = path_lib.join(exeDir, 'Updater.exe');

      // Geliştirme ortamı veya fallback konumları
      if (!File(updaterPath).existsSync()) {
        updaterPath = path_lib.join(
          Directory.current.path,
          'windows',
          'bin',
          'Updater.exe',
        );
      }
      if (!File(updaterPath).existsSync()) {
        updaterPath = path_lib.join(
          Directory.current.path,
          'windows',
          'updater',
          'bin',
          'Release',
          'Updater.exe',
        );
      }

      final themeArg = themeMode == ThemeMode.light ? 'light' : 'dark';
      final langArg = languageCode.toLowerCase().startsWith('tr') ? 'tr' : 'en';
      final mainAppExePath = Platform.resolvedExecutable;

      if (File(updaterPath).existsSync()) {
        await Process.start(
          updaterPath,
          [downloadUrl, themeArg, langArg, mainAppExePath],
          mode: ProcessStartMode.detached,
        );

        // Ana Flutter uygulaması Process.start sonrasında exit(0) ile hemen kapatılır
        exit(0);
      } else {
        debugPrint('Updater.exe bulunamadı: $updaterPath');
      }
    } catch (e) {
      debugPrint('Updater başlatılırken hata: $e');
    }
  }
}
