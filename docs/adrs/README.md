# Architectural Decision Records

Este diretório armazena os ADRs (Architectural Decision Records) da feature **Sistema de Webhooks de
Notificação de Pedidos**.

Cada decisão arquitetural relevante é registrada em um arquivo individual, nomeado no formato
`ADR-NNN-titulo-em-kebab-case.md`, seguindo o formato **MADR**: Status, Contexto, Decisão,
Alternativas Consideradas e Consequências (positivas, negativas e trade-off explícito).

Todas as decisões abaixo têm origem na reunião técnica registrada em
[`TRANSCRICAO.md`](../../TRANSCRICAO.md) e/ou no código da aplicação. A rastreabilidade item a item
está em [`docs/TRACKER.md`](../TRACKER.md).

## Índice

| ADR | Decisão | Status | Decisão principal da reunião |
| --- | --- | --- | --- |
| [ADR-001](./ADR-001-outbox-no-mysql.md) | Padrão Outbox no MySQL para publicação de eventos de pedido | Aceita | Padrão Outbox no MySQL |
| [ADR-002](./ADR-002-worker-em-processo-separado-com-polling.md) | Worker em processo separado consumindo a outbox por polling de 2 s | Aceita | Worker em processo separado em polling |
| [ADR-003](./ADR-003-retry-com-backoff-exponencial-e-dlq.md) | Retry com backoff exponencial e DLQ em tabela separada | Aceita | Política de retry com backoff e DLQ |
| [ADR-004](./ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md) | Assinatura HMAC-SHA256 com secret por endpoint e rotação com grace de 24 h | Aceita (sujeita à revisão de segurança) | Autenticação HMAC-SHA256 com secret por endpoint |
| [ADR-005](./ADR-005-entrega-at-least-once-com-x-event-id.md) | Entrega at-least-once com deduplicação delegada via `X-Event-Id` | Aceita | Garantia at-least-once com `X-Event-Id` |
| [ADR-006](./ADR-006-reuso-dos-padroes-existentes-do-projeto.md) | Reuso máximo dos padrões existentes do projeto | Aceita | Reuso dos padrões existentes do projeto |
| [ADR-007](./ADR-007-snapshot-do-payload-na-insercao-da-outbox.md) | Snapshot do payload renderizado na inserção da outbox | Aceita | Decisão secundária (encerramento da call) |

As seis decisões principais discutidas na reunião estão cobertas por ADR-001 a ADR-006. A ADR-007
registra uma decisão secundária fechada no encerramento da call ([09:52]) que tem consequência
arquitetural relevante — imutabilidade do evento e desacoplamento do worker.

Decisões técnicas secundárias sem impacto estrutural (formato exato do payload, timeouts, headers,
limite de 64 KB, obrigatoriedade de `https`) **não** viraram ADR e estão especificadas em
[`docs/FDD.md`](../FDD.md), conforme decidido na própria reunião — Larissa, sobre o limite de
payload: "não vejo como decisão arquitetural separada, é só requisito não funcional" ([09:24]).
