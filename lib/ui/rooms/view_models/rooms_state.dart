import '../../../domain/models/models.dart';

const _unchanged = Object();

class RoomsState {
  RoomsState({
    this.loading = true,
    this.refreshing = false,
    List<ConversationSummary> rooms = const [],
    List<ConversationSummary> invitations = const [],
    Set<String> accepting = const {},
    Map<String, ConversationError> invitationErrors = const {},
    this.error,
    this.selected,
  }) : rooms = List.unmodifiable(rooms),
       invitations = List.unmodifiable(invitations),
       accepting = Set.unmodifiable(accepting),
       invitationErrors = Map.unmodifiable(invitationErrors);
  final bool loading;
  final bool refreshing;
  final List<ConversationSummary> rooms;
  final List<ConversationSummary> invitations;
  final Set<String> accepting;
  final Map<String, ConversationError> invitationErrors;
  bool get isEmpty => rooms.isEmpty && invitations.isEmpty;
  final ConversationError? error;
  final ConversationSummary? selected;
  RoomsState copyWith({
    bool? loading,
    bool? refreshing,
    List<ConversationSummary>? rooms,
    List<ConversationSummary>? invitations,
    Set<String>? accepting,
    Map<String, ConversationError>? invitationErrors,
    Object? error = _unchanged,
    Object? selected = _unchanged,
  }) => RoomsState(
    loading: loading ?? this.loading,
    refreshing: refreshing ?? this.refreshing,
    rooms: rooms ?? this.rooms,
    invitations: invitations ?? this.invitations,
    accepting: accepting ?? this.accepting,
    invitationErrors: invitationErrors ?? this.invitationErrors,
    error:
        identical(error, _unchanged) ? this.error : error as ConversationError?,
    selected:
        identical(selected, _unchanged)
            ? this.selected
            : selected as ConversationSummary?,
  );
}
