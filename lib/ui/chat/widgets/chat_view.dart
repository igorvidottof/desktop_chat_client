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

class ChatView extends StatefulWidget {
  const ChatView({super.key, required this.viewModel});
  final ChatViewModel viewModel;
  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  bool _opened = false;
  late ChatState _previous;
  late final void Function() _removeListener;
  @override
  void initState() {
    super.initState();
    _previous = widget.viewModel.state;
    // A história pode terminar antes de a View montar seu listener.
    if (!_previous.loading) {
      _opened = true;
      _scrollRecent();
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
      if (!_opened && !next.loading) {
        _opened = true;
        _scrollRecent();
      } else if (previous.messages != next.messages &&
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
                            : SelectionArea(
                              child: ListView.builder(
                                controller: _scroll,
                                padding: const EdgeInsets.all(LayoutTokens.gap),
                                itemCount: messages.length,
                                itemBuilder:
                                    (context, index) =>
                                        MessageBubble(message: messages[index]),
                              ),
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
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.all(LayoutTokens.gap),
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _composer,
                      builder: (context, value, _) {
                        final valid =
                            value.text.trim().isNotEmpty &&
                            value.text.runes.length <= maxMessageChars;
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
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
                                    labelText: 'Mensagem',
                                    hintText: 'Escreva uma mensagem…',
                                    helperText:
                                        'Enter para enviar · Shift+Enter para nova linha',
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

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});
  final MessageSummary message;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final undecryptable =
        message.body == 'Não foi possível descriptografar esta mensagem.';
    return Align(
      key: ValueKey(message.id),
      alignment: message.isOwn ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: LayoutTokens.compact),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: LayoutTokens.messageWidth,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color:
                  undecryptable
                      ? colors.surfaceContainerHigh
                      : message.isOwn
                      ? colors.primaryContainer
                      : colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(LayoutTokens.radius),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(LayoutTokens.gap),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message.senderId,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: LayoutTokens.compact),
                  Text(
                    message.body,
                    style: TextStyle(
                      color:
                          undecryptable
                              ? colors.onSurfaceVariant
                              : message.isOwn
                              ? colors.onPrimaryContainer
                              : colors.onSurface,
                      fontStyle:
                          undecryptable ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                  const SizedBox(height: LayoutTokens.compact),
                  Text(
                    messageTimestamp(message.timestampMs),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
