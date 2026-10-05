import 'dart:async';

import 'package:desktop_chat_client/app/chat_app.dart';
import 'package:desktop_chat_client/data/services/matrix_bridge_service.dart';
import 'package:desktop_chat_client/data/services/native_matrix_updates.dart';
import 'package:desktop_chat_client/ui/chat/widgets/chat_view.dart';
import 'package:get/get.dart';

import 'package:desktop_chat_client/domain/models/models.dart';
import 'package:desktop_chat_client/ui/rooms/view_models/rooms_view_model.dart';
import 'package:desktop_chat_client/ui/rooms/widgets/rooms_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/repository_fakes.dart';

const invitation = ConversationSummary(
  id: 'invite',
  displayName: 'Sala convidada',
  isInvited: true,
  isEncrypted: true,
);
const joined = ConversationSummary(
  id: 'invite',
  displayName: 'Sala convidada',
  isEncrypted: true,
);
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'Convites separados; aceitação seleciona somente após sucesso e impede duplicatas',
    () async {
      final pending = Completer<ConversationSummary>();
      var snapshot = [roomA, invitation];
      final repository =
          FakeRoomRepository()
            ..loadAction = () async {
              return snapshot;
            }
            ..acceptAction = (_) => pending.future;
      final vm = RoomsViewModel(repository: repository)..onStart();
      await settle();
      vm.selectRoom(roomA);
      expect(vm.state.rooms, [roomA]);
      expect(vm.state.invitations, [invitation]);
      vm.selectRoom(invitation);
      expect(vm.state.selected, roomA);
      final accepting = vm.acceptInvitation('invite');
      await vm.acceptInvitation('invite');
      expect(repository.acceptedRooms, ['invite']);
      expect(vm.state.accepting, {'invite'});
      expect(vm.state.selected, roomA);
      snapshot = [roomA, joined];
      pending.complete(joined);
      await accepting;
      await settle();
      expect(vm.state.invitations, isEmpty);
      expect(vm.state.rooms, contains(joined));
      expect(vm.state.selected, joined);
      expect(vm.state.accepting, isEmpty);
      expect(vm.state.rooms.last.isEncrypted, isTrue);
      vm.onDelete();
      await repository.events.close();
    },
  );

  test('Falha segura mantém convite e permite nova tentativa', () async {
    var snapshot = [roomA, invitation];
    final repository =
        FakeRoomRepository()
          ..loadAction = () async {
            return snapshot;
          }
          ..acceptAction = (_) async => throw ConversationError.network;
    final vm = RoomsViewModel(repository: repository)..onStart();
    await settle();
    vm.selectRoom(roomA);
    await vm.acceptInvitation('invite');
    expect(vm.state.selected, roomA);
    expect(vm.state.invitations, [invitation]);
    expect(vm.state.invitationErrors['invite'], ConversationError.network);
    expect(vm.state.accepting, isEmpty);
    repository.acceptAction = (_) async {
      snapshot = [roomA, joined];
      return joined;
    };
    await vm.acceptInvitation('invite');
    await settle();
    expect(repository.acceptedRooms, ['invite', 'invite']);
    expect(vm.state.invitations, isEmpty);
    expect(vm.state.invitationErrors, isEmpty);
    expect(vm.state.rooms, [roomA, joined]);
    expect(vm.state.selected, joined);
    vm.onDelete();
    await repository.events.close();
  });

  test('Snapshot anterior à aceitação não restaura convite', () async {
    final repository =
        FakeRoomRepository()
          ..loadAction = () async {
            return [roomA, invitation];
          }
          ..acceptAction = (_) async => joined;
    final vm = RoomsViewModel(repository: repository)..onStart();
    await settle();
    final stale = Completer<List<ConversationSummary>>();
    repository.loadAction = () => stale.future;
    final loading = vm.load(background: true);
    await vm.acceptInvitation('invite');
    expect(vm.state.invitations, isEmpty);
    expect(vm.state.rooms, contains(joined));
    expect(vm.state.selected, joined);
    repository.loadAction = () async => [roomA, joined];
    stale.complete([roomA, invitation]);
    await loading;
    await settle();
    expect(vm.state.invitations, isEmpty);
    expect(vm.state.rooms, contains(joined));
    expect(vm.state.selected, joined);
    vm.onDelete();
    await repository.events.close();
  });

  for (final dispose in [false, true]) {
    for (final fails in [false, true]) {
      test(
        'Sessão obsoleta ignora aceitação: descarte=$dispose falha=$fails',
        () async {
          var active = true;
          final pending = Completer<ConversationSummary>();
          final repository =
              FakeRoomRepository()
                ..loadAction = () async {
                  return [roomA, invitation];
                }
                ..acceptAction = (_) => pending.future;
          final vm = RoomsViewModel(
            repository: repository,
            sessionIsCurrent: () => active,
          )..onStart();
          await settle();
          vm.selectRoom(roomA);
          final accepting = vm.acceptInvitation('invite');
          active = false;
          if (dispose) vm.onDelete();
          final before = vm.state;
          repository.events.add(
            fixtureUpdate(kind: MatrixUpdateKind.conversationsChanged),
          );
          if (fails) {
            pending.completeError(StateError('private'));
          } else {
            pending.complete(joined);
          }
          await accepting;
          expect(identical(vm.state, before), isTrue);
          expect(vm.state.selected, roomA);
          expect(repository.loads, 1);
          if (!dispose) vm.onDelete();
          expect(repository.events.hasListener, isFalse);
          await repository.events.close();
        },
      );
    }
  }

  test(
    'Sync adiciona e remove convites sem alterar seleção ou badges',
    () async {
      const unread = ConversationSummary(
        id: 'a',
        displayName: 'A',
        unreadMessageCount: 4,
        isEncrypted: true,
      );
      var snapshot = [roomB, unread];
      final repository =
          FakeRoomRepository()..loadAction = () async => snapshot;
      final vm = RoomsViewModel(repository: repository)..onStart();
      await settle();
      vm.selectRoom(roomB);
      snapshot = [roomB, unread, invitation];
      repository.events.add(
        fixtureUpdate(kind: MatrixUpdateKind.conversationsChanged),
      );
      await settle();
      expect(vm.state.invitations, [invitation]);
      expect(vm.state.selected, roomB);
      expect(vm.state.rooms.last.unreadMessageCount, 4);
      expect(vm.state.rooms.last.isEncrypted, isTrue);
      snapshot = [roomB, unread, joined];
      repository.events.add(
        fixtureUpdate(kind: MatrixUpdateKind.conversationsChanged),
      );
      await settle();
      expect(vm.state.invitations, isEmpty);
      expect(vm.state.rooms, contains(joined));
      expect(vm.state.selected, roomB);
      vm.onDelete();
      await repository.events.close();
    },
  );

  testWidgets('Convite compacto, loading, erro e retry sem refresh manual', (
    tester,
  ) async {
    var snapshot = [invitation];
    final pending = Completer<ConversationSummary>();
    final repository =
        FakeRoomRepository()
          ..loadAction = () async {
            return snapshot;
          }
          ..acceptAction = (_) => pending.future;
    final vm = RoomsViewModel(repository: repository)..onStart();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 320, child: RoomsView(viewModel: vm)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Convites pendentes'), findsOneWidget);
    expect(find.textContaining('Você foi convidado'), findsOneWidget);
    expect(find.textContaining('Criptografada'), findsOneWidget);
    expect(find.text('Sala convidada'), findsOneWidget);
    await tester.tap(find.text('Aceitar'));
    await tester.pump();
    final button = tester.widget<TextButton>(
      find.descendant(
        of: find.byKey(const ValueKey('invite')),
        matching: find.byType(TextButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.completeError(StateError('private server details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Não foi possível aceitar'), findsOneWidget);
    expect(find.textContaining('private'), findsNothing);
    expect(find.text('Aceitar'), findsOneWidget);
    repository.acceptAction = (_) async {
      snapshot = [joined];
      return joined;
    };
    await tester.tap(find.text('Aceitar'));
    await tester.pumpAndSettle();
    expect(find.text('Convites pendentes'), findsNothing);
    expect(find.text('Aceitar'), findsNothing);
    expect(find.text('Sala convidada'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(vm.state.selected, joined);
    expect(
      tester
          .widget<ListTile>(
            find.descendant(
              of: find.byType(RoomsView),
              matching: find.byKey(const ValueKey('invite')),
            ),
          )
          .selected,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    vm.onDelete();
    await repository.events.close();
  });

  for (final width in [700.0, 1100.0]) {
    testWidgets(
      'Aceitação abre conversa e carrega histórico automaticamente em $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(Get.reset);
        const plainInvite = ConversationSummary(
          id: 'invite',
          displayName: 'Sala convidada',
          isInvited: true,
        );
        const plainJoined = ConversationSummary(
          id: 'invite',
          displayName: 'Sala convidada',
          unreadMessageCount: 2,
        );
        const otherUnread = ConversationSummary(
          id: 'b',
          displayName: 'Conversa B',
          unreadMessageCount: 4,
          isEncrypted: true,
        );
        var snapshot = [roomA, otherUnread, plainInvite];
        final pendingAccept = Completer<ConversationSummary>();
        final history = Completer<List<MessageSummary>>();
        final loadedRooms = <String>[];
        final auth =
            FakeAuthRepository()
              ..initializeAction =
                  () async => const SessionState(account: fixtureAccount);
        final rooms =
            FakeRoomRepository()
              ..loadAction = (() async => snapshot)
              ..acceptAction = ((_) => pendingAccept.future);
        final chat =
            FakeChatRepository()
              ..historyAction = (id) {
                loadedRooms.add(id);
                return id == 'invite'
                    ? history.future
                    : Future.value([fixtureMessage('previous')]);
              };
        await tester.pumpWidget(
          ChatApp(
            bridge: MatrixBridgeService(
              openUpdates: EmptyMatrixUpdateSource.new,
            ),
            authRepository: auth,
            roomRepository: rooms,
            chatRepository: chat,
          ),
        );
        await tester.pumpAndSettle();
        if (width >= 800) {
          await tester.tap(find.text('Conversa A'));
          await tester.pumpAndSettle();
          expect(find.text('previous'), findsOneWidget);
        }
        final previousChat =
            width >= 800
                ? tester.widget<ChatView>(find.byType(ChatView)).viewModel
                : null;
        await tester.tap(find.text('Aceitar'));
        await tester.pump();
        expect(loadedRooms, isNot(contains('invite')));
        expect(find.textContaining('Você foi convidado'), findsOneWidget);
        final invitationTile = find.byKey(const ValueKey('invite'));
        final acceptButton = find.descendant(
          of: invitationTile,
          matching: find.byType(TextButton),
        );
        expect(tester.widget<TextButton>(acceptButton).onPressed, isNull);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        snapshot = [roomA, otherUnread, plainJoined];
        pendingAccept.complete(plainJoined);
        await tester.pump();
        await tester.pump();
        expect(loadedRooms.where((id) => id == 'invite'), hasLength(1));
        final opened = tester.widget<ChatView>(find.byType(ChatView)).viewModel;
        expect(opened.roomId, 'invite');
        expect(opened.state.loading, isTrue);
        expect(opened.initialUnreadCount, 2);
        expect(previousChat?.isClosed, width >= 800 ? isTrue : isNull);
        expect(find.text('Carregando mensagens…'), findsOneWidget);
        expect(find.text('Aceitar'), findsNothing);
        expect(find.textContaining('Você foi convidado'), findsNothing);
        if (width >= 800) {
          expect(
            tester
                .widget<ListTile>(
                  find.descendant(
                    of: find.byType(RoomsView),
                    matching: find.byKey(const ValueKey('invite')),
                  ),
                )
                .selected,
            isTrue,
          );
          expect(find.text('4'), findsOneWidget);
          expect(find.byIcon(Icons.lock_outline), findsOneWidget);
        }
        history.complete([
          fixtureMessage('accepted-history', body: 'Histórico da sala aceita'),
        ]);
        await tester.pumpAndSettle();
        expect(find.text('Histórico da sala aceita'), findsOneWidget);
        expect(find.text('previous'), findsNothing);
        expect(rooms.acceptedRooms, ['invite']);
        expect(rooms.readRooms, ['invite']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await rooms.events.close();
        await chat.events.close();
      },
    );
  }

  testWidgets(
    'Falha na aceitação mantém conversa aberta e não carrega convite',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(Get.reset);
      final pending = Completer<ConversationSummary>();
      final auth =
          FakeAuthRepository()
            ..initializeAction =
                () async => const SessionState(account: fixtureAccount);
      final rooms =
          FakeRoomRepository()
            ..loadAction = (() async => [roomA, invitation])
            ..acceptAction = ((_) => pending.future);
      final loadedRooms = <String>[];
      final chat =
          FakeChatRepository()
            ..historyAction = (id) async {
              loadedRooms.add(id);
              return [fixtureMessage('current', body: 'Conversa atual')];
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
      await tester.tap(find.text('Conversa A'));
      await tester.pumpAndSettle();
      final previous = tester.widget<ChatView>(find.byType(ChatView)).viewModel;
      await tester.tap(find.text('Aceitar'));
      await tester.pump();
      pending.completeError(ConversationError.network);
      await tester.pumpAndSettle();
      expect(
        tester.widget<ChatView>(find.byType(ChatView)).viewModel,
        same(previous),
      );
      expect(previous.isClosed, isFalse);
      expect(find.text('Conversa atual'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.descendant(
          of: find.byType(RoomsView),
          matching: find.byKey(const ValueKey('a')),
        ),
        80,
        scrollable: find.descendant(
          of: find.byType(RoomsView),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        tester
            .widget<ListTile>(
              find.descendant(
                of: find.byType(RoomsView),
                matching: find.byKey(const ValueKey('a')),
              ),
            )
            .selected,
        isTrue,
      );
      expect(loadedRooms, ['a']);
      expect(find.textContaining('Você foi convidado'), findsOneWidget);
      expect(find.textContaining('Não foi possível aceitar'), findsOneWidget);
      expect(find.text('Aceitar'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await rooms.events.close();
      await chat.events.close();
    },
  );
}
