import 'dart:async';

import 'package:flutter/material.dart';

import 'src/rust/api/simple.dart';

typedef MessageHistoryLoader =
    Future<List<MessageSummary>> Function({required String conversationId});

typedef TextMessageSender =
    Future<SendMessageResult> Function({
      required String conversationId,
      required String body,
    });

// Mesmo limite do Rust: valores escalares Unicode, não grafemas ou UTF-16.
const maxMessageChars = 10000;

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.conversation,
    required this.load,
    required this.sessionActive,
    this.send = sendTextMessage,
    this.updates = const Stream.empty(),
  });

  final ConversationSummary conversation;
  final MessageHistoryLoader load;
  final TextMessageSender send;
  final ValueNotifier<bool> sessionActive;
  final Stream<MatrixUpdate> updates;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<MatrixUpdate>? _subscription;
  final _duringLoad = <MessageSummary>[];
  bool _refreshPending = false;
  MatrixSyncStatus _syncStatus = MatrixSyncStatus.connecting;
  bool _sending = false;
  SendMessageError? _sendError;
  String? _sentEventId;
  bool _loading = false;
  List<MessageSummary> _messages = const [];
  MessageHistoryError? _error;

  @override
  void initState() {
    super.initState();
    widget.sessionActive.addListener(_sessionChanged);
    _composer.addListener(_textChanged);
    _subscription = widget.updates.listen(_updated);
    _load();
  }

  void _updated(MatrixUpdate update) {
    if (!mounted || !widget.sessionActive.value) return;
    if (update.kind == MatrixUpdateKind.status) {
      setState(() => _syncStatus = update.status);
      return;
    }
    if (update.conversationId != null &&
        update.conversationId != widget.conversation.id) {
      return;
    }
    if (update.kind == MatrixUpdateKind.resyncRequired) {
      if (_loading) {
        _refreshPending = true;
      } else {
        unawaited(_load());
      }
      return;
    }
    final message = update.message;
    if (update.kind != MatrixUpdateKind.message ||
        message == null ||
        _error == MessageHistoryError.encryptionUnsupported) {
      return;
    }
    if (_loading) {
      // Limite também durante requests lentos; um overflow pede novo retrato finito.
      if (_duringLoad.length < 128) {
        _duringLoad.add(message);
      } else {
        _refreshPending = true;
      }
    }
    setState(() => _messages = mergeMessages(_messages, [message]));
  }

  void _textChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    if (_sending ||
        _loading ||
        _error != null ||
        !widget.sessionActive.value ||
        _composer.text.trim().isEmpty ||
        _composer.text.runes.length > maxMessageChars) {
      return;
    }
    final body = _composer.text;
    setState(() {
      _sending = true;
      _sendError = null;
      _sentEventId = null;
    });
    try {
      final result = await widget.send(
        conversationId: widget.conversation.id,
        body: body,
      );
      if (!mounted || !widget.sessionActive.value) return;
      // Confirmação separada do refresh: falha ao carregar não permite reenviar
      // automaticamente uma mensagem já aceita. Nenhum timestamp é inventado.
      _composer.clear();
      setState(() => _sentEventId = result.eventId);
      await _load();
      if (!mounted || !widget.sessionActive.value) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.sessionActive.value && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    } on SendMessageError catch (error) {
      if (!mounted || !widget.sessionActive.value) return;
      setState(() {
        _sendError = error;
        if (error == SendMessageError.encryptionUnsupported) {
          _error = MessageHistoryError.encryptionUnsupported;
        } else if (error == SendMessageError.notAuthenticated) {
          _error = MessageHistoryError.notAuthenticated;
        }
      });
    } catch (_) {
      if (!mounted || !widget.sessionActive.value) return;
      setState(() => _sendError = SendMessageError.internal);
    } finally {
      if (mounted && widget.sessionActive.value) {
        setState(() => _sending = false);
      }
    }
  }

  void _sessionChanged() {
    // O descarte da lista pode ocorrer com a árvore bloqueada durante dispose.
    // A autoridade já foi invalidada; atualizar a apresentação no próximo frame.
    unawaited(_subscription?.cancel());
    _duringLoad.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _messages = const [];
        _composer.clear();
        _sentEventId = null;
        _sendError = null;
        _sending = false;
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
      setState(
        () =>
            _messages = mergeMessages(messages, [..._messages, ..._duringLoad]),
      );
      _duringLoad.clear();
    } on MessageHistoryError catch (error) {
      if (!mounted || !widget.sessionActive.value) return;
      setState(() {
        _error = error;
        if (error == MessageHistoryError.encryptionUnsupported) {
          _messages = const [];
          _duringLoad.clear();
        }
      });
    } catch (_) {
      if (!mounted || !widget.sessionActive.value) return;
      setState(() => _error = MessageHistoryError.internal);
    } finally {
      if (mounted && widget.sessionActive.value) {
        setState(() => _loading = false);
        if (_refreshPending) {
          _refreshPending = false;
          unawaited(_load());
        }
      }
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    widget.sessionActive.removeListener(_sessionChanged);
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.conversation.displayName)),
      body: Column(
        children: [
          if (_syncStatus == MatrixSyncStatus.reconnecting)
            const Text(
              'Reconectando… As mensagens carregadas continuam disponíveis.',
            ),
          if (_syncStatus == MatrixSyncStatus.authenticationRequired)
            const Text(
              'A sincronização requer nova autenticação. Saia e entre novamente.',
            ),
          Expanded(child: _history()),
          if (_sentEventId != null && widget.sessionActive.value)
            Semantics(
              liveRegion: true,
              child: Text(
                _messages.any((message) => message.id == _sentEventId)
                    ? 'Mensagem enviada.'
                    : 'Mensagem enviada. Histórico ainda não atualizado.',
              ),
            ),
          if (_sentEventId != null &&
              !_loading &&
              _error == null &&
              !_messages.any((message) => message.id == _sentEventId))
            TextButton(
              onPressed: _load,
              child: const Text('Atualizar histórico'),
            ),
          if (_sendError != null && widget.sessionActive.value)
            Semantics(
              liveRegion: true,
              child: Text(sendMessageErrorMessage(_sendError!)),
            ),
          if (!_loading && _error == null && widget.sessionActive.value)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      enabled: !_sending,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        labelText: 'Mensagem',
                        helperText:
                            '${_composer.text.runes.length}/$maxMessageChars caracteres Unicode',
                        errorText:
                            _composer.text.runes.length > maxMessageChars
                                ? 'Máximo de 10.000 caracteres Unicode.'
                                : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed:
                        _sending ||
                                _composer.text.trim().isEmpty ||
                                _composer.text.runes.length > maxMessageChars
                            ? null
                            : _send,
                    child: Text(_sending ? 'Enviando…' : 'Enviar'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _history() =>
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
              controller: _scroll,
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
          );
}

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

String sendMessageErrorMessage(SendMessageError error) => switch (error) {
  SendMessageError.notAuthenticated => 'A sessão não está mais autenticada.',
  SendMessageError.invalidConversationId =>
    'Identificador de conversa inválido.',
  SendMessageError.conversationNotFound => 'Conversa não encontrada.',
  SendMessageError.conversationNotJoined =>
    'Você não participa desta conversa.',
  SendMessageError.encryptionUnsupported =>
    'Conversas criptografadas ainda não são suportadas.',
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
