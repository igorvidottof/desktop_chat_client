import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop_chat_client/domain/models/models.dart' as domain;
import 'package:desktop_chat_client/src/rust/api/simple.dart' as native;
import 'package:desktop_chat_client/data/services/matrix_bridge_service.dart';
import 'package:desktop_chat_client/data/services/native_matrix_updates.dart';
import 'package:desktop_chat_client/data/repositories/matrix_auth_repository.dart';
import 'package:desktop_chat_client/data/repositories/matrix_room_repository.dart';
import 'package:desktop_chat_client/data/repositories/matrix_chat_repository.dart';
import '../../support/bridge_harness.dart' show StreamSource;

const account = native.AccountSummary(
  userId: '@fixture:example.invalid',
  deviceId: 'DEVICE',
  homeserverAddress: 'https://example.invalid',
);
void main() {
  test(
    'Rooms mapeia convites, encaminha aceitação e normaliza falhas',
    () async {
      const invite = native.ConversationSummary(
        id: 'invite',
        displayName: 'Convite',
        isInvited: true,
        isEncrypted: true,
      );
      final repository = MatrixRoomRepository(
        MatrixBridgeService(
          rooms: () async => [invite],
          acceptInvitation: ({required conversationId}) async {
            expect(conversationId, 'invite');
            return const native.ConversationSummary(
              id: 'invite',
              displayName: 'Convite',
              isEncrypted: true,
            );
          },
        ),
        EmptyMatrixUpdateSource(),
      );
      expect((await repository.load()).single.isInvited, isTrue);
      final joined = await repository.acceptInvitation('invite');
      expect(joined.isInvited, isFalse);
      expect(joined.isEncrypted, isTrue);
      for (final error in [
        ...native.ConversationError.values,
        StateError('private'),
      ]) {
        final failing = MatrixRoomRepository(
          MatrixBridgeService(
            acceptInvitation: ({required conversationId}) async => throw error,
          ),
          EmptyMatrixUpdateSource(),
        );
        await expectLater(
          failing.acceptInvitation('invite'),
          throwsA(
            error is native.ConversationError
                ? domain.ConversationError.values.byName(error.name)
                : domain.ConversationError.internal,
          ),
        );
      }
    },
  );
  test('Rooms encaminha leitura e normaliza falhas nativas', () async {
    String? readRoom;
    final repository = MatrixRoomRepository(
      MatrixBridgeService(
        markRoomRead: ({required conversationId}) async {
          readRoom = conversationId;
        },
      ),
      EmptyMatrixUpdateSource(),
    );
    await repository.markRead('opaque');
    expect(readRoom, 'opaque');
    for (final error in [
      ...native.ConversationError.values,
      StateError('private'),
    ]) {
      final failing = MatrixRoomRepository(
        MatrixBridgeService(
          markRoomRead: ({required conversationId}) async => throw error,
        ),
        EmptyMatrixUpdateSource(),
      );
      await expectLater(
        failing.markRead('opaque'),
        throwsA(
          error is native.ConversationError
              ? domain.ConversationError.values.byName(error.name)
              : domain.ConversationError.internal,
        ),
      );
    }
  });
  test('Auth mapeia resumos e mantém somente a projeção da sessão', () async {
    final repository = MatrixAuthRepository(
      MatrixBridgeService(
        initialize: () async => const native.SessionState(account: account),
        login: (address, username, password) async {
          expect(password, 'synthetic');
          return account;
        },
        probe:
            (address) async => native.ServerInfo(
              serverAddress: address,
              supportsPasswordLogin: true,
            ),
        logout:
            () async => const native.LogoutResult(
              remoteStatus: native.RemoteLogoutStatus.network,
              storeCleanupPending: true,
            ),
      ),
    );
    final state = await repository.initialize();
    expect(state.account, isA<domain.AccountSummary>());
    expect(repository.account!.deviceId, 'DEVICE');
    expect(
      (await repository.probe('https://example.invalid')).supportsPasswordLogin,
      isTrue,
    );
    expect(
      await repository.login('address', 'user', 'synthetic'),
      state.account,
    );
    final logout = await repository.logout();
    expect(logout.remoteStatus, domain.RemoteLogoutStatus.network);
    expect(logout.storeCleanupPending, isTrue);
    expect(repository.account, isNull);
  });
  test(
    'Auth normaliza categorias nativas e não vaza falhas inesperadas',
    () async {
      for (final error in native.LoginError.values) {
        final repository = MatrixAuthRepository(
          MatrixBridgeService(login: (_, _, _) async => throw error),
        );
        await expectLater(
          repository.login('address', 'user', 'synthetic'),
          throwsA(domain.LoginError.values.byName(error.name)),
        );
      }
      final repository = MatrixAuthRepository(
        MatrixBridgeService(
          initialize: () => throw StateError('private'),
          probe: (_) => throw StateError('private'),
          logout: () => throw StateError('private'),
        ),
      );
      await expectLater(
        repository.initialize(),
        throwsA(domain.SessionError.internal),
      );
      await expectLater(
        repository.probe('address'),
        throwsA(domain.ProbeError.internal),
      );
      await expectLater(
        repository.logout(),
        throwsA(domain.LogoutError.internal),
      );
    },
  );
  test('Rooms produz lista imutável e mapeia falhas', () async {
    final source = EmptyMatrixUpdateSource();
    final repository = MatrixRoomRepository(
      MatrixBridgeService(
        rooms:
            () async => [
              const native.ConversationSummary(
                id: 'opaque',
                displayName: '<Sala>',
                unreadMessageCount: 12,
                isEncrypted: true,
              ),
            ],
      ),
      source,
    );
    final rooms = await repository.load();
    expect(
      rooms.single,
      const domain.ConversationSummary(
        id: 'opaque',
        displayName: '<Sala>',
        unreadMessageCount: 12,
        isEncrypted: true,
      ),
    );
    expect(() => rooms.clear(), throwsUnsupportedError);
    for (final error in native.ConversationError.values) {
      await expectLater(
        MatrixRoomRepository(
          MatrixBridgeService(rooms: () async => throw error),
          source,
        ).load(),
        throwsA(domain.ConversationError.values.byName(error.name)),
      );
    }
  });
  test(
    'Chat preserva texto literal, timestamp, identidade e aceitação',
    () async {
      const text = '  <script>literal</script>\n🦀  ';
      final repository = MatrixChatRepository(
        MatrixBridgeService(
          history:
              ({required conversationId}) async => [
                const native.MessageSummary(
                  id: 'event',
                  senderId: '@sender:example.invalid',
                  body: text,
                  timestampMs: 1234,
                  isOwn: true,
                ),
              ],
          send: ({required conversationId, required body}) async {
            expect(conversationId, 'opaque');
            expect(body, text);
            return const native.SendMessageResult(eventId: 'accepted');
          },
        ),
        EmptyMatrixUpdateSource(),
      );
      final messages = await repository.history('opaque');
      expect(messages.single.body, text);
      expect(messages.single.timestampMs, 1234);
      expect(messages.single.isOwn, isTrue);
      expect(() => messages.clear(), throwsUnsupportedError);
      expect((await repository.send('opaque', text)).eventId, 'accepted');
      expect(repository.reconcile(messages, messages).length, 1);
    },
  );
  test(
    'Chat normaliza erros de história/envio e falhas de transporte',
    () async {
      final source = EmptyMatrixUpdateSource();
      for (final error in native.MessageHistoryError.values) {
        await expectLater(
          MatrixChatRepository(
            MatrixBridgeService(
              history: ({required conversationId}) async => throw error,
            ),
            source,
          ).history('room'),
          throwsA(domain.MessageHistoryError.values.byName(error.name)),
        );
      }
      for (final error in native.SendMessageError.values) {
        await expectLater(
          MatrixChatRepository(
            MatrixBridgeService(
              send:
                  ({required conversationId, required body}) async =>
                      throw error,
            ),
            source,
          ).send('room', 'synthetic'),
          throwsA(domain.SendMessageError.values.byName(error.name)),
        );
      }
      final repository = MatrixChatRepository(
        MatrixBridgeService(
          history: ({required conversationId}) => throw StateError('private'),
          send:
              ({required conversationId, required body}) =>
                  throw StateError('private'),
        ),
        source,
      );
      await expectLater(
        repository.history('room'),
        throwsA(domain.MessageHistoryError.internal),
      );
      await expectLater(
        repository.send('room', 'synthetic'),
        throwsA(domain.SendMessageError.internal),
      );
    },
  );
  test(
    'Repos compartilham transporte e encaminham eventos sem DTOs nativos',
    () async {
      final events = StreamController<native.MatrixUpdate>.broadcast(
        sync: true,
      );
      final source = StreamSource(events.stream);
      final rooms = MatrixRoomRepository(const MatrixBridgeService(), source);
      final chat = MatrixChatRepository(const MatrixBridgeService(), source);
      final roomEvents = <domain.MatrixUpdate>[];
      final chatEvents = <domain.MatrixUpdate>[];
      final a = rooms.updates.listen(roomEvents.add);
      final b = chat.updates.listen(chatEvents.add);
      events.add(
        const native.MatrixUpdate(
          subscriptionId: 'native',
          sequence: 1,
          kind: native.MatrixUpdateKind.message,
          conversationId: 'opaque',
          message: native.MessageSummary(
            id: 'event',
            senderId: 'sender',
            body: 'literal',
            timestampMs: 1,
            isOwn: false,
          ),
          status: native.MatrixSyncStatus.connected,
        ),
      );
      expect(roomEvents.single.message!.body, 'literal');
      expect(chatEvents.single.kind, domain.MatrixUpdateKind.message);
      await a.cancel();
      await b.cancel();
      expect(events.hasListener, isFalse);
      await events.close();
    },
  );
}
