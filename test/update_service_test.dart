import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'package:karadelik/services/update_service.dart';

void main() {
  test('release version matches the package manifest', () {
    final match = RegExp(r'^version:\s*([^+\s]+)', multiLine: true)
        .firstMatch(File('pubspec.yaml').readAsStringSync());
    expect(UpdateService.currentVersion, match?.group(1));
  });
  test('updater selects setup even when portable asset appears first', () {
    expect(
        UpdateService.selectSetupUrl([
          {
            'name': 'KaraDelik_Windows.exe',
            'browser_download_url': 'https://example.org/portable'
          },
          {
            'name': 'KaraDelik_Setup.exe',
            'browser_download_url': 'https://example.org/setup'
          },
        ]),
        'https://example.org/setup');
    expect(
        UpdateService.selectSetupUrl([
          {
            'name': 'KaraDelik_Windows.exe',
            'browser_download_url': 'https://example.org/portable'
          },
        ]),
        isNull);
  });
  test('published patch is newer, current patch does not offer itself', () {
    expect(UpdateService.isNewerVersion('v1.0.3', '1.0.2'), isTrue);
    expect(UpdateService.isNewerVersion('v1.0.3', '1.0.3'), isFalse);
  });
}
