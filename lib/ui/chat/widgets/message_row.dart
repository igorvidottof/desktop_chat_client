import 'package:flutter/material.dart';

import '../../../domain/models/models.dart';
import 'message_presentation.dart';

/// Agrupa visualmente mensagens sem alterar o histórico ou manter outro cache.
class MessageRow extends StatefulWidget {
  const MessageRow({super.key, required this.message, this.previous});

  final MessageSummary message;
  final MessageSummary? previous;

  @override
  State<MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<MessageRow> {
  bool _hovered = false;

  MessageSummary get message => widget.message;
  MessageSummary? get previous => widget.previous;

  bool get _continuesGroup {
    final prior = previous;
    if (prior == null || prior.senderId != message.senderId) return false;
    final elapsed = message.timestampMs - prior.timestampMs;
    if (elapsed < 0 || elapsed > 300000) return false;
    if (message.timestampMs.abs() > 8640000000000000 ||
        prior.timestampMs.abs() > 8640000000000000) {
      return false;
    }
    final currentTime =
        DateTime.fromMillisecondsSinceEpoch(message.timestampMs).toLocal();
    final previousTime =
        DateTime.fromMillisecondsSinceEpoch(prior.timestampMs).toLocal();
    return DateUtils.isSameDay(currentTime, previousTime);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final grouped = _continuesGroup;
    final senderColor =
        message.isOwn ? colors.primary : const Color(0xFF005A83);
    final sender = message.senderId;
    final label =
        sender.startsWith('@') ? sender.substring(1).split(':').first : sender;
    final name = label.isEmpty ? sender : label;
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    final undecryptable =
        message.body == 'Não foi possível descriptografar esta mensagem.';
    final fullTimestamp = messageTimestamp(message.timestampMs);
    final time =
        fullTimestamp == 'Data indisponível'
            ? '—'
            : fullTimestamp.split(' · ').last;
    return Align(
      key: ValueKey(message.id),
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (previous != null && !grouped)
            Divider(
              height: 8,
              thickness: 0.5,
              indent: 76,
              color: colors.outlineVariant.withValues(alpha: 0.5),
            ),
          Padding(
            padding: EdgeInsets.only(top: grouped ? 0 : 20),
            child: MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color:
                      _hovered
                          ? colors.surfaceContainerLow
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 60,
                        child: Column(
                          children: [
                            if (!grouped) ...[
                              ExcludeSemantics(
                                child: CircleAvatar(
                                  radius: 20,
                                  backgroundColor: senderColor.withValues(
                                    alpha: 0.08,
                                  ),
                                  foregroundColor: senderColor,
                                  child: Text(initial),
                                ),
                              ),
                              const SizedBox(height: 4),
                            ],
                            if (_hovered)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(
                                  time,
                                  semanticsLabel: fullTimestamp,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!grouped) ...[
                              SizedBox(
                                height: 40,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Tooltip(
                                    message: sender,
                                    child: Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      semanticsLabel: sender,
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                            fontSize: 18,
                                            color: senderColor,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                            ],
                            Semantics(
                              label: fullTimestamp,
                              child: Text(
                                message.body,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  height: 1.5,
                                  color:
                                      undecryptable
                                          ? colors.onSurfaceVariant
                                          : colors.onSurface,
                                  fontStyle:
                                      undecryptable
                                          ? FontStyle.italic
                                          : FontStyle.normal,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
