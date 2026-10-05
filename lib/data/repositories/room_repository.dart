import '../../domain/models/models.dart';

abstract interface class RoomRepository {
  Future<List<ConversationSummary>> load();
  Future<ConversationSummary> createRoom(String name, List<String> invitees);
  Future<ConversationSummary> acceptInvitation(String roomId);
  Future<void> markRead(String roomId);

  /// A lista local pode estar vazia enquanto o sync inicial ainda não terminou.
  bool get initialRoomSyncPending;
  Stream<MatrixUpdate> get updates;
}
