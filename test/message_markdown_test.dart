import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planulix/widgets/message_markdown.dart';

void main() {
  testWidgets('renders fenced code as selectable code block', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageMarkdown(
            text: 'Before\n```bash\ngit status\n```\nAfter',
            baseStyle: TextStyle(fontSize: 14),
          ),
        ),
      ),
    );

    expect(find.text('Before'), findsOneWidget);
    expect(find.text('bash'), findsOneWidget);
    expect(find.text('git status'), findsOneWidget);
    expect(find.text('After'), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsOneWidget);
  });
}
