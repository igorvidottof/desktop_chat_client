import 'dart:async';

import 'support/bridge_harness.dart';
import 'package:desktop_chat_client/src/rust/api/simple.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const restoredAccount = AccountSummary(
  userId: '@fixture:example.invalid',
  deviceId: 'SYNTHETIC_DEVICE',
  homeserverAddress: 'https://example.invalid/',
);

Widget startupApp(
  SessionInitializer initialize, {
  Future<List<ConversationSummary>> Function()? rooms,
}) => fixtureApp(
  logoutAction: () async => throw LogoutError.internal,
  initialize: initialize,
  probe: (_) async => throw ProbeError.internal,
  authenticate: (_, _, _) async => restoredAccount,
  loadConversations: rooms ?? () async => [],
);

void main() {
  testWidgets('Startup pendente não mostra formulário nem carrega salas', (
    tester,
  ) async {
    final pending = Completer<SessionState>();
    var roomCalls = 0;
    await tester.pumpWidget(
      startupApp(
        () => pending.future,
        rooms: () async {
          roomCalls++;
          return [];
        },
      ),
    );
    expect(find.text('Verificando sessão…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Entrar'), findsNothing);
    expect(roomCalls, 0);
    pending.complete(const SessionState(account: null));
    await tester.pumpAndSettle();
    expect(find.text('Entrar'), findsOneWidget);
    expect(find.text('Verificando sessão…'), findsNothing);
    expect(roomCalls, 0);
  });

  testWidgets('Restauração carrega o fluxo existente de conversas sem login', (
    tester,
  ) async {
    final pending = Completer<SessionState>();
    var calls = 0;
    await tester.pumpWidget(
      startupApp(
        () => pending.future,
        rooms: () async {
          calls++;
          return [
            const ConversationSummary(
              id: 'fixture-room',
              displayName: 'Sala restaurada',
            ),
          ];
        },
      ),
    );
    expect(find.text('Entrar'), findsNothing);
    pending.complete(const SessionState(account: restoredAccount));
    await tester.pumpAndSettle();
    expect(find.text(restoredAccount.userId), findsOneWidget);
    expect(find.text('Sala restaurada'), findsOneWidget);
    expect(find.text('Entrar'), findsNothing);
    expect(calls, 1);
  });

  for (final error in SessionError.values) {
    testWidgets('Falha segura ${error.name} oferece a ação correspondente', (
      tester,
    ) async {
      await tester.pumpWidget(startupApp(() async => throw error));
      await tester.pumpAndSettle();
      expect(find.text(sessionErrorMessage(error)), findsOneWidget);
      if (error == SessionError.invalidSession) {
        expect(find.text('Entrar'), findsOneWidget);
        expect(find.text('Tentar novamente'), findsNothing);
      } else {
        expect(find.text('Tentar novamente'), findsOneWidget);
        expect(find.text('Entrar'), findsNothing);
        expect(find.byType(TextField), findsNothing);
      }
    });
  }

  testWidgets('Falha de rede permite nova inicialização e recuperação', (
    tester,
  ) async {
    var calls = 0;
    final retry = Completer<SessionState>();
    await tester.pumpWidget(
      startupApp(() {
        if (++calls == 1) return Future.error(SessionError.network);
        return retry.future;
      }),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tentar novamente'));
    await tester.pump();
    expect(find.text('Verificando sessão…'), findsOneWidget);
    expect(find.text('Entrar'), findsNothing);
    retry.complete(const SessionState(account: restoredAccount));
    await tester.pumpAndSettle();
    expect(find.text('Conta autenticada'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets('Oculta falha inesperada e ignora resultado após dispose', (
    tester,
  ) async {
    await tester.pumpWidget(
      startupApp(() => throw StateError('untrusted native detail')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(sessionErrorMessage(SessionError.internal)),
      findsOneWidget,
    );
    expect(find.textContaining('untrusted'), findsNothing);
    final pending = Completer<SessionState>();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(startupApp(() => pending.future));
    await tester.pumpWidget(const SizedBox());
    pending.completeError(SessionError.network);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
