# Limitações e itens pendentes

Este registro distingue funcionalidades fora do escopo de verificações ainda
necessárias. Foi conferido contra o código atual; os comandos do README não
representam resultados de testes ou builds nesta revisão documental.

## Limitações funcionais

| Área | Limitação atual |
| --- | --- |
| Autenticação | Uma sessão ativa; senha e homeserver HTTPS explícito, sem redirecionamentos. Sem cadastro, SSO ou descoberta automática por domínio. |
| Salas | Lista salas ingressadas e convites pendentes, com aceitação; cria salas privadas com convites por IDs Matrix completos. Sem descoberta pública, aliases, ingresso por ID/alias, rejeição de convites ou administração/alteração de membros após criação. |
| Histórico | Até 50 eventos recentes, filtrados pelos tipos suportados, e até 50 mensagens na timeline. Sem paginação; podem aparecer menos de 50 mensagens. |
| Conteúdo | Envio de texto; apresentação de texto, avisos e emotes simples. Sem anexos, reações, busca, edição ou tratamento de respostas encadeadas. |
| Envio | Até 10.000 valores escalares Unicode. Sem fila persistente offline ou repetição automática do envio pela aplicação. |
| Salas criptografadas | Fora do escopo; histórico e envio não são suportados. |
| Plataformas | Alvos macOS, Linux e Windows; Android, iOS e web não fazem parte do escopo desktop. |

Se um envio falhar após chegar ao servidor, sua aceitação pode ficar incerta.
Confira o histórico antes de repetir para evitar duplicação.

## Sessão e logout

- O cofre nativo deve estar disponível e desbloqueado. Falhas de acesso podem
  impedir login, restauração ou limpeza local.
- Logout aguarda operações nativas e a parada cooperativa do sync, incluindo
  uma requisição longa em andamento. A tela de progresso pode permanecer visível.
- Logout remoto pode falhar mesmo com saída local concluída. A interface
  distingue os resultados; saída local não prova revogação do token no servidor.
- A exclusão física dos bancos usados pelo processo é diferida para a próxima
  inicialização nativa. Hot restart Dart não equivale a reiniciar o processo.
## Verificações ainda necessárias

Testes Dart isolam a aplicação por fakes; testes Rust exercitam o SDK e fixtures
locais. Eles não comprovam integração com homeserver de produção. Não há suíte
`integration_test/` para os fluxos completos.

Antes de considerar a entrega validada em uso real:

1. Executar login, sincronização de salas, histórico e envio/recebimento entre
   dois clientes com conta de teste e homeserver adequado.
2. Encerrar e reabrir o processo para conferir restauração; realizar logout e
   conferir limpeza na próxima inicialização, incluindo falha remota e
   indisponibilidade do cofre.
3. Executar testes e builds no host de cada plataforma. macOS é o ambiente de
   desenvolvimento inspecionado; Linux e Windows permanecem pendentes de
   validação nos respectivos hosts. O build macOS não foi reexecutado nesta revisão.

A integração macOS existente usa CocoaPods. O README anterior registra um aviso
de compatibilidade do plugin gerado com Swift Package Manager; a integração não
foi migrada nem revalidada nesta revisão.
