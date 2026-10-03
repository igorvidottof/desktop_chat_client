import 'package:flutter/material.dart';

import 'src/rust/api/simple.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(MyApp(probe: (address) => probeServer(address: address)));
}

typedef ServerProbe = Future<ServerInfo> Function(String address);

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.probe});

  final ServerProbe probe;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Desktop Chat Client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: ServerProbeScreen(probe: probe),
    );
  }
}

class ServerProbeScreen extends StatefulWidget {
  const ServerProbeScreen({super.key, required this.probe});

  final ServerProbe probe;

  @override
  State<ServerProbeScreen> createState() => _ServerProbeScreenState();
}

class _ServerProbeScreenState extends State<ServerProbeScreen> {
  final _address = TextEditingController(text: 'https://matrix.org');
  bool _loading = false;
  ServerInfo? _info;
  ProbeError? _error;

  Future<void> _probe() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _info = null;
      _error = null;
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

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnóstico Matrix')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Consulta pública ao servidor, sem autenticação.'),
                const SizedBox(height: 16),
                TextField(
                  controller: _address,
                  enabled: !_loading,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'URL HTTPS do homeserver',
                    hintText: 'https://matrix.org',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _probe(),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _loading ? null : _probe,
                  child: const Text('Verificar servidor'),
                ),
                if (_loading) ...[
                  const SizedBox(height: 16),
                  const Center(child: CircularProgressIndicator()),
                  const Text('Consultando servidor…'),
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
