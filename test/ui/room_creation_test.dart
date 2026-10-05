import 'dart:async';
import 'package:desktop_chat_client/app/chat_app.dart';
import 'package:desktop_chat_client/data/services/matrix_bridge_service.dart';
import 'package:desktop_chat_client/data/services/native_matrix_updates.dart';
import 'package:desktop_chat_client/domain/models/models.dart';
import 'package:desktop_chat_client/ui/chat/widgets/chat_view.dart';
import 'package:desktop_chat_client/ui/rooms/view_models/rooms_view_model.dart';
import 'package:desktop_chat_client/ui/rooms/widgets/create_room_dialog.dart';
import 'package:desktop_chat_client/ui/rooms/widgets/rooms_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import '../support/repository_fakes.dart';

const created = ConversationSummary(id: 'created', displayName: 'Nova sala');
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'Convites individuais validam, impedem duplicatas e permitem remoção',
    () async {
      final repository = FakeRoomRepository();
      final vm = RoomsViewModel(repository: repository)..onStart();
      await settle();
      vm.beginCreation();
      for (final value in [
        'alice',
        '',
        '@alice:matrix.org @bob:example.org',
        '@alice:matrix.org\n@bob:example.org',
        '@alice:matrix.org,@bob:example.org',
      ]) {
        expect(vm.addInvitee(value), isFalse);
        expect(vm.state.inviteeError, contains('apenas um ID Matrix completo'));
        expect(vm.state.creationInvitees, isEmpty);
      }
      expect(vm.addInvitee(' @alice:matrix.org '), isTrue);
      expect(vm.addInvitee('@bob:example.org'), isTrue);
      expect(vm.addInvitee('@alice:matrix.org'), isFalse);
      expect(vm.state.inviteeError, 'Esta pessoa já foi adicionada.');
      expect(vm.state.creationInvitees, [
        '@alice:matrix.org',
        '@bob:example.org',
      ]);
      expect(() => vm.state.creationInvitees.clear(), throwsUnsupportedError);
      vm.removeInvitee('@alice:matrix.org');
      expect(vm.state.creationInvitees, ['@bob:example.org']);
      expect(vm.state.inviteeError, isNull);
      vm.onDelete();
      await repository.events.close();
    },
  );

  testWidgets('Cabeçalho reúne Salas e nova; dialog tem superfície branca', (
    tester,
  ) async {
    final repository = FakeRoomRepository();
    final vm = RoomsViewModel(repository: repository)..onStart();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 320, child: RoomsView(viewModel: vm)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Salas'), findsOneWidget);
    expect(find.text('Conversas'), findsNothing);
    expect(find.text('nova'), findsOneWidget);
    expect(find.byTooltip('Criar sala'), findsOneWidget);
    final header =
        find.ancestor(of: find.text('Salas'), matching: find.byType(Row)).first;
    expect(
      find.descendant(of: header, matching: find.text('nova')),
      findsOneWidget,
    );
    expect(
      tester.getCenter(find.text('nova')).dy,
      closeTo(tester.getCenter(find.text('Salas')).dy, 3),
    );
    expect(
      tester.getRect(find.byTooltip('Criar sala')).right,
      closeTo(tester.getRect(header).right, .1),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(
      tester.getCenter(find.widgetWithText(TextButton, 'Adicionar')).dy,
      closeTo(tester.getCenter(find.byType(TextField).at(1)).dy, .1),
    );
    expect(dialog.backgroundColor, Colors.white);
    expect(dialog.surfaceTintColor, Colors.transparent);
    expect(
      tester
          .widget<Material>(
            find
                .descendant(
                  of: find.byType(Dialog),
                  matching: find.byType(Material),
                )
                .first,
          )
          .color,
      Colors.white,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    vm.onDelete();
    await repository.events.close();
  });

  testWidgets(
    'Adicionar e Enter acumulam IDs, limpam campo e permitem remoção',
    (tester) async {
      var snapshot = <ConversationSummary>[];
      final repository =
          FakeRoomRepository()
            ..loadAction = (() async => snapshot)
            ..createAction = (_, _) async {
              snapshot = [created];
              return created;
            };
      final vm = RoomsViewModel(repository: repository)..onStart();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RoomsView(viewModel: vm))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('nova'));
      await tester.pumpAndSettle();
      final inviteField = find.byType(TextField).at(1);
      await tester.enterText(inviteField, 'alice');
      await tester.tap(find.text('Adicionar'));
      await tester.pump();
      expect(
        find.textContaining('apenas um ID Matrix completo'),
        findsOneWidget,
      );
      expect(vm.state.creationInvitees, isEmpty);
      for (final input in [
        '@alice:matrix.org @bob:example.org',
        '@alice:matrix.org\n@bob:example.org',
        '@alice:matrix.org,@bob:example.org',
      ]) {
        await tester.enterText(inviteField, input);
        await tester.tap(find.text('Adicionar'));
        await tester.pump();
        expect(vm.state.creationInvitees, isEmpty);
        expect(
          find.textContaining('apenas um ID Matrix completo'),
          findsOneWidget,
        );
      }
      await tester.enterText(inviteField, '@alice:matrix.org');
      await tester.tap(find.text('Adicionar'));
      await tester.pump();
      expect(tester.widget<TextField>(inviteField).controller!.text, isEmpty);
      expect(find.text('@alice:matrix.org'), findsOneWidget);
      await tester.enterText(inviteField, '@alice:matrix.org');
      await tester.tap(find.text('Adicionar'));
      await tester.pump();
      expect(find.text('Esta pessoa já foi adicionada.'), findsOneWidget);
      expect(vm.state.creationInvitees, ['@alice:matrix.org']);
      await tester.enterText(inviteField, '@bob:example.org');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(vm.state.creationInvitees, [
        '@alice:matrix.org',
        '@bob:example.org',
      ]);
      expect(tester.widget<TextField>(inviteField).controller!.text, isEmpty);
      expect(repository.createdRooms, isEmpty);
      expect(find.byType(CreateRoomDialog), findsOneWidget);
      await tester.tap(find.byTooltip('Remover @alice:matrix.org'));
      await tester.pump();
      expect(find.text('@alice:matrix.org'), findsNothing);
      expect(vm.state.creationInvitees, ['@bob:example.org']);
      await tester.enterText(find.byType(TextField).at(0), 'Nova sala');
      await tester.tap(find.text('Criar'));
      await tester.pumpAndSettle();
      expect(repository.createdRooms.single.$2, ['@bob:example.org']);
      expect(vm.state.selected, created);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      vm.onDelete();
      await repository.events.close();
    },
  );

  testWidgets('ID pendente precisa ser adicionado ou limpo antes da criação', (
    tester,
  ) async {
    final repository = FakeRoomRepository();
    final vm = RoomsViewModel(repository: repository)..onStart();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: RoomsView(viewModel: vm))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('nova'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Nova sala');
    await tester.enterText(find.byType(TextField).at(1), '@alice:matrix.org');
    await tester.tap(find.text('Criar'));
    await tester.pump();
    expect(find.textContaining('Use Adicionar'), findsOneWidget);
    expect(repository.createdRooms, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      '@alice:matrix.org',
    );
    await tester.pumpWidget(const SizedBox());
    vm.onDelete();
    await repository.events.close();
  });
  test(
    'Validação rejeita nome vazio e IDs incompletos antes da bridge',
    () async {
      final repository = FakeRoomRepository();
      final vm = RoomsViewModel(repository: repository)..onStart();
      await settle();
      expect(await vm.createRoom(' \n ', ''), isFalse);
      expect(vm.state.creationError, 'Informe o nome da sala.');
      for (final id in [
        'alice',
        '@alice',
        'alice:matrix.org',
        '@:matrix.org',
        '@alice:',
        '@alice:https://matrix.org',
        '@alice:..',
        '@alice:bad_host',
      ]) {
        expect(await vm.createRoom('Sala', id), isFalse, reason: id);
        expect(vm.state.creationError, contains('IDs Matrix completos'));
      }
      expect(repository.createdRooms, isEmpty);
      vm.onDelete();
      await repository.events.close();
    },
  );

  for (final inviteText in [
    '',
    '@alice:matrix.org\n@bob:example.org\n@alice:matrix.org',
  ]) {
    test('Criação normaliza entradas e seleciona sala: $inviteText', () async {
      var snapshot = [roomA];
      final pending = Completer<ConversationSummary>();
      final repository =
          FakeRoomRepository()
            ..loadAction = (() async => snapshot)
            ..createAction = (_, _) => pending.future;
      final vm = RoomsViewModel(repository: repository)..onStart();
      await settle();
      vm.selectRoom(roomA);
      final operation = vm.createRoom('  Nova sala  ', inviteText);
      expect(vm.state.creating, isTrue);
      expect(await vm.createRoom('Duplicada', ''), isFalse);
      expect(repository.createdRooms, hasLength(1));
      expect(repository.createdRooms.single.$1, 'Nova sala');
      expect(
        repository.createdRooms.single.$2,
        inviteText.isEmpty
            ? <String>[]
            : ['@alice:matrix.org', '@bob:example.org'],
      );
      expect(vm.state.selected, roomA);
      snapshot = [roomA, created];
      pending.complete(created);
      expect(await operation, isTrue);
      await settle();
      expect(vm.state.rooms, contains(created));
      expect(vm.state.selected, created);
      expect(vm.state.creating, isFalse);
      expect(vm.state.creationError, isNull);
      vm.onDelete();
      await repository.events.close();
    });
  }

  test(
    'Falha mantém seleção/lista e retry cria somente após sucesso',
    () async {
      var snapshot = [roomA];
      final repository =
          FakeRoomRepository()
            ..loadAction = (() async => snapshot)
            ..createAction =
                (_, _) async => throw StateError('private server details');
      final vm = RoomsViewModel(repository: repository)..onStart();
      await settle();
      vm.selectRoom(roomA);
      expect(await vm.createRoom('Nova sala', ''), isFalse);
      expect(vm.state.rooms, [roomA]);
      expect(vm.state.selected, roomA);
      expect(
        vm.state.creationError,
        'Não foi possível criar a sala. Tente novamente.',
      );
      expect(vm.state.creating, isFalse);
      repository.createAction = (_, _) async {
        snapshot = [roomA, created];
        return created;
      };
      expect(await vm.createRoom('Nova sala', ''), isTrue);
      await settle();
      expect(vm.state.selected, created);
      expect(repository.createdRooms, hasLength(2));
      vm.onDelete();
      await repository.events.close();
    },
  );

  test('Snapshot anterior à criação não remove sala confirmada', () async {
    final repository = FakeRoomRepository()..loadAction = () async => [roomA];
    final vm = RoomsViewModel(repository: repository)..onStart();
    await settle();
    final stale = Completer<List<ConversationSummary>>();
    repository.loadAction = () => stale.future;
    final loading = vm.load(background: true);
    expect(await vm.createRoom('Nova sala', ''), isTrue);
    repository.loadAction = () async => [roomA, created];
    stale.complete([roomA]);
    await loading;
    await settle();
    expect(vm.state.rooms, contains(created));
    expect(vm.state.selected, created);
    vm.onDelete();
    await repository.events.close();
  });

  for (final dispose in [false, true]) {
    for (final fails in [false, true]) {
      test(
        'Resultado obsoleto descartado: dispose=$dispose erro=$fails',
        () async {
          var active = true;
          final pending = Completer<ConversationSummary>();
          final repository =
              FakeRoomRepository()..createAction = (_, _) => pending.future;
          final vm = RoomsViewModel(
            repository: repository,
            sessionIsCurrent: () => active,
          )..onStart();
          await settle();
          vm.selectRoom(roomA);
          final operation = vm.createRoom('Nova sala', '');
          active = false;
          if (dispose) vm.onDelete();
          final before = vm.state;
          if (fails) {
            pending.completeError(ConversationError.network);
          } else {
            pending.complete(created);
          }
          expect(await operation, isFalse);
          expect(vm.state, same(before));
          expect(vm.state.selected, roomA);
          expect(repository.loads, 1);
          if (!dispose) vm.onDelete();
          await repository.events.close();
        },
      );
    }
  }

  testWidgets('Dialog valida, bloqueia envio e preserva entradas no retry', (
    tester,
  ) async {
    var snapshot = <ConversationSummary>[];
    final pending = Completer<ConversationSummary>();
    final repository =
        FakeRoomRepository()
          ..loadAction = (() async => snapshot)
          ..createAction = (_, _) => pending.future;
    final vm = RoomsViewModel(repository: repository)..onStart();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: RoomsView(viewModel: vm))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('nova'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Criar'));
    await tester.pumpAndSettle();
    expect(find.text('Informe o nome da sala.'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'Nova sala');
    for (final id in ['@alice:matrix.org', '@bob:example.org']) {
      await tester.enterText(find.byType(TextField).at(1), id);
      await tester.tap(find.text('Adicionar'));
      await tester.pump();
    }
    await tester.tap(find.text('Criar'));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(repository.createdRooms, hasLength(1));
    pending.completeError(ConversationError.network);
    await tester.pumpAndSettle();
    expect(find.byType(CreateRoomDialog), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
      'Nova sala',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      isEmpty,
    );
    expect(find.text('@alice:matrix.org'), findsOneWidget);
    expect(find.text('@bob:example.org'), findsOneWidget);
    expect(vm.state.creationInvitees, [
      '@alice:matrix.org',
      '@bob:example.org',
    ]);
    expect(find.textContaining('Verifique a conexão'), findsOneWidget);
    expect(vm.state.rooms, isEmpty);
    repository.createAction = (_, _) async {
      snapshot = [created];
      return created;
    };
    await tester.tap(find.text('Criar'));
    await tester.pumpAndSettle();
    expect(find.byType(CreateRoomDialog), findsNothing);
    expect(vm.state.selected, created);
    expect(repository.createdRooms.last.$2, [
      '@alice:matrix.org',
      '@bob:example.org',
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    vm.onDelete();
    await repository.events.close();
  });

  for (final width in [700.0, 1100.0]) {
    testWidgets('Criação abre conversa e inicia histórico em $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(Get.reset);
      const unread = ConversationSummary(
        id: 'unread',
        displayName: 'Existente',
        unreadMessageCount: 4,
        isEncrypted: true,
      );
      var snapshot = [unread];
      final history = Completer<List<MessageSummary>>();
      final auth =
          FakeAuthRepository()
            ..initializeAction =
                () async => const SessionState(account: fixtureAccount);
      final rooms =
          FakeRoomRepository()
            ..loadAction = (() async => snapshot)
            ..createAction = (_, _) async {
              snapshot = [unread, created];
              return created;
            };
      final loaded = <String>[];
      final chat =
          FakeChatRepository()
            ..historyAction = (id) {
              loaded.add(id);
              return history.future;
            };
      await tester.pumpWidget(
        ChatApp(
          bridge: MatrixBridgeService(openUpdates: EmptyMatrixUpdateSource.new),
          authRepository: auth,
          roomRepository: rooms,
          chatRepository: chat,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('nova'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'Nova sala');
      await tester.tap(find.text('Criar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CreateRoomDialog), findsNothing);
      expect(loaded, ['created']);
      final opened = tester.widget<ChatView>(find.byType(ChatView)).viewModel;
      expect(opened.roomId, 'created');
      expect(opened.state.loading, isTrue);
      expect(find.text('Carregando mensagens…'), findsOneWidget);
      if (width >= 800) {
        expect(find.text('4'), findsOneWidget);
        expect(find.byIcon(Icons.lock_outline), findsOneWidget);
        expect(
          tester
              .widget<ListTile>(
                find.descendant(
                  of: find.byType(RoomsView),
                  matching: find.byKey(const ValueKey('created')),
                ),
              )
              .selected,
          isTrue,
        );
      }
      history.complete([fixtureMessage('first', body: 'Histórico carregado')]);
      await tester.pumpAndSettle();
      expect(find.text('Histórico carregado'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await rooms.events.close();
      await chat.events.close();
    });
  }
}
