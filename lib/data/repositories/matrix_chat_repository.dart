import '../../domain/models/models.dart';
import '../services/matrix_bridge_service.dart';
import 'model_mapping.dart';
import '../services/native_matrix_updates.dart';
import '../../src/rust/api/simple.dart' as native;
import 'chat_repository.dart';
import 'message_reconciliation.dart';

class MatrixChatRepository implements ChatRepository {
  MatrixChatRepository(this.bridge, this.source);
  final MatrixBridgeService bridge;
  final MatrixUpdateSource source;
  @override
  Stream<MatrixUpdate> get updates => source.updates.map(mapUpdate);
  @override
  Future<List<MessageSummary>> history(String roomId) => safeBridgeCall(
    () async => List.unmodifiable(
      (await bridge.history(conversationId: roomId)).map(mapMessage),
    ),
    MessageHistoryError.values,
    MessageHistoryError.internal,
    native.MessageHistoryError,
  );
  @override
  Future<SendMessageResult> send(String roomId, String body) => safeBridgeCall(
    () async => SendMessageResult(
      eventId: (await bridge.send(conversationId: roomId, body: body)).eventId,
    ),
    SendMessageError.values,
    SendMessageError.internal,
    native.SendMessageError,
  );
  @override
  List<MessageSummary> reconcile(
    Iterable<MessageSummary> history,
    Iterable<MessageSummary> incoming,
  ) => mergeMessages(history, incoming);
}
