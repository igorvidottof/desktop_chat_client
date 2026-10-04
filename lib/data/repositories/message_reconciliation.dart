import '../../domain/models/models.dart';

// Preserva a ordem relativa do retrato SDK. Eventos novos usam timestamp Matrix
// para inserção, sem reorganizar o histórico por relógios divergentes/arrival time.
List<MessageSummary> mergeMessages(
  Iterable<MessageSummary> history,
  Iterable<MessageSummary> incoming,
) {
  final seen = <String>{};
  final result = history.where((m) => seen.add(m.id)).toList();
  for (final message in incoming) {
    if (!seen.add(message.id)) continue;
    final index = result.indexWhere((m) => m.timestampMs > message.timestampMs);
    result.insert(index < 0 ? result.length : index, message);
  }
  // O fluxo recente continua limitado; não adicionamos paginação nem cache infinito.
  return List.unmodifiable(
    result.length > 50 ? result.sublist(result.length - 50) : result,
  );
}
