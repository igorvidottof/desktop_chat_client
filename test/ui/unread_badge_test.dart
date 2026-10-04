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
    expect(find.text('1'), findsOneWidget);

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
}
