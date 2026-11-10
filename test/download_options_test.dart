import 'package:flutter_test/flutter_test.dart';
import 'package:karadelik/services/download_service.dart';
import 'package:karadelik/services/ytdlp_extra_service.dart';

void main() {
  test('silent option selects video and requests audio removal', () {
    expect(DownloadQuality.silentVideo.isVideoOnly, isTrue);
    expect(DownloadQuality.silentVideo.isAudioOnly, isFalse);
    expect(YtDlpExtraService.formatForQuality('https://youtube.com/watch?v=x', DownloadQuality.silentVideo), 'bv*/best');
    expect(DownloadQuality.silentVideo.fileExtension, 'mp4');
  });
  test('YouTube title creates safe Windows filenames', () {
    expect(DownloadService.safeVideoTitle('Video: A/B? *test*'), 'Video_ A_B_ _test_');
    expect(DownloadService.safeVideoTitle('CON'), '_CON');
    expect(DownloadService.safeVideoTitle('...'), 'YouTube');
  });
}
