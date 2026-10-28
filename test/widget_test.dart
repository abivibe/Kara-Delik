import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:karadelik/main.dart';
import 'package:karadelik/services/update_service.dart';
import 'package:karadelik/services/localization_service.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const KaraDelikApp());
    expect(find.text('KaraDelik'), findsOneWidget);
  });
  testWidgets('Info shows the same release version as the updater',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 0.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(const KaraDelikApp());
    await tester.tap(find.byTooltip(AppLocalizations.tr('info')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('v${UpdateService.currentVersion} (AMOLED Edition)'),
        findsOneWidget);
    expect(find.text('v2.0.0 (AMOLED Edition)'), findsNothing);
  });
}
