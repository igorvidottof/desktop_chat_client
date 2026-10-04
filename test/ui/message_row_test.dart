import 'package:desktop_chat_client/domain/models/models.dart';
import 'package:desktop_chat_client/ui/chat/widgets/message_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

MessageSummary message(
  String id,
  int time, {
  String sender = '@igor:example.org',
}) => MessageSummary(
  id: id,
  senderId: sender,
  body: 'Texto $id',
  timestampMs: time,
  isOwn: true,
);

void main() {
  final start = DateTime(2026, 10, 4, 12).millisecondsSinceEpoch;

  testWidgets('Agrupa remetente e preserva texto, horário e identidade', (
    tester,
  ) async {
    final first = message('primeira', start);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: Column(
              children: [
                MessageRow(message: first),
                MessageRow(
                  message: message('segunda', start + 60000),
                  previous: first,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(CircleAvatar), findsOneWidget);
    expect(find.text('igor'), findsOneWidget);
    expect(find.byTooltip('@igor:example.org'), findsOneWidget);
    expect(find.text('Texto primeira'), findsOneWidget);
    expect(find.text('Texto segunda'), findsOneWidget);
    expect(find.text('12:00'), findsNothing);
    expect(find.text('12:01'), findsNothing);
    expect(find.byType(Divider), findsNothing);
    expect(
      tester.getTopLeft(find.text('Texto primeira')).dx,
      tester.getTopLeft(find.text('Texto segunda')).dx,
    );
    expect(tester.takeException(), isNull);
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    await pointer.moveTo(tester.getCenter(find.text('Texto segunda')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('12:01'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('12:01')).dx,
      lessThan(tester.getTopLeft(find.text('Texto segunda')).dx),
    );
    await pointer.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.text('12:01'), findsNothing);
    await pointer.removePointer();
  });

  for (final entry
      in {
        'outro remetente': message(
          'nova',
          start + 60000,
          sender: '@ana:example.org',
        ),
        'intervalo longo': message('nova', start + 300001),
        'horário anterior': message('nova', start - 1),
        'data inválida': message('nova', 9007199254740991),
        'outro dia': message(
          'nova',
          DateTime(2026, 10, 5).millisecondsSinceEpoch,
        ),
      }.entries) {
    testWidgets('Novo grupo após ${entry.key}', (tester) async {
      final previousTime =
          entry.key == 'outro dia'
              ? DateTime(2026, 10, 4, 23, 59).millisecondsSinceEpoch
              : start;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageRow(
              message: entry.value,
              previous: message('anterior', previousTime),
            ),
          ),
        ),
      );
      expect(find.byType(CircleAvatar), findsOneWidget);
      expect(find.byType(Divider), findsOneWidget);
      expect(find.text('Texto nova'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
