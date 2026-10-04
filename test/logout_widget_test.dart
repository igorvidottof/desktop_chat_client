import 'dart:async';

import 'support/bridge_harness.dart';
import 'package:desktop_chat_client/src/rust/api/simple.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const account = AccountSummary(
  userId: '@fixture:example.invalid',
  deviceId: 'SYNTHETIC_DEVICE',
  homeserverAddress: 'https://example.invalid/',
);
const room = ConversationSummary(
  id: 'synthetic-room',
  displayName: 'Sala antiga',
);

Widget logoutApp({
  required Future<LogoutResult> Function() logout,
  Future<List<ConversationSummary>> Function()? rooms,
  SessionInitializer? initialize,
}) => fixtureApp(
  initialize: initialize ?? () async => const SessionState(account: account),
  logoutAction: logout,
  probe: (_) async => throw ProbeError.internal,
  authenticate: (_, _, _) async => account,
  loadConversations: rooms ?? () async => [room],
);

void main() {
  testWidgets('Logout aparece somente para conta autenticada', (tester) async {
    await tester.pumpWidget(
      logoutApp(
        logout: () async => throw LogoutError.internal,
        initialize: () async => const SessionState(account: null),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Logout'), findsNothing);
    expect(find.text('Entrar'), findsOneWidget);
  });

  for (final status in RemoteLogoutStatus.values) {
    testWidgets('Saída local com ${status.name} limpa conta e salas', (
      tester,
    ) async {
      final pending = Completer<LogoutResult>();
      var calls = 0;
      await tester.pumpWidget(
        logoutApp(
          logout: () {
            calls++;
            return pending.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sala antiga'), findsOneWidget);
      final logoutButton =
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Logout'))
              .onPressed!;
      await tester.tap(find.text('Logout'));
      await tester.pump();
      expect(find.text('Saindo da sua conta…'), findsOneWidget);
      expect(find.text('Encerrando a sincronização…'), findsOneWidget);
      expect(find.text('Sala antiga'), findsNothing);
      expect(find.text('Logout'), findsNothing);
      expect(find.text(account.userId), findsNothing);
      expect(find.text('Verificar servidor'), findsNothing);
      // Mesmo um callback capturado antes do rebuild respeita a reserva existente.
      logoutButton();
      expect(calls, 1);
      pending.complete(
        LogoutResult(remoteStatus: status, storeCleanupPending: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('Entrar'), findsOneWidget);
      expect(find.text(account.userId), findsNothing);
      expect(find.text('Sala antiga'), findsNothing);
      expect(find.text('Logout'), findsNothing);
      final confirmed =
          status == RemoteLogoutStatus.confirmed ||
          status == RemoteLogoutStatus.alreadyInvalid;
      expect(
        find.textContaining('Não foi possível confirmar a saída no servidor'),
        confirmed ? findsNothing : findsOneWidget,
      );
    });
  }

  testWidgets('Espera longa gira texto local e mantém uma única saída', (
    tester,
  ) async {
    final pending = Completer<LogoutResult>();
    var calls = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      logoutApp(
        logout: () {
          calls++;
          return pending.future;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    await tester.pump();
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .value,
      isNull,
    );
    expect(
      find.bySemanticsLabel(
        'Saindo da sua conta. Aguarde o encerramento da sessão.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 4999));
    expect(find.text('Encerrando a sincronização…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('Finalizando operações em andamento…'), findsOneWidget);
    for (final message in [
      'Protegendo os dados da sua sessão…',
      'Só mais alguns instantes…',
      'Finalizando com segurança…',
      'Finalizando operações em andamento…',
      'Protegendo os dados da sua sessão…',
    ]) {
      await tester.pump(const Duration(seconds: 5));
      expect(find.text(message), findsOneWidget);
      expect(find.text('Encerrando a sincronização…'), findsNothing);
    }
    expect(calls, 1);
    pending.complete(
      const LogoutResult(
        remoteStatus: RemoteLogoutStatus.confirmed,
        storeCleanupPending: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Entrar'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(calls, 1);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('Falha após rotação cancela espera e retry reinicia texto', (
    tester,
  ) async {
    final first = Completer<LogoutResult>();
    final second = Completer<LogoutResult>();
    var calls = 0;
    await tester.pumpWidget(
      logoutApp(logout: () => ++calls == 1 ? first.future : second.future),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Protegendo os dados da sua sessão…'), findsOneWidget);
    first.completeError(LogoutError.localCleanup);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    expect(
      find.text(logoutErrorMessage(LogoutError.localCleanup)),
      findsOneWidget,
    );
    expect(find.text(account.userId), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(calls, 1);
    await tester.tap(find.text('Logout'));
    await tester.pump();
    expect(find.text('Encerrando a sincronização…'), findsOneWidget);
    expect(calls, 2);
    second.complete(
      const LogoutResult(
        remoteStatus: RemoteLogoutStatus.confirmed,
        storeCleanupPending: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Entrar'), findsOneWidget);
  });

  for (final error in [
    LogoutError.secureStorage,
    LogoutError.localCleanup,
    LogoutError.internal,
  ]) {
    testWidgets('Falha ${error.name} preserva conta e permite retry', (
      tester,
    ) async {
      var calls = 0;
      await tester.pumpWidget(
        logoutApp(
          logout: () async {
            if (++calls == 1) throw error;
            return const LogoutResult(
              remoteStatus: RemoteLogoutStatus.alreadyInvalid,
              storeCleanupPending: false,
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Logout'));
      await tester.pumpAndSettle();
      expect(find.text(logoutErrorMessage(error)), findsOneWidget);
      expect(find.text(account.userId), findsOneWidget);
      expect(find.text('Entrar'), findsNothing);
      await tester.tap(find.text('Logout'));
      await tester.pumpAndSettle();
      expect(find.text('Entrar'), findsOneWidget);
      expect(find.text(account.userId), findsNothing);
      expect(find.text(logoutErrorMessage(error)), findsNothing);
    });
  }

  testWidgets(
    'Resultado antigo de salas não reaparece após saída e novo login',
    (tester) async {
      final rooms = Completer<List<ConversationSummary>>();
      var loads = 0;
      await tester.pumpWidget(
        logoutApp(
          logout:
              () async => const LogoutResult(
                remoteStatus: RemoteLogoutStatus.confirmed,
                storeCleanupPending: true,
              ),
          rooms: () => ++loads == 1 ? rooms.future : Future.value([]),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Logout'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'remoção dos dados locais restantes ficou pendente',
        ),
        findsNothing,
      );
      expect(find.text('Entrar'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(1), 'fixture');
      await tester.enterText(
        find.byType(TextField).at(2),
        'synthetic-password',
      );
      await tester.tap(find.text('Entrar'));
      await tester.pumpAndSettle();
      rooms.complete([room]);
      await tester.pumpAndSettle();
      expect(find.text('Sala antiga'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Conclusão após descarte e falha inesperada não vazam detalhes', (
    tester,
  ) async {
    final pending = Completer<LogoutResult>();
    await tester.pumpWidget(logoutApp(logout: () => pending.future));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
    expect(tester.takeException(), isNull);
    pending.completeError(StateError('synthetic-private-detail'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('synthetic-private-detail'), findsNothing);
  });

  testWidgets('Conta ausente em Rust reconcilia startup após Logout', (
    tester,
  ) async {
    var starts = 0;
    await tester.pumpWidget(
      logoutApp(
        initialize:
            () async => SessionState(account: ++starts == 1 ? account : null),
        logout: () async => throw LogoutError.notAuthenticated,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    await tester.pumpAndSettle();
    expect(find.text('Entrar'), findsOneWidget);
    expect(find.text(account.userId), findsNothing);
  });
}
