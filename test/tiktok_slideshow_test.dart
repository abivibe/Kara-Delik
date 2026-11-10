import 'package:flutter_test/flutter_test.dart';
import 'package:karadelik/services/download_service.dart';
import 'package:karadelik/services/tiktok_slideshow.dart';

void main() {
  test('photo URLs retain the complete post path', () {
    expect(DownloadService().extractSupportedUrl('https://www.tiktok.com/@ustura0620/photo/7706267344229747988?_r=1'), 'https://www.tiktok.com/@ustura0620/photo/7706267344229747988');
  });
  test('photo response keeps every image and the music', () {
    final post = TikTokSlideshow.fromApi({'images': ['https://example.com/1.jpg', 'https://example.com/2.jpg'], 'music': 'https://example.com/a.mp3'});
    expect(post!.images.length, 2);
    expect(post.audioUrl, 'https://example.com/a.mp3');
    expect(TikTokSlideshow.fromApi({'play': 'https://example.com/video.mp4'}), isNull);
  });
}
