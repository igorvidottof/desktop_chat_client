import 'package:desktop_chat_client/domain/models/models.dart';
import 'package:desktop_chat_client/ui/core/themes/app_theme.dart';
import 'package:desktop_chat_client/ui/rooms/view_models/rooms_view_model.dart';
import 'package:desktop_chat_client/ui/rooms/widgets/rooms_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/repository_fakes.dart';

void main() {
  for (final width in [320.0, 600.0]) {
    testWidgets('Indicador criptografado acessível e compacto em $width', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final repository =
          FakeRoomRepository()
            ..loadAction =
                () async => const [
                  ConversationSummary(
                    id: 'encrypted',
                    displayName: 'Uma sala criptografada com nome muito longo',
                    unreadMessageCount: 3,
                    isEncrypted: true,
                  ),
                  ConversationSummary(id: 'plain', displayName: 'Sala aberta'),
                ];
      final viewModel = RoomsViewModel(repository: repository)..onStart();
      final theme = buildAppTheme();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: RoomsView(viewModel: viewModel),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Criptografada'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Sala criptografada')),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.text('Criptografada')).style!.color,
        theme.colorScheme.error,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.lock_outline)).color,
        theme.colorScheme.error,
      );
      final name = find.text('Uma sala criptografada com nome muito longo');
      expect(
        tester.getRect(find.text('Criptografada')).bottom,
        lessThanOrEqualTo(tester.getRect(name).top),
      );
      final plain = find.byKey(const ValueKey('plain'));
      expect(
        find.descendant(of: plain, matching: find.byIcon(Icons.lock_outline)),
        findsNothing,
      );
      expect(find.text('3'), findsOneWidget);
      await tester.tap(name);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('encrypted')))
            .selected,
        isTrue,
      );
      expect(find.text('3'), findsNothing);
      expect(repository.readRooms, ['encrypted']);
      expect(viewModel.state.selected!.isEncrypted, isTrue);
      expect(find.text('Criptografada'), findsOneWidget);
      await viewModel.load(background: true);
      await tester.pumpAndSettle();
      expect(find.text('Criptografada'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      viewModel.onDelete();
      await repository.events.close();
      semantics.dispose();
    });
  }

  test('Criptografia participa da identidade do resumo e padrão é falso', () {
    const plain = ConversationSummary(id: 'a', displayName: 'A');
    const encrypted = ConversationSummary(
      id: 'a',
      displayName: 'A',
      isEncrypted: true,
    );
    expect(plain.isEncrypted, isFalse);
    expect(encrypted, isNot(plain));
    expect({plain, encrypted}, hasLength(2));
  });
}
