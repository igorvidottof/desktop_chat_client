import 'dart:async';

import 'package:flutter/material.dart';

class LogoutProgressScreen extends StatefulWidget {
  const LogoutProgressScreen({super.key});

  @override
  State<LogoutProgressScreen> createState() => _LogoutProgressScreenState();
}

class _LogoutProgressScreenState extends State<LogoutProgressScreen> {
  static const _messages = [
    'Encerrando a sincronização…',
    'Finalizando operações em andamento…',
    'Protegendo os dados da sua sessão…',
    'Só mais alguns instantes…',
    'Finalizando com segurança…',
  ];

  late final Timer _rotation;
  int _messageIndex = 0;

  @override
  void initState() {
    super.initState();
    // Texto de apresentação, sem progresso nativo ou chamadas de rede/ponte.
    // Depois do primeiro ciclo, não sugerir que a sincronização reiniciou.
    _rotation = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      setState(() {
        _messageIndex =
            _messageIndex + 1 < _messages.length ? _messageIndex + 1 : 1;
      });
    });
  }

  @override
  void dispose() {
    _rotation.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Semantics(
                container: true,
                liveRegion: true,
                label: 'Saindo da sua conta. Aguarde o encerramento da sessão.',
                // A leitura assistiva é estável; só o texto visual muda a cada 5s.
                child: ExcludeSemantics(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Saindo da sua conta…',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 24),
                      const CircularProgressIndicator(),
                      const SizedBox(height: 24),
                      Text(
                        _messages[_messageIndex],
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
