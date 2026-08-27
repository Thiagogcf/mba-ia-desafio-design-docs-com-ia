# RFC — Sistema de Webhooks de Notificação de Pedidos

> **Documento submetido à equipe para revisão.** Responde *o que propomos e por quê*. O
> detalhamento de implementação — contratos completos, matriz de erros, modelagem de tabelas — está
> em [`docs/FDD.md`](./FDD.md); o *porquê de produto* está em [`docs/PRD.md`](./PRD.md).

## Metadados

| Campo | Valor |
| --- | --- |
| **RFC** | 001 — Sistema de Webhooks de Notificação de Pedidos |
| **Status** | **Em revisão** |
| **Autora** | Larissa — Tech Lead, que assumiu abrir o design doc da feature ([09:50]) |
| **Redação** | Thiago Ferronato, a partir de [`TRANSCRICAO.md`](../TRANSCRICAO.md) e do código |
| **Data** | 2026-08-26 |
| **Revisores** | **Bruno** e **Diego**, em sessão a marcar antes de codar ([09:50]); **Sofia**, com 2 dias úteis para revisar HMAC e geração de secret antes do deploy ([09:46]); **Marcos**, escopo e prazo |
| **Relacionados** | [PRD](./PRD.md) · [FDD](./FDD.md) · [ADRs](./adrs/) · [Tracker](./TRACKER.md) |

---

## 1. Resumo executivo (TL;DR)

Notificação **outbound** de mudança de status via webhook HTTP, sobre o **padrão Outbox no MySQL já
existente**: mudança de status e registro do evento na **mesma transação**, e um **worker em processo
separado**, em polling de **2 segundos**, entrega.

Falha do cliente é tratada com **backoff exponencial (1m → 5m → 30m → 2h → 12h, 5 retentativas)**;
esgotada a escada, o evento vai para uma **tabela de dead letter**, com replay manual restrito a
`ADMIN`. Cada envio é assinado em **HMAC-SHA256** com **secret única por endpoint**, rotacionável com
**grace de 24 horas**. A garantia é **at-least-once**, com deduplicação delegada ao cliente via
**`X-Event-Id`**.

Sem infraestrutura nova e sem dependência adicional no `package.json`. O módulo
`src/modules/webhooks/` segue o padrão dos existentes.

**Custo:** três sprints, com a revisão de segurança dentro ([09:46] Larissa).
**Prazo:** fim de novembro, compromisso com a Atlas ([09:45] Marcos).

---

## 2. Contexto e problema

Três clientes B2B — **Atlas Comercial, MaxDistribuição e Nova Cargo** — pediram formalmente para ser
notificados quando o status dos pedidos deles muda ([09:00] Marcos). Hoje fazem **polling em
`GET /orders`**, o que torna a integração lenta e cara do lado deles; a Atlas sinalizou possível
migração para um concorrente se não entregarmos até o fim do trimestre ([09:00] Marcos).

"Tempo real", para eles, é **abaixo de 10 segundos**; o inaceitável é ficar pendurado e ter de
atualizar manualmente ([09:02] Marcos). O escopo é **exclusivamente outbound** ([09:02] Marcos;
confirmado por Sofia em [09:03]).

O OMS **não tem hoje mecanismo algum de notificação externa, evento ou fila**. O que existe é a
máquina de estados de `src/modules/orders/order.status.ts` e uma transação de mudança de status já
densa em `src/modules/orders/order.service.ts:131`, que valida a transição, movimenta estoque,
atualiza `orders` e insere em `order_status_history`.

O problema é: **como emitir um evento externo sem comprometer a integridade nem a disponibilidade do
fluxo de pedidos**, sendo o destino infraestrutura de terceiro.

---

## 3. Proposta técnica

### 3.1 Visão geral

```
  PATCH /api/v1/orders/:id/status
        │
        ▼  OrderService.changeStatus — $transaction
     valida transição · movimenta estoque · UPDATE orders
     INSERT order_status_history
     INSERT webhook_outbox   ← 1 linha por endpoint assinante
        │                      falhou aqui ⇒ ROLLBACK de tudo
        ▼ commit
  [ webhook_outbox ]  PENDING · PROCESSING · FAILED · DELIVERED · DEAD_LETTERED
        │
        ▼  polling 2s — processo separado (src/worker.ts)
     lê pendentes em ordem de created_at · assina HMAC-SHA256 · POST · timeout 10s
        │
    2xx ├──────────────► DELIVERED + registro de entrega
        │
   falha └──► retry 1m→5m→30m→2h→12h (5x) ──esgotou──► [ webhook_dead_letter ]
                                                              │ replay manual (ADMIN)
                                                              └──► volta como PENDING
```

### 3.2 Pilares da proposta

| Pilar | O que decidimos | Origem | ADR |
| --- | --- | --- | --- |
| **Publicação transacional** | O evento é gravado na mesma transação que muda o status: commit ⟺ evento registrado. Falha ao gravar **aborta a mudança de status**. O gancho é `publishWebhookEvent(tx, order, from, to)`, função que recebe o transaction client em vez de um repositório injetado | [09:06], [09:40], [09:41] | [ADR-001](./adrs/ADR-001-outbox-no-mysql.md) |
| **Consumo desacoplado** | Entrypoint próprio no molde do `src/server.ts`, com `PrismaClient` seu, acionado por `npm run worker`. Polling porque o MySQL não tem `LISTEN`/`NOTIFY`; 2 s cabem no orçamento de 10 s | [09:09], [09:11], [09:30] | [ADR-002](./adrs/ADR-002-worker-em-processo-separado-com-polling.md) |
| **Resiliência** | Cinco retentativas em escada 1m/5m/30m/2h/12h (~14h36min), timeout de 10 s por tentativa. Esgotada a escada, o evento vai para `webhook_dead_letter`, de onde só sai por replay manual como `ADMIN`, com registro de autoria | [09:17], [09:18], [09:36], [09:42] | [ADR-003](./adrs/ADR-003-retry-com-backoff-exponencial-e-dlq.md) |
| **Segurança** | HMAC-SHA256 sobre o corpo, secret única por endpoint — "se vaza uma, vaza tudo" — rotacionável com grace de 24 h. URL obrigatoriamente `https` | [09:21], [09:22], [09:23] | [ADR-004](./adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md) |
| **Semântica de entrega** | *At-least-once*, com deduplicação delegada ao cliente via `X-Event-Id` estável entre tentativas. Garantia documentada no portal do desenvolvedor | [09:25], [09:26] | [ADR-005](./adrs/ADR-005-entrega-at-least-once-com-x-event-id.md) |
| **Aderência ao codebase** | Módulo igual aos existentes, erros herdando de `AppError` com prefixo `WEBHOOK_`, nada novo de logging, error middleware absorve os erros sem alteração | [09:27], [09:29], [09:30] | [ADR-006](./adrs/ADR-006-reuso-dos-padroes-existentes-do-projeto.md) |
| **Imutabilidade do evento** | Payload renderizado e gravado como snapshot na inserção, para o evento refletir o estado de quando o status mudou | [09:52] | [ADR-007](./adrs/ADR-007-snapshot-do-payload-na-insercao-da-outbox.md) |

### 3.3 Superfície pública proposta

Três famílias de contrato, detalhadas em [`docs/FDD.md`](./FDD.md):

1. **CRUD de configuração** (autenticado, qualquer papel): criar, listar, editar, remover e
   rotacionar secret ([09:31] Marcos; [09:33] Bruno; [09:21] Sofia). O `customer_id` **não vem do
   JWT** — vai no body ou no path, porque o JWT atual representa o operador, não o cliente
   ([09:32] Larissa, corrigindo a proposta inicial de [09:31] Marcos).
2. **Histórico de entregas**, com sucesso/falha, payload, response e tempo ([09:34] Marcos).
3. **Replay administrativo de dead letter**, restrito a `ADMIN` via `requireRole` ([09:36] Larissa),
   com auditoria de autoria ([09:36] Sofia).

Os caminhos completos, já com o prefixo `/api/v1` que o app monta em todas as rotas, estão em
[`docs/FDD.md`](./FDD.md#6-contratos-públicos).

---

## 4. Alternativas consideradas

Todas foram levantadas e descartadas na própria reunião.

| # | Alternativa | Trade-off que motivou o descarte | ADR |
| --- | --- | --- | --- |
| 1 | **Disparo HTTP síncrono dentro de `changeStatus`** — Larissa abre ([09:03]), Bruno contesta ([09:04]) | Disponibilidade do core de pedidos por facilidade de implementação: cliente lento travaria a mudança de status de **outros** pedidos, e não há rollback aceitável se ele estiver fora do ar. "Síncrono está fora de questão" ([09:06] Diego) | [ADR-001](./adrs/ADR-001-outbox-no-mysql.md) |
| 2 | **Redis Streams / broker dedicado** — Larissa ([09:07]) | Escalabilidade futura por custo operacional imediato num time pequeno; e publicar fora da transação reintroduziria o dual-write. "Subir Redis Cluster pra isso é overengineering" ([09:07] Diego) | [ADR-001](./adrs/ADR-001-outbox-no-mysql.md) |
| 3 | **Trigger de banco notificando o worker** — Bruno ([09:09]) | Latência que **não é requisito** (SLA < 10 s) por um mecanismo frágil: MySQL não tem `LISTEN`/`NOTIFY`, e trigger só executa SQL ([09:09] Diego) | [ADR-002](./adrs/ADR-002-worker-em-processo-separado-com-polling.md) |
| 4 | **Garantia exactly-once** — Diego ([09:25]) | Simplicidade para o cliente por complexidade desproporcional: exigiria coordenação dos dois lados ([09:25]) | [ADR-005](./adrs/ADR-005-entrega-at-least-once-com-x-event-id.md) |
| 5 | **Secret global da plataforma** — Sofia ([09:21]) | Simplicidade operacional por um raio de explosão igual à base inteira: "se vaza uma, vaza tudo" ([09:21]) | [ADR-004](./adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md) |

Outras quatro alternativas descartadas, com o trade-off registrado na ADR correspondente: **DLQ como
flag `failed` na própria outbox** ([09:17] Larissa → ADR-003), **3 retentativas em vez de 5**
([09:16] Bruno → ADR-003), **retry indefinido com backoff** ([09:15] Diego → ADR-003) e **guardar só
`order_id` e renderizar no envio** ([09:51] Bruno → ADR-007).

---

## 5. Questões em aberto

### 5.1 Levantadas na reunião e não decididas

| # | Questão | Como ficou | Pendente |
| --- | --- | --- | --- |
| **Q1** | Rate limiting de saída — 50 pedidos mudando de status viram 50 chamadas ao cliente? ([09:38] Diego) | "Fica como observar e decidir depois" ([09:39] Larissa) | Definir a métrica que dispara a decisão |
| **Q2** | O CRUD de webhook pode ser feito por qualquer papel autenticado? ([09:36] Marcos) | "Por enquanto sim. Mais pra frente a gente pode endurecer" ([09:37] Sofia) | Critério e momento do endurecimento |
| **Q3** | Como escalar para múltiplos workers sem perder ordenação? | "Problema do futuro, não agora" ([09:13] Diego); registrado como limitação conhecida ([09:13] Larissa) | Gatilho de volume que obriga a decidir |
| **Q4** | Arquivamento das linhas entregues (~30 dias) | Declarado fora do escopo desta feature ([09:08] Diego) | Política de retenção, mecanismo e responsável |
| **Q5** | Alerta ao cliente sobre webhook com problema ([09:37] Marcos) | "Talvez próxima fase, depois que a gente medir o impacto" ([09:37] Larissa) | Qual métrica condiciona a decisão |

### 5.2 Surgidas durante a redação deste RFC

| # | Questão | Por que existe |
| --- | --- | --- |
| **Q6** | A secret fica em claro ou cifrada em repouso? | Diferente de senha (hash bcrypt em `users.passwordHash`), ela precisa ser recuperável para recomputar o HMAC. A reunião definiu que a tabela a armazena ([09:21] Bruno), não a forma. Vai à revisão de segurança ([09:46] Sofia) |
| **Q7** | O que "a antiga fica válida por 24 horas em paralelo" ([09:21] Sofia) significa num fluxo outbound? | Quem assina somos nós; só produz o efeito desejado se o envio carregar as duas assinaturas na janela. Interpretação em [ADR-004](./adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md), a confirmar ([09:46]) |
| **Q8** | E se o cliente rotacionar duas vezes em menos de 24 h? | Haveria três secrets relevantes; caso não tratado. Proposta: recusar a segunda rotação enquanto a janela estiver aberta |

## 6. Impacto e riscos

### 6.1 Impacto

| Dimensão | Impacto |
| --- | --- |
| **Código existente** | Uma única alteração de comportamento: `changeStatus` em `src/modules/orders/order.service.ts`. O resto é mecânico (registro do módulo, extensão das classes de erro e do env, script novo) — lista completa em [FDD §10.1](./FDD.md#101-mapa-de-integração). `error.middleware.ts`, `validate.middleware.ts` e `auth.middleware.ts` são **consumidos sem alteração** ([09:29] Bruno) |
| **Logger** | `src/shared/logger/index.ts` exige **uma alteração obrigatória**: incluir a secret na lista de `redactPaths`, que hoje não a cobre — senão um log acidental vaza o segredo, o incidente relatado por Diego ([09:22]). Ver [FDD §9.2](./FDD.md#92-logs) |
| **Banco de dados** | Quatro tabelas novas + migration. A transação de `changeStatus` ganha um `INSERT` por endpoint assinante, aumentando o tempo de lock |
| **Operação** | Artefato de deploy novo (`npm run worker`) e **duas pools** contra o mesmo MySQL — revisar `max_connections` |
| **Contrato com o cliente** | Garantia at-least-once exige deduplicação do lado dele e documentação no portal ([09:26] e [09:40] Marcos) |
| **Cronograma** | Três sprints, revisão de segurança ao final ([09:46] Larissa) |

### 6.2 Riscos de arquitetura

Só os que decorrem da forma escolhida. Risco de produto está em
[`docs/PRD.md`](./PRD.md#10-riscos-e-mitigação); risco técnico, em
[`docs/FDD.md`](./FDD.md#13-riscos-técnicos-e-mitigação).

| Risco | Origem | Reabre |
| --- | --- | --- |
| A transação de `changeStatus` fica mais longa e ganha um modo de falha novo | [09:04] Bruno; [09:40] Bruno | ADR-001 |
| Worker em instância única para de entregar com sintoma silencioso: a taxa de erro fica em zero | [09:11] e [09:12] Diego | ADR-002 + **Q3** |
| A outbox cresce sem limite enquanto o arquivamento estiver fora de escopo | [09:07] Bruno; [09:08] Diego | **Q4** |
| O SLA de 10 s não fecha no pior caso: 2 s de polling + 10 s de timeout | [09:02] Marcos; [09:42] Diego | ADR-002 |
| A secret precisa ficar recuperável em claro para recomputar o HMAC | [09:21] Bruno; [09:22] Diego | **Q6** |

---

## 7. Decisões relacionadas

Cada pilar da seção 3.2 tem a sua ADR. As sete, todas com status **Aceita** — a
[ADR-004](./adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md) sujeita à revisão de
segurança ([09:46]):

[ADR-001 Outbox no MySQL](./adrs/ADR-001-outbox-no-mysql.md) ·
[ADR-002 Worker separado com polling](./adrs/ADR-002-worker-em-processo-separado-com-polling.md) ·
[ADR-003 Retry com backoff e DLQ](./adrs/ADR-003-retry-com-backoff-exponencial-e-dlq.md) ·
[ADR-004 HMAC-SHA256 por endpoint](./adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md) ·
[ADR-005 At-least-once com `X-Event-Id`](./adrs/ADR-005-entrega-at-least-once-com-x-event-id.md) ·
[ADR-006 Reuso dos padrões do projeto](./adrs/ADR-006-reuso-dos-padroes-existentes-do-projeto.md) ·
[ADR-007 Snapshot do payload](./adrs/ADR-007-snapshot-do-payload-na-insercao-da-outbox.md)

---

## 8. O que se espera desta revisão

- **Bruno e Diego** — validar o gancho transacional em `changeStatus` e a granularidade da linha da
  outbox (um evento por endpoint assinante), na sessão a marcar ([09:50]).
- **Sofia** — decidir **Q6**, confirmar **Q7**, avaliar **Q8**, nos 2 dias reservados ([09:46]).
- **Marcos** — confirmar o escopo contra o prazo com a Atlas ([09:45]) e assumir a documentação da
  garantia at-least-once no portal ([09:26]).
- **Todos** — apontar o que não corresponda ao decidido. Rastreabilidade em
  [`docs/TRACKER.md`](./TRACKER.md).
