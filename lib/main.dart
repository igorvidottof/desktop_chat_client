import 'package:flutter/material.dart';

import 'src/rust/api/simple.dart';
import 'conversation_list.dart';
import 'conversation_screen.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(
    MyApp(
      initialize: initializeSession,
      logoutAction: logout,
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

typedef SessionInitializer = Future<SessionState> Function();

typedef ServerProbe = Future<ServerInfo> Function(String address);

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.initialize,
    required this.logoutAction,
    required this.probe,
    required this.authenticate,
    required this.loadConversations,
    this.loadHistory = loadMessageHistory,
  });

  final SessionInitializer initialize;
  final Future<LogoutResult> Function() logoutAction;
  final ServerProbe probe;
  final PasswordLogin authenticate;
  final ConversationLoader loadConversations;
  final MessageHistoryLoader loadHistory;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Desktop Chat Client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: LoginScreen(
        initialize: initialize,
        logoutAction: logoutAction,
        probe: probe,
        authenticate: authenticate,
        loadConversations: loadConversations,
        loadHistory: loadHistory,
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.initialize,
    required this.logoutAction,
    required this.probe,
    required this.authenticate,
    required this.loadConversations,
    required this.loadHistory,
  });

  final SessionInitializer initialize;
  final Future<LogoutResult> Function() logoutAction;
  final ServerProbe probe;
  final PasswordLogin authenticate;
  final ConversationLoader loadConversations;
  final MessageHistoryLoader loadHistory;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _address = TextEditingController(text: 'https://matrix.org');
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _initializing = true;
  bool _loggingOut = false;
  LogoutError? _logoutError;
  String? _logoutNotice;
  SessionError? _sessionError;
  bool _loading = false;
  bool _loggingIn = false;
  AccountSummary? _account;
  LoginError? _loginError;
  ServerInfo? _info;
  ProbeError? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    setState(() {
      _initializing = true;
      _sessionError = null;
    });
    try {
      // Rust é a autoridade também após hot restart; Dart só recebe resumo seguro.
      final state = await widget.initialize();
      if (!mounted) return;
      setState(() => _account = state.account);
    } on SessionError catch (error) {
      if (!mounted) return;
      setState(() => _sessionError = error);
    } catch (_) {
      if (!mounted) return;
      setState(() => _sessionError = SessionError.internal);
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  Future<void> _probe() async {
    if (_loading || _initializing) return;
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
    if (_loading || _initializing || _account != null) return;
    setState(() {
      _loading = true;
      _loggingIn = true;
      _loginError = null;
      _logoutNotice = null;
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
      setState(() {
        _account = account;
        _sessionError = null;
      });
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

  Future<void> _logout() async {
    if (_loading || _loggingOut || _account == null) return;
    setState(() {
      _loggingOut = true;
      _logoutError = null;
      _info = null;
      _error = null;
    });
    try {
      final result = await widget.logoutAction();
      if (!mounted) return;
      setState(() {
        _account = null;
        _sessionError = null;
        _loginError = null;
        _username.clear();
        _password.clear();
        final remoteConfirmed =
            result.remoteStatus == RemoteLogoutStatus.confirmed ||
            result.remoteStatus == RemoteLogoutStatus.alreadyInvalid;
        _logoutNotice = [
          if (!remoteConfirmed)
            'A sessão local foi removida. Não foi possível confirmar a saída no servidor.',
          if (result.storeCleanupPending)
            'A sessão não pode ser restaurada, mas a remoção dos dados locais restantes ficou pendente.',
        ].join(' ');
      });
    } on LogoutError catch (error) {
      if (!mounted) return;
      if (error == LogoutError.notAuthenticated) {
        // Reconcilia com Rust quando outro chamador já encerrou a sessão.
        await _initialize();
      } else {
        setState(() => _logoutError = error);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _logoutError = LogoutError.internal);
    } finally {
      if (mounted) setState(() => _loggingOut = false);
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
    if (_initializing ||
        (_sessionError != null &&
            _sessionError != SessionError.invalidSession)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Acesso Matrix')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_initializing) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  const Text('Verificando sessão…'),
                ] else ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(sessionErrorMessage(_sessionError!)),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _initialize,
                    child: const Text('Tentar novamente'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
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
                if (_account == null)
                  const Text(
                    'Entre com sua conta Matrix. A sessão será salva com segurança.',
                  ),
                if (_sessionError == SessionError.invalidSession)
                  Text(sessionErrorMessage(SessionError.invalidSession)),
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
                  FilledButton(
                    onPressed: _loading || _loggingOut ? null : _logout,
                    child: const Text('Logout'),
                  ),
                  if (_loggingOut) ...[
                    const CircularProgressIndicator(),
                    const Text('Saindo…'),
                  ] else
                    // Desmontar durante logout invalida callbacks de salas antigas.
                    ConversationList(
                      load: widget.loadConversations,
                      loadHistory: widget.loadHistory,
                    ),
                ],
                if (_logoutError case final error?)
                  Semantics(
                    liveRegion: true,
                    child: Text(logoutErrorMessage(error)),
                  ),
                if (_logoutNotice case final notice? when notice.isNotEmpty)
                  Semantics(liveRegion: true, child: Text(notice)),
                if (_loginError case final error?) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(loginErrorMessage(error)),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _loading || _loggingOut ? null : _probe,
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
    'Já existe uma conta autenticada. Verifique a sessão novamente.',
  LoginError.loginInProgress =>
    'Já existe uma tentativa de login em andamento.',
  LoginError.unusableHomeserver => probeErrorMessage(
    ProbeError.unusableHomeserver,
  ),
  LoginError.secureStorage =>
    'O armazenamento seguro não está disponível. O login não foi concluído. Desbloqueie o cofre do sistema e tente novamente.',
  LoginError.persistence =>
    'Não foi possível salvar a sessão. O login não foi concluído. Verifique o armazenamento e tente novamente.',
  LoginError.internal => 'Não foi possível concluir o login. Tente novamente.',
};

String sessionErrorMessage(SessionError error) => switch (error) {
  SessionError.operationInProgress =>
    'Uma operação de autenticação está em andamento. Tente novamente.',
  SessionError.network =>
    'Não foi possível validar a sessão com o servidor. Verifique a conexão e tente novamente. A sessão salva foi preservada.',
  SessionError.tls => probeErrorMessage(ProbeError.tls),
  SessionError.invalidSession =>
    'A sessão foi rejeitada pelo servidor. Entre novamente.',
  SessionError.corruptedSession =>
    'A sessão salva está incompleta ou não pôde ser lida. Verifique o armazenamento e tente novamente.',
  SessionError.secureStorage =>
    'Não foi possível acessar o armazenamento seguro. Desbloqueie o cofre do sistema e tente novamente.',
  SessionError.persistence =>
    'Não foi possível acessar os dados da sessão. Verifique o armazenamento e tente novamente.',
  SessionError.internal =>
    'Não foi possível verificar a sessão. Tente novamente.',
};

String logoutErrorMessage(LogoutError error) => switch (error) {
  LogoutError.notAuthenticated => 'A sessão já não está autenticada.',
  LogoutError.logoutInProgress => 'A saída já está em andamento.',
  LogoutError.authenticationOperationInProgress =>
    'Uma operação de autenticação está em andamento. Tente novamente.',
  LogoutError.secureStorage =>
    'Não foi possível remover a sessão do armazenamento seguro. Desbloqueie o cofre do sistema e tente Logout novamente.',
  LogoutError.localCleanup =>
    'Não foi possível concluir a remoção da sessão local. Tente Logout novamente.',
  LogoutError.internal =>
    'Não foi possível confirmar a saída. Tente Logout novamente.',
};
