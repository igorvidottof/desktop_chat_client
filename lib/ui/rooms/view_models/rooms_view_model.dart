import 'dart:async';
import 'package:get/get.dart';
import '../../../domain/models/models.dart';
import '../../../data/repositories/room_repository.dart';
import 'rooms_state.dart';

class RoomsViewModel extends GetxController {
  RoomsViewModel({required this.repository, bool Function()? sessionIsCurrent})
    : _sessionIsCurrent = sessionIsCurrent ?? (() => true);
  final RoomRepository repository;
  final bool Function() _sessionIsCurrent;
  RoomsState _state = RoomsState();
  RoomsState get state => _state;
  set state(RoomsState value) {
    if (isClosed) return;
    _state = value;
    update();
  }

  bool get _active => !isClosed && _sessionIsCurrent();
  StreamSubscription<MatrixUpdate>? _subscription;
  int _generation = 0;
  bool _inFlight = false;
  bool _pending = false;
  ConversationError? _syncFailure;
  @override
  void onInit() {
    super.onInit();
    _generation++;
    _subscription = repository.updates.listen((event) {
      if (!_active) return;
      if (repository.initialRoomSyncPending) {
        _syncFailure = switch (event.status) {
          MatrixSyncStatus.reconnecting => ConversationError.network,
          MatrixSyncStatus.authenticationRequired =>
            ConversationError.notAuthenticated,
          _ => null,
        };
        if (_syncFailure != null && state.rooms.isEmpty) {
          state = state.copyWith(loading: false, error: _syncFailure);
        }
      }
      if (event.kind == MatrixUpdateKind.conversationsChanged ||
          (event.kind == MatrixUpdateKind.resyncRequired &&
              event.conversationId == null)) {
        if (_inFlight) {
          _pending = true;
        } else {
          unawaited(load(background: true));
        }
      }
    });
    Future.microtask(load);
  }

  @override
  void onClose() {
    _generation++;
    unawaited(_subscription?.cancel());
    super.onClose();
  }

  void selectRoom(ConversationSummary? room) =>
      state = state.copyWith(selected: room);
  Future<void> load({bool background = false}) async {
    if (!_active || _inFlight) return;
    _inFlight = true;
    final generation = _generation;
    state = state.copyWith(
      loading: !background && state.rooms.isEmpty,
      refreshing: background || state.rooms.isNotEmpty,
      error: null,
    );
    try {
      final rooms = await repository.load();
      if (!_active || generation != _generation) return;
      final selected = state.selected;
      state = state.copyWith(
        rooms: List.unmodifiable(rooms),
        selected:
            selected == null
                ? null
                : rooms.where((r) => r.id == selected.id).firstOrNull,
      );
    } on ConversationError catch (error) {
      if (_active && generation == _generation) {
        state = state.copyWith(error: error);
      }
    } catch (_) {
      if (_active && generation == _generation) {
        state = state.copyWith(error: ConversationError.internal);
      }
    } finally {
      if (generation == _generation) _inFlight = false;
      if (_active && generation == _generation) {
        final awaitingSync =
            state.rooms.isEmpty && repository.initialRoomSyncPending;
        final error = state.error ?? (awaitingSync ? _syncFailure : null);
        state = state.copyWith(
          loading: awaitingSync && error == null,
          refreshing: false,
          error: error,
        );
        if (_pending) {
          _pending = false;
          unawaited(load(background: true));
        }
      }
    }
  }
}
