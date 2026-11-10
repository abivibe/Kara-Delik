import 'package:flutter_test/flutter_test.dart';
import 'package:karadelik/services/youtube_title_resolver.dart';

void main() {
  test('falls back when primary metadata is unavailable', () async {
    final title = await resolveYouTubeTitle([
      () async => null,
      () async => '  Original title  ',
    ]);
    expect(title, 'Original title');
  });
  test('ignores errors and blank titles', () async {
    final title = await resolveYouTubeTitle([
      () async => throw Exception('unavailable'),
      () async => '',
      () async => 'Actual title',
    ]);
    expect(title, 'Actual title');
  });
}
