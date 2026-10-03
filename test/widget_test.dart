import 'dart:async';

import 'package:desktop_chat_client/main.dart';
import 'package:desktop_chat_client/src/rust/api/simple.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Consulta o endereço e mostra carregamento e sucesso', (
    tester,
  ) async {
    final pending = Completer<ServerInfo>();
    String? received;
    await tester.pumpWidget(
      MyApp(
        probe: (address) {
          received = address;
          return pending.future;
        },
      ),
    );
    await tester.enterText(find.byType(TextField), 'https://example.org');
    await tester.tap(find.text('Verificar servidor'));
    await tester.pump();
    expect(received, 'https://example.org');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    pending.complete(
      const ServerInfo(
        serverAddress: 'https://example.org/',
        supportsPasswordLogin: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('https://example.org/'), findsOneWidget);
    expect(find.text('Login com senha: suportado'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('Remove resultado anterior e permite tentar após uma falha', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MyApp(
        probe: (_) async {
          calls++;
          if (calls > 1) throw ProbeError.network;
          return const ServerInfo(
            serverAddress: 'https://example.org/',
            supportsPasswordLogin: false,
          );
        },
      ),
    );
    await tester.tap(find.text('Verificar servidor'));
    await tester.pumpAndSettle();
    expect(find.text('Login com senha: não suportado'), findsOneWidget);
    await tester.tap(find.text('Verificar servidor'));
    await tester.pumpAndSettle();
    expect(find.text('Login com senha: não suportado'), findsNothing);
    expect(find.text(probeErrorMessage(ProbeError.network)), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  for (final error in ProbeError.values) {
    testWidgets('Apresenta mensagem segura para ${error.name}', (tester) async {
      await tester.pumpWidget(MyApp(probe: (_) async => throw error));
      await tester.tap(find.text('Verificar servidor'));
      await tester.pumpAndSettle();
      expect(find.text(probeErrorMessage(error)), findsOneWidget);
    });
  }

  testWidgets('Oculta detalhes de falhas inesperadas da ponte', (tester) async {
    await tester.pumpWidget(
      MyApp(
        probe: (_) async {
          throw StateError('sensitive remote response');
        },
      ),
    );
    await tester.tap(find.text('Verificar servidor'));
    await tester.pumpAndSettle();
    expect(find.text(probeErrorMessage(ProbeError.internal)), findsOneWidget);
    expect(find.textContaining('sensitive'), findsNothing);
  });

  testWidgets('Ignora a conclusão depois de fechar a tela', (tester) async {
    final pending = Completer<ServerInfo>();
    await tester.pumpWidget(MyApp(probe: (_) => pending.future));
    await tester.tap(find.text('Verificar servidor'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.completeError(ProbeError.network);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
