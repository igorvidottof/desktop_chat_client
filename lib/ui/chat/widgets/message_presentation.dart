import '../../../domain/models/models.dart';

String messageTimestamp(int milliseconds) {
  // O SDK aceita timestamps além do intervalo de DateTime; conteúdo remoto não deve derrubar a tela.
  if (milliseconds.abs() > 8640000000000000) return 'Data indisponível';
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.day)}/${two(time.month)}/${time.year} · '
      '${two(time.hour)}:${two(time.minute)}';
}

bool historyRetryable(MessageHistoryError error) => switch (error) {
  MessageHistoryError.network ||
  MessageHistoryError.tls ||
  MessageHistoryError.rateLimited ||
  MessageHistoryError.history ||
  MessageHistoryError.internal => true,
  _ => false,
};

String messageHistoryErrorMessage(MessageHistoryError error) => switch (error) {
  MessageHistoryError.notAuthenticated => 'A sessão não está mais autenticada.',
  MessageHistoryError.invalidConversationId =>
    'Identificador de conversa inválido.',
  MessageHistoryError.conversationNotFound => 'Conversa não encontrada.',
  MessageHistoryError.conversationNotJoined =>
    'Você não participa desta conversa.',
  MessageHistoryError.encryptionUnsupported =>
    'Não foi possível concluir a operação. Tente novamente.',
  MessageHistoryError.network =>
    'Não foi possível carregar as mensagens. Verifique a conexão.',
  MessageHistoryError.tls =>
    'Não foi possível estabelecer uma conexão TLS segura.',
  MessageHistoryError.rateLimited =>
    'O servidor limitou as solicitações. Aguarde antes de tentar novamente.',
  MessageHistoryError.history || MessageHistoryError.internal =>
    'Não foi possível carregar as mensagens. Tente novamente.',
};

String sendMessageErrorMessage(SendMessageError error) => switch (error) {
  SendMessageError.notAuthenticated => 'A sessão não está mais autenticada.',
  SendMessageError.invalidConversationId =>
    'Identificador de conversa inválido.',
  SendMessageError.conversationNotFound => 'Conversa não encontrada.',
  SendMessageError.conversationNotJoined =>
    'Você não participa desta conversa.',
  SendMessageError.encryptionUnsupported =>
    'Não foi possível concluir a operação. Tente novamente.',
  SendMessageError.emptyMessage => 'Digite uma mensagem.',
  SendMessageError.messageTooLong => 'Máximo de 10.000 caracteres Unicode.',
  SendMessageError.sendInProgress =>
    'Já existe um envio em andamento nesta conversa.',
  SendMessageError.rateLimited =>
    'O servidor limitou os envios. Aguarde antes de enviar novamente.',
  SendMessageError.network =>
    'Não foi possível confirmar o envio. Verifique a conexão e o histórico antes de tentar novamente.',
  SendMessageError.tls =>
    'Não foi possível estabelecer uma conexão TLS segura. Verifique o histórico antes de tentar novamente.',
  SendMessageError.send || SendMessageError.internal =>
    'Não foi possível confirmar o envio. Verifique o histórico antes de tentar novamente.',
};
