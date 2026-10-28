import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karadelik/services/download_service.dart';

// Explicitly enabled: real network transfers and full FFmpeg decode checks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Widget bindings block HTTP by default; these opt-in tests require real IO.
  HttpOverrides.global = null;
  const links = <String, String>{
    'youtube':
        'https://www.youtube.com/watch?v=faHM7E6Yz5E&pp=ugUEEgJ0cg%3D%3D',
    'shorts': 'https://www.youtube.com/shorts/3LFa5au0vM8',
    'instagram': 'https://www.instagram.com/reels/DfA4UOGKbYT/',
    'tiktok':
        'https://www.tiktok.com/@fikrikereviz5/video/7700335817755036948?lang=tr-TR',
    'x': 'https://x.com/bpthaber/status/2115388667195785438/video/1',
    'facebook': 'https://www.facebook.com/facebook/videos/671204259264003/',
  };
  final enabled = Platform.environment['KARADELIK_LIVE_TEST'] == '1';
  final repeats =
      int.tryParse(Platform.environment['KARADELIK_REPEATS'] ?? '') ?? 2;
  final selected = Platform.environment['KARADELIK_PLATFORM'];
  final root = Directory(
          Platform.environment['KARADELIK_TEST_ROOT'] ?? 'output/live-tests')
      .absolute
    ..createSync(recursive: true);
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (_) async => root.path);

  for (var round = 1; round <= repeats; round++) {
    for (final entry in links.entries) {
      if (selected != null && entry.key != selected) continue;
      for (final quality in DownloadQuality.values) {
        test('${entry.key} ${quality.name} round $round', () async {
          final dir =
              Directory('${root.path}/${entry.key}/${quality.name}/$round')
                ..createSync(recursive: true);
          final service = DownloadService()..customDownloadPath = dir.path;
          final watch = Stopwatch()..start();
          final result = <String, dynamic>{
            'platform': entry.key,
            'format': quality.name,
            'round': round,
            'url': entry.value,
          };
          try {
            final filePath = await service.startDownload(
              targetUrl: entry.value,
              quality: quality,
              onProgress: (progress, text, {speed, eta}) {
                if (progress < .3 || progress >= .96) {
                  // ignore: avoid_print
                  print('${entry.key}: $text');
                }
              },
            );
            expect(filePath.endsWith('.${quality.name}'), isTrue);
            final file = File(filePath);
            expect(await file.length(), greaterThan(1024));
            final ffmpeg = File('windows/bin/ffmpeg.exe').absolute.path;
            final probe = await Process.run(
                File('windows/bin/ffprobe.exe').absolute.path, [
              '-v',
              'error',
              '-select_streams',
              'v:0',
              '-show_entries',
              'stream=codec_name',
              '-of',
              'csv=p=0',
              filePath
            ]);
            final hardwareAv1 =
                Platform.environment['KARADELIK_HW_DECODE'] == '1' &&
                    probe.stdout.toString().trim() == 'av1';
            final decode = await Process.run(ffmpeg, [
              '-hide_banner',
              '-nostdin',
              '-v',
              'info',
              '-xerror',
              if (hardwareAv1) ...['-hwaccel', 'cuda', '-c:v', 'av1_cuvid'],
              '-i',
              filePath,
              '-map',
              '0:a:0',
              if (!quality.isAudioOnly) ...['-map', '0:v:0'],
              '-f',
              'null',
              '-',
            ]).timeout(const Duration(minutes: 10));
            await File('${dir.path}/decode.txt')
                .writeAsString('${decode.stderr}');
            expect(decode.exitCode, 0, reason: '${decode.stderr}');
            if (quality.isAudioOnly) {
              expect('${decode.stderr}', contains('Audio: mp3'));
            } else {
              expect('${decode.stderr}', contains('Video:'));
              final header = await file.openRead(0, 12).first;
              expect(ascii.decode(header.sublist(4, 8)), 'ftyp');
            }
            result.addAll({
              'passed': true,
              'path': filePath,
              'bytes': await file.length()
            });
          } catch (e) {
            result.addAll({'passed': false, 'error': '$e'});
            rethrow;
          } finally {
            result['elapsedSeconds'] = watch.elapsed.inSeconds;
            await File('${dir.path}/result.json').writeAsString(
              const JsonEncoder.withIndent('  ').convert(result),
            );
            service.cancelDownload();
          }
        }, skip: !enabled, timeout: const Timeout(Duration(minutes: 25)));
      }
    }
  }

  test(
      'cancel before native launch releases download lock and leaves no output',
      () async {
    final dir = Directory('${root.path}/cancel')..createSync(recursive: true);
    final service = DownloadService()..customDownloadPath = dir.path;
    var cancelled = false;
    await expectLater(
        service.startDownload(
          targetUrl: links['instagram']!,
          quality: DownloadQuality.mp4,
          onProgress: (progress, text, {speed, eta}) {
            if (!cancelled && text == 'İndirme motoru bağlanıyor...') {
              cancelled = true;
              service.cancelDownload();
              expect(service.isDownloading, isTrue);
            }
          },
        ),
        throwsException);
    expect(cancelled, isTrue);
    expect(service.isDownloading, isFalse);
    expect(dir.listSync(), isEmpty);
  }, skip: !enabled);
}
