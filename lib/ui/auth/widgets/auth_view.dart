import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../view_models/auth_view_model.dart';
import '../../../domain/models/models.dart';
import '../../core/themes/layout_tokens.dart';
import '../../core/ui/state_panel.dart';
import 'failure_messages.dart';
import 'logout_progress_view.dart';

class AuthView extends StatefulWidget {
  const AuthView({
    super.key,
    required this.viewModel,
    required this.authenticatedView,
  });
  final AuthViewModel viewModel;
  final Widget Function() authenticatedView;
  @override
  State<AuthView> createState() => _AuthViewState();
}

class _AuthViewState extends State<AuthView> {
  final _address = TextEditingController(text: 'https://matrix.org');
  final _username = TextEditingController();
  final _password = TextEditingController();
  late bool _hadAccount;
  late final void Function() _removeListener;
  @override
  void initState() {
    super.initState();
    _hadAccount = widget.viewModel.state.account != null;
    _removeListener = widget.viewModel.addListener(() {
      final hasAccount = widget.viewModel.state.account != null;
      if (_hadAccount && !hasAccount) {
        _username.clear();
        _password.clear();
      }
      _hadAccount = hasAccount;
    });
  }

  void _login() {
    final notifier = widget.viewModel;
    final pending = notifier.login(
      _address.text,
      _username.text,
      _password.text,
    );
    _password.clear();
    unawaited(pending);
  }

  @override
  void dispose() {
    _removeListener();
    _address.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GetBuilder<AuthViewModel>(
    init: widget.viewModel,
    global: false,
    autoRemove: false,
    builder: (viewModel) {
      final state = viewModel.state;
      if (state.loggingOut) return const LogoutProgressScreen();
      if (state.initializing ||
          (state.sessionError != null &&
              state.sessionError != SessionError.invalidSession)) {
        return Scaffold(
          body: StatePanel(
            message:
                state.initializing
                    ? 'Verificando sessão…'
                    : sessionErrorMessage(state.sessionError!),
            loading: state.initializing,
            retry: state.initializing ? null : widget.viewModel.initialize,
          ),
        );
      }
      if (state.account != null) return widget.authenticatedView();
      final busy = state.loggingIn || state.probing;
      return Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(LayoutTokens.padding),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: LayoutTokens.loginWidth,
              ),
              child: AutofillGroup(
                onDisposeAction: AutofillContextAction.cancel,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.forum_outlined,
                      size: 40,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: LayoutTokens.gap),
                    Text(
                      'Desktop Chat',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: LayoutTokens.compact),
                    const Text(
                      'Entre com sua conta Matrix. A sessão será salva com segurança.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: LayoutTokens.padding),
                    if (state.sessionError != null)
                      Text(sessionErrorMessage(state.sessionError!)),
                    TextField(
                      controller: _address,
                      enabled: !busy,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'URL HTTPS do homeserver',
                        hintText: 'https://matrix.org',
                      ),
                    ),
                    const SizedBox(height: LayoutTokens.gap),
                    TextField(
                      controller: _username,
                      enabled: !busy,
                      autofillHints: const [AutofillHints.username],
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Usuário ou ID Matrix',
                      ),
                    ),
                    const SizedBox(height: LayoutTokens.gap),
                    TextField(
                      controller: _password,
                      enabled: !busy,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(labelText: 'Senha'),
                      onSubmitted: (_) => _login(),
                    ),
                    const SizedBox(height: LayoutTokens.gap),
                    FilledButton(
                      onPressed: busy ? null : _login,
                      child: const Text('Entrar'),
                    ),
                    const SizedBox(height: LayoutTokens.compact),
                    FilledButton.tonal(
                      onPressed:
                          busy
                              ? null
                              : () => widget.viewModel.probe(_address.text),
                      child: const Text('Verificar servidor'),
                    ),
                    if (busy) ...[
                      const SizedBox(height: LayoutTokens.gap),
                      const Center(child: CircularProgressIndicator()),
                      Text(
                        state.loggingIn
                            ? 'Autenticando…'
                            : 'Consultando servidor…',
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (state.info case final info?) ...[
                      const SizedBox(height: LayoutTokens.gap),
                      const Text('Servidor respondeu à consulta Matrix.'),
                      SelectableText(info.serverAddress),
                      Text(
                        'Login com senha: ${info.supportsPasswordLogin ? 'suportado' : 'não suportado'}',
                      ),
                    ],
                    for (final error in [
                      if (state.loginError != null)
                        loginErrorMessage(state.loginError!),
                      if (state.probeError != null)
                        probeErrorMessage(state.probeError!),
                      if (state.logoutNotice != null) state.logoutNotice!,
                    ])
                      Padding(
                        padding: const EdgeInsets.only(top: LayoutTokens.gap),
                        child: Semantics(liveRegion: true, child: Text(error)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
