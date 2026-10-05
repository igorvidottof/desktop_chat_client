import 'dart:async';
import 'package:get/get.dart';
import '../../../domain/models/models.dart';
import '../../../data/repositories/chat_repository.dart';
import 'chat_state.dart';

class ChatViewModel extends GetxController {
  ChatViewModel({
    required this.repository,
    required this.roomId,
    this.initialUnreadCount = 0,
    bool Function()? sessionIsCurrent,
  }) : _sessionIsCurrent = sessionIsCurrent ?? (() => true);
  final ChatRepository repository;
  final String roomId;
  final int initialUnreadCount;
  bool _unreadBoundaryResolved = false;
  final bool Function() _sessionIsCurrent;
  ChatState _state = ChatState();
  ChatState get state => _state;
  set state(ChatState value) {
    if (isClosed) return;
    _state = value;
    update();
  }

  int _generation = 0;
  final _duringLoad = <MessageSummary>[];
  bool _inFlight = false;
  bool _pending = false;
  StreamSubscription<MatrixUpdate>? _subscription;
  bool _active = true;
  bool get active => !isClosed && _active && _sessionIsCurrent();
  @override
  void onInit() {
    super.onInit();
    _generation++;
    _subscription = repository.updates.listen(_updated);
    Future.microtask(load);
  }

  @override
  void onClose() {
    _generation++;
    _active = false;
    _duringLoad.clear();
    unawaited(_subscription?.cancel());
    super.onClose();
  }

  void invalidateSession() {
    _active = false;
    _generation++;
    unawaited(_subscription?.cancel());
    _duringLoad.clear();
    state = ChatState(
      loading: false,
      error: MessageHistoryError.notAuthenticated,
    );
  }

  void _updated(MatrixUpdate update) {
    if (!active) return;
    if (update.kind == MatrixUpdateKind.status) {
      state = state.copyWith(syncStatus: update.status);
      return;
    }
    if (update.conversationId != null && update.conversationId != roomId) {
      return;
    }
    if (update.kind == MatrixUpdateKind.resyncRequired) {
      if (_inFlight) {
        _pending = true;
      } else {
        unawaited(load(background: true));
      }
      return;
    }
    final message = update.message;
    if (update.kind != MatrixUpdateKind.message || message == null) return;
    if (_inFlight) {
      if (_duringLoad.length < 128) {
        _duringLoad.add(message);
      } else {
        _pending = true;
      }
    }
    state = state.copyWith(
      messages: repository.reconcile(state.messages, [message]),
    );
  }

  Future<void> load({bool background = false}) async {
    if (!active || _inFlight) return;
    _inFlight = true;
    final generation = _generation;
    state = state.copyWith(
      loading: !background && state.messages.isEmpty,
      refreshing: background || state.messages.isNotEmpty,
      error: null,
    );
    try {
      final messages = await repository.history(roomId);
      if (!active || generation != _generation) return;
      // Resolve apenas no primeiro histórico bem-sucedido. Eventos recebidos
      // após a abertura não fazem parte da contagem capturada na seleção.
      if (!_unreadBoundaryResolved) {
        final arrivingIds = {
          ...state.messages.map((message) => message.id),
          ..._duringLoad.map((message) => message.id),
        };
        final openingHistory =
            repository
                .reconcile(messages, const [])
                .where((message) => !arrivingIds.contains(message.id))
                .toList();
        final insufficient = initialUnreadCount > openingHistory.length;
        state = state.copyWith(
          firstUnreadMessageId:
              initialUnreadCount > 0 && !insufficient
                  ? openingHistory[openingHistory.length - initialUnreadCount]
                      .id
                  : null,
          unreadHistoryInsufficient: insufficient,
        );
        _unreadBoundaryResolved = true;
      }
      state = state.copyWith(
        messages: repository.reconcile(messages, [
          ...state.messages,
          ..._duringLoad,
        ]),
      );
      _duringLoad.clear();
    } on MessageHistoryError catch (error) {
      if (active && generation == _generation) {
        state = state.copyWith(error: error);
      }
    } catch (_) {
      if (active && generation == _generation) {
        state = state.copyWith(error: MessageHistoryError.internal);
      }
    } finally {
      if (generation == _generation) _inFlight = false;
      if (active && generation == _generation) {
        state = state.copyWith(loading: false, refreshing: false);
        if (_pending) {
          _pending = false;
          unawaited(load(background: true));
        }
      }
    }
  }

  Future<bool> sendMessage(String body) async {
    if (!active ||
        state.sending ||
        state.loading ||
        state.error != null ||
        body.trim().isEmpty ||
        body.runes.length > maxMessageChars) {
      return false;
    }
    final generation = _generation;
    state = state.copyWith(sending: true, sendError: null, sentEventId: null);
    try {
      final result = await repository.send(roomId, body);
      if (!active || generation != _generation) return false;
      state = state.copyWith(sentEventId: result.eventId);
      await load(background: true);
      return active && generation == _generation;
    } on SendMessageError catch (error) {
      if (active && generation == _generation) {
        state = state.copyWith(
          sendError: error,
          error:
              error == SendMessageError.notAuthenticated
                  ? MessageHistoryError.notAuthenticated
                  : state.error,
        );
      }
    } catch (_) {
      if (active && generation == _generation) {
        state = state.copyWith(sendError: SendMessageError.internal);
      }
    } finally {
      if (active && generation == _generation) {
        state = state.copyWith(sending: false);
      }
    }
    return false;
  }
}
