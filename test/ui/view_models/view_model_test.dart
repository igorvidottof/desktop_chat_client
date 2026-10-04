import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:desktop_chat_client/app/app_binding.dart';
import 'package:desktop_chat_client/data/services/matrix_bridge_service.dart';
import 'package:desktop_chat_client/data/services/native_matrix_updates.dart';
import 'package:desktop_chat_client/domain/models/models.dart';
import 'package:desktop_chat_client/ui/auth/view_models/auth_view_model.dart';
import 'package:desktop_chat_client/ui/rooms/view_models/rooms_view_model.dart';
import 'package:desktop_chat_client/ui/chat/view_models/chat_view_model.dart';
import '../../support/repository_fakes.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('Logout invalida eventos e futuros antes do próximo frame', () async {
    final auth =
        FakeAuthRepository()
          ..initializeAction =
              () async => const SessionState(account: fixtureAccount);
    final rooms = FakeRoomRepository();
    final chat = FakeChatRepository();
    final pendingSend = Completer<SendMessageResult>();
    final pendingLogout = Completer<LogoutResult>();
    chat.sendAction = (_, _) => pendingSend.future;
    auth.logoutAction = () => pendingLogout.future;
    final binding = AppBinding(
      bridge: MatrixBridgeService(openUpdates: EmptyMatrixUpdateSource.new),
      authRepository: auth,
      roomRepository: rooms,
      chatRepository: chat,
    )..dependencies();
    addTearDown(() {
      binding.dispose();
      Get.reset();
    });
    await settle();
    binding.rooms!.selectRoom(roomA);
    await settle();
    final conversation = binding.chat!;
    final sending = conversation.sendMessage('synthetic');
    final loggingOut = binding.auth.logout();
    chat.events.add(fixtureUpdate(message: fixtureMessage('stale')));
    expect(conversation.state.messages, isEmpty);
    expect(conversation.isClosed, isTrue);
    expect(chat.events.hasListener, isFalse);
    pendingSend.complete(const SendMessageResult(eventId: 'stale-accepted'));
    expect(await sending, isFalse);
    expect(conversation.state.sentEventId, isNull);
    pendingLogout.complete(
      const LogoutResult(
        remoteStatus: RemoteLogoutStatus.confirmed,
        storeCleanupPending: false,
      ),
    );
    await loggingOut;
    binding.dispose();
    await rooms.events.close();
    await chat.events.close();
  });

  test('Auth: restauração, erro, login, logout e sessão projetada', () async {
    final repository = FakeAuthRepository();
    final pending = Completer<SessionState>();
    repository.initializeAction = () => pending.future;
    final viewModel = AuthViewModel(repository: repository)..onStart();
    addTearDown(viewModel.onDelete.call);
    expect(viewModel.state.initializing, isTrue);
    pending.complete(const SessionState());
    await settle();
    expect(viewModel.state.initializing, isFalse);
    repository.loginAction = () async => throw LoginError.invalidCredentials;
    await viewModel.login('address', 'user', 'synthetic');
    expect(viewModel.state.loginError, LoginError.invalidCredentials);
    repository.loginAction = () async => fixtureAccount;
    await viewModel.login('address', 'user', 'synthetic');
    expect(viewModel.state.account, repository.account);
    expect(viewModel.state.loginError, isNull);
    await viewModel.logout();
    expect(viewModel.state.account, isNull);
    expect(repository.account, isNull);
  });

  test('Auth: reserva de login e rejeição depois de descarte', () async {
    final repository = FakeAuthRepository();
    final pending = Completer<AccountSummary>();
    var calls = 0;
    repository.loginAction = () {
      calls++;
      return pending.future;
    };
    final viewModel = AuthViewModel(repository: repository)..onStart();
    await settle();
    final first = viewModel.login('address', 'user', 'synthetic');
    await viewModel.login('address', 'user', 'synthetic');
    expect(calls, 1);
    expect(viewModel.state.loggingIn, isTrue);
    viewModel.onDelete();
    pending.complete(fixtureAccount);
    await first;
    expect(viewModel.state.account, isNull);
  });

  test('Rooms: estados, seleção única, refresh visível e limpeza', () async {
    final repository = FakeRoomRepository();
    final pending = Completer<List<ConversationSummary>>();
    repository.loadAction = () => pending.future;
    final viewModel = RoomsViewModel(repository: repository)..onStart();
    expect(viewModel.state.loading, isTrue);
    pending.complete([roomA, roomB]);
    await settle();
    viewModel.selectRoom(roomB);
    expect(viewModel.state.selected, roomB);
    final refresh = Completer<List<ConversationSummary>>();
    repository.loadAction = () => refresh.future;
    repository.events.add(
      fixtureUpdate(kind: MatrixUpdateKind.conversationsChanged),
    );
    expect(viewModel.state.refreshing, isTrue);
    expect(viewModel.state.rooms, [roomA, roomB]);
    refresh.complete([roomB]);
    await settle();
    expect(viewModel.state.selected, roomB);
    repository.loadAction = () async => throw ConversationError.network;
    await viewModel.load(background: true);
    expect(viewModel.state.rooms, [roomB]);
    expect(viewModel.state.error, ConversationError.network);
    repository.loadAction = () async => [];
    await viewModel.load();
    expect(viewModel.state.rooms, isEmpty);
    expect(viewModel.state.selected, isNull);
    viewModel.onDelete();
    await settle();
    expect(repository.events.hasListener, isFalse);
    await repository.events.close();
  });

  test(
    'Rooms: resultado de request descartado não atualiza outra sessão',
    () async {
      final repository = FakeRoomRepository();
      final pending = Completer<List<ConversationSummary>>();
      repository.loadAction = () => pending.future;
      final viewModel = RoomsViewModel(repository: repository)..onStart();
      await settle();
      viewModel.onDelete();
      final previous = viewModel.state;
      pending.completeError(ConversationError.network);
      await settle();
      expect(viewModel.state, same(previous));
      expect(repository.events.hasListener, isFalse);
      await repository.events.close();
    },
  );

  test('Chat: troca A/B rejeita história e envio atrasados de A', () async {
    final chat = FakeChatRepository();
    final historyA = Completer<List<MessageSummary>>();
    final sendA = Completer<SendMessageResult>();
    chat.historyAction =
        (id) =>
            id == 'a' ? historyA.future : Future.value([fixtureMessage('B')]);
    chat.sendAction = (_, _) => sendA.future;
    var viewModel = ChatViewModel(repository: chat, roomId: 'a')..onStart();
    await settle();
    expect(viewModel.state.loading, isTrue);
    viewModel.onDelete();
    viewModel = ChatViewModel(repository: chat, roomId: 'b')..onStart();
    await settle();
    expect(viewModel.state.messages.single.id, 'B');
    historyA.complete([fixtureMessage('A')]);
    await settle();
    expect(viewModel.state.messages.single.id, 'B');
    viewModel.onDelete();
    viewModel = ChatViewModel(repository: chat, roomId: 'a')..onStart();
    await settle();
    final sending = viewModel.sendMessage('synthetic');
    viewModel.onDelete();
    viewModel = ChatViewModel(repository: chat, roomId: 'b')..onStart();
    await settle();
    sendA.complete(const SendMessageResult(eventId: 'old-send'));
    expect(await sending, isFalse);
    expect(viewModel.state.sentEventId, isNull);
    expect(viewModel.state.messages.single.id, 'B');
    viewModel.onDelete();
    await settle();
    expect(chat.events.hasListener, isFalse);
    await chat.events.close();
  });

  test(
    'Chat: sending, deduplicação, refresh e resultado aceito independente da história',
    () async {
      final chat = FakeChatRepository();
      final pending = Completer<SendMessageResult>();
      chat.sendAction = (_, _) => pending.future;
      final viewModel = ChatViewModel(repository: chat, roomId: 'a')..onStart();
      await settle();
      expect(viewModel.state.messages, isEmpty);
      final sending = viewModel.sendMessage('synthetic');
      expect(viewModel.state.sending, isTrue);
      expect(await viewModel.sendMessage('synthetic'), isFalse);
      chat.events.add(fixtureUpdate(message: fixtureMessage('accepted')));
      chat.events.add(fixtureUpdate(message: fixtureMessage('accepted')));
      expect(viewModel.state.messages.length, 1);
      chat.historyAction = (_) async => throw MessageHistoryError.network;
      pending.complete(const SendMessageResult(eventId: 'accepted'));
      expect(await sending, isTrue);
      expect(chat.sends, 1);
      expect(viewModel.state.sentEventId, 'accepted');
      expect(viewModel.state.sendError, isNull);
      expect(viewModel.state.error, MessageHistoryError.network);
      expect(viewModel.state.messages.single.id, 'accepted');
      viewModel.onDelete();
      await chat.events.close();
    },
  );
}
