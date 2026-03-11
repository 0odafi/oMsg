import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omsg_app/main.dart';

void main() {
  testWidgets('oMsg app boots', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const ProviderScope(child: AstraMessengerApp()));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.textContaining('oMsg'), findsWidgets);
  });
}
