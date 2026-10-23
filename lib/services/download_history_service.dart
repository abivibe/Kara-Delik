import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path_lib;
import 'package:path_provider/path_provider.dart';

class DownloadedItem {
  final String filePath;
  final String fileName;
  final int fileSize;
  final String formattedSize;
  final String date;
  final String? url;

  DownloadedItem({
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.formattedSize,
    required this.date,
    this.url,
  });

  Map<String, dynamic> toJson() => {
        'filePath': filePath,
        'fileName': fileName,
        'fileSize': fileSize,
        'formattedSize': formattedSize,
        'date': date,
        'url': url,
      };

  factory DownloadedItem.fromJson(Map<String, dynamic> json) => DownloadedItem(
        filePath: json['filePath'] as String,
        fileName: json['fileName'] as String,
        fileSize: json['fileSize'] as int? ?? 0,
        formattedSize: json['formattedSize'] as String? ?? '0 MB',
        date: json['date'] as String? ?? '',
        url: json['url'] as String?,
      );
}

class DownloadHistoryService {
  static final DownloadHistoryService _instance =
      DownloadHistoryService._internal();
  factory DownloadHistoryService() => _instance;
  DownloadHistoryService._internal();

  final List<DownloadedItem> _items = [];
  List<DownloadedItem> get items => List.unmodifiable(_items);

  File? _storageFile;

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${suffixes[i]}';
  }

  Future<File> _getStorageFile() async {
    if (_storageFile != null) return _storageFile!;
    final dir = await getApplicationSupportDirectory();
    _storageFile = File(path_lib.join(dir.path, 'downloads_history.json'));
    return _storageFile!;
  }

  Future<void> loadHistory() async {
    _items.clear();
    try {
      final file = await _getStorageFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final jsonList = jsonDecode(content) as List;
        for (final item in jsonList) {
          if (item is Map<String, dynamic>) {
            final entry = DownloadedItem.fromJson(item);
            if (File(entry.filePath).existsSync()) {
              _items.add(entry);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('İndirme geçmişi yüklenirken hata: $e');
    }

    // Windows'ta kullanıcının İndirilenler klasöründeki mevcut KaraDelik dosyalarını da tara
    if (Platform.isWindows) {
      await _scanExistingKaraDelikFiles();
    }

    // Tarihe göre yeniden eskiye sırala
    _items.sort((a, b) => b.filePath.compareTo(a.filePath));
  }

  Future<void> _scanExistingKaraDelikFiles() async {
    try {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile == null) return;
      final winDownloads = Directory('$userProfile\\Downloads');
      if (!await winDownloads.exists()) return;

      final existingPaths = _items.map((e) => e.filePath.toLowerCase()).toSet();

      final files = winDownloads.listSync().whereType<File>();
      for (final f in files) {
        final name = path_lib.basename(f.path);
        if (name.startsWith('KaraDelik_') &&
            (name.endsWith('.mp4') || name.endsWith('.mp3'))) {
          if (!existingPaths.contains(f.path.toLowerCase())) {
            final length = f.lengthSync();
            if (length > 1024) {
              final dateStr = DateFormat('dd.MM.yyyy HH:mm')
                  .format(f.lastModifiedSync());
              _items.add(
                DownloadedItem(
                  filePath: f.path,
                  fileName: name,
                  fileSize: length,
                  formattedSize: formatBytes(length),
                  date: dateStr,
                ),
              );
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Mevcut dosyalar taranırken hata: $e');
    }
  }

  Future<void> addItem(String filePath, {String? url}) async {
    final file = File(filePath);
    if (!await file.exists()) return;
    final length = await file.length();
    if (length <= 1024) return;

    final name = path_lib.basename(filePath);
    final dateStr =
        DateFormat('dd.MM.yyyy HH:mm').format(DateTime.now());

    // Eğer zaten varsa güncelle
    _items.removeWhere((it) => it.filePath.toLowerCase() == filePath.toLowerCase());

    _items.insert(
      0,
      DownloadedItem(
        filePath: filePath,
        fileName: name,
        fileSize: length,
        formattedSize: formatBytes(length),
        date: dateStr,
        url: url,
      ),
    );

    await _saveHistory();
  }

  Future<bool> _deletePhysicalFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return true;

      for (var i = 0; i < 4 && await file.exists(); i++) {
        try {
          await file.delete();
          return true;
        } catch (e) {
          debugPrint('Dosya silme denemesi ${i + 1} ($filePath): $e');
          if (Platform.isWindows) {
            try {
              await Process.run('cmd.exe', ['/c', 'del', '/f', '/q', filePath.replaceAll('/', '\\')]);
            } catch (_) {}
          }
          if (await file.exists()) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
        }
      }
      return !await file.exists();
    } catch (e) {
      debugPrint('Fiziksel dosya silme hatası ($filePath): $e');
      return false;
    }
  }

  Future<bool> deleteItem(DownloadedItem item) async {
    try {
      final deleted = await _deletePhysicalFile(item.filePath);
      if (!deleted) {
        return false; // Hâlâ kilitli
      }

      // 2. Uygulama listesinden sil
      _items.removeWhere((it) => it.filePath.toLowerCase() == item.filePath.toLowerCase());
      await _saveHistory();
      return true;
    } catch (e) {
      debugPrint('Dosya silinirken hata: $e');
      return false;
    }
  }

  Future<int> clearAllHistory({bool deleteFiles = true, String? customDownloadPath}) async {
    int deletedCount = 0;

    if (deleteFiles) {
      // 1. Listedeki tüm öğelerin fiziksel dosyalarını sil
      for (final item in List<DownloadedItem>.from(_items)) {
        final success = await _deletePhysicalFile(item.filePath);
        if (success) deletedCount++;
      }

      // 2. Windows Downloads klasöründeki olası KaraDelik dosyalarını da temizle
      if (Platform.isWindows) {
        try {
          final userProfile = Platform.environment['USERPROFILE'];
          if (userProfile != null) {
            final winDownloads = Directory('$userProfile\\Downloads');
            if (await winDownloads.exists()) {
              final files = winDownloads.listSync().whereType<File>();
              for (final f in files) {
                final name = path_lib.basename(f.path);
                if (name.startsWith('KaraDelik_') &&
                    (name.endsWith('.mp4') || name.endsWith('.mp3'))) {
                  final ok = await _deletePhysicalFile(f.path);
                  if (ok) deletedCount++;
                }
              }
            }
          }
        } catch (e) {
          debugPrint('Windows indirme klasörü temizlenirken hata: $e');
        }
      }

      // 3. Özel indirme klasörü varsa oradaki KaraDelik dosyalarını da temizle
      if (customDownloadPath != null && customDownloadPath.trim().isNotEmpty) {
        try {
          final customDir = Directory(customDownloadPath.trim());
          if (await customDir.exists()) {
            final files = customDir.listSync().whereType<File>();
            for (final f in files) {
              final name = path_lib.basename(f.path);
              if (name.startsWith('KaraDelik_') &&
                  (name.endsWith('.mp4') || name.endsWith('.mp3'))) {
                final ok = await _deletePhysicalFile(f.path);
                if (ok) deletedCount++;
              }
            }
          }
        } catch (e) {
          debugPrint('Özel indirme klasörü temizlenirken hata: $e');
        }
      }
    }

    // 4. Bellek ve kalıcı JSON geçmişini sıfırla
    _items.clear();
    await _saveHistory();
    return deletedCount;
  }

  Future<void> _saveHistory() async {
    try {
      final file = await _getStorageFile();
      final data = _items.map((e) => e.toJson()).toList();
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('Geçmiş kaydedilirken hata: $e');
    }
  }

  /// Windows varsayılan medya oynatıcısında dosyayı doğrudan açar
  Future<void> playInDefaultPlayer(String filePath) async {
    if (!Platform.isWindows) return;
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await Process.run('cmd.exe', ['/c', 'start', '""', filePath]);
      }
    } catch (e) {
      debugPrint('Dosya oynatılırken hata: $e');
    }
  }

  /// Windows Klasörde Göster Çözümü:
  /// 1. Birincil Strateji (Windows Shell API): KaraDelikNotifier.exe /open (shell32.dll Win32 SHOpenFolderAndSelectItems & ILCreateFromPathW)
  /// 2. İkincil Strateji (Doğrudan Explorer): Mutlak C:\Windows\explorer.exe (/select, CreateProcessW)
  /// 3. Üçüncül Strateji (Bypass Shell Start): cmd.exe /c start "" "{dizin}"
  Future<void> openContainingFolder(String filePath) async {
    if (!Platform.isWindows) return;
    try {
      final normalized = path_lib.normalize(filePath.replaceAll('/', '\\'));

      // 1. Birincil Strateji: KaraDelikNotifier.exe /open (Yerel Win32 Shell API: SHOpenFolderAndSelectItems & ILCreateFromPathW)
      try {
        final exeDir = path_lib.dirname(Platform.resolvedExecutable);
        String notifierPath = path_lib.join(exeDir, 'KaraDelikNotifier.exe');
        if (!File(notifierPath).existsSync()) {
          notifierPath = path_lib.join(Directory.current.path, 'windows', 'bin', 'KaraDelikNotifier.exe');
        }
        if (File(notifierPath).existsSync()) {
          final proc = await Process.start(
            notifierPath,
            ['/open', normalized],
            mode: ProcessStartMode.detached,
          );
          if (proc.pid > 0) return;
        }
      } catch (e) {
        debugPrint('KaraDelikNotifier /open hatası: $e');
      }

      // 2. İkincil Strateji: Doğrudan C:\Windows\explorer.exe (Mutlak yol, CreateProcessW)
      try {
        final winDir = Platform.environment['WINDIR'] ?? r'C:\Windows';
        final explorerPath = path_lib.join(winDir, 'explorer.exe');
        final targetPath = File(explorerPath).existsSync() ? explorerPath : 'explorer.exe';

        if (await File(normalized).exists()) {
          final p = await Process.start(
            targetPath,
            ['/select,$normalized'],
            mode: ProcessStartMode.detached,
          );
          if (p.pid > 0) return;
        } else {
          final isDir = await Directory(normalized).exists();
          final targetDir = isDir ? normalized : path_lib.dirname(normalized);
          final p = await Process.start(
            targetPath,
            [targetDir],
            mode: ProcessStartMode.detached,
          );
          if (p.pid > 0) return;
        }
      } catch (e) {
        debugPrint('Doğrudan explorer.exe hatası: $e');
      }

      // 3. Üçüncül Strateji: Bypass Shell Start (cmd.exe /c start "" "{dizin}")
      try {
        String targetDir = normalized;
        if (await File(normalized).exists()) {
          targetDir = path_lib.dirname(normalized);
        } else if (!await Directory(normalized).exists()) {
          final parent = path_lib.dirname(normalized);
          if (await Directory(parent).exists()) {
            targetDir = parent;
          } else {
            final userProfile = Platform.environment['USERPROFILE'];
            targetDir = userProfile != null ? '$userProfile\\Downloads' : normalized;
          }
        }

        await Process.start(
          'cmd.exe',
          ['/c', 'start', '""', targetDir],
          mode: ProcessStartMode.detached,
        );
      } catch (e) {
        debugPrint('Bypass Shell Start hatası: $e');
      }
    } catch (e) {
      debugPrint('Klasör açılırken genel hata: $e');
    }
  }

  /// Windows SaveFileDialog ile kullanıcının istediği farklı bir klasöre dosyayı kaydeder
  Future<String?> saveAsDifferentFile(DownloadedItem item) async {
    if (!Platform.isWindows) return null;
    try {
      final srcFile = File(item.filePath);
      if (!await srcFile.exists()) return null;

      final safeName = item.fileName.replaceAll('"', '');
      final script = '''
Add-Type -AssemblyName System.Windows.Forms
\$sfd = New-Object System.Windows.Forms.SaveFileDialog
\$sfd.Title = "KaraDelik: Videoyu Farkli Klasore Kaydet"
\$sfd.FileName = "$safeName"
\$sfd.Filter = "Medya Dosyasi (*.mp4;*.mp3)|*.mp4;*.mp3|Tum Dosyalar (*.*)|*.*"
if (\$sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.Write(\$sfd.FileName)
}
''';

      final res = await Process.run('powershell', ['-NoProfile', '-Command', script]);
      final destination = res.stdout.toString().trim();
      if (destination.isNotEmpty && destination != item.filePath) {
        final destFile = await srcFile.copy(destination);
        await addItem(destFile.path, url: item.url);
        return destFile.path;
      }
    } catch (e) {
      debugPrint('Farklı kaydetme hatası: $e');
    }
    return null;
  }
}
