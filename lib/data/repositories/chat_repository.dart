import '../../domain/models/models.dart';

const maxMessageChars = 10000;

abstract interface class ChatRepository {
  Future<List<MessageSummary>> history(String roomId);
  Future<SendMessageResult> send(String roomId, String body);
  Stream<MatrixUpdate> get updates;
  List<MessageSummary> reconcile(
    Iterable<MessageSummary> history,
    Iterable<MessageSummary> incoming,
  );
}
