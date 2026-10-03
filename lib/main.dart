import 'package:flutter/material.dart';

import 'src/rust/api/simple.dart';
import 'conversation_list.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(
    MyApp(
      loadConversations: listConversations,
      probe: (address) => probeServer(address: address),
      authenticate:
          (address, username, password) => login(
            homeserverAddress: address,
            username: username,
            password: password,
          ),
    ),
  );
}

typedef PasswordLogin =
    Future<AccountSummary> Function(
      String address,
      String username,
      String password,
    );

typedef ServerProbe = Future<ServerInfo> Function(String address);

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.probe,
    required this.authenticate,
    required this.loadConversations,
  });

  final ServerProbe probe;
  final PasswordLogin authenticate;
  final ConversationLoader loadConversations;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Desktop Chat Client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: LoginScreen(
        probe: probe,
        authenticate: authenticate,
        loadConversations: loadConversations,
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.probe,
    required this.authenticate,
    required this.loadConversations,
  });

  final ServerProbe probe;
  final PasswordLogin authenticate;
  final ConversationLoader loadConversations;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _address = TextEditingController(text: 'https://matrix.org');
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _loggingIn = false;
  AccountSummary? _account;
  LoginError? _loginError;
  ServerInfo? _info;
  ProbeError? _error;

  Future<void> _probe() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _info = null;
      _error = null;
      _loginError = null;
    });
    try {
      final info = await widget.probe(_address.text);
      if (!mounted) return;
      setState(() => _info = info);
    } on ProbeError catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } catch (_) {
      // Falhas de transporte da ponte também recebem uma mensagem fixa e segura.
      if (!mounted) return;
      setState(() => _error = ProbeError.internal);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _login() async {
    if (_loading || _account != null) return;
    setState(() {
      _loading = true;
      _loggingIn = true;
      _loginError = null;
      _error = null;
      _info = null;
    });
    try {
      // A senha é enviada somente nesta chamada, sem cópia em estado da tela.
      final pending = widget.authenticate(
        _address.text,
        _username.text,
        _password.text,
      );
      _password.clear();
      final account = await pending;
      if (!mounted) return;
      setState(() => _account = account);
    } on LoginError catch (error) {
      if (!mounted) return;
      setState(() => _loginError = error);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loginError = LoginError.internal);
    } finally {
      if (mounted) {
        // Inclui falha síncrona da ponte. Não guardamos a senha para nova tentativa.
        _password.clear();
        setState(() {
          _loading = false;
          _loggingIn = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Acesso Matrix')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Entre com sua conta Matrix. A sessão dura até fechar o aplicativo.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _address,
                  enabled: !_loading && _account == null,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'URL HTTPS do homeserver',
                    hintText: 'https://matrix.org',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _login(),
                ),
                const SizedBox(height: 16),
                if (_account == null)
                  AutofillGroup(
                    // Cancelar evita solicitar que a plataforma salve a credencial.
                    onDisposeAction: AutofillContextAction.cancel,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _username,
                          enabled: !_loading,
                          autofillHints: const [AutofillHints.username],
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Usuário ou ID Matrix',
                            border: OutlineInputBorder(),
                          ),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _password,
                          enabled: !_loading,
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            labelText: 'Senha',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _login(),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _loading ? null : _login,
                          child: const Text('Entrar'),
                        ),
                      ],
                    ),
                  ),
                if (_account case final account?) ...[
                  const Text('Conta autenticada'),
                  SelectableText(account.userId),
                  SelectableText('Dispositivo: ${account.deviceId}'),
                  SelectableText(account.homeserverAddress),
                  const SizedBox(height: 16),
                  ConversationList(load: widget.loadConversations),
                ],
                if (_loginError case final error?) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(loginErrorMessage(error)),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _loading ? null : _probe,
                  child: const Text('Verificar servidor'),
                ),
                if (_loading) ...[
                  const SizedBox(height: 16),
                  const Center(child: CircularProgressIndicator()),
                  Text(_loggingIn ? 'Autenticando…' : 'Consultando servidor…'),
                ],
                if (_info case final info?) ...[
                  const SizedBox(height: 16),
                  const Text('Servidor respondeu à consulta Matrix.'),
                  SelectableText(info.serverAddress),
                  Text(
                    'Login com senha: ${info.supportsPasswordLogin ? 'suportado' : 'não suportado'}',
                  ),
                ],
                if (_error case final error?) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(probeErrorMessage(error)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String probeErrorMessage(ProbeError error) => switch (error) {
  ProbeError.invalidServerAddress =>
    'Informe uma URL HTTPS válida, sem credenciais, consulta ou fragmento.',
  ProbeError.network =>
    'Não foi possível conectar ao servidor. Verifique o endereço e a conexão e tente novamente.',
  ProbeError.tls =>
    'Não foi possível estabelecer uma conexão TLS segura. Verifique o certificado do servidor.',
  ProbeError.unusableHomeserver =>
    'O servidor não forneceu uma resposta Matrix válida para esta consulta. Verifique a URL ou tente novamente mais tarde.',
  ProbeError.internal =>
    'Não foi possível concluir a verificação. Tente novamente.',
};

String loginErrorMessage(LoginError error) => switch (error) {
  LoginError.invalidServerAddress => probeErrorMessage(
    ProbeError.invalidServerAddress,
  ),
  LoginError.invalidInput => 'Informe o usuário e a senha.',
  LoginError.passwordLoginUnsupported =>
    'Este servidor não oferece login com senha.',
  LoginError.invalidCredentials =>
    'Usuário ou senha inválidos. Digite novamente para tentar.',
  LoginError.network => probeErrorMessage(ProbeError.network),
  LoginError.tls => probeErrorMessage(ProbeError.tls),
  LoginError.rateLimited =>
    'Muitas tentativas. Aguarde antes de tentar novamente.',
  LoginError.alreadyAuthenticated =>
    'Já existe uma conta autenticada. Reinicie o aplicativo para entrar com outra conta.',
  LoginError.loginInProgress =>
    'Já existe uma tentativa de login em andamento.',
  LoginError.unusableHomeserver => probeErrorMessage(
    ProbeError.unusableHomeserver,
  ),
  LoginError.internal => 'Não foi possível concluir o login. Tente novamente.',
};
