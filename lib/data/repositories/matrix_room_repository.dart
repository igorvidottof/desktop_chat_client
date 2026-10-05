import '../../domain/models/models.dart';
import '../services/matrix_bridge_service.dart';
import 'model_mapping.dart';
import '../services/native_matrix_updates.dart';
import '../../src/rust/api/simple.dart' as native;
import 'room_repository.dart';

class MatrixRoomRepository implements RoomRepository {
  MatrixRoomRepository(this.bridge, this.source);
  final MatrixBridgeService bridge;
  final MatrixUpdateSource source;
  @override
  bool get initialRoomSyncPending => source.initialRoomSyncPending;
  @override
  Stream<MatrixUpdate> get updates => source.updates.map(mapUpdate);
  @override
  Future<ConversationSummary> acceptInvitation(String roomId) => safeBridgeCall(
    () async => mapRoom(await bridge.acceptInvitation(conversationId: roomId)),
    ConversationError.values,
    ConversationError.internal,
    native.ConversationError,
  );
  @override
  Future<void> markRead(String roomId) => safeBridgeCall(
    () => bridge.markRoomRead(conversationId: roomId),
    ConversationError.values,
    ConversationError.internal,
    native.ConversationError,
  );
  @override
  Future<List<ConversationSummary>> load() => safeBridgeCall(
    () async => List.unmodifiable((await bridge.rooms()).map(mapRoom)),
    ConversationError.values,
    ConversationError.internal,
    native.ConversationError,
  );
}
