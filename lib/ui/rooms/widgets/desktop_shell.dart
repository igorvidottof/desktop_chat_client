import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../view_models/rooms_view_model.dart';
import '../../auth/view_models/auth_view_model.dart';
import '../../../domain/models/models.dart';
import '../../core/themes/layout_tokens.dart';
import '../../core/ui/state_panel.dart';
import '../../core/ui/initial_avatar.dart';
import '../../auth/widgets/failure_messages.dart';
import 'rooms_view.dart';

class DesktopShell extends StatelessWidget {
  const DesktopShell({
    super.key,
    required this.auth,
    required this.rooms,
    required this.conversationBuilder,
  });
  final AuthViewModel auth;
  final RoomsViewModel rooms;
  final Widget Function(ConversationSummary) conversationBuilder;
  @override
  Widget build(BuildContext context) => GetBuilder<RoomsViewModel>(
    init: rooms,
    global: false,
    autoRemove: false,
    filter: (viewModel) => viewModel.state.selected ?? const Object(),
    builder: (viewModel) {
      final selected = viewModel.state.selected;
      final account = auth.state.account;
      final error = auth.state.logoutError;
      return Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow =
                  constraints.maxWidth < LayoutTokens.desktopBreakpoint;
              final sidebar = Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 80,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            Icon(
                              Icons.forum_outlined,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'Desktop Chat',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Divider(),
                    Expanded(child: RoomsView(viewModel: rooms)),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.all(LayoutTokens.gap),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (account != null)
                            Row(
                              children: [
                                InitialAvatar(
                                  name: account.userId.replaceFirst('@', ''),
                                  radius: 18,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Tooltip(
                                    message:
                                        'Dispositivo: ${account.deviceId}\n${account.homeserverAddress}',
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          account.userId,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style:
                                              Theme.of(
                                                context,
                                              ).textTheme.bodyMedium,
                                        ),
                                        Text(
                                          'Conta autenticada',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall?.copyWith(
                                            color:
                                                Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          if (error != null)
                            Semantics(
                              liveRegion: true,
                              child: Text(logoutErrorMessage(error)),
                            ),
                          TextButton.icon(
                            onPressed: auth.logout,
                            icon: const Icon(Icons.logout, size: 18),
                            label: const Text('Logout'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
              final conversation =
                  selected == null
                      ? const StatePanel(
                        message: 'Selecione uma conversa',
                        supporting:
                            'Escolha uma sala na lista para ver as mensagens.',
                        icon: Icons.forum_outlined,
                      )
                      : Column(
                        children: [
                          SizedBox(
                            height: 80,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              child: Row(
                                children: [
                                  if (narrow)
                                    IconButton(
                                      tooltip: 'Voltar às conversas',
                                      onPressed: () => rooms.selectRoom(null),
                                      icon: const Icon(Icons.arrow_back),
                                    ),
                                  InitialAvatar(name: selected.displayName),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      selected.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  if (narrow)
                                    IconButton(
                                      tooltip: 'Logout',
                                      onPressed: auth.logout,
                                      icon: const Icon(Icons.logout),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (narrow && error != null)
                            Padding(
                              padding: const EdgeInsets.all(
                                LayoutTokens.compact,
                              ),
                              child: Text(logoutErrorMessage(error)),
                            ),
                          const Divider(),
                          Expanded(child: conversationBuilder(selected)),
                        ],
                      );
              if (narrow) return selected == null ? sidebar : conversation;
              return Row(
                children: [
                  SizedBox(width: LayoutTokens.sidebarWidth, child: sidebar),
                  const VerticalDivider(),
                  Expanded(child: conversation),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}
