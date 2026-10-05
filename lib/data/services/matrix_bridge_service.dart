import '../../src/rust/api/simple.dart' as native;
import 'native_matrix_updates.dart';

typedef SessionInitializer = Future<native.SessionState> Function();
typedef ServerProbe = Future<native.ServerInfo> Function(String address);
typedef PasswordLogin =
    Future<native.AccountSummary> Function(
      String address,
      String username,
      String password,
    );
typedef ConversationLoader =
    Future<List<native.ConversationSummary>> Function();
typedef MessageHistoryLoader =
    Future<List<native.MessageSummary>> Function({
      required String conversationId,
    });
typedef TextMessageSender =
    Future<native.SendMessageResult> Function({
      required String conversationId,
      required String body,
    });

class MatrixBridgeService {
  const MatrixBridgeService({
    this.initialize = native.initializeSession,
    this.logout = native.logout,
    this.probe = probeNative,
    this.login = loginNative,
    this.rooms = native.listConversations,
    this.acceptInvitation = native.acceptRoomInvitation,
    this.markRoomRead = native.markConversationRead,
    this.history = native.loadMessageHistory,
    this.send = native.sendTextMessage,
    this.openUpdates = NativeMatrixUpdateSource.new,
  });

  final SessionInitializer initialize;
  final Future<native.LogoutResult> Function() logout;
  final ServerProbe probe;
  final PasswordLogin login;
  final ConversationLoader rooms;
  final Future<native.ConversationSummary> Function({
    required String conversationId,
  })
  acceptInvitation;
  final Future<void> Function({required String conversationId}) markRoomRead;
  final MessageHistoryLoader history;
  final TextMessageSender send;
  final MatrixUpdateSourceFactory openUpdates;

  static Future<native.ServerInfo> probeNative(String address) =>
      native.probeServer(address: address);
  static Future<native.AccountSummary> loginNative(
    String address,
    String username,
    String password,
  ) => native.login(
    homeserverAddress: address,
    username: username,
    password: password,
  );
}
