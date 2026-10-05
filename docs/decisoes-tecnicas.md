# Principais decisões técnicas

Este registro descreve o código atual.
A presença da implementação não substitui a validação com homeserver real.

## Flutter para apresentação; Rust para Matrix

Flutter concentra interface, interação e estado de apresentação. Rust possui o
cliente Matrix ativo, protocolo, sincronização, sessão e bancos do SDK. Flutter
Rust Bridge transporta comandos assíncronos e eventos; handles Matrix não
atravessam essa fronteira.

Isso permite usar protocolo e armazenamento suportados pelo SDK sem manter
um segundo cliente Matrix em Dart. O custo é uma toolchain nativa adicional e
a regeneração dos bindings quando a API muda.

## Camadas e composição

A organização acompanha o [guia de arquitetura do Flutter](https://docs.flutter.dev/app-architecture/guide):
Views renderizam e encaminham ações; ViewModels controlam estados e ações;
repositórios convertem dados e falhas; serviços isolam a bridge.

```text
View → ViewModel → contrato de repositório → serviço de bridge → Rust/Matrix SDK
```

`lib/ui/` agrupa autenticação, salas e conversa; `lib/data/` contém contratos,
implementações e serviços; `lib/domain/models/` contém modelos imutáveis sem
Flutter, GetX ou tipos gerados. `lib/app/app_binding.dart` compõe as dependências.
Os repositórios Dart expõem a projeção dos dados nativos; Rust continua sendo a
autoridade da sessão e dos stores. Não há casos de uso que apenas repassem chamadas.

Essa divisão permite testar ViewModels com fakes e trocar o adaptador nativo
sem alterar Views, ao custo de mapear explicitamente DTOs e categorias de erro.

## GetX com escopo explícito

GetX implementa ViewModels e composição. Cada funcionalidade expõe snapshots
imutáveis, apresentados por `GetBuilder` local. Modelos, serviços e repositórios
não dependem de GetX; a navegação usa Flutter.

A composição mantém autenticação durante a vida da aplicação, salas durante a
sessão autenticada e conversa durante a seleção da sala. Descartar esses objetos
cancela assinaturas de apresentação. Gerações de operação e épocas de sessão
rejeitam respostas antigas após troca de sala ou logout. Isso exige controle
explícito do ciclo de vida, mas evita tornar todas as dependências permanentes.

## Um proprietário da sincronização

Rust inicia um único sync por cliente autenticado e o encerra cooperativamente
no logout. Salas e conversa compartilham um consumidor nativo na apresentação
Dart. Descartar esse consumidor fecha sua assinatura sem parar o sync; reconstruir
widgets não inicia outro loop.

O transporte tem filas limitadas, confirmação de consumo e um evento em voo por
assinatura. Atrasos ou perdas provocam invalidação e nova leitura do estado.
Essa escolha limita memória, ao custo de recargas adicionais.

## Sessão pelo SDK

O backend usa SQLite embarcado e o armazenamento de estado do Matrix SDK.
Tokens e a passphrase do store ficam no cofre do sistema: Keychain no macOS,
cofre de credenciais no Windows e Secret Service no Linux. Metadados em disco
identificam o store; a senha de login não é persistida.

A restauração reutiliza sessão, dispositivo e store. Logout revoga a restauração
local e solicita logout remoto. A exclusão física de stores usados pelo processo
é registrada para a próxima inicialização nativa, evitando apagar bancos com
handles vivos, ao custo de limpeza diferida.

## Histórico limitado e confirmação de envio

O histórico consulta até 50 eventos e a timeline mantém até 50 mensagens.
Repositórios reconciliam por `event_id`. A entrada só é limpa após aceitação
pelo servidor e envios sobrepostos são bloqueados. Não há fila persistente offline.

O limite mantém memória e trabalho previsíveis para o desafio, mas impede navegar
pelo histórico completo. Falhas de rede podem deixar a aceitação de um envio
incerta, por isso uma nova tentativa é explícita.
