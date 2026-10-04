import '../../../domain/models/models.dart';

const _unchanged = Object();

class RoomsState {
  RoomsState({
    this.loading = true,
    this.refreshing = false,
    List<ConversationSummary> rooms = const [],
    this.error,
    this.selected,
  }) : rooms = List.unmodifiable(rooms);
  final bool loading;
  final bool refreshing;
  final List<ConversationSummary> rooms;
  final ConversationError? error;
  final ConversationSummary? selected;
  RoomsState copyWith({
    bool? loading,
    bool? refreshing,
    List<ConversationSummary>? rooms,
    Object? error = _unchanged,
    Object? selected = _unchanged,
  }) => RoomsState(
    loading: loading ?? this.loading,
    refreshing: refreshing ?? this.refreshing,
    rooms: rooms ?? this.rooms,
    error:
        identical(error, _unchanged) ? this.error : error as ConversationError?,
    selected:
        identical(selected, _unchanged)
            ? this.selected
            : selected as ConversationSummary?,
  );
}
