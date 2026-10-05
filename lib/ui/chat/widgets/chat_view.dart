import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../view_models/chat_view_model.dart';
import '../view_models/chat_state.dart';
import '../../../domain/models/models.dart';
import '../../core/themes/layout_tokens.dart';
import '../../core/ui/state_panel.dart';
import '../../../data/repositories/chat_repository.dart';
import 'message_presentation.dart';
import 'message_row.dart';

class ChatView extends StatefulWidget {
  const ChatView({super.key, required this.viewModel});
  final ChatViewModel viewModel;
  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  final _unreadSliverKey = GlobalKey();
  bool _opened = false;
  late ChatState _previous;
  late final void Function() _removeListener;
  @override
  void initState() {
    super.initState();
    _previous = widget.viewModel.state;
    // A história pode terminar antes de a View montar seu listener.
    if (!_previous.loading && _previous.error == null) {
      _opened = true;
      _scrollOpening();
    }
    _removeListener = widget.viewModel.addListener(() {
      final previous = _previous;
      final next = widget.viewModel.state;
      _previous = next;
      if (next.sentEventId != null &&
          next.sentEventId != previous.sentEventId) {
        _composer.clear();
        _scrollRecent();
      }
      if (!_opened && !next.loading && next.error == null) {
        _opened = true;
        _scrollOpening();
      } else if (_opened &&
          !next.loading &&
          previous.messages != next.messages &&
          (!_scroll.hasClients || _scroll.position.extentAfter < 80)) {
        _scrollRecent();
      }
      if (!widget.viewModel.active) _composer.clear();
    });
  }

  @override
  void dispose() {
    _removeListener();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollOpening() {
    if (widget.viewModel.state.firstUnreadMessageId == null) _scrollRecent();
  }

  Widget _message(ChatState state, int index) => MessageRow(
    message: state.messages[index],
    previous:
        index == 0 || state.messages[index].id == state.firstUnreadMessageId
            ? null
            : state.messages[index - 1],
  );

  Widget _timeline(ChatState state) {
    final boundary = state.messages.indexWhere(
      (message) => message.id == state.firstUnreadMessageId,
    );
    if (state.firstUnreadMessageId == null) {
      return ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(20, 4, 24, 24),
        itemCount: state.messages.length,
        itemBuilder: (context, index) => _message(state, index),
      );
    }
    // O centro inicia na fronteira sem estimar alturas nem montar toda a lista.
    // Se a janela recente remover o evento, não inventamos uma nova fronteira.
    final start = boundary < 0 ? 0 : boundary;
    return CustomScrollView(
      controller: _scroll,
      center: _unreadSliverKey,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 4, 24, 0),
          sliver: SliverList.builder(
            itemCount: start,
            itemBuilder: (context, index) => _message(state, start - index - 1),
          ),
        ),
        SliverPadding(
          key: _unreadSliverKey,
          padding: const EdgeInsets.fromLTRB(20, 0, 24, 24),
          sliver: SliverList.builder(
            itemCount: state.messages.length - start,
            itemBuilder: (context, index) {
              final row = _message(state, start + index);
              if (index != 0 || boundary < 0) return row;
              final theme = Theme.of(context);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: LayoutTokens.compact,
                    ),
                    child: Row(
                      children: [
                        const Expanded(child: Divider()),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: LayoutTokens.gap,
                          ),
                          child: Text(
                            'Novas mensagens',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const Expanded(child: Divider()),
                      ],
                    ),
                  ),
                  row,
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  void _send() => widget.viewModel.sendMessage(_composer.text);
  void _scrollRecent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: GetBuilder<ChatViewModel>(
            init: widget.viewModel,
            global: false,
            autoRemove: false,
            builder: (viewModel) {
              final state = viewModel.state;
              final messages = state.messages;
              return Column(
                children: [
                  if (state.syncStatus == MatrixSyncStatus.reconnecting)
                    const Text(
                      'Reconectando… As mensagens carregadas continuam disponíveis.',
                    ),
                  if (state.syncStatus ==
                      MatrixSyncStatus.authenticationRequired)
                    const Text(
                      'A sincronização requer nova autenticação. Saia e entre novamente.',
                    ),
                  if (state.refreshing) const LinearProgressIndicator(),
                  if (state.unreadHistoryInsufficient)
                    Padding(
                      padding: const EdgeInsets.all(LayoutTokens.compact),
                      child: Text(
                        'Há mensagens não lidas anteriores ao histórico carregado.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (state.error != null &&
                      messages.isNotEmpty &&
                      state.error != MessageHistoryError.notAuthenticated)
                    Padding(
                      padding: const EdgeInsets.all(LayoutTokens.compact),
                      child: Column(
                        children: [
                          Text(messageHistoryErrorMessage(state.error!)),
                          if (historyRetryable(state.error!))
                            TextButton(
                              onPressed: widget.viewModel.load,
                              child: const Text('Tentar novamente'),
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    child:
                        state.loading
                            ? const StatePanel(
                              message: 'Carregando mensagens…',
                              loading: true,
                            )
                            : state.error != null &&
                                (messages.isEmpty ||
                                    state.error ==
                                        MessageHistoryError.notAuthenticated)
                            ? StatePanel(
                              message: messageHistoryErrorMessage(state.error!),
                              icon:
                                  state.error ==
                                          MessageHistoryError
                                              .encryptionUnsupported
                                      ? Icons.lock_outline
                                      : null,
                              supporting:
                                  state.error ==
                                          MessageHistoryError
                                              .encryptionUnsupported
                                      ? 'Selecione uma sala sem criptografia para ler e enviar mensagens.'
                                      : null,
                              retry:
                                  historyRetryable(state.error!)
                                      ? widget.viewModel.load
                                      : null,
                            )
                            : messages.isEmpty
                            ? const StatePanel(
                              message: 'Nenhuma mensagem ainda.',
                              icon: Icons.chat_bubble_outline,
                            )
                            : ColoredBox(
                              color:
                                  Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerLowest,
                              child: SelectionArea(child: _timeline(state)),
                            ),
                  ),
                ],
              );
            },
          ),
        ),
        GetBuilder<ChatViewModel>(
          init: widget.viewModel,
          global: false,
          autoRemove: false,
          filter: (viewModel) {
            final s = viewModel.state;
            return (
              s.loading,
              s.sending,
              s.error,
              s.sendError,
              s.sentEventId,
              s.messages.any((m) => m.id == s.sentEventId),
            );
          },
          builder: (viewModel) {
            final s = viewModel.state;
            final state = (
              s.loading,
              s.sending,
              s.error,
              s.sendError,
              s.sentEventId,
              s.messages.any((m) => m.id == s.sentEventId),
            );
            return Column(
              children: [
                if (state.$5 != null &&
                    !state.$1 &&
                    state.$3 == null &&
                    !state.$6)
                  TextButton(
                    onPressed: widget.viewModel.load,
                    child: const Text('Atualizar histórico'),
                  ),
                if (state.$4 != null)
                  Semantics(
                    liveRegion: true,
                    child: Text(sendMessageErrorMessage(state.$4!)),
                  ),
                if (!state.$1 && state.$3 == null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _composer,
                      builder: (context, value, _) {
                        final valid =
                            value.text.trim().isNotEmpty &&
                            value.text.runes.length <= maxMessageChars;
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Focus(
                                onKeyEvent: (_, event) {
                                  final enter =
                                      event.logicalKey ==
                                          LogicalKeyboardKey.enter ||
                                      event.logicalKey ==
                                          LogicalKeyboardKey.numpadEnter;
                                  if (!enter ||
                                      !_composer.value.composing.isCollapsed) {
                                    return KeyEventResult.ignored;
                                  }
                                  if (event is KeyRepeatEvent) {
                                    return KeyEventResult.handled;
                                  }
                                  if (event is! KeyDownEvent) {
                                    return KeyEventResult.ignored;
                                  }
                                  if (state.$2) return KeyEventResult.handled;
                                  if (HardwareKeyboard
                                      .instance
                                      .isShiftPressed) {
                                    final value = _composer.value;
                                    final selection =
                                        value.selection.isValid
                                            ? value.selection
                                            : TextSelection.collapsed(
                                              offset: value.text.length,
                                            );
                                    _composer.value = TextEditingValue(
                                      text: value.text.replaceRange(
                                        selection.start,
                                        selection.end,
                                        '\n',
                                      ),
                                      selection: TextSelection.collapsed(
                                        offset: selection.start + 1,
                                      ),
                                    );
                                  } else {
                                    _send();
                                  }
                                  return KeyEventResult.handled;
                                },
                                child: TextField(
                                  controller: _composer,
                                  enabled: !state.$2,
                                  minLines: 1,
                                  maxLines: 4,
                                  textInputAction: TextInputAction.newline,
                                  decoration: InputDecoration(
                                    filled: true,
                                    fillColor:
                                        Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainerLow,
                                    hintText: 'Escreva uma mensagem…',
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide.none,
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide.none,
                                    ),
                                    helperStyle: Theme.of(
                                      context,
                                    ).textTheme.bodySmall?.copyWith(
                                      color:
                                          Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                    ),
                                    helperText:
                                        'Enter para enviar · Shift+Enter para nova linha',
                                    helperMaxLines: 2,
                                    errorText:
                                        value.text.runes.length >
                                                maxMessageChars
                                            ? 'Máximo de 10.000 caracteres Unicode.'
                                            : null,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: LayoutTokens.compact),
                            FilledButton(
                              onPressed: !state.$2 && valid ? _send : null,
                              child: Text(state.$2 ? 'Enviando…' : 'Enviar'),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}
