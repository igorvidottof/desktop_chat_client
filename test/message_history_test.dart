import 'dart:async';

import 'package:desktop_chat_client/main.dart';
import 'package:desktop_chat_client/conversation_list.dart';
import 'package:desktop_chat_client/conversation_screen.dart';
import 'package:desktop_chat_client/src/rust/api/simple.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const room = ConversationSummary(
  id: 'opaque / ? #',
  displayName: 'Sala de teste',
);

MessageSummary message(String id, String body, bool own, int time) =>
    MessageSummary(
      id: id,
      senderId: own ? '@me:example.org' : '@other:example.org',
      body: body,
      timestampMs: time,
      isOwn: own,
    );

Widget screen(MessageHistoryLoader load, ValueNotifier<bool> active) =>
    MaterialApp(
      home: ConversationScreen(
        conversation: room,
        load: load,
        sessionActive: active,
      ),
    );

void main() {
  test('Timestamp fora do intervalo não derruba apresentação', () {
    expect(messageTimestamp(9007199254740991), 'Data indisponível');
  });
  testWidgets('Seleção preserva ID, carregamento e lista ao voltar', (
    tester,
  ) async {
    var roomCalls = 0;
    String? received;
    final pending = Completer<List<MessageSummary>>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationList(
            load: () async {
              roomCalls++;
              return [room];
            },
            loadHistory: ({required conversationId}) {
              received = conversationId;
              return pending.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(room.displayName));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(received, room.id);
    expect(
      find.descendant(
        of: find.byType(ConversationScreen),
        matching: find.text(room.displayName),
      ),
      findsOneWidget,
    );
    expect(find.text('Carregando mensagens…'), findsOneWidget);
    pending.complete([
      message('old', "<script>alert('test')</script>", false, 1000),
      message('new', 'Mensagem 2', true, 2000),
    ]);
    await tester.pumpAndSettle();
    expect(find.text("<script>alert('test')</script>"), findsOneWidget);
    expect(find.text('@other:example.org'), findsOneWidget);
    expect(find.text('@me:example.org'), findsOneWidget);
    expect(find.text(messageTimestamp(1000)), findsOneWidget);
    expect(
      tester.getTopLeft(find.text("<script>alert('test')</script>")).dy,
      lessThan(tester.getTopLeft(find.text('Mensagem 2')).dy),
    );
    expect(
      tester.widget<Align>(find.byKey(const ValueKey('old'))).alignment,
      Alignment.centerLeft,
    );
    expect(
      tester.widget<Align>(find.byKey(const ValueKey('new'))).alignment,
      Alignment.centerRight,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text(room.displayName), findsOneWidget);
    expect(roomCalls, 1);
  });

  testWidgets('Distingue vazio de carregamento', (tester) async {
    final active = ValueNotifier(true);
    final pending = Completer<List<MessageSummary>>();
    await tester.pumpWidget(
      screen(({required conversationId}) => pending.future, active),
    );
    expect(find.text('Nenhuma mensagem ainda.'), findsNothing);
    pending.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('Nenhuma mensagem ainda.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    active.dispose();
  });

  for (final error in MessageHistoryError.values) {
    testWidgets('Erro seguro ${error.name} e retry apropriado', (tester) async {
      final active = ValueNotifier(true);
      var calls = 0;
      final pending = Completer<List<MessageSummary>>();
      await tester.pumpWidget(
        screen(({required conversationId}) {
          expect(conversationId, room.id);
          if (++calls == 1) return Future.error(error);
          return pending.future;
        }, active),
      );
      await tester.pumpAndSettle();
      expect(find.text(messageHistoryErrorMessage(error)), findsOneWidget);
      expect(find.text('Nenhuma mensagem ainda.'), findsNothing);
      if (historyRetryable(error)) {
        await tester.tap(find.text('Tentar novamente'));
        await tester.pump();
        expect(calls, 2);
        expect(find.text('Tentar novamente'), findsNothing);
        expect(find.text('Carregando mensagens…'), findsOneWidget);
        pending.complete([message('ok', 'Recuperada', false, 0)]);
        await tester.pumpAndSettle();
        expect(find.text('Recuperada'), findsOneWidget);
      } else {
        expect(find.text('Tentar novamente'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      active.dispose();
    });
  }

  testWidgets('Detalhes inesperados da ponte não aparecem', (tester) async {
    final active = ValueNotifier(true);
    await tester.pumpWidget(
      screen(
        ({required conversationId}) => throw StateError('private detail'),
        active,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(messageHistoryErrorMessage(MessageHistoryError.internal)),
      findsOneWidget,
    );
    expect(find.textContaining('private detail'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    active.dispose();
  });

  for (final success in [true, false]) {
    testWidgets('Descarta conclusão após sair ($success)', (tester) async {
      final active = ValueNotifier(true);
      final pending = Completer<List<MessageSummary>>();
      await tester.pumpWidget(
        screen(({required conversationId}) => pending.future, active),
      );
      await tester.pumpWidget(const SizedBox());
      if (success) {
        pending.complete([message('old', 'Antiga', true, 0)]);
      } else {
        pending.completeError(MessageHistoryError.network);
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
      active.dispose();
    });
  }

  testWidgets(
    'Logout na aplicação invalida rota e novo login não aceita histórico antigo',
    (tester) async {
      final pending = Completer<List<MessageSummary>>();
      const account = AccountSummary(
        userId: '@me:example.org',
        deviceId: 'SYNTHETIC',
        homeserverAddress: 'https://example.invalid',
      );
      await tester.pumpWidget(
        MyApp(
          initialize: () async => const SessionState(account: account),
          logoutAction:
              () async => const LogoutResult(
                remoteStatus: RemoteLogoutStatus.confirmed,
                storeCleanupPending: false,
              ),
          probe: (_) async => throw ProbeError.internal,
          authenticate: (_, _, _) async => account,
          loadConversations: () async => [room],
          loadHistory: ({required conversationId}) => pending.future,
        ),
      );
      await tester.pumpAndSettle();
      final logout =
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Logout'))
              .onPressed!;
      await tester.tap(find.text(room.displayName));
      await tester.pump();
      // Simula logout por outro chamador enquanto a rota de histórico está aberta.
      logout();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.text(
          messageHistoryErrorMessage(MessageHistoryError.notAuthenticated),
        ),
        findsOneWidget,
      );
      pending.complete([message('old', 'Conta anterior', true, 0)]);
      await tester.pumpAndSettle();
      expect(find.text('Conta anterior'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Entrar'));
      await tester.pumpAndSettle();
      expect(find.text('Conta anterior'), findsNothing);
      expect(find.text(room.displayName), findsOneWidget);
    },
  );

  testWidgets('Logout apaga retrato e descarta resultado antigo', (
    tester,
  ) async {
    final active = ValueNotifier(true);
    final pending = Completer<List<MessageSummary>>();
    await tester.pumpWidget(
      screen(({required conversationId}) => pending.future, active),
    );
    active.value = false;
    await tester.pump();
    pending.complete([message('old', 'Conta antiga', true, 0)]);
    await tester.pumpAndSettle();
    expect(find.text('Conta antiga'), findsNothing);
    expect(
      find.text(
        messageHistoryErrorMessage(MessageHistoryError.notAuthenticated),
      ),
      findsOneWidget,
    );
    expect(find.text('Tentar novamente'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    active.dispose();
  });
}
