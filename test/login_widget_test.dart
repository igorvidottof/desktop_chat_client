import 'dart:async';

import 'package:desktop_chat_client/main.dart';
import 'package:desktop_chat_client/src/rust/api/simple.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const account = AccountSummary(
  userId: '@fixture:example.invalid',
  deviceId: 'FIXTURE_DEVICE',
  homeserverAddress: 'https://example.invalid/',
);

Finder field(String label) => find.widgetWithText(TextField, label);

Widget loginApp(PasswordLogin authenticate) => MyApp(
  loadConversations: () async => [],
  probe: (_) async => throw ProbeError.internal,
  authenticate: authenticate,
);

Future<void> fillForm(WidgetTester tester) async {
  await tester.enterText(
    field('URL HTTPS do homeserver'),
    'https://example.invalid',
  );
  await tester.enterText(field('Usuário ou ID Matrix'), 'fixture');
  // Marcador sintético para o fake; não pertence a uma conta ou serviço real.
  await tester.enterText(field('Senha'), 'synthetic-input');
}

void main() {
  testWidgets('Senha oculta com semântica de autofill e sem sugestões', (
    tester,
  ) async {
    await tester.pumpWidget(loginApp((_, _, _) async => account));
    final password = tester.widget<TextField>(field('Senha'));
    expect(password.obscureText, isTrue);
    expect(password.autofillHints, [AutofillHints.password]);
    expect(password.autocorrect, isFalse);
    expect(password.enableSuggestions, isFalse);
    expect(
      tester.widget<AutofillGroup>(find.byType(AutofillGroup)).onDisposeAction,
      AutofillContextAction.cancel,
    );
  });

  testWidgets(
    'Envia dados ao fake, limpa senha e mostra apenas resumo seguro',
    (tester) async {
      final pending = Completer<AccountSummary>();
      var calls = 0;
      await tester.pumpWidget(
        loginApp((address, username, password) {
          calls++;
          expect(address, 'https://example.invalid');
          expect(username, 'fixture');
          expect(password, 'synthetic-input');
          return pending.future;
        }),
      );
      await fillForm(tester);
      final controller = tester.widget<TextField>(field('Senha')).controller!;
      await tester.tap(find.text('Entrar'));
      await tester.pump();
      expect(controller.text, isEmpty);
      expect(find.text('Autenticando…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      for (final button in tester.widgetList<FilledButton>(
        find.byType(FilledButton),
      )) {
        expect(button.onPressed, isNull);
      }
      await tester.tap(find.text('Entrar'));
      expect(calls, 1);
      pending.complete(account);
      await tester.pumpAndSettle();
      expect(find.text('Conta autenticada'), findsOneWidget);
      expect(find.text(account.userId), findsOneWidget);
      expect(find.text('Dispositivo: ${account.deviceId}'), findsOneWidget);
      expect(find.text(account.homeserverAddress), findsOneWidget);
      expect(find.text('Entrar'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(controller.text, isEmpty);
    },
  );

  for (final error in LoginError.values) {
    testWidgets(
      'Falha ${error.name} mostra mensagem segura e libera nova tentativa',
      (tester) async {
        await tester.pumpWidget(loginApp((_, _, _) async => throw error));
        await fillForm(tester);
        await tester.tap(find.text('Entrar'));
        await tester.pumpAndSettle();
        expect(find.text(loginErrorMessage(error)), findsOneWidget);
        expect(
          tester.widget<TextField>(field('Senha')).controller!.text,
          isEmpty,
        );
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Entrar'))
              .onPressed,
          isNotNull,
        );
        expect(find.text('Conta autenticada'), findsNothing);
      },
    );
  }

  testWidgets('Nova tentativa remove erro anterior e pode autenticar', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      loginApp((_, _, _) async {
        if (++calls == 1) throw LoginError.invalidCredentials;
        return account;
      }),
    );
    await fillForm(tester);
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Senha'), 'synthetic-input');
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle();
    expect(
      find.text(loginErrorMessage(LoginError.invalidCredentials)),
      findsNothing,
    );
    expect(find.text('Conta autenticada'), findsOneWidget);
  });

  testWidgets(
    'Falha síncrona inesperada da ponte não mostra detalhes nem retém senha',
    (tester) async {
      await tester.pumpWidget(
        loginApp((_, _, _) => throw StateError('untrusted fixture detail')),
      );
      await fillForm(tester);
      await tester.tap(find.text('Entrar'));
      await tester.pumpAndSettle();
      expect(find.text(loginErrorMessage(LoginError.internal)), findsOneWidget);
      expect(find.textContaining('untrusted'), findsNothing);
      expect(
        tester.widget<TextField>(field('Senha')).controller!.text,
        isEmpty,
      );
    },
  );

  for (final succeeds in [true, false]) {
    testWidgets('Ignora conclusão de login após fechar a tela ($succeeds)', (
      tester,
    ) async {
      final pending = Completer<AccountSummary>();
      await tester.pumpWidget(loginApp((_, _, _) => pending.future));
      await fillForm(tester);
      await tester.tap(find.text('Entrar'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      if (succeeds) {
        pending.complete(account);
      } else {
        pending.completeError(LoginError.network);
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
