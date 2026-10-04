import 'dart:async';

import 'package:flutter/material.dart';

import 'src/rust/api/simple.dart';
import 'conversation_screen.dart';
import 'matrix_updates.dart';

typedef ConversationLoader = Future<List<ConversationSummary>> Function();

class ConversationList extends StatefulWidget {
  const ConversationList({
    super.key,
    required this.load,
    required this.loadHistory,
    this.sendMessage = sendTextMessage,
    this.updates = EmptyMatrixUpdateSource.new,
  });

  final ConversationLoader load;
  final MessageHistoryLoader loadHistory;
  final TextMessageSender sendMessage;
  final MatrixUpdateSourceFactory updates;

  @override
  State<ConversationList> createState() => _ConversationListState();
}

class _ConversationListState extends State<ConversationList> {
  final _historySessions = <ValueNotifier<bool>>{};
  late final MatrixUpdateSource _source;
  StreamSubscription<MatrixUpdate>? _subscription;
  bool _refreshPending = false;
  bool _loadInFlight = false;
  bool _loading = true;
  List<ConversationSummary> _rooms = const [];
  ConversationError? _error;

  @override
  void initState() {
    super.initState();
    _source = widget.updates();
    _subscription = _source.updates.listen((update) {
      if (update.kind == MatrixUpdateKind.conversationsChanged ||
          (update.kind == MatrixUpdateKind.resyncRequired &&
              update.conversationId == null)) {
        if (_loadInFlight) {
          _refreshPending = true;
        } else {
          unawaited(_load(background: true));
        }
      }
    });
    _load();
  }

  Future<void> _load({bool background = false}) async {
    if (_loadInFlight || !mounted) return;
    _loadInFlight = true;
    setState(() {
      _loading = !background;
      _error = null;
    });
    try {
      final rooms = await widget.load();
      if (!mounted) return;
      setState(() => _rooms = List.unmodifiable(rooms));
    } on ConversationError catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } catch (_) {
      // Detalhes inesperados da ponte nunca são apresentados como texto remoto.
      if (!mounted) return;
      setState(() => _error = ConversationError.internal);
    } finally {
      _loadInFlight = false;
      if (mounted) {
        setState(() => _loading = false);
        if (_refreshPending) {
          _refreshPending = false;
          unawaited(_load(background: true));
        }
      }
    }
  }

  Future<void> _open(ConversationSummary room) async {
    final active = ValueNotifier(true);
    _historySessions.add(active);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder:
              (_) => ConversationScreen(
                conversation: room,
                load: widget.loadHistory,
                send: widget.sendMessage,
                sessionActive: active,
                updates: _source.updates,
              ),
        ),
      );
    } finally {
      _historySessions.remove(active);
      active.dispose();
    }
  }

  @override
  void dispose() {
    // Desmontar a lista no início do logout invalida também as rotas abertas.
    for (final active in _historySessions) {
      active.value = false;
    }
    unawaited(_subscription?.cancel());
    unawaited(_source.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Column(
        children: [CircularProgressIndicator(), Text('Carregando conversas…')],
      );
    }
    if (_error case final error?) {
      return Column(
        children: [
          Semantics(
            liveRegion: true,
            child: Text(conversationErrorMessage(error)),
          ),
          FilledButton(onPressed: _load, child: const Text('Tentar novamente')),
        ],
      );
    }
    if (_rooms.isEmpty) {
      return const Text(
        'Nenhuma conversa encontrada. Você ainda não participa de salas.',
      );
    }
    return SizedBox(
      height: 320,
      child: ListView.builder(
        itemCount: _rooms.length,
        itemBuilder: (context, index) {
          final room = _rooms[index];
          // O ID só identifica o widget, sem parsing. Nomes remotos são texto simples.
          return ListTile(
            key: ValueKey(room.id),
            title: Text(room.displayName),
            onTap: () => _open(room),
          );
        },
      ),
    );
  }
}

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
