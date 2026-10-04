import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop_chat_client/app/chat_app.dart';
import 'package:desktop_chat_client/data/services/matrix_bridge_service.dart';
import 'package:desktop_chat_client/data/services/native_matrix_updates.dart';
import 'package:desktop_chat_client/domain/models/models.dart';
import '../support/repository_fakes.dart';

Widget app(
  FakeAuthRepository auth,
  FakeRoomRepository rooms,
  FakeChatRepository chat,
) => ChatApp(
  bridge: MatrixBridgeService(openUpdates: EmptyMatrixUpdateSource.new),
  authRepository: auth,
  roomRepository: rooms,
  chatRepository: chat,
);
Future<void> capture(WidgetTester tester, String name) async {
  const enabled = bool.fromEnvironment('CAPTURE_UI');
  if (!enabled) return;
  final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(
    '/tmp/checkpoint-$name.png',
  ).writeAsBytes(bytes!.buffer.asUint8List());
  image.dispose();
}

void main() {
  setUpAll(() async {
    const directory = String.fromEnvironment('UI_FONT_DIRECTORY');
    if (directory.isEmpty) return;
    for (final entry
        in {
          'Roboto': 'Roboto-Regular.ttf',
          'MaterialIcons': 'MaterialIcons-Regular.otf',
        }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        File(
          '$directory/${entry.value}',
        ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
      await loader.load();
    }
  });
  for (final size in [
    const Size(1440, 900),
    const Size(1024, 768),
    const Size(620, 768),
    const Size(380, 620),
  ]) {
    testWidgets(
      'Shell redimensionável ${size.width}: seleção, mensagens e volta',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth =
            FakeAuthRepository()
              ..initializeAction =
                  () async => const SessionState(account: fixtureAccount);
        final rooms = FakeRoomRepository();
        final chat =
            FakeChatRepository()
              ..historyAction =
                  (_) async => [
                    fixtureMessage('remote', body: 'Mensagem recebida'),
                    fixtureMessage(
                      'own',
                      own: true,
                      time: 2,
                      body: 'Mensagem enviada',
                    ),
                    fixtureMessage(
                      'encrypted',
                      time: 3,
                      body: 'Não foi possível descriptografar esta mensagem.',
                    ),
                  ];
        await tester.pumpWidget(app(auth, rooms, chat));
        await tester.pumpAndSettle();
        expect(
          find.text('Selecione uma conversa'),
          size.width >= 800 ? findsOneWidget : findsNothing,
        );
        expect(find.text('Conversas'), findsOneWidget);
        await tester.tap(find.text(roomA.displayName));
        await tester.pumpAndSettle();
        expect(find.text('Mensagem recebida'), findsOneWidget);
        expect(find.byType(SelectionArea), findsOneWidget);
        expect(
          tester.widget<Align>(find.byKey(const ValueKey('remote'))).alignment,
          Alignment.centerLeft,
        );
        expect(
          tester.widget<Align>(find.byKey(const ValueKey('own'))).alignment,
          Alignment.centerLeft,
        );
        final placeholder = tester.widget<Text>(
          find.text('Não foi possível descriptografar esta mensagem.'),
        );
        expect(placeholder.style!.fontStyle, FontStyle.italic);
        expect(find.byType(TextField), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Enviar'))
              .onPressed,
          isNull,
        );
        if (size.width >= 800) {
          expect(find.text('Conversas'), findsOneWidget);
          expect(
            tester
                .widget<ListTile>(
                  find.byWidgetPredicate(
                    (w) => w is ListTile && w.key == const ValueKey('a'),
                  ),
                )
                .selected,
            isTrue,
          );
          await tester.tap(find.text(roomB.displayName));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<ListTile>(
                  find.byWidgetPredicate(
                    (w) => w is ListTile && w.key == const ValueKey('b'),
                  ),
                )
                .selected,
            isTrue,
          );
          expect(find.text('Logout'), findsOneWidget);
        } else {
          expect(find.text('Conversas'), findsNothing);
          expect(find.byTooltip('Logout'), findsOneWidget);
          await tester.tap(find.byTooltip('Voltar às conversas'));
          await tester.pumpAndSettle();
          expect(find.text('Conversas'), findsOneWidget);
          await tester.tap(find.text(roomA.displayName));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        await tester.runAsync(
          () => capture(tester, 'shell-${size.width.toInt()}'),
        );
        await tester.pumpWidget(const SizedBox());
        await rooms.events.close();
        await chat.events.close();
      },
    );
  }
  testWidgets(
    'Enter envia uma vez; Shift+Enter insere newline; IME não envia',
    (tester) async {
      final auth =
          FakeAuthRepository()
            ..initializeAction =
                () async => const SessionState(account: fixtureAccount);
      final rooms = FakeRoomRepository();
      final chat = FakeChatRepository();
      final pending = Completer<SendMessageResult>();
      chat.sendAction = (_, _) => pending.future;
      await tester.pumpWidget(app(auth, rooms, chat));
      await tester.pumpAndSettle();
      await tester.tap(find.text(roomA.displayName));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Primeira');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      final composer =
          tester.widget<TextField>(find.byType(TextField)).controller!;
      expect(composer.text, 'Primeira\n');
      expect(chat.sends, 0);
      composer.value = const TextEditingValue(
        text: 'Composição',
        selection: TextSelection.collapsed(offset: 10),
        composing: TextRange(start: 0, end: 10),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(chat.sends, 0);
      await tester.enterText(find.byType(TextField), 'Enviar');
      await tester.pump();
      final button =
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Enviar'))
              .onPressed!;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      button();
      await tester.pump();
      expect(chat.sends, 1);
      expect(find.text('Enviando…'), findsOneWidget);
      expect(composer.text, 'Enviar');
      pending.complete(const SendMessageResult(eventId: 'accepted'));
      await tester.pumpAndSettle();
      expect(composer.text, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await rooms.events.close();
      await chat.events.close();
    },
  );
  testWidgets(
    'História recente, renderização lazy e leitura antiga sem salto',
    (tester) async {
      final auth =
          FakeAuthRepository()
            ..initializeAction =
                () async => const SessionState(account: fixtureAccount);
      final rooms = FakeRoomRepository();
      final chat =
          FakeChatRepository()
            ..historyAction =
                (_) async => List.generate(
                  50,
                  (i) => fixtureMessage(
                    'event-$i',
                    time: i,
                    body: 'Mensagem $i: ${'Texto longo. ' * 20}',
                  ),
                );
      await tester.pumpWidget(app(auth, rooms, chat));
      await tester.pumpAndSettle();
      await tester.tap(find.text(roomA.displayName));
      await tester.pumpAndSettle();
      final timeline = find.byWidgetPredicate(
        (w) => w is ListView && w.controller != null,
      );
      final controller = tester.widget<ListView>(timeline).controller!;
      expect(controller.position.extentAfter, lessThan(1));
      expect(find.byKey(const ValueKey('event-49')), findsOneWidget);
      expect(find.byKey(const ValueKey('event-0')), findsNothing);
      controller.jumpTo(controller.position.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      final offset = controller.offset;
      chat.events.add(
        fixtureUpdate(message: fixtureMessage('live', time: 100)),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(offset, 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await rooms.events.close();
      await chat.events.close();
    },
  );
  testWidgets('Login com repositórios falsos mantém campos e foco de teclado', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    final rooms = FakeRoomRepository();
    final chat = FakeChatRepository();
    await tester.pumpWidget(app(auth, rooms, chat));
    await tester.pumpAndSettle();
    expect(find.text('Desktop Chat'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextField, 'URL HTTPS do homeserver'));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TextField>()
          ?.decoration
          ?.labelText,
      'Usuário ou ID Matrix',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TextField>()
          ?.obscureText,
      isTrue,
    );
    await tester.runAsync(() => capture(tester, 'login'));
    await tester.pumpWidget(const SizedBox());
    await rooms.events.close();
    await chat.events.close();
  });
}
