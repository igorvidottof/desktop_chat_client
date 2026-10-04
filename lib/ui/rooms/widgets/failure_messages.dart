import '../../../domain/models/models.dart';

String conversationErrorMessage(ConversationError error) => switch (error) {
  ConversationError.notAuthenticated =>
    'A sessão não está autenticada. Reinicie o aplicativo para entrar novamente.',
  ConversationError.network =>
    'Não foi possível carregar as conversas. Verifique a conexão e tente novamente.',
  ConversationError.tls =>
    'Não foi possível estabelecer uma conexão TLS segura. Verifique o certificado do servidor.',
  ConversationError.rateLimited =>
    'O servidor limitou as solicitações. Aguarde antes de tentar novamente.',
  ConversationError.synchronization =>
    'O servidor não concluiu a sincronização. Tente novamente mais tarde.',
  ConversationError.internal =>
    'Não foi possível carregar as conversas. Tente novamente.',
};
