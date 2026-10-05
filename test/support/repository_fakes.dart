import 'dart:async';
import 'package:desktop_chat_client/domain/models/models.dart';
import 'package:desktop_chat_client/data/repositories/auth_repository.dart';
import 'package:desktop_chat_client/data/repositories/room_repository.dart';
import 'package:desktop_chat_client/data/repositories/chat_repository.dart';
import 'package:desktop_chat_client/data/repositories/message_reconciliation.dart';

const fixtureAccount = AccountSummary(
  userId: '@fixture:example.invalid',
  deviceId: 'DEVICE',
  homeserverAddress: 'https://example.invalid',
);
const roomA = ConversationSummary(id: 'a', displayName: 'Conversa A');
const roomB = ConversationSummary(id: 'b', displayName: 'Conversa B');
MessageSummary fixtureMessage(
  String id, {
  bool own = false,
  int time = 1,
  String? body,
}) => MessageSummary(
  id: id,
  senderId: own ? fixtureAccount.userId : '@other:example.invalid',
  body: body ?? id,
  timestampMs: time,
  isOwn: own,
);
MatrixUpdate fixtureUpdate({
  String? roomId = 'a',
  MessageSummary? message,
  MatrixUpdateKind kind = MatrixUpdateKind.message,
}) => MatrixUpdate(
  kind: kind,
  conversationId: roomId,
  message: message,
  status: MatrixSyncStatus.connected,
);

class FakeAuthRepository implements AuthRepository {
  @override
  AccountSummary? account;
  Future<SessionState> Function() initializeAction =
      () async => const SessionState();
  Future<AccountSummary> Function() loginAction = () async => fixtureAccount;
  Future<LogoutResult> Function() logoutAction =
      () async => const LogoutResult(
        remoteStatus: RemoteLogoutStatus.confirmed,
        storeCleanupPending: false,
      );
  @override
  Future<SessionState> initialize() async {
    final result = await initializeAction();
    account = result.account;
    return result;
  }

  @override
  Future<ServerInfo> probe(String address) async =>
      ServerInfo(serverAddress: address, supportsPasswordLogin: true);
  @override
  Future<AccountSummary> login(
    String address,
    String username,
    String password,
  ) async => account = await loginAction();
  @override
  Future<LogoutResult> logout() async {
    final result = await logoutAction();
    account = null;
    return result;
  }
}

class FakeRoomRepository implements RoomRepository {
  final acceptedRooms = <String>[];
  Future<ConversationSummary> Function(String) acceptAction =
      (id) async => ConversationSummary(id: id, displayName: id);
  @override
  Future<ConversationSummary> acceptInvitation(String roomId) {
    acceptedRooms.add(roomId);
    return acceptAction(roomId);
  }

  final readRooms = <String>[];
  Future<void> Function(String) markReadAction = (_) async {};
  @override
  Future<void> markRead(String roomId) {
    readRooms.add(roomId);
    return markReadAction(roomId);
  }

  @override
  bool initialRoomSyncPending = false;
  final events = StreamController<MatrixUpdate>.broadcast(sync: true);
  Future<List<ConversationSummary>> Function() loadAction =
      () async => [roomA, roomB];
  int loads = 0;
  @override
  Stream<MatrixUpdate> get updates => events.stream;
  @override
  Future<List<ConversationSummary>> load() {
    loads++;
    return loadAction();
  }
}

class FakeChatRepository implements ChatRepository {
  final events = StreamController<MatrixUpdate>.broadcast(sync: true);
  Future<List<MessageSummary>> Function(String) historyAction = (_) async => [];
  Future<SendMessageResult> Function(String, String) sendAction =
      (_, _) async => const SendMessageResult(eventId: 'accepted');
  int loads = 0;
  int sends = 0;
  @override
  Stream<MatrixUpdate> get updates => events.stream;
  @override
  Future<List<MessageSummary>> history(String roomId) {
    loads++;
    return historyAction(roomId);
  }

  @override
  Future<SendMessageResult> send(String roomId, String body) {
    sends++;
    return sendAction(roomId, body);
  }

  @override
  List<MessageSummary> reconcile(
    Iterable<MessageSummary> history,
    Iterable<MessageSummary> incoming,
  ) => mergeMessages(history, incoming);
}
