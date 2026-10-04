import 'package:flutter/material.dart';
import '../themes/layout_tokens.dart';

class StatePanel extends StatelessWidget {
  const StatePanel({
    super.key,
    required this.message,
    this.supporting,
    this.loading = false,
    this.retry,
    this.icon,
  });
  final String message;
  final String? supporting;
  final bool loading;
  final VoidCallback? retry;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(LayoutTokens.padding),
      child: Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading) const CircularProgressIndicator(),
            if (icon != null)
              Icon(
                icon,
                size: 40,
                color: Theme.of(context).colorScheme.primary,
              ),
            const SizedBox(height: LayoutTokens.gap),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (supporting != null) ...[
              const SizedBox(height: LayoutTokens.compact),
              Text(supporting!, textAlign: TextAlign.center),
            ],
            if (retry != null) ...[
              const SizedBox(height: LayoutTokens.gap),
              FilledButton(
                onPressed: retry,
                child: const Text('Tentar novamente'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
