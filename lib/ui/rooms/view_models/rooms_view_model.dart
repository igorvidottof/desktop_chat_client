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
  int _snapshotRevision = 0;
  bool _inFlight = false;
  bool _pending = false;
  ConversationError? _syncFailure;
  List<ConversationSummary> _nativeRooms = const [];
  final _readCounts = <String, int>{};
  final _reading = <String>{};
  @override
  void onInit() {
    super.onInit();
    _generation++;
    _subscription = repository.updates.listen((event) {
      if (!_active) return;
      if (event.kind == MatrixUpdateKind.message) {
        _readCounts.remove(event.conversationId);
      }
      if (repository.initialRoomSyncPending) {
        _syncFailure = switch (event.status) {
          MatrixSyncStatus.reconnecting => ConversationError.network,
          MatrixSyncStatus.authenticationRequired =>
            ConversationError.notAuthenticated,
          _ => null,
        };
        if (_syncFailure != null && state.isEmpty) {
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

  void selectRoom(ConversationSummary? room) {
    if (!_active || room?.isInvited == true) return;
    state = state.copyWith(selected: room);
    if (room == null || _reading.contains(room.id)) return;
    final current = state.rooms.where((r) => r.id == room.id).firstOrNull;
    if (current == null || current.unreadMessageCount == 0) return;
    _readCounts[room.id] = current.unreadMessageCount;
    _reading.add(room.id);
    state = state.copyWith(error: null);
    _projectRooms();
    unawaited(_markRead(room.id));
  }

  Future<void> _markRead(String roomId) async {
    final generation = _generation;
    try {
      await repository.markRead(roomId);
    } catch (error) {
      if (!_active || generation != _generation) return;
      _readCounts.remove(roomId);
      _projectRooms();
      state = state.copyWith(
        error: error is ConversationError ? error : ConversationError.internal,
      );
    } finally {
      _reading.remove(roomId);
    }
  }

  void _projectRooms() {
    // Oculta o contador otimisticamente até o sync confirmar o recibo nativo.
    // Uma nova mensagem ou contagem maior volta a permitir o badge.
    final rooms =
        _nativeRooms.where((room) => !room.isInvited).map((room) {
          final readCount = _readCounts[room.id];
          if (readCount == null) return room;
          if (room.unreadMessageCount == 0 ||
              room.unreadMessageCount > readCount) {
            _readCounts.remove(room.id);
            return room;
          }
          return ConversationSummary(
            id: room.id,
            displayName: room.displayName,
            isEncrypted: room.isEncrypted,
          );
        }).toList();
    _readCounts.removeWhere((id, _) => !rooms.any((room) => room.id == id));
    state = state.copyWith(
      rooms: rooms,
      invitations: _nativeRooms.where((room) => room.isInvited).toList(),
      invitationErrors: {
        for (final entry in state.invitationErrors.entries)
          if (_nativeRooms.any((r) => r.id == entry.key && r.isInvited))
            entry.key: entry.value,
      },
      selected: rooms.where((r) => r.id == state.selected?.id).firstOrNull,
    );
  }

  Future<void> acceptInvitation(String roomId) async {
    if (!_active ||
        state.accepting.contains(roomId) ||
        !state.invitations.any((room) => room.id == roomId)) {
      return;
    }
    final generation = _generation;
    state = state.copyWith(
      accepting: {...state.accepting, roomId},
      invitationErrors: {...state.invitationErrors}..remove(roomId),
    );
    try {
      final joined = await repository.acceptInvitation(roomId);
      if (!_active || generation != _generation) return;
      // A resposta confirma o store nativo. Retratos iniciados antes dela são descartados.
      _snapshotRevision++;
      _nativeRooms = [
        ..._nativeRooms.where((room) => room.id != roomId),
        joined,
      ]..sort((a, b) {
        final name = a.displayName.compareTo(b.displayName);
        return name == 0 ? a.id.compareTo(b.id) : name;
      });
      _projectRooms();
      selectRoom(joined);
      if (_inFlight) {
        _pending = true;
      } else {
        unawaited(load(background: true));
      }
    } catch (error) {
      if (!_active || generation != _generation) return;
      state = state.copyWith(
        invitationErrors: {
          ...state.invitationErrors,
          roomId:
              error is ConversationError ? error : ConversationError.internal,
        },
      );
    } finally {
      if (_active && generation == _generation) {
        state = state.copyWith(accepting: {...state.accepting}..remove(roomId));
      }
    }
  }

  Future<void> load({bool background = false}) async {
    if (!_active || _inFlight) return;
    _inFlight = true;
    final generation = _generation;
    final revision = _snapshotRevision;
    state = state.copyWith(
      loading: !background && state.isEmpty,
      refreshing: background || !state.isEmpty,
      error: null,
    );
    try {
      final rooms = await repository.load();
      if (!_active || generation != _generation) return;
      if (revision != _snapshotRevision) {
        _pending = true;
        return;
      }
      _nativeRooms = List.unmodifiable(rooms);
      _projectRooms();
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
        final awaitingSync = state.isEmpty && repository.initialRoomSyncPending;
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
