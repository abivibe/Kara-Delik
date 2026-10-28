import 'package:flutter_test/flutter_test.dart';
import 'package:karadelik/services/ytdlp_extra_service.dart';

void main() {
  test('YouTube explicitly enables the bundled JavaScript runtime', () {
    expect(
        YtDlpExtraService.getExtraArgsForUrl(
            'https://www.youtube.com/watch?v=faHM7E6Yz5E'),
        contains('--js-runtimes'));
    expect(
        YtDlpExtraService.getExtraArgsForUrl(
            'https://www.instagram.com/reel/abc/'),
        isEmpty);
  });
  test('normalizes Instagram reels without damaging signed CDN URLs', () {
    expect(
        YtDlpExtraService.normalizeUrl(
            'https://www.instagram.com/reels/DfA4UOGKbYT/?igsh=abc'),
        'https://www.instagram.com/reel/DfA4UOGKbYT/');
    const cdn =
        'https://scontent.cdninstagram.com/video.mp4?token=abc&expires=123';
    expect(YtDlpExtraService.normalizeUrl(cdn), cdn);
  });
  test('validates platform hosts instead of substrings', () {
    expect(
        YtDlpExtraService.isSupportedPlatform('https://x.com/user/status/123'),
        isTrue);
    expect(
        YtDlpExtraService.isSupportedPlatform(
            'https://example.com/?url=instagram.com'),
        isFalse);
    expect(
        YtDlpExtraService.isSupportedPlatform(
            'https://instagram.com.example.org/reel/abc'),
        isFalse);
  });
}
