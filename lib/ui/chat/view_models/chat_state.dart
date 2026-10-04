import '../../../domain/models/models.dart';

const _unchanged = Object();

class ChatState {
  ChatState({
    this.loading = true,
    this.refreshing = false,
    this.sending = false,
    List<MessageSummary> messages = const [],
    this.error,
    this.sendError,
    this.sentEventId,
    this.syncStatus = MatrixSyncStatus.connecting,
  }) : messages = List.unmodifiable(messages);
  final bool loading;
  final bool refreshing;
  final bool sending;
  final List<MessageSummary> messages;
  final MessageHistoryError? error;
  final SendMessageError? sendError;
  final String? sentEventId;
  final MatrixSyncStatus syncStatus;
  ChatState copyWith({
    bool? loading,
    bool? refreshing,
    bool? sending,
    List<MessageSummary>? messages,
    Object? error = _unchanged,
    Object? sendError = _unchanged,
    Object? sentEventId = _unchanged,
    MatrixSyncStatus? syncStatus,
  }) => ChatState(
    loading: loading ?? this.loading,
    refreshing: refreshing ?? this.refreshing,
    sending: sending ?? this.sending,
    messages: messages ?? this.messages,
    error:
        identical(error, _unchanged)
            ? this.error
            : error as MessageHistoryError?,
    sendError:
        identical(sendError, _unchanged)
            ? this.sendError
            : sendError as SendMessageError?,
    sentEventId:
        identical(sentEventId, _unchanged)
            ? this.sentEventId
            : sentEventId as String?,
    syncStatus: syncStatus ?? this.syncStatus,
  );
}
