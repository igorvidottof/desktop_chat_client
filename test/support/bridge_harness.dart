import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:desktop_chat_client/app/chat_app.dart';
import 'package:desktop_chat_client/app/app_binding.dart';
import 'package:desktop_chat_client/data/repositories/matrix_chat_repository.dart';
import 'package:desktop_chat_client/domain/models/models.dart' as domain;
import 'package:desktop_chat_client/ui/auth/view_models/auth_view_model.dart';
import 'package:desktop_chat_client/ui/core/ui/state_panel.dart';
import 'package:desktop_chat_client/ui/auth/widgets/failure_messages.dart'
    as auth;
import 'package:desktop_chat_client/ui/rooms/widgets/failure_messages.dart'
    as rooms;
import 'package:desktop_chat_client/ui/rooms/widgets/desktop_shell.dart';
import 'package:desktop_chat_client/ui/chat/widgets/chat_view.dart';
import 'package:desktop_chat_client/ui/chat/view_models/chat_view_model.dart';
import 'package:desktop_chat_client/ui/chat/widgets/message_presentation.dart'
    as chat;
import 'package:desktop_chat_client/data/repositories/message_reconciliation.dart'
    as reconciliation;
import 'package:desktop_chat_client/data/services/matrix_bridge_service.dart';
import 'package:desktop_chat_client/data/services/native_matrix_updates.dart';
import 'package:desktop_chat_client/data/repositories/model_mapping.dart';
import 'package:desktop_chat_client/src/rust/api/simple.dart';

export 'package:desktop_chat_client/data/services/matrix_bridge_service.dart';
export 'package:desktop_chat_client/data/services/native_matrix_updates.dart';
export 'package:desktop_chat_client/data/repositories/chat_repository.dart'
    show maxMessageChars;
export 'package:desktop_chat_client/ui/chat/widgets/chat_view.dart';

Widget fixtureApp({
  required SessionInitializer initialize,
  required Future<LogoutResult> Function() logoutAction,
  required ServerProbe probe,
  required PasswordLogin authenticate,
  required ConversationLoader loadConversations,
  MessageHistoryLoader loadHistory = loadMessageHistory,
  TextMessageSender sendMessage = sendTextMessage,
  MatrixUpdateSourceFactory updates = EmptyMatrixUpdateSource.new,
}) => ChatApp(
  bridge: MatrixBridgeService(
    initialize: initialize,
    logout: logoutAction,
    probe: probe,
    login: authenticate,
    rooms: loadConversations,
    history: loadHistory,
    send: sendMessage,
    openUpdates: updates,
  ),
);

class ConversationList extends StatefulWidget {
  const ConversationList({
    super.key,
    required this.load,
    required this.loadHistory,
    this.sendMessage = sendTextMessage,
    this.updates = EmptyMatrixUpdateSource.new,
  });
  final ConversationLoader load;
  final MessageHistoryLoader loadHistory;
  final TextMessageSender sendMessage;
  final MatrixUpdateSourceFactory updates;
  @override
  State<ConversationList> createState() => _ConversationListState();
}

class _ConversationListState extends State<ConversationList> {
  late final AppBinding binding;
  @override
  void initState() {
    super.initState();
    binding = AppBinding(
      bridge: MatrixBridgeService(
        initialize:
            () async => const SessionState(
              account: AccountSummary(
                userId: '@fixture:example.invalid',
                deviceId: 'FIXTURE',
                homeserverAddress: 'https://example.invalid',
              ),
            ),
        rooms: widget.load,
        history: widget.loadHistory,
        send: widget.sendMessage,
        openUpdates: widget.updates,
      ),
    )..dependencies();
  }

  @override
  void dispose() {
    binding.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GetBuilder<AuthViewModel>(
    init: binding.auth,
    global: false,
    autoRemove: false,
    builder:
        (_) =>
            binding.rooms == null
                ? const StatePanel(
                  message: 'Carregando conversas…',
                  loading: true,
                )
                : SizedBox(
                  width: 700,
                  child: DesktopShell(
                    auth: binding.auth,
                    rooms: binding.rooms!,
                    conversationBuilder:
                        (room) => ChatView(
                          key: ValueKey(room.id),
                          viewModel: binding.chat!,
                        ),
                  ),
                ),
  );
}

class StreamSource implements MatrixUpdateSource {
  @override
  bool get initialRoomSyncPending => false;
  StreamSource(this.updates);
  @override
  final Stream<MatrixUpdate> updates;
  @override
  Future<void> dispose() async {}
}

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.conversation,
    required this.load,
    required this.sessionActive,
    this.send = sendTextMessage,
    this.updates = const Stream.empty(),
  });
  final ConversationSummary conversation;
  final MessageHistoryLoader load;
  final TextMessageSender send;
  final ValueNotifier<bool> sessionActive;
  final Stream<MatrixUpdate> updates;
  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  late final ChatViewModel viewModel;
  void _changed() {
    if (!widget.sessionActive.value) {
      viewModel.invalidateSession();
    }
  }

  @override
  void initState() {
    super.initState();
    viewModel = ChatViewModel(
      roomId: widget.conversation.id,
      repository: MatrixChatRepository(
        MatrixBridgeService(history: widget.load, send: widget.send),
        StreamSource(widget.updates),
      ),
    )..onStart();
    widget.sessionActive.addListener(_changed);
  }

  @override
  void dispose() {
    widget.sessionActive.removeListener(_changed);
    viewModel.onDelete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.conversation.displayName)),
    body: ChatView(viewModel: viewModel),
  );
}

String probeErrorMessage(ProbeError error) =>
    auth.probeErrorMessage(domain.ProbeError.values.byName(error.name));
String loginErrorMessage(LoginError error) =>
    auth.loginErrorMessage(domain.LoginError.values.byName(error.name));
String sessionErrorMessage(SessionError error) =>
    auth.sessionErrorMessage(domain.SessionError.values.byName(error.name));
String logoutErrorMessage(LogoutError error) =>
    auth.logoutErrorMessage(domain.LogoutError.values.byName(error.name));
String conversationErrorMessage(ConversationError error) =>
    rooms.conversationErrorMessage(
      domain.ConversationError.values.byName(error.name),
    );
String messageHistoryErrorMessage(MessageHistoryError error) =>
    chat.messageHistoryErrorMessage(
      domain.MessageHistoryError.values.byName(error.name),
    );
String sendMessageErrorMessage(SendMessageError error) => chat
    .sendMessageErrorMessage(domain.SendMessageError.values.byName(error.name));
bool historyRetryable(MessageHistoryError error) =>
    chat.historyRetryable(domain.MessageHistoryError.values.byName(error.name));
String messageTimestamp(int time) => chat.messageTimestamp(time);
List<domain.MessageSummary> mergeMessages(
  Iterable<MessageSummary> history,
  Iterable<MessageSummary> incoming,
) => reconciliation.mergeMessages(
  history.map(mapMessage),
  incoming.map(mapMessage),
);
