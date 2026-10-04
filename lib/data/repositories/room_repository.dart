import '../../domain/models/models.dart';

abstract interface class RoomRepository {
  Future<List<ConversationSummary>> load();

  /// A lista local pode estar vazia enquanto o sync inicial ainda não terminou.
  bool get initialRoomSyncPending;
  Stream<MatrixUpdate> get updates;
}
