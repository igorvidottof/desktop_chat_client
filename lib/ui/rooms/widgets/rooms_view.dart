import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../view_models/rooms_view_model.dart';
import '../../core/themes/layout_tokens.dart';
import '../../core/ui/state_panel.dart';
import '../../core/ui/initial_avatar.dart';
import 'failure_messages.dart';

class RoomsView extends StatelessWidget {
  const RoomsView({super.key, required this.viewModel});
  final RoomsViewModel viewModel;
  @override
  Widget build(BuildContext context) => GetBuilder<RoomsViewModel>(
    init: viewModel,
    global: false,
    autoRemove: false,
    builder: (viewModel) {
      final state = viewModel.state;
      if (state.loading || (state.refreshing && state.isEmpty)) {
        return const StatePanel(
          message: 'Carregando conversas…',
          loading: true,
        );
      }
      if (state.error != null && state.isEmpty) {
        return StatePanel(
          message: conversationErrorMessage(state.error!),
          retry: viewModel.load,
        );
      }
      if (state.isEmpty) {
        return const StatePanel(
          message:
              'Nenhuma conversa encontrada. Você ainda não participa de salas.',
          icon: Icons.chat_bubble_outline,
        );
      }
      return Column(
        children: [
          if (state.refreshing) const LinearProgressIndicator(),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.all(LayoutTokens.gap),
              child: Column(
                children: [
                  Text(conversationErrorMessage(state.error!)),
                  TextButton(
                    onPressed: viewModel.load,
                    child: const Text('Tentar novamente'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(LayoutTokens.compact),
              itemCount:
                  state.invitations.length +
                  state.rooms.length +
                  (state.invitations.isEmpty ? 0 : 1),
              itemBuilder: (context, index) {
                if (state.invitations.isNotEmpty) {
                  if (index == 0) {
                    return const Padding(
                      padding: EdgeInsets.all(LayoutTokens.compact),
                      child: Text('Convites pendentes'),
                    );
                  }
                  if (index <= state.invitations.length) {
                    final invitation = state.invitations[index - 1];
                    final accepting = state.accepting.contains(invitation.id);
                    final error = state.invitationErrors[invitation.id];
                    return ListTile(
                      key: ValueKey(invitation.id),
                      leading: InitialAvatar(name: invitation.displayName),
                      title: Text(
                        invitation.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          'Você foi convidado',
                          if (invitation.isEncrypted) 'Criptografada',
                          if (error != null) invitationErrorMessage(error),
                        ].join(' · '),
                      ),
                      trailing: TextButton(
                        onPressed:
                            accepting
                                ? null
                                : () =>
                                    viewModel.acceptInvitation(invitation.id),
                        child:
                            accepting
                                ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    semanticsLabel: 'Aceitando convite',
                                  ),
                                )
                                : const Text('Aceitar'),
                      ),
                    );
                  }
                }
                final room =
                    state.rooms[index -
                        (state.invitations.isEmpty
                            ? 0
                            : state.invitations.length + 1)];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ListTile(
                    key: ValueKey(room.id),
                    selected: room.id == state.selected?.id,
                    leading: InitialAvatar(name: room.displayName),
                    title: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (room.isEncrypted)
                          Semantics(
                            label: 'Sala criptografada',
                            child: ExcludeSemantics(
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.lock_outline,
                                      size: 12,
                                      color:
                                          Theme.of(context).colorScheme.error,
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        'Criptografada',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.labelSmall?.copyWith(
                                          color:
                                              Theme.of(
                                                context,
                                              ).colorScheme.error,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        Text(
                          room.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight:
                                room.id == state.selected?.id
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    trailing:
                        room.unreadMessageCount > 0
                            ? Semantics(
                              label:
                                  room.unreadMessageCount == 1
                                      ? '1 mensagem não lida'
                                      : '${room.unreadMessageCount} mensagens não lidas',
                              child: ExcludeSemantics(
                                child: Badge.count(
                                  count: room.unreadMessageCount,
                                  maxCount: 99,
                                ),
                              ),
                            )
                            : null,
                    onTap: () => viewModel.selectRoom(room),
                    focusColor: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: .18),
                    hoverColor: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: .08),
                  ),
                );
              },
            ),
          ),
        ],
      );
    },
  );
}
