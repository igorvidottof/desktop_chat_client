import 'dart:async';

import 'package:desktop_chat_client/conversation_list.dart';
import 'package:desktop_chat_client/main.dart';
import 'package:desktop_chat_client/src/rust/api/simple.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget roomsApp(ConversationLoader load) =>
    MaterialApp(home: Scaffold(body: ConversationList(load: load)));

void main() {
  testWidgets('Distingue carregamento de lista vazia bem-sucedida', (
    tester,
  ) async {
    final pending = Completer<List<ConversationSummary>>();
    await tester.pumpWidget(roomsApp(() => pending.future));
    expect(find.text('Carregando conversas…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('Nenhuma conversa'), findsNothing);
    pending.complete([]);
    await tester.pumpAndSettle();
    expect(find.textContaining('Nenhuma conversa'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Tentar novamente'), findsNothing);
  });

  testWidgets('Exibe nomes como texto e usa identificadores opacos', (
    tester,
  ) async {
    await tester.pumpWidget(
      roomsApp(
        () async => [
          const ConversationSummary(
            id: 'opaque / ? #',
            displayName: '<b>Sala</b>',
          ),
          const ConversationSummary(id: 'other', displayName: 'Sala sem nome'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('<b>Sala</b>'), findsOneWidget);
    expect(find.byKey(const ValueKey('opaque / ? #')), findsOneWidget);
    expect(find.text('opaque / ? #'), findsNothing);
    expect(find.text('Sala sem nome'), findsOneWidget);
  });

  for (final error in ConversationError.values) {
    testWidgets('Erro ${error.name} seguro e nova tentativa', (tester) async {
      var calls = 0;
      final retry = Completer<List<ConversationSummary>>();
      await tester.pumpWidget(
        roomsApp(() {
          if (++calls == 1) return Future.error(error);
          return retry.future;
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text(conversationErrorMessage(error)), findsOneWidget);
      expect(find.textContaining('Nenhuma conversa'), findsNothing);
      await tester.tap(find.text('Tentar novamente'));
      await tester.pump();
      expect(calls, 2);
      expect(find.text(conversationErrorMessage(error)), findsNothing);
      expect(find.text('Carregando conversas…'), findsOneWidget);
      expect(find.text('Tentar novamente'), findsNothing);
      retry.complete([
        const ConversationSummary(id: 'opaque', displayName: 'Sala de teste'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Sala de teste'), findsOneWidget);
    });
  }

  testWidgets('Falha inesperada não expõe detalhes da ponte', (tester) async {
    await tester.pumpWidget(
      roomsApp(() => throw StateError('untrusted remote detail')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(conversationErrorMessage(ConversationError.internal)),
      findsOneWidget,
    );
    expect(find.textContaining('untrusted'), findsNothing);
  });

  for (final succeeds in [true, false]) {
    testWidgets('Ignora conclusão após fechar a tela ($succeeds)', (
      tester,
    ) async {
      final pending = Completer<List<ConversationSummary>>();
      await tester.pumpWidget(roomsApp(() => pending.future));
      await tester.pumpWidget(const SizedBox());
      if (succeeds) {
        pending.complete([]);
      } else {
        pending.completeError(ConversationError.network);
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Login inicia carregamento único das salas autenticadas', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MyApp(
        probe: (_) async => throw ProbeError.internal,
        authenticate:
            (_, _, _) async => const AccountSummary(
              userId: '@fixture:example.invalid',
              deviceId: 'FIXTURE',
              homeserverAddress: 'https://example.invalid/',
            ),
        loadConversations: () async {
          calls++;
          return [
            const ConversationSummary(id: 'opaque', displayName: 'Conversa'),
          ];
        },
      ),
    );
    expect(calls, 0);
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Conta autenticada'), findsOneWidget);
    expect(find.text('Conversa'), findsOneWidget);
  });
}
