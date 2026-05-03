import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planulix/main.dart';

void main() {
  testWidgets('Planulix app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const PlanulixApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(MaterialApp), findsOneWidget);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'Planulix');
  });
}
