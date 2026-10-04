import 'dart:async';
import 'package:desktop_chat_client/domain/models/models.dart';
import 'package:desktop_chat_client/ui/rooms/view_models/rooms_view_model.dart';
import 'package:desktop_chat_client/ui/rooms/widgets/rooms_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/repository_fakes.dart';

void main() {
  testWidgets('Badges exibem contagem, limite e semântica e ocultam zero', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final repository =
        FakeRoomRepository()
          ..loadAction =
              () async => const [
                ConversationSummary(id: 'zero', displayName: 'Sem pendências'),
                ConversationSummary(
                  id: 'one',
                  displayName: 'Uma',
                  unreadMessageCount: 1,
                ),
                ConversationSummary(
                  id: 'many',
                  displayName: 'Muitas',
                  unreadMessageCount: 145,
                ),
              ];
    final viewModel = RoomsViewModel(repository: repository)..onStart();
    addTearDown(() async {
      viewModel.onDelete();
      await repository.events.close();
    });
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: RoomsView(viewModel: viewModel))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Badge), findsNWidgets(2));
    expect(find.text('1'), findsOneWidget);
    expect(find.text('99+'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('1 mensagem não lida')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('145 mensagens não lidas')),
      findsOneWidget,
    );
    await tester.tap(find.text('Uma'));
    await tester.pump();
    expect(viewModel.state.selected?.id, 'one');
    expect(find.text('1'), findsNothing);
    expect(repository.readRooms, ['one']);
    await tester.tap(find.text('Muitas'));
    await tester.pump();
    expect(find.byType(Badge), findsNothing);
    await tester.tap(find.text('Uma'));
    await tester.pump();
    expect(repository.readRooms, ['one', 'many']);

    // O retrato anterior ao recibo não deve fazer o badge reaparecer.
    await viewModel.load(background: true);
    await tester.pump();
    expect(find.byType(Badge), findsNothing);

    repository.events.add(
      fixtureUpdate(roomId: 'many', message: fixtureMessage('new')),
    );

    repository.loadAction =
        () async => const [
          ConversationSummary(
            id: 'zero',
            displayName: 'Sem pendências',
            unreadMessageCount: 2,
          ),
          ConversationSummary(id: 'one', displayName: 'Uma'),
          ConversationSummary(
            id: 'many',
            displayName: 'Muitas',
            unreadMessageCount: 99,
          ),
        ];
    repository.events.add(
      fixtureUpdate(kind: MatrixUpdateKind.conversationsChanged),
    );
    await tester.pumpAndSettle();
    expect(find.text('1'), findsNothing);
    expect(find.text('99+'), findsNothing);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('99'), findsOneWidget);
    expect(viewModel.state.selected?.id, 'one');
    expect(viewModel.state.selected?.unreadMessageCount, 0);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  test(
    'Falha no recibo restaura o contador e permite nova tentativa',
    () async {
      final pending = Completer<void>();
      final repository =
          FakeRoomRepository()
            ..loadAction =
                () async => const [
                  ConversationSummary(
                    id: 'a',
                    displayName: 'A',
                    unreadMessageCount: 3,
                  ),
                  roomB,
                ];
      repository.markReadAction = (_) => pending.future;
      final viewModel = RoomsViewModel(repository: repository)..onStart();
      await Future<void>.delayed(Duration.zero);
      viewModel.selectRoom(viewModel.state.rooms.first);
      expect(viewModel.state.rooms.first.unreadMessageCount, 0);
      viewModel.selectRoom(viewModel.state.selected);
      expect(repository.readRooms, ['a']);
      viewModel.selectRoom(roomB);
      pending.completeError(ConversationError.network);
      await Future<void>.delayed(Duration.zero);
      expect(viewModel.state.selected?.id, 'b');
      expect(viewModel.state.rooms.first.unreadMessageCount, 3);
      expect(viewModel.state.error, ConversationError.network);
      repository.markReadAction = (_) async {};
      viewModel.selectRoom(viewModel.state.rooms.first);
      await Future<void>.delayed(Duration.zero);
      expect(repository.readRooms, ['a', 'a']);
      expect(viewModel.state.rooms.first.unreadMessageCount, 0);
      viewModel.onDelete();
      await repository.events.close();
    },
  );

  test('Conclusão antiga do recibo não altera sessão encerrada', () async {
    final pending = Completer<void>();
    final repository =
        FakeRoomRepository()
          ..loadAction =
              () async => const [
                ConversationSummary(
                  id: 'a',
                  displayName: 'A',
                  unreadMessageCount: 1,
                ),
              ];
    repository.markReadAction = (_) => pending.future;
    final viewModel = RoomsViewModel(repository: repository)..onStart();
    await Future<void>.delayed(Duration.zero);
    viewModel.selectRoom(viewModel.state.rooms.first);
    viewModel.onDelete();
    pending.completeError(ConversationError.network);
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.state.error, isNull);
    expect(viewModel.state.rooms.first.unreadMessageCount, 0);
    await repository.events.close();
  });
}
