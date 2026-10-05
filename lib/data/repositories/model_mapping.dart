import '../../domain/models/models.dart' as domain;
import '../../src/rust/api/simple.dart' as native;

domain.AccountSummary mapAccount(native.AccountSummary value) =>
    domain.AccountSummary(
      userId: value.userId,
      deviceId: value.deviceId,
      homeserverAddress: value.homeserverAddress,
    );
domain.ConversationSummary mapRoom(native.ConversationSummary value) =>
    domain.ConversationSummary(
      id: value.id,
      displayName: value.displayName,
      unreadMessageCount: value.unreadMessageCount,
      isEncrypted: value.isEncrypted,
    );
domain.MessageSummary mapMessage(native.MessageSummary value) =>
    domain.MessageSummary(
      id: value.id,
      senderId: value.senderId,
      body: value.body,
      timestampMs: value.timestampMs.toInt(),
      isOwn: value.isOwn,
    );
domain.MatrixUpdate mapUpdate(native.MatrixUpdate value) => domain.MatrixUpdate(
  kind: domain.MatrixUpdateKind.values.byName(value.kind.name),
  conversationId: value.conversationId,
  message: value.message == null ? null : mapMessage(value.message!),
  status: domain.MatrixSyncStatus.values.byName(value.status.name),
);

Future<T> safeBridgeCall<T, E extends Enum>(
  Future<T> Function() action,
  List<E> failures,
  E fallback,
  Type nativeErrorType,
) async {
  try {
    return await action();
  } catch (error) {
    if (error is Enum && error.runtimeType == nativeErrorType) {
      throw failures.byName(error.name);
    }
    throw fallback;
  }
}
