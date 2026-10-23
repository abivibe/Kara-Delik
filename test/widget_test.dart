import 'package:flutter_test/flutter_test.dart';
import 'package:karadelik/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const KaraDelikApp());
    expect(find.text('KaraDelik'), findsOneWidget);
  });
}
