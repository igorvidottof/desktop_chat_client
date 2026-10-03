import 'package:flutter/material.dart';

import 'src/rust/api/simple.dart';

typedef MessageHistoryLoader =
    Future<List<MessageSummary>> Function({required String conversationId});

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.conversation,
    required this.load,
    required this.sessionActive,
  });

  final ConversationSummary conversation;
  final MessageHistoryLoader load;
  final ValueNotifier<bool> sessionActive;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  bool _loading = false;
  List<MessageSummary> _messages = const [];
  MessageHistoryError? _error;

  @override
  void initState() {
    super.initState();
    widget.sessionActive.addListener(_sessionChanged);
    _load();
  }

  void _sessionChanged() {
    // O descarte da lista pode ocorrer com a árvore bloqueada durante dispose.
    // A autoridade já foi invalidada; atualizar a apresentação no próximo frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _messages = const [];
        _loading = false;
        _error = MessageHistoryError.notAuthenticated;
      });
    });
  }

  Future<void> _load() async {
    if (_loading || !widget.sessionActive.value) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final messages = await widget.load(
        conversationId: widget.conversation.id,
      );
      if (!mounted || !widget.sessionActive.value) return;
      setState(() => _messages = List.unmodifiable(messages));
    } on MessageHistoryError catch (error) {
      if (!mounted || !widget.sessionActive.value) return;
      setState(() => _error = error);
    } catch (_) {
      if (!mounted || !widget.sessionActive.value) return;
      setState(() => _error = MessageHistoryError.internal);
    } finally {
      if (mounted && widget.sessionActive.value) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    widget.sessionActive.removeListener(_sessionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.conversation.displayName)),
      body:
          _loading
              ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    Text('Carregando mensagens…'),
                  ],
                ),
              )
              : _error != null
              ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(messageHistoryErrorMessage(_error!)),
                    ),
                    if (historyRetryable(_error!) && widget.sessionActive.value)
                      FilledButton(
                        onPressed: _load,
                        child: const Text('Tentar novamente'),
                      ),
                  ],
                ),
              )
              : _messages.isEmpty
              ? const Center(child: Text('Nenhuma mensagem ainda.'))
              : SelectionArea(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final message = _messages[index];
                    return Align(
                      key: ValueKey(message.id),
                      alignment:
                          message.isOwn
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment:
                              message.isOwn
                                  ? CrossAxisAlignment.end
                                  : CrossAxisAlignment.start,
                          children: [
                            Text(message.senderId),
                            // Conteúdo remoto permanece literal: sem HTML, Markdown ou links.
                            Text(message.body),
                            Text(messageTimestamp(message.timestampMs.toInt())),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
    );
  }
}

String messageTimestamp(int milliseconds) {
  // O SDK aceita timestamps além do intervalo de DateTime; conteúdo remoto não deve derrubar a tela.
  if (milliseconds.abs() > 8640000000000000) return 'Data indisponível';
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
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
    'Conversas criptografadas ainda não são suportadas.',
  MessageHistoryError.network =>
    'Não foi possível carregar as mensagens. Verifique a conexão.',
  MessageHistoryError.tls =>
    'Não foi possível estabelecer uma conexão TLS segura.',
  MessageHistoryError.rateLimited =>
    'O servidor limitou as solicitações. Aguarde antes de tentar novamente.',
  MessageHistoryError.history || MessageHistoryError.internal =>
    'Não foi possível carregar as mensagens. Tente novamente.',
};
