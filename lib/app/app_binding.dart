import 'dart:async';
import 'package:get/get.dart';
import '../data/repositories/auth_repository.dart';
import '../data/repositories/room_repository.dart';
import '../data/repositories/chat_repository.dart';
import '../data/repositories/matrix_auth_repository.dart';
import '../data/repositories/matrix_room_repository.dart';
import '../data/repositories/matrix_chat_repository.dart';
import '../data/services/matrix_bridge_service.dart';
import '../data/services/native_matrix_updates.dart';
import '../domain/models/models.dart';
import '../ui/auth/view_models/auth_view_model.dart';
import '../ui/rooms/view_models/rooms_view_model.dart';
import '../ui/chat/view_models/chat_view_model.dart';

/// A raiz possui os registros; reconstruções das Views não alteram sua duração.
class AppBinding extends Bindings {
  AppBinding({
    this.bridge = const MatrixBridgeService(),
    AuthRepository? authRepository,
    RoomRepository? roomRepository,
    ChatRepository? chatRepository,
  }) : _authRepository = authRepository,
       _roomRepository = roomRepository,
       _chatRepository = chatRepository;

  final MatrixBridgeService bridge;
  final AuthRepository? _authRepository;
  final RoomRepository? _roomRepository;
  final ChatRepository? _chatRepository;
  final String _tag = 'chat-app-${_nextId++}';
  static int _nextId = 0;
  late final AuthViewModel auth;
  RoomsViewModel? rooms;
  ChatViewModel? chat;
  MatrixUpdateSource? _source;
  void Function()? _removeAuthListener;
  void Function()? _removeRoomsListener;
  int? _epoch;
  AccountSummary? _account;
  bool _disposed = false;

  @override
  void dependencies() {
    Get.put<MatrixBridgeService>(bridge, tag: _tag);
    Get.put<AuthRepository>(
      _authRepository ?? MatrixAuthRepository(Get.find(tag: _tag)),
      tag: _tag,
    );
    auth = Get.put<AuthViewModel>(
      AuthViewModel(repository: Get.find<AuthRepository>(tag: _tag)),
      tag: _tag,
      permanent: true,
    );
    _removeAuthListener = auth.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    final state = auth.state;
    final active = !_disposed && state.account != null && !state.loggingOut;
    if (active && _epoch == state.sessionEpoch && _account == state.account) {
      return;
    }
    _closeSession();
    if (!active) return;
    final epoch = _epoch = state.sessionEpoch;
    _account = state.account;
    bool current() =>
        !_disposed &&
        !auth.isClosed &&
        auth.state.account != null &&
        !auth.state.loggingOut &&
        auth.state.sessionEpoch == epoch;

    // Salas e conversa compartilham uma única porta FRB da sessão de apresentação.
    final source = _source = bridge.openUpdates();
    Get.put<RoomRepository>(
      _roomRepository ?? MatrixRoomRepository(bridge, source),
      tag: _tag,
    );
    Get.put<ChatRepository>(
      _chatRepository ?? MatrixChatRepository(bridge, source),
      tag: _tag,
    );
    rooms = Get.put<RoomsViewModel>(
      RoomsViewModel(
        repository: Get.find<RoomRepository>(tag: _tag),
        sessionIsCurrent: current,
      ),
      tag: _tag,
    );
    _removeRoomsListener = rooms!.addListener(() {
      final id = rooms!.state.selected?.id;
      if (chat?.roomId == id) return;
      _closeChat();
      if (id == null || !current()) return;
      chat = Get.put<ChatViewModel>(
        ChatViewModel(
          repository: Get.find<ChatRepository>(tag: _tag),
          roomId: id,
          initialUnreadCount: rooms!.state.selected!.unreadMessageCount,
          sessionIsCurrent: current,
        ),
        tag: _tag,
      );
    });
  }

  void _closeChat() {
    if (chat == null) return;
    unawaited(Get.delete<ChatViewModel>(tag: _tag));
    chat = null;
  }

  void _closeSession() {
    _epoch = null;
    _account = null;
    _removeRoomsListener?.call();
    _removeRoomsListener = null;
    _closeChat();
    if (rooms != null) {
      unawaited(Get.delete<RoomsViewModel>(tag: _tag));
      rooms = null;
      unawaited(Get.delete<RoomRepository>(tag: _tag));
      unawaited(Get.delete<ChatRepository>(tag: _tag));
    }
    final source = _source;
    _source = null;
    // Fechar o consumidor não encerra a sincronização que pertence a Rust.
    if (source != null) unawaited(source.dispose());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _removeAuthListener?.call();
    _closeSession();
    unawaited(Get.delete<AuthViewModel>(tag: _tag, force: true));
    unawaited(Get.delete<AuthRepository>(tag: _tag));
    unawaited(Get.delete<MatrixBridgeService>(tag: _tag));
  }
}
