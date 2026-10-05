import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../view_models/rooms_view_model.dart';

class CreateRoomDialog extends StatefulWidget {
  const CreateRoomDialog({super.key, required this.viewModel});
  final RoomsViewModel viewModel;

  @override
  State<CreateRoomDialog> createState() => _CreateRoomDialogState();
}

class _CreateRoomDialogState extends State<CreateRoomDialog> {
  final _name = TextEditingController();
  final _invitees = TextEditingController();
  final _inviteFocus = FocusNode();

  @override
  void dispose() {
    _name.dispose();
    _invitees.dispose();
    _inviteFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!widget.viewModel.confirmInviteeDraft(_invitees.text)) return;
    final created = await widget.viewModel.createRoom(
      _name.text,
      widget.viewModel.state.creationInvitees.join('\n'),
    );
    if (created && mounted) Navigator.of(context).pop();
  }

  void _addInvitee() {
    if (widget.viewModel.addInvitee(_invitees.text)) {
      _invitees.clear();
      _inviteFocus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) => GetBuilder<RoomsViewModel>(
    init: widget.viewModel,
    global: false,
    autoRemove: false,
    builder:
        (vm) => PopScope(
          canPop: !vm.state.creating,
          child: AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            title: const Text('Criar sala privada'),
            content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _name,
                      autofocus: true,
                      enabled: !vm.state.creating,
                      decoration: const InputDecoration(
                        labelText: 'Nome da sala',
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _invitees,
                            focusNode: _inviteFocus,
                            enabled: !vm.state.creating,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _addInvitee(),
                            decoration: const InputDecoration(
                              labelText: 'Convidar pessoa (opcional)',
                              hintText: '@usuario:servidor.com',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: vm.state.creating ? null : _addInvitee,
                          child: const Text('Adicionar'),
                        ),
                      ],
                    ),
                    if (vm.state.inviteeError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            vm.state.inviteeError!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    for (final id in vm.state.creationInvitees)
                      Row(
                        children: [
                          Expanded(child: Text(id)),
                          IconButton(
                            tooltip: 'Remover $id',
                            onPressed:
                                vm.state.creating
                                    ? null
                                    : () => vm.removeInvitee(id),
                            icon: const Icon(Icons.close, size: 16),
                          ),
                        ],
                      ),
                    if (vm.state.creationError != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          vm.state.creationError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed:
                    vm.state.creating
                        ? null
                        : () => Navigator.of(context).pop(),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: vm.state.creating ? null : _submit,
                child:
                    vm.state.creating
                        ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            semanticsLabel: 'Criando sala',
                          ),
                        )
                        : const Text('Criar'),
              ),
            ],
          ),
        ),
  );
}
