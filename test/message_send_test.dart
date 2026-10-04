import 'dart:async';

import 'package:desktop_chat_client/conversation_screen.dart';
import 'package:desktop_chat_client/src/rust/api/simple.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const room = ConversationSummary(id: 'opaque / ? #', displayName: 'Sala');
MessageSummary message(String id, String body) => MessageSummary(
  id: id,
  senderId: '@me:example.org',
  body: body,
  timestampMs: 1,
  isOwn: true,
);

Widget screen(
  ValueNotifier<bool> active,
  TextMessageSender send, {
  MessageHistoryLoader? load,
}) => MaterialApp(
  home: ConversationScreen(
    conversation: room,
    sessionActive: active,
    send: send,
    load: load ?? ({required conversationId}) async => [],
  ),
);
Finder get button => find.widgetWithText(FilledButton, 'Enviar');
String draft(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  testWidgets('Composer valida vazio, espaços e escalares Unicode', (
    tester,
  ) async {
    final active = ValueNotifier(true);
    await tester.pumpWidget(
      screen(
        active,
        ({required conversationId, required body}) async =>
            const SendMessageResult(eventId: r'$sent'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byType(TextField), ' \n\t');
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '🦀' * maxMessageChars);
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    await tester.enterText(
      find.byType(TextField),
      '🦀' * (maxMessageChars + 1),
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    active.dispose();
  });

  testWidgets(
    'Preserva texto, bloqueia duplicação, limpa após sucesso e recarrega uma vez',
    (tester) async {
      final active = ValueNotifier(true);
      final pending = Completer<SendMessageResult>();
      var sends = 0;
      var loads = 0;
      const body = "  primeira\n<script>alert('send-test')</script>  ";
      await tester.pumpWidget(
        screen(
          active,
          ({required conversationId, required body}) {
            expect(conversationId, room.id);
            expect(body, "  primeira\n<script>alert('send-test')</script>  ");
            sends++;
            return pending.future;
          },
          load: ({required conversationId}) async {
            loads++;
            return loads == 1
                ? [message('old', 'Anterior')]
                : [
                  message('old', 'Anterior'),
                  message(r'$sent', body),
                  message(r'$sent', body),
                ];
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), body);
      await tester.pump();
      final submit = tester.widget<FilledButton>(button).onPressed!;
      submit();
      submit();
      await tester.pump();
      expect(sends, 1);
      expect(draft(tester), body);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Enviando…'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      pending.complete(const SendMessageResult(eventId: r'$sent'));
      await tester.pumpAndSettle();
      expect(draft(tester), '');
      expect(loads, 2);
      expect(find.text(body), findsOneWidget);
      expect(find.text('Mensagem enviada.'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Anterior')).dy,
        lessThan(tester.getTopLeft(find.text(body)).dy),
      );
      await tester.pumpWidget(const SizedBox());
      active.dispose();
    },
  );

  for (final error in SendMessageError.values) {
    testWidgets(
      'Falha segura ${error.name} preserva rascunho e exige retry explícito',
      (tester) async {
        final active = ValueNotifier(true);
        var calls = 0;
        await tester.pumpWidget(
          screen(active, ({required conversationId, required body}) async {
            calls++;
            throw error;
          }),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'mensagem');
        await tester.pump();
        final controller =
            tester.widget<TextField>(find.byType(TextField)).controller!;
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(controller.text, 'mensagem');
        expect(find.text(sendMessageErrorMessage(error)), findsWidgets);
        expect(calls, 1);
        if (error != SendMessageError.encryptionUnsupported &&
            error != SendMessageError.notAuthenticated) {
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(calls, 2);
        } else {
          expect(find.byType(TextField), findsNothing);
        }
        await tester.pumpWidget(const SizedBox());
        active.dispose();
      },
    );
  }

  testWidgets(
    'Aceitação seguida de falha no histórico nunca vira falha de envio',
    (tester) async {
      final active = ValueNotifier(true);
      var loads = 0;
      var sends = 0;
      await tester.pumpWidget(
        screen(
          active,
          ({required conversationId, required body}) async {
            sends++;
            return const SendMessageResult(eventId: r'$sent');
          },
          load: ({required conversationId}) async {
            if (++loads == 2) throw MessageHistoryError.network;
            return loads == 1 ? [] : [message(r'$sent', 'Aceita')];
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Aceita');
      await tester.pump();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        find.text('Mensagem enviada. Histórico ainda não atualizado.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();
      expect(sends, 1);
      expect(draft(tester), '');
      expect(find.text('Aceita'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      active.dispose();
    },
  );

  testWidgets(
    'Histórico ainda sem evento oferece somente atualização explícita',
    (tester) async {
      final active = ValueNotifier(true);
      var sends = 0;
      await tester.pumpWidget(
        screen(active, ({required conversationId, required body}) async {
          sends++;
          return const SendMessageResult(eventId: r'$sent');
        }),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Aceita');
      await tester.pump();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        find.text('Mensagem enviada. Histórico ainda não atualizado.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Atualizar histórico'));
      await tester.pumpAndSettle();
      expect(sends, 1);
      await tester.pumpWidget(const SizedBox());
      active.dispose();
    },
  );

  testWidgets('Conversa criptografada não oferece composer', (tester) async {
    final active = ValueNotifier(true);
    await tester.pumpWidget(
      screen(
        active,
        ({required conversationId, required body}) async =>
            throw StateError('envio indevido'),
        load:
            ({required conversationId}) async =>
                throw MessageHistoryError.encryptionUnsupported,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(
      find.text(
        messageHistoryErrorMessage(MessageHistoryError.encryptionUnsupported),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    active.dispose();
  });

  for (final logout in [false, true]) {
    for (final success in [false, true]) {
      testWidgets('Descarta envio após sair/logout ($logout, $success)', (
        tester,
      ) async {
        final active = ValueNotifier(true);
        final pending = Completer<SendMessageResult>();
        var loads = 0;
        await tester.pumpWidget(
          screen(
            active,
            ({required conversationId, required body}) => pending.future,
            load: ({required conversationId}) async {
              loads++;
              return [];
            },
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Conta antiga');
        await tester.pump();
        await tester.tap(button);
        await tester.pump();
        if (logout) {
          active.value = false;
          await tester.pumpAndSettle();
        } else {
          await tester.pumpWidget(const SizedBox());
        }
        if (success) {
          pending.complete(const SendMessageResult(eventId: r'$old'));
        } else {
          pending.completeError(SendMessageError.network);
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(loads, 1);
        expect(find.text('Mensagem enviada.'), findsNothing);
        if (logout) {
          expect(find.byType(TextField), findsNothing);
          expect(
            find.text(
              messageHistoryErrorMessage(MessageHistoryError.notAuthenticated),
            ),
            findsOneWidget,
          );
        }
        await tester.pumpWidget(const SizedBox());
        active.dispose();
      });
    }
  }
}
