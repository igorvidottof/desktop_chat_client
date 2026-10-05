import 'dart:async';

import 'package:desktop_chat_client/app/chat_app.dart';
import 'package:desktop_chat_client/data/services/matrix_bridge_service.dart';
import 'package:desktop_chat_client/data/services/native_matrix_updates.dart';
import 'package:desktop_chat_client/domain/models/models.dart';
import 'package:desktop_chat_client/ui/chat/view_models/chat_view_model.dart';
import 'package:desktop_chat_client/ui/chat/widgets/chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/repository_fakes.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);
List<MessageSummary> history(int count) => List.generate(
  count,
  (i) => fixtureMessage('m$i', time: i, body: 'Mensagem $i ${'texto ' * 30}'),
);

void main() {
  for (final count in [0, 1, 3, 5, 6]) {
    test('Fronteira inicial com contagem $count e cinco mensagens', () async {
      final repository =
          FakeChatRepository()..historyAction = (_) async => history(5);
      final viewModel = ChatViewModel(
        repository: repository,
        roomId: 'a',
        initialUnreadCount: count,
      )..onStart();
      await settle();
      expect(
        viewModel.state.firstUnreadMessageId,
        count == 0 || count > 5 ? null : 'm${5 - count}',
      );
      expect(viewModel.state.unreadHistoryInsufficient, count > 5);
      viewModel.onDelete();
      await repository.events.close();
    });
  }

  test(
    'Eventos durante a abertura e refresh não deslocam a fronteira',
    () async {
      final pending = Completer<List<MessageSummary>>();
      final repository =
          FakeChatRepository()..historyAction = (_) => pending.future;
      final viewModel = ChatViewModel(
        repository: repository,
        roomId: 'a',
        initialUnreadCount: 2,
      )..onStart();
      await settle();
      final arriving = fixtureMessage('live', time: 10);
      repository.events.add(fixtureUpdate(message: arriving));
      pending.complete([...history(5), arriving]);
      await settle();
      expect(viewModel.state.firstUnreadMessageId, 'm3');
      repository.events.add(
        fixtureUpdate(message: fixtureMessage('later', time: 11)),
      );
      repository.historyAction = (_) async => history(4);
      await viewModel.load(background: true);
      expect(viewModel.state.firstUnreadMessageId, 'm3');
      viewModel.onDelete();
      await repository.events.close();
    },
  );

  test(
    'Erro inicial permite resolver no retry; insuficiência não é reestimada',
    () async {
      final repository =
          FakeChatRepository()
            ..historyAction = (_) async => throw MessageHistoryError.network;
      final viewModel = ChatViewModel(
        repository: repository,
        roomId: 'a',
        initialUnreadCount: 3,
      )..onStart();
      await settle();
      expect(viewModel.state.firstUnreadMessageId, isNull);
      repository.historyAction = (_) async => history(2);
      await viewModel.load();
      expect(viewModel.state.unreadHistoryInsufficient, isTrue);
      repository.historyAction = (_) async => history(5);
      await viewModel.load(background: true);
      expect(viewModel.state.firstUnreadMessageId, isNull);
      viewModel.onDelete();
      await repository.events.close();
    },
  );

  test('Troca de sala e sessão rejeita história e eventos antigos', () async {
    final pending = Completer<List<MessageSummary>>();
    final repository =
        FakeChatRepository()
          ..historyAction =
              (id) => id == 'a' ? pending.future : Future.value(history(5));
    final old = ChatViewModel(
      repository: repository,
      roomId: 'a',
      initialUnreadCount: 1,
    )..onStart();
    await settle();
    old.onDelete();
    var currentSession = true;
    final selected = ChatViewModel(
      repository: repository,
      roomId: 'b',
      initialUnreadCount: 3,
      sessionIsCurrent: () => currentSession,
    )..onStart();
    await settle();
    pending.complete(history(2));
    repository.events.add(fixtureUpdate(message: fixtureMessage('old')));
    await settle();
    expect(selected.state.firstUnreadMessageId, 'm2');
    expect(selected.state.messages.length, 5);
    final before = selected.state;
    currentSession = false;
    repository.events.add(
      fixtureUpdate(roomId: 'b', message: fixtureMessage('stale')),
    );
    await selected.load();
    expect(selected.state, same(before));
    selected.invalidateSession();
    expect(selected.state.firstUnreadMessageId, isNull);
    selected.onDelete();
    await repository.events.close();
  });

  for (final count in [0, 20, 51]) {
    testWidgets('Abertura com $count não lidas mantém posição e apresentação', (
      tester,
    ) async {
      final repository =
          FakeChatRepository()..historyAction = (_) async => history(50);
      final viewModel = ChatViewModel(
        repository: repository,
        roomId: 'a',
        initialUnreadCount: count,
      )..onStart();
      // Também verifica a montagem depois da conclusão do histórico.
      await tester.runAsync(settle);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ChatView(viewModel: viewModel))),
      );
      await tester.pumpAndSettle();
      if (count == 20) {
        final divider = find.text('Novas mensagens');
        expect(divider, findsOneWidget);
        final first = find.byKey(const ValueKey('m30')).last;
        expect(
          tester.getRect(divider).bottom,
          lessThanOrEqualTo(tester.getRect(first).top),
        );
        final scrollable = find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        );
        final viewport = tester.getRect(scrollable);
        expect(viewport.contains(tester.getCenter(divider)), isTrue);
        expect(viewport.overlaps(tester.getRect(first)), isTrue);
        final controller =
            tester
                .widget<CustomScrollView>(find.byType(CustomScrollView))
                .controller!;
        expect(controller.offset, 0);
        repository.events.add(
          fixtureUpdate(message: fixtureMessage('live', time: 100)),
        );
        await tester.pumpAndSettle();
        expect(viewModel.state.firstUnreadMessageId, 'm30');
        expect(controller.offset, 0);
        expect(viewport.contains(tester.getCenter(divider)), isTrue);
        controller.jumpTo(controller.position.minScrollExtent);
        await tester.pumpAndSettle();
        expect(find.textContaining('Mensagem 1 '), findsOneWidget);
      } else {
        expect(find.text('Novas mensagens'), findsNothing);
        final controller =
            tester.widget<ListView>(find.byType(ListView)).controller!;
        expect(controller.position.extentAfter, lessThan(1));
        expect(
          find.text(
            'Há mensagens não lidas anteriores ao histórico carregado.',
          ),
          count > 50 ? findsOneWidget : findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      viewModel.onDelete();
      await repository.events.close();
    });
  }

  testWidgets(
    'Seleção captura badge antes de ocultá-lo e isola a próxima sala',
    (tester) async {
      final auth =
          FakeAuthRepository()
            ..initializeAction =
                () async => const SessionState(account: fixtureAccount);
      final rooms =
          FakeRoomRepository()
            ..loadAction =
                () async => const [
                  ConversationSummary(
                    id: 'a',
                    displayName: 'Sala A',
                    unreadMessageCount: 2,
                  ),
                  ConversationSummary(id: 'b', displayName: 'Sala B'),
                ];
      final chat =
          FakeChatRepository()..historyAction = (_) async => history(5);
      await tester.pumpWidget(
        ChatApp(
          bridge: MatrixBridgeService(openUpdates: EmptyMatrixUpdateSource.new),
          authRepository: auth,
          roomRepository: rooms,
          chatRepository: chat,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.text('Sala A'));
      await tester.pumpAndSettle();
      expect(find.text('2'), findsNothing);
      expect(rooms.readRooms, ['a']);
      expect(find.text('Novas mensagens'), findsOneWidget);
      final view = tester.widget<ChatView>(find.byType(ChatView));
      expect(view.viewModel.state.firstUnreadMessageId, 'm3');
      await tester.tap(find.text('Sala B'));
      await tester.pumpAndSettle();
      expect(find.text('Novas mensagens'), findsNothing);
      chat.events.add(fixtureUpdate(message: fixtureMessage('old')));
      await tester.pumpAndSettle();
      expect(find.text('Novas mensagens'), findsNothing);
      expect(
        tester
            .widget<ChatView>(find.byType(ChatView))
            .viewModel
            .state
            .messages
            .length,
        5,
      );
      await tester.pumpWidget(const SizedBox());
      await rooms.events.close();
      await chat.events.close();
    },
  );
}
