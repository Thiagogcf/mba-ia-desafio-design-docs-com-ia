# FDD — Sistema de Webhooks de Notificação de Pedidos

> **Documento de desenho de implementação.** Responde *como construir, em detalhe*. A justificativa
> de produto está em [`docs/PRD.md`](./PRD.md); a proposta em nível de arquitetura e as questões em
> aberto estão em [`docs/RFC.md`](./RFC.md); cada decisão isolada está em [`docs/adrs/`](./adrs/).
> A rastreabilidade item a item está em [`docs/TRACKER.md`](./TRACKER.md).

| Campo | Valor |
| --- | --- |
| **Feature** | Sistema de Webhooks de Notificação de Pedidos |
| **Status** | Pronto para revisão técnica ([09:50] Larissa) |
| **Data** | 2026-08-26 |
| **Autores** | Bruno (Eng. Pleno — Pedidos) e Diego (Eng. Sênior — Plataforma), a partir das decisões da reunião; redação por Thiago Ferronato |
| **Base** | [`TRANSCRICAO.md`](../TRANSCRICAO.md) + código do OMS neste repositório |

---

## Sumário

1. [Contexto e motivação técnica](#1-contexto-e-motivação-técnica)
2. [Objetivos técnicos](#2-objetivos-técnicos)
3. [Escopo e exclusões](#3-escopo-e-exclusões)
4. [Modelo de dados](#4-modelo-de-dados)
5. [Fluxos detalhados](#5-fluxos-detalhados)
6. [Contratos públicos](#6-contratos-públicos)
7. [Matriz de erros](#7-matriz-de-erros)
8. [Estratégias de resiliência](#8-estratégias-de-resiliência)
9. [Observabilidade](#9-observabilidade)
10. [Integração com o sistema existente](#10-integração-com-o-sistema-existente)
11. [Dependências e compatibilidade](#11-dependências-e-compatibilidade)
12. [Critérios de aceite técnicos](#12-critérios-de-aceite-técnicos)
13. [Riscos técnicos e mitigação](#13-riscos-técnicos-e-mitigação)

---

## 1. Contexto e motivação técnica

O OMS não possui hoje **nenhum** mecanismo de notificação externa, evento, fila ou webhook. O ciclo
de vida do pedido é fechado dentro da aplicação: a máquina de estados em
`src/modules/orders/order.status.ts` restringe as transições, e `OrderService.changeStatus`
(`src/modules/orders/order.service.ts:126`) aplica a mudança dentro de um `prisma.$transaction` que
também movimenta estoque e grava auditoria em `order_status_history`.

Três clientes B2B precisam ser notificados dessas transições em menos de 10 segundos ([09:02]
Marcos). Tecnicamente, isso exige resolver quatro problemas que hoje não existem no sistema:

1. **Emitir um efeito externo a partir de uma transação de banco** sem introduzir *dual-write* — se o
   status commitou, o evento existe; se deu rollback, o evento não existe ([09:06] Diego).
2. **Não acoplar a disponibilidade do fluxo de pedidos à disponibilidade de terceiros.** Uma chamada
   HTTP dentro do `$transaction` faria um cliente lento travar mudança de status de outros pedidos
   ([09:04] Bruno).
3. **Tolerar falha prolongada do destino**, com política de retry que cubra indisponibilidade real —
   já houve cliente com duas horas de manutenção planejada ([09:16] Diego).
4. **Provar autenticidade e integridade** de um payload que trafega para fora da nossa
   infraestrutura ([09:19] Sofia).

A resposta arquitetural para os quatro pontos está no [RFC](./RFC.md) e nos
[ADRs](./adrs/). Este documento especifica a implementação.

---

## 2. Objetivos técnicos

| # | Objetivo | Critério verificável | Origem |
| --- | --- | --- | --- |
| OT-1 | Publicar o evento na mesma transação da mudança de status | Falha no `INSERT` da outbox aborta `changeStatus`; nenhum commit de `orders` sem linha correspondente na `webhook_outbox` para endpoints assinantes | [09:06], [09:40], [09:41] |
| OT-2 | Entregar em menos de 10 s no caminho feliz | p95 de `webhook_outbox_lag_seconds` + duração da entrega < 10 s | [09:02] Marcos |
| OT-3 | Isolar o ciclo de vida da entrega do ciclo de vida da API | Worker é processo próprio (`npm run worker`); restart da API não interrompe entrega | [09:11] Diego, [09:11] Larissa |
| OT-4 | Não perder evento por falha transitória do destino | 5 retentativas em escada, cobrindo ~14h36min; esgotada a escada, o evento é persistido na DLQ | [09:15]–[09:18] |
| OT-5 | Assinar todo envio de forma verificável pelo cliente | Todo request outbound carrega `X-Signature` com HMAC-SHA256 do corpo, computado com a secret daquele endpoint | [09:20], [09:22] Sofia |
| OT-6 | Não introduzir infraestrutura nem dependência nova | `package.json` sem dependências novas; nenhum serviço além do MySQL já existente | [09:07] Diego, [09:29] Bruno |
| OT-7 | Aderir integralmente aos padrões do codebase | Módulo espelha `src/modules/orders/`; erros herdam de `AppError`; error middleware não é alterado | [09:27]–[09:30] |

---

## 3. Escopo e exclusões

### 3.1 Dentro do escopo

- Tabelas de configuração de webhook, outbox, histórico de entregas e dead letter.
- Módulo `src/modules/webhooks/` com CRUD de configuração, rotação de secret e consulta de entregas.
- Entrypoint `src/worker.ts` e processador de outbox.
- Assinatura HMAC-SHA256, com rotação e grace period de 24 h.
- Endpoint administrativo de replay de dead letter, restrito a `ADMIN`.
- Gancho transacional em `OrderService.changeStatus`.

### 3.2 Fora do escopo (com origem explícita)

| Item excluído | Natureza | Origem |
| --- | --- | --- |
| Webhooks **inbound** (cliente → nós) | Nunca esteve no escopo | [09:02] Marcos: "Só saindo da gente pra eles" |
| **Alerta por e-mail** ao cliente após falhas seguidas | Adiado para próxima fase | [09:37] Larissa: "Email tá fora de escopo dessa fase" |
| **Dashboard/painel visual** para o cliente | Projeto separado do time de frontend | [09:40] Larissa: "Não, agora não. Só endpoints" |
| **Rate limiting de saída** por cliente | Observar e decidir depois | [09:39] Diego e Larissa |
| **Arquivamento** de linhas entregues (~30 dias) | Declarado fora do escopo da feature | [09:08] Diego |
| **Múltiplos workers em paralelo** / ordenação global | Problema do futuro | [09:13] Diego; [09:13] Larissa registra como limitação conhecida |
| **Garantia exactly-once** | Descartada | [09:25] Diego |
| Endurecimento de papéis no CRUD de webhook | Adiado | [09:37] Sofia: "Por enquanto sim. Mais pra frente a gente pode endurecer" |

---

## 4. Modelo de dados

Quatro modelos novos em `prisma/schema.prisma`, seguindo as convenções existentes: id `UUID` em
`@db.Char(36)` ([09:51] Larissa), nome de tabela em `snake_case` via `@@map`, `createdAt`/`updatedAt`
padrão.

```prisma
enum WebhookOutboxStatus {
  PENDING        // pendente
  PROCESSING     // processando
  FAILED         // falhou, aguardando a próxima tentativa
  DELIVERED      // entregue
  DEAD_LETTERED  // retentativas esgotadas — estado terminal, ver nota de modelagem
}

enum WebhookDeliveryOutcome {
  SUCCESS
  FAILURE
}

model WebhookEndpoint {
  id                      String    @id @default(uuid()) @db.Char(36)
  customerId              String    @db.Char(36)
  url                     String    @db.VarChar(500)
  secret                  String    @db.VarChar(128)
  previousSecret          String?   @db.VarChar(128)
  previousSecretExpiresAt DateTime?
  secretRotatedAt         DateTime?   // proposta: quando a última rotação ocorreu
  subscribedStatuses      Json      // OrderStatus[]  — filtro de eventos do endpoint
  active                  Boolean   @default(true)
  createdAt               DateTime  @default(now())
  updatedAt               DateTime  @updatedAt

  customer     Customer        @relation(fields: [customerId], references: [id])
  outboxEvents WebhookOutbox[]

  @@index([customerId])
  @@index([customerId, active])
  @@map("webhook_endpoints")
}

model WebhookOutbox {
  id                String              @id @default(uuid()) @db.Char(36)
  webhookEndpointId String              @db.Char(36)
  orderId           String              @db.Char(36)
  eventType         String              @db.VarChar(64)   // "order.status_changed"
  payload           Json                                  // snapshot renderizado na inserção
  status            WebhookOutboxStatus @default(PENDING)
  attempts          Int                 @default(0)
  nextAttemptAt     DateTime            @default(now())
  lastError         String?             @db.VarChar(500)
  requestId         String?             @db.Char(36)      // correlação com o request que originou
  createdAt         DateTime            @default(now())
  updatedAt         DateTime            @updatedAt

  endpoint   WebhookEndpoint   @relation(fields: [webhookEndpointId], references: [id])
  deliveries WebhookDelivery[]

  @@index([status, nextAttemptAt])
  @@index([createdAt])
  @@index([orderId])
  @@map("webhook_outbox")
}

model WebhookDelivery {
  id                String                 @id @default(uuid()) @db.Char(36)
  outboxEventId     String                 @db.Char(36)
  webhookEndpointId String                 @db.Char(36)
  attempt           Int
  outcome           WebhookDeliveryOutcome
  httpStatus        Int?
  responseBody      String?                @db.Text       // truncado em 2 KB
  durationMs        Int
  errorMessage      String?                @db.VarChar(500)
  createdAt         DateTime               @default(now())

  outboxEvent WebhookOutbox @relation(fields: [outboxEventId], references: [id])

  @@index([webhookEndpointId, createdAt])
  @@index([outboxEventId])
  @@map("webhook_deliveries")
}

model WebhookDeadLetter {
  id                String    @id @default(uuid()) @db.Char(36)
  outboxEventId     String    @db.Char(36)
  webhookEndpointId String    @db.Char(36)
  eventType         String    @db.VarChar(64)
  payload           Json
  failureReason     String    @db.VarChar(500)
  attempts          Int
  failedAt          DateTime  @default(now())
  replayedAt        DateTime?
  replayedById      String?   @db.Char(36)   // usuário ADMIN que executou o replay

  @@index([webhookEndpointId])
  @@index([failedAt])
  @@map("webhook_dead_letter")
}
```

### Notas de modelagem

- **Granularidade da outbox: uma linha por (evento × endpoint assinante).** Retry, DLQ e histórico
  são estado **por endpoint** — um cliente pode ter dois webhooks, um saudável e outro fora do ar.
  Uma linha por evento com fan-out no envio não teria onde guardar `attempts` e `nextAttemptAt` de
  cada destino. O `X-Webhook-Id` pedido por Sofia ([09:44]) confirma que o envio é identificado por
  cadastro.
- **Estado terminal separado.** `DEAD_LETTERED` existe para que a linha morta saia da query de
  trabalho sem exigir uma coluna `nextAttemptAt` nulável. Sem ele, `FAILED` teria dois significados
  ("aguardando retry" e "morto") e a linha dead-lettered voltaria a casar com a query do worker a
  cada ciclo. *(Regra derivada: a reunião decidiu a DLQ em tabela separada ([09:18] Diego), mas não
  tratou o estado residual da linha de origem.)*
- **Relações declaradas nos dois lados.** O Prisma exige o campo inverso, então `WebhookEndpoint`
  declara `outboxEvents WebhookOutbox[]` e `WebhookOutbox` declara `deliveries WebhookDelivery[]`,
  seguindo o padrão de `Order.items` ↔ `OrderItem.order` em `prisma/schema.prisma`. O inverso em
  `Customer` (`webhookEndpoints WebhookEndpoint[]`) está em 10.8, junto das demais alterações no
  schema existente. **Duas colunas ficam deliberadamente escalares, sem relação:**
  `WebhookDelivery.webhookEndpointId` — indexada e usada para consultar o histórico em 6.6, mas sem
  relação porque o caminho canônico até o endpoint já existe via `outboxEvent` — e o
  `WebhookDeadLetter` inteiro, que guarda `outboxEventId` e `webhookEndpointId` como colunas soltas
  justamente para sobreviver como evidência independente do ciclo de vida da outbox.
- **Índices.** Diego especificou índice no campo de status e em `created_at` ([09:08]). O índice do
  caminho quente é composto — `(status, nextAttemptAt)` — porque a query do worker precisa filtrar
  também eventos em espera de retry ([09:17] Diego); `createdAt` fica indexado isoladamente para
  ordenação e para a varredura de arquivamento futura (Q4 do [RFC](./RFC.md#5-questões-em-aberto)).
- **`secretRotatedAt` é proposta desta especificação** ⇢ *derivado*. A reunião definiu a rotação com
  grace de 24 h ([09:21] Sofia), sem falar em registrar quando ela ocorreu. A coluna existe porque
  `previousSecretExpiresAt` deixa de ser informativo assim que a janela fecha, e o cliente precisa
  conseguir ver quando rotacionou pela última vez. É devolvida em 6.1, 6.2, 6.3 e 6.5.
- **UUID como padrão de identificador.** Larissa fechou "UUID, segue o padrão do resto do projeto"
  ([09:51]). No schema atual, todos os modelos de domínio — `User`, `Customer`, `Product`, `Order`,
  `OrderItem`, `OrderStatusHistory` — usam `@id @default(uuid()) @db.Char(36)`. A única exceção é
  `OrderNumberSequence`, cujo `id` é `Int @default(1)` porque é uma tabela de linha única para
  sequência, não uma entidade. Os quatro modelos novos seguem o padrão das entidades.
- **`secret` não é hasheada.** Diferente de `users.passwordHash` (`prisma/schema.prisma`), a secret
  precisa ser recuperável para recomputar o HMAC a cada entrega. Se ficará em claro ou cifrada em
  repouso é **questão em aberto Q6** do [RFC](./RFC.md#5-questões-em-aberto), endereçada à revisão de
  segurança ([09:46] Sofia).
- **`subscribedStatuses` como `Json`.** Segue o precedente de `Customer.address`, que já é `Json` no
  schema atual. Os valores válidos são os do enum `OrderStatus`, validados por Zod na borda.
- **`webhook_dead_letter` duplica o payload** de propósito: Diego pediu payload, motivo da falha e
  timestamp na tabela separada, como evidência para debug e reprocessamento ([09:18]).

---

## 5. Fluxos detalhados

### 5.1 Criação do evento na outbox (dentro da transação de `changeStatus`)

Ponto de integração: `OrderService.changeStatus`, em
`src/modules/orders/order.service.ts:126`. Hoje a transação já faz, nesta ordem: busca o pedido,
valida a transição por `canTransition`, debita ou repõe estoque, `tx.order.update` e
`tx.orderStatusHistory.create`. A publicação entra **depois da gravação do histórico e antes da
releitura final**, ainda dentro do mesmo `tx`.

```
changeStatus(id, input, userId)
│
└─ prisma.$transaction(async (tx) => {
     1. tx.order.findUnique(...)                         [ existente ]
     2. canTransition(from, to) ?                        [ existente ]
     3. debitStock / replenishStock                      [ existente ]
     4. tx.order.update({ status: to })                  [ existente ]
     5. tx.orderStatusHistory.create({...})              [ existente ]
     6. await publishWebhookEvent(tx, order, from, to)   [ NOVO ]
     7. tx.order.findUnique(... include ...)             [ existente ]
   })
```

`publishWebhookEvent` é uma **função pura que recebe o transaction client**, e não um repositório
injetado no `OrderService` — desenho proposto por Bruno ([09:41]) e aprovado por Diego na hora
("função pura recebendo o tx. Não precisa injetar repository inteiro", [09:41]).

**Algoritmo:**

```
publishWebhookEvent(tx, order, fromStatus, toStatus, requestId?):
  1. endpoints ← tx.webhookEndpoint.findMany({
                    where: { customerId: order.customerId, active: true } })
  2. assinantes ← endpoints.filter(e => e.subscribedStatuses.includes(toStatus))
  3. se assinantes.length === 0 → return          // não insere nada  [09:34] Bruno
  4. para cada assinante:
       a. eventId ← uuidv4()                     // um id por LINHA da outbox  [09:25] Diego
       b. payload ← renderEventPayload(eventId, order, fromStatus, toStatus)   // snapshot [09:52]
       c. bytes ← Buffer.byteLength(JSON.stringify(payload))
          se bytes > 65536 → throw WebhookPayloadTooLargeError                 // 64 KB [09:24]
       d. tx.webhookOutbox.create({
            id: eventId,                          // event_id === webhook_outbox.id
            webhookEndpointId, orderId, eventType: 'order.status_changed',
            payload, status: PENDING, attempts: 0, nextAttemptAt: now(), requestId })
```

**Pontos críticos deste fluxo:**

- **Filtragem na inserção, não no envio.** Se nenhum webhook ativo do customer assina aquele status,
  a linha nem é criada — "economiza linha na tabela" ([09:34] Bruno; concordado por Diego). O efeito
  colateral é que **não existe backfill**: um webhook criado depois não recebe eventos passados.
- **O `event_id` nasce por linha da outbox, dentro do laço — não antes dele.** Diego definiu o
  identificador como "um UUID gerado quando o evento entra na outbox... único por evento"
  ([09:25]), e cada linha é uma entrada na outbox. Gerar o id **fora** do laço faria dois endpoints
  do mesmo customer receberem o **mesmo** `X-Event-Id`: o cliente que deduplica por esse header —
  exatamente o que [ADR-005](./adrs/ADR-005-entrega-at-least-once-com-x-event-id.md) exige dele —
  descartaria a segunda entrega como duplicata, e o evento se perderia em silêncio. Com o id por
  linha, `event_id === webhook_outbox.id`, e o `X-Webhook-Id` pedido por Sofia ([09:44]) diz a qual
  cadastro cada entrega pertence. É por isso que o payload é renderizado **dentro** do laço: ele
  carrega o `event_id`.
- **Qualquer exceção aqui aborta a mudança de status.** É o requisito explícito: "se a outbox falhar
  de inserir, rollback. Não pode ter caso de status mudar e evento não sair" ([09:40] Bruno;
  "essencial", [09:41] Diego).
- **O limite de 64 KB é avaliado dentro da transação** ⇢ *derivado*. A reunião decidiu que um evento
  acima do teto produz **erro em vez de truncamento** ([09:23] Sofia; [09:24] Diego e Larissa), mas
  falou em não **enviar** — ninguém disse que a mudança de status deveria falhar. Como o payload é
  materializado na inserção ([ADR-007](./adrs/ADR-007-snapshot-do-payload-na-insercao-da-outbox.md))
  dentro da transação ([ADR-001](./adrs/ADR-001-outbox-no-mysql.md)), avaliar o tamanho ali é a
  consequência direta — e faz o erro se propagar para `PATCH /orders/:id/status`. **É a derivação de
  maior impacto do pacote e está na pauta da revisão técnica** ([09:50] Larissa). A alternativa que
  preserva a letra da decisão é validar o tamanho no worker e mandar o evento direto para a DLQ, sem
  tocar no fluxo de pedidos. Na prática o payload é enxuto por decisão ([09:43] Diego) e nenhum
  evento chega perto do teto ([09:24] Diego).
- **`orders` sem webhook cadastrado seguem funcionando sem qualquer alteração de comportamento** —
  passo 3 retorna cedo.

### 5.2 Processamento pelo worker

`src/worker.ts` é um entrypoint no molde de `src/server.ts`: instancia o próprio `PrismaClient` via
`createPrismaClient()` ([09:30] Bruno), registra `SIGINT`/`SIGTERM` para shutdown gracioso e entra em
loop.

```
loop a cada 2 000 ms:                                   [09:09] Diego
  1. lote ← webhookOutbox.findMany({
              where: { status: { in: [PENDING, FAILED] },      // DEAD_LETTERED e DELIVERED ficam de fora
                       nextAttemptAt: { lte: now() } },
              orderBy: { createdAt: 'asc' },
              take: WEBHOOK_WORKER_BATCH_SIZE })        // batch pequeno  [09:08] Diego
  2. para cada evento do lote, sequencialmente:
     a. marca status = PROCESSING
     b. endpoint ← carrega cadastro (url, secret, previousSecret, previousSecretExpiresAt)
     c. corpo ← JSON.stringify(evento.payload)          // snapshot, sem reconsultar orders
     d. headers ← buildHeaders(evento, endpoint, corpo)  // ver 6.8
     e. resposta ← fetch(endpoint.url, { method: 'POST', headers, body: corpo,
                                          signal: AbortSignal.timeout(10_000) })   [09:42]
     f. registra WebhookDelivery com `attempt = evento.attempts + 1` (número do **envio**, começando
        em 1), outcome, httpStatus, durationMs e responseBody truncado
     g. 2xx  → status = DELIVERED
        senão → aplica política de retry (5.3)
```

**Ordenação.** O `orderBy: createdAt asc` combinado com processamento **sequencial** dentro do lote e
**instância única** entrega os eventos de um mesmo pedido na ordem em que aconteceram ([09:12]
Diego). Não há garantia de ordenação global, e isso é limitação conhecida e documentada ([09:13]
Larissa) — os clientes nunca pediram ordenação global ([09:14] Marcos).

**Reivindicação de eventos travados.** Se o processo morrer entre (a) e (g), a linha fica em
`PROCESSING` para sempre. O worker, ao iniciar cada ciclo, devolve para `PENDING` toda linha em
`PROCESSING` cujo `updatedAt` seja mais antigo que **60 s** — seis vezes o timeout de 10 s ([09:42]
Diego), margem suficiente para não competir com um envio em andamento. *(Regra derivada: a reunião
não tratou o caso de crash em meio ao envio; ela é necessária para que a promessa de "restart drena o
acumulado" se sustente.)*

### 5.3 Retry com backoff exponencial

Falha é: resposta **não-2xx**, **timeout de 10 s** ([09:42] Diego) ou erro de conexão/DNS.

```
onFailure(evento, motivo):
  evento.attempts += 1
  se evento.attempts > WEBHOOK_MAX_RETRIES (5):
      → move para dead letter (5.4)
  senão:
      evento.status        = FAILED
      evento.lastError     = motivo (truncado em 500 chars)
      evento.nextAttemptAt = now() + BACKOFF[evento.attempts - 1]

BACKOFF = [ 1min, 5min, 30min, 2h, 12h ]                 [09:17] Diego
```

**Escada completa, do primeiro envio à última tentativa:**

| Tentativa | Quando | Intervalo desde a anterior | Acumulado desde a 1ª falha |
| --- | --- | --- | --- |
| 1 — envio inicial | até ~2 s após o commit | — | — |
| 2 — 1ª retentativa | +1 min | 1 min | 1 min |
| 3 — 2ª retentativa | +5 min | 5 min | 6 min |
| 4 — 3ª retentativa | +30 min | 30 min | 36 min |
| 5 — 4ª retentativa | +2 h | 2 h | 2 h 36 min |
| 6 — 5ª retentativa | +12 h | 12 h | **14 h 36 min** |
| → dead letter | após falhar a 5ª retentativa | — | — |

> **Nota de interpretação — "5 tentativas".** No resumo final Larissa fala em "total 5 tentativas"
> ([09:48]), mas a escada proposta por Diego tem cinco intervalos e ele mesmo quantificou o
> resultado: "total de quase 15 horas entre primeira falha e última tentativa" ([09:17]). Os
> ~14h36min da tabela acima só fecham se as cinco tentativas forem as cinco **retentativas** — 6
> envios no total. A leitura alternativa (5 envios, 4 intervalos) encerraria em 2h36min e
> contradiria tanto os "quase 15 horas" quanto a justificativa de cobrir a manutenção planejada de
> duas horas ([09:16] Diego) e a "janela de até 12 ou 24 horas" ([09:15] Diego). Adotamos a leitura
> aritmeticamente consistente; a constante é `WEBHOOK_MAX_RETRIES = 5`. **Ponto a confirmar na
> revisão técnica** ([09:50] Larissa).

### 5.4 Dead letter e replay

```
moveToDeadLetter(evento, motivo):
  transação:
    webhookDeadLetter.create({ outboxEventId, webhookEndpointId, eventType,
                               payload, failureReason: motivo, attempts })
    webhookOutbox.update({ status: DEAD_LETTERED, lastError: motivo })
```

A linha da outbox transita para o **estado terminal `DEAD_LETTERED`**, que **não** está no
`status: { in: [PENDING, FAILED] }` da query do worker (5.2) — portanto ela nunca mais é selecionada,
sem depender de anular `nextAttemptAt` (a coluna é obrigatória, ver seção 4). A DLQ é o registro
consultável, "evidence pra debug e reprocessamento" ([09:18] Diego).

> **Por que a linha continua existindo na outbox.**
> [ADR-003](./adrs/ADR-003-retry-com-backoff-exponencial-e-dlq.md) escolheu a tabela separada
> porque, nas palavras de Diego, ela é "mais limpa a leitura da outbox principal, e fica como
> evidence pra debug e reprocessamento" ([09:18]). O estado terminal preserva esse benefício onde
> ele importa: `DEAD_LETTERED` fica fora da query de trabalho do worker, então a leitura quente
> continua limpa. A linha permanece como **tombstone** — não é apagada — para manter a integridade
> referencial do histórico de entregas (`webhook_deliveries.outboxEventId`) e permitir que o replay
> reative o mesmo `event_id`. O custo, payload duplicado entre outbox e DLQ, já está registrado como
> consequência negativa na própria ADR-003. *(Que a linha vire tombstone em vez de ser apagada é
> ⇢ derivado: a reunião decidiu a tabela separada, não o destino da linha de origem.)*

**Replay** (`POST /api/v1/admin/webhooks/dead-letter/:id/replay`, contrato em 6.7):

```
replay(deadLetterId, adminUserId):
  1. item ← webhookDeadLetter.findUnique(deadLetterId)
     se ausente → WEBHOOK_DEAD_LETTER_NOT_FOUND
     se item.replayedAt != null → WEBHOOK_ALREADY_REPLAYED
  2. transação:
     a. webhookOutbox.update({ where: { id: item.outboxEventId },
                               data: { status: PENDING, attempts: 0,
                                       nextAttemptAt: now(), lastError: null } })
     b. webhookDeadLetter.update({ replayedAt: now(), replayedById: adminUserId })
  3. logger.info({ deadLetterId, outboxEventId, replayedBy: adminUserId }, 'webhook_dlq_replayed')
```

- **Recoloca na outbox como pendente**, exatamente como especificado ([09:18] Diego).
- **`replayedById` + log de auditoria** atendem ao requisito de Sofia: "o endpoint de admin tem que
  logar quem fez o replay, pra auditoria" ([09:36]).
- **O `event_id` é preservado** — o replay reenvia o mesmo `X-Event-Id`, o que permite ao cliente
  deduplicar caso o evento já tenha sido processado do lado dele
  ([ADR-005](./adrs/ADR-005-entrega-at-least-once-com-x-event-id.md)).

### 5.5 Rotação de secret

```
rotate(webhookId):
  0. se endpoint.active === false → WEBHOOK_INACTIVE
  1. se endpoint.previousSecretExpiresAt > now() → WEBHOOK_ROTATION_IN_PROGRESS   (ver Q8 do RFC)
  2. novaSecret ← 'whsec_' + randomBytes(32).toString('base64url')     // formato: proposta, ver nota
  3. update: { previousSecret: secretAtual,
               previousSecretExpiresAt: now() + 24h,                              [09:21] Sofia
               secret: novaSecret,
               secretRotatedAt: now() }
  4. devolve a nova secret ao cliente (única exibição)
```

**O formato da secret** (`whsec_` + 32 bytes aleatórios em base64url) **é proposta desta
especificação**, não decisão da reunião: ficou definido apenas que a secret é gerada por nós
([09:31] Marcos) e que é única por endpoint ([09:21] Sofia). Comprimento e prefixo entram na revisão
de segurança ([09:46] Sofia).

Durante a janela de 24 h, todo envio carrega **duas assinaturas** — ver 6.8 e a nota de
interpretação em [ADR-004](./adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md).
Encerrada a janela, `previousSecret` é ignorada e limpa na primeira leitura posterior: "depois disso,
a antiga morre" ([09:21] Sofia).

---

## 6. Contratos públicos

**Convenções herdadas do código existente** (`src/app.ts`, `src/middlewares/error.middleware.ts`,
`src/shared/http/response.ts`):

- Todas as rotas ficam sob o prefixo **`/api/v1`**, montado em `src/app.ts` (`app.use('/api/v1', buildApiRouter(controllers))`).
- Autenticação por **JWT Bearer** via `authenticate` (`src/middlewares/auth.middleware.ts`).
- Erros seguem o envelope `{ "error": { "code", "message", "details"? } }`.
- Listagens seguem o envelope `{ "data": [...], "pagination": { page, pageSize, total, totalPages } }`.
- Corpo da requisição em **camelCase**, como nos demais módulos.

> **Nota de compatibilidade de caminhos.** A reunião registrou os caminhos sem prefixo —
> `POST /admin/webhooks/dead-letter/:id/replay` ([09:18] e [09:35] Diego) e
> `GET /webhooks/:id/deliveries` ([09:34] Marcos). Como `src/app.ts` monta todo o router sob
> `/api/v1`, os caminhos reais recebem esse prefixo. A estrutura de caminho decidida na reunião é
> preservada integralmente.

### 6.1 `POST /api/v1/webhooks` — cadastrar webhook

Autenticado, qualquer papel ([09:37] Sofia). O `customerId` vai **no body**, não vem do JWT — o JWT
atual representa o usuário operador do nosso sistema, não o cliente ([09:32] Bruno levanta, [09:32]
Marcos confirma o modelo, [09:32] Larissa decide).

**Request**

```http
POST /api/v1/webhooks
Authorization: Bearer <jwt>
Content-Type: application/json
```
```json
{
  "customerId": "9c0f4b8e-4a4a-4a0e-9d1f-2b7f5c9a1d33",
  "url": "https://hooks.atlascomercial.com.br/oms/orders",
  "subscribedStatuses": ["SHIPPED", "DELIVERED"],
  "active": true
}
```

**Response `201 Created`** — a `secret` é gerada por nós e devolvida **apenas nesta resposta**
([09:31] Marcos).

```json
{
  "id": "1f2e3d4c-5b6a-4789-8c0d-1e2f3a4b5c6d",
  "customerId": "9c0f4b8e-4a4a-4a0e-9d1f-2b7f5c9a1d33",
  "url": "https://hooks.atlascomercial.com.br/oms/orders",
  "subscribedStatuses": ["SHIPPED", "DELIVERED"],
  "active": true,
  "secret": "whsec_9tK2Yb7Qm1xV0pL4sR8wZaC3nE6hJ5uD",
  "secretRotatedAt": null,
  "createdAt": "2026-08-26T13:04:11.482Z",
  "updatedAt": "2026-08-26T13:04:11.482Z"
}
```

| Status | Situação |
| --- | --- |
| `201` | Webhook criado |
| `400` | `VALIDATION_ERROR` (corpo inválido) · `WEBHOOK_INVALID_URL` (URL não `https` ou malformada) · `WEBHOOK_INVALID_EVENT_FILTER` (status fora do enum `OrderStatus`) |
| `401` | `UNAUTHORIZED` — token ausente, inválido ou expirado |
| `404` | `NOT_FOUND` — `customerId` inexistente |

### 6.2 `GET /api/v1/webhooks` — listar webhooks de um customer

**Request**

```http
GET /api/v1/webhooks?customerId=9c0f4b8e-4a4a-4a0e-9d1f-2b7f5c9a1d33&page=1&pageSize=20
Authorization: Bearer <jwt>
```

**Response `200 OK`** — a `secret` **nunca** é retornada em listagem ou leitura; só na criação e na
rotação.

```json
{
  "data": [
    {
      "id": "1f2e3d4c-5b6a-4789-8c0d-1e2f3a4b5c6d",
      "customerId": "9c0f4b8e-4a4a-4a0e-9d1f-2b7f5c9a1d33",
      "url": "https://hooks.atlascomercial.com.br/oms/orders",
      "subscribedStatuses": ["SHIPPED", "DELIVERED"],
      "active": true,
      "secretRotatedAt": null,
      "createdAt": "2026-08-26T13:04:11.482Z",
      "updatedAt": "2026-08-26T13:04:11.482Z"
    }
  ],
  "pagination": { "page": 1, "pageSize": 20, "total": 1, "totalPages": 1 }
}
```

| Status | Situação |
| --- | --- |
| `200` | Lista paginada (envelope de `src/shared/http/response.ts`) |
| `400` | `VALIDATION_ERROR` — `customerId` ausente ou não-UUID, `pageSize` fora de 1..100 |
| `401` | `UNAUTHORIZED` |

### 6.3 `PATCH /api/v1/webhooks/:id` — editar webhook

Campos editáveis: `url`, `subscribedStatuses`, `active` ([09:33] Bruno). A `secret` **não** é
editável por aqui — só por rotação (6.5).

**Request**

```http
PATCH /api/v1/webhooks/1f2e3d4c-5b6a-4789-8c0d-1e2f3a4b5c6d
Authorization: Bearer <jwt>
Content-Type: application/json
```
```json
{
  "subscribedStatuses": ["PAID", "PROCESSING", "SHIPPED", "DELIVERED"],
  "active": true
}
```

**Response `200 OK`**

```json
{
  "id": "1f2e3d4c-5b6a-4789-8c0d-1e2f3a4b5c6d",
  "customerId": "9c0f4b8e-4a4a-4a0e-9d1f-2b7f5c9a1d33",
  "url": "https://hooks.atlascomercial.com.br/oms/orders",
  "subscribedStatuses": ["PAID", "PROCESSING", "SHIPPED", "DELIVERED"],
  "active": true,
  "secretRotatedAt": null,
  "createdAt": "2026-08-26T13:04:11.482Z",
  "updatedAt": "2026-08-26T15:22:07.109Z"
}
```

| Status | Situação |
| --- | --- |
| `200` | Webhook atualizado |
| `400` | `VALIDATION_ERROR` · `WEBHOOK_INVALID_URL` · `WEBHOOK_INVALID_EVENT_FILTER` |
| `401` | `UNAUTHORIZED` |
| `404` | `WEBHOOK_NOT_FOUND` |

**Semântica:** a alteração de `subscribedStatuses` vale **daqui para frente**. Eventos passados não
são materializados retroativamente, porque a filtragem acontece na inserção ([09:34] Bruno).

### 6.4 `DELETE /api/v1/webhooks/:id` — remover webhook

**Request**

```http
DELETE /api/v1/webhooks/1f2e3d4c-5b6a-4789-8c0d-1e2f3a4b5c6d
Authorization: Bearer <jwt>
```

**Response `204 No Content`** — sem corpo, como nos demais módulos
(`src/modules/orders/order.controller.ts`).

| Status | Situação |
| --- | --- |
| `204` | Webhook removido |
| `401` | `UNAUTHORIZED` |
| `404` | `WEBHOOK_NOT_FOUND` |

**Semântica:** eventos já materializados na outbox para este endpoint **continuam sendo entregues**
até serem concluídos ou irem para a DLQ — a remoção afeta apenas a materialização de eventos
futuros. Para interromper entregas em andamento, o caminho é `PATCH` com `"active": false`.

### 6.5 `POST /api/v1/webhooks/:id/secret/rotate` — rotacionar secret

Endpoint pedido por Sofia: "a secret tem que ser rotacionável. Endpoint pro cliente conseguir pedir
nova secret pela API" ([09:21]).

**Request**

```http
POST /api/v1/webhooks/1f2e3d4c-5b6a-4789-8c0d-1e2f3a4b5c6d/secret/rotate
Authorization: Bearer <jwt>
```

**Response `200 OK`**

```json
{
  "id": "1f2e3d4c-5b6a-4789-8c0d-1e2f3a4b5c6d",
  "secret": "whsec_Lp8Zq3Vt6Nn0Ry5Xw2Kb9Hj4Mc7Fd1S",
  "previousSecretExpiresAt": "2026-08-27T15:40:00.000Z",
  "secretRotatedAt": "2026-08-26T15:40:00.000Z"
}
```

| Status | Situação |
| --- | --- |
| `200` | Secret rotacionada; a anterior permanece aceita até `previousSecretExpiresAt` |
| `401` | `UNAUTHORIZED` |
| `404` | `WEBHOOK_NOT_FOUND` |
| `409` | `WEBHOOK_INACTIVE` — rotação sobre endpoint desativado |
| `409` | `WEBHOOK_ROTATION_IN_PROGRESS` — já existe janela de grace aberta (**proposta**, pendente da questão Q8 do [RFC](./RFC.md#5-questões-em-aberto)) |

**Semântica:** durante as 24 h seguintes, todo envio para este endpoint carrega **duas assinaturas**
(nova e anterior), para que o cliente possa migrar sem downtime ([09:21] Sofia). Ver 6.8.

### 6.6 `GET /api/v1/webhooks/:id/deliveries` — histórico de entregas

Pedido por Marcos: "esses são os últimos 100 webhooks que vocês mandaram pra mim, sucesso/falha,
payload, response, tempo de resposta" ([09:34]).

**Request**

```http
GET /api/v1/webhooks/1f2e3d4c-5b6a-4789-8c0d-1e2f3a4b5c6d/deliveries?page=1&pageSize=100
Authorization: Bearer <jwt>
```

**Response `200 OK`**

```json
{
  "data": [
    {
      "id": "aa11bb22-cc33-4d44-9e55-6f7788990011",
      "eventId": "7c9d1e2f-3a4b-4c5d-8e9f-0a1b2c3d4e5f",
      "attempt": 2,
      "outcome": "SUCCESS",
      "httpStatus": 200,
      "durationMs": 412,
      "payload": {
        "event_id": "7c9d1e2f-3a4b-4c5d-8e9f-0a1b2c3d4e5f",
        "event_type": "order.status_changed",
        "timestamp": "2026-08-26T13:04:11.482Z",
        "order_id": "5d6e7f80-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
        "order_number": "ORD-000128",
        "from_status": "PROCESSING",
        "to_status": "SHIPPED",
        "customer_id": "9c0f4b8e-4a4a-4a0e-9d1f-2b7f5c9a1d33",
        "total_cents": 31500
      },
      "responseBody": "{\"received\":true}",
      "errorMessage": null,
      "createdAt": "2026-08-26T13:05:12.774Z"
    },
    {
      "id": "bb22cc33-dd44-4e55-9f66-778899001122",
      "eventId": "7c9d1e2f-3a4b-4c5d-8e9f-0a1b2c3d4e5f",
      "attempt": 1,
      "outcome": "FAILURE",
      "httpStatus": null,
      "durationMs": 10001,
      "payload": { "event_id": "7c9d1e2f-3a4b-4c5d-8e9f-0a1b2c3d4e5f", "...": "..." },
      "responseBody": null,
      "errorMessage": "WEBHOOK_DELIVERY_TIMEOUT: no response within 10000ms",
      "createdAt": "2026-08-26T13:04:13.559Z"
    }
  ],
  "pagination": { "page": 1, "pageSize": 100, "total": 2, "totalPages": 1 }
}
```

| Status | Situação |
| --- | --- |
| `200` | Histórico paginado, mais recente primeiro |
| `400` | `VALIDATION_ERROR` — `pageSize` fora de 1..100 |
| `401` | `UNAUTHORIZED` |
| `404` | `WEBHOOK_NOT_FOUND` |

**Semântica:** `pageSize` máximo de **100**, alinhado ao `listOrdersQuerySchema` existente em
`src/modules/orders/order.schemas.ts` e suficiente para os "últimos 100" pedidos por Marcos
([09:34]). O `responseBody` é truncado na gravação (ver 6.8).

O campo `payload` **não é uma coluna de `webhook_deliveries`**: ele vem por join da relação
`WebhookDelivery.outboxEvent → WebhookOutbox.payload` declarada na seção 4. Como o payload é um
snapshot imutável ([ADR-007](./adrs/ADR-007-snapshot-do-payload-na-insercao-da-outbox.md)), todas as
tentativas do mesmo evento compartilham exatamente os mesmos bytes — guardar uma cópia por tentativa
seria duplicação pura. É também por isso que a linha da outbox vira `DEAD_LETTERED` em vez de ser
apagada (5.4): o histórico de entregas depende dela.

### 6.7 `POST /api/v1/admin/webhooks/dead-letter/:id/replay` — replay administrativo

Restrito a `ADMIN` via `requireRole('ADMIN')` — "mexer em fila de entrega de notificação não é coisa
de operador" ([09:36] Sofia; ratificado por Larissa em [09:36], reaproveitando o `requireRole`
existente).

**Request**

```http
POST /api/v1/admin/webhooks/dead-letter/dd44ee55-ff66-4778-8899-00aabbccddee/replay
Authorization: Bearer <jwt de usuário ADMIN>
```

**Response `202 Accepted`** — o evento foi reenfileirado, não reentregue; a entrega efetiva acontece
no próximo ciclo do worker. *(O código `202` é proposta desta especificação: a reunião definiu o
endpoint e o efeito — "recoloca na outbox como pendente", [09:18] Diego — mas não o status HTTP.
O projeto hoje usa apenas `200`/`201`/`204`; `202` foi escolhido por descrever com precisão a
semântica assíncrona.)*

```json
{
  "deadLetterId": "dd44ee55-ff66-4778-8899-00aabbccddee",
  "outboxEventId": "7c9d1e2f-3a4b-4c5d-8e9f-0a1b2c3d4e5f",
  "eventId": "7c9d1e2f-3a4b-4c5d-8e9f-0a1b2c3d4e5f",
  "status": "PENDING",
  "replayedAt": "2026-08-26T16:10:44.001Z",
  "replayedBy": {
    "id": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
    "email": "admin@oms.local"
  }
}
```

| Status | Situação |
| --- | --- |
| `202` | Evento recolocado na outbox como `PENDING` |
| `401` | `UNAUTHORIZED` |
| `403` | `FORBIDDEN` — papel diferente de `ADMIN`, produzido pelo `requireRole` existente |
| `404` | `WEBHOOK_DEAD_LETTER_NOT_FOUND` |
| `409` | `WEBHOOK_ALREADY_REPLAYED` |

**Semântica:** o `X-Event-Id` é preservado no reenvio, permitindo deduplicação do lado do cliente
([09:25] Diego). O objeto `replayedBy` **não é uma coluna**: `webhook_dead_letter` persiste apenas
`replayedById`, e o `email` vem de uma consulta a `users` na montagem da resposta — a tabela não
declara relação, pela decisão de mantê-la independente (seção 4). A autoria do replay é gravada em `webhook_dead_letter.replayedById` e emitida em
log estruturado, atendendo à exigência de auditoria de Sofia ([09:36]).

### 6.8 Contrato outbound — o request que **nós** enviamos ao cliente

Este é o contrato mais importante da feature: é o que o cliente integra.

**Request**

```http
POST /oms/orders HTTP/1.1
Host: hooks.atlascomercial.com.br
Content-Type: application/json
X-Event-Id: 7c9d1e2f-3a4b-4c5d-8e9f-0a1b2c3d4e5f
X-Webhook-Id: 1f2e3d4c-5b6a-4789-8c0d-1e2f3a4b5c6d
X-Timestamp: 2026-08-26T13:04:13.402Z
X-Signature: sha256=6b1e4c0a9f2d7b83c5e1a04f6d92b7c8e3a5f1d0b6c4e2a9f8d3b7c1e5a0f4d2
```
```json
{
  "event_id": "7c9d1e2f-3a4b-4c5d-8e9f-0a1b2c3d4e5f",
  "event_type": "order.status_changed",
  "timestamp": "2026-08-26T13:04:11.482Z",
  "order_id": "5d6e7f80-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
  "order_number": "ORD-000128",
  "from_status": "PROCESSING",
  "to_status": "SHIPPED",
  "customer_id": "9c0f4b8e-4a4a-4a0e-9d1f-2b7f5c9a1d33",
  "total_cents": 31500
}
```

**Headers**

| Header | Conteúdo | Origem |
| --- | --- | --- |
| `Content-Type` | `application/json` | [09:44] Diego |
| `X-Event-Id` | UUID gerado na inserção da outbox, único por evento e **estável entre todas as tentativas** | [09:25] e [09:44] Diego |
| `X-Signature` | HMAC-SHA256 do corpo bruto. **O formato `sha256=<hex>` é proposta desta especificação** — a reunião definiu o algoritmo e o header, não a serialização | [09:20] Sofia, [09:44] Diego |
| `X-Timestamp` | Instante do **envio** em ISO 8601, para o cliente detectar replay attack se quiser | [09:44] Diego |
| `X-Webhook-Id` | Id do cadastro de webhook, para cliente com vários endpoints identificar qual caiu | [09:44] Sofia |

**Durante a janela de rotação (24 h)**, `X-Signature` carrega as duas assinaturas separadas por
vírgula, a nova primeiro:

```http
X-Signature: sha256=<hmac com a secret nova>,sha256=<hmac com a secret anterior>
```

O cliente aceita o request se **qualquer uma** das assinaturas conferir. Fora da janela, o header
carrega uma assinatura só. *(Interpretação de "a antiga fica válida por 24 horas em paralelo",
[09:21] Sofia — ver Q7 do [RFC](./RFC.md#5-questões-em-aberto) e
[ADR-004](./adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md).)*

**Campos do payload** ([09:43] Diego): `event_id`, `event_type`, `timestamp` (ISO 8601), `order_id`,
`order_number`, `from_status`, `to_status`, `customer_id` e `total_cents`. **Os `items` do pedido
não vão no payload**, para não inflar; o cliente que precisar de detalhe consulta
`GET /api/v1/orders/:id` ([09:43] Diego), endpoint já existente em
`src/modules/orders/order.routes.ts`.

> **Nota de convenção.** O payload outbound usa `snake_case`, exatamente como Diego enumerou os
> campos ([09:43]), enquanto a API REST interna usa `camelCase` (`orderNumber`, `totalCents` em
> `prisma/schema.prisma`). A divergência é deliberada: o payload é um contrato público estável,
> desacoplado da nomenclatura interna.

**Resposta esperada do cliente**

| Resposta do cliente | Interpretação |
| --- | --- |
| `2xx` (qualquer) | Sucesso. Evento marcado como `DELIVERED` |
| `3xx`, `4xx`, `5xx` | Falha. Entra na escada de retry (5.3) |
| Sem resposta em **10 s** | Falha por timeout ([09:42] Diego). Entra na escada de retry |
| Erro de conexão / DNS / TLS | Falha. Entra na escada de retry |

O corpo da resposta do cliente é ignorado para fins de decisão, mas é gravado truncado no histórico
de entregas (6.6), para diagnóstico. **O limite de 2 KB é proposta desta especificação** — a reunião
pediu que a resposta ficasse disponível ([09:34] Marcos), sem definir tamanho; o número existe para
impedir que um cliente com resposta grande infle a tabela, e é calibrável.

**Verificação do lado do cliente (documentação do portal, [09:40] Marcos):**

```js
import { createHmac, timingSafeEqual } from 'node:crypto'

function verify(rawBody, signatureHeader, secret) {
  const expected = 'sha256=' + createHmac('sha256', secret).update(rawBody).digest('hex')
  return signatureHeader
    .split(',')
    .some((s) => s.length === expected.length &&
                 timingSafeEqual(Buffer.from(s), Buffer.from(expected)))
}
```

A assinatura é calculada sobre o **corpo bruto**, antes de qualquer parse ([09:22] Sofia: "HMAC-SHA256
sobre o corpo do request").

---

## 7. Matriz de erros

Todos os erros do módulo usam o **prefixo `WEBHOOK_`** ([09:29] Larissa) e herdam de `AppError`,
seguindo exatamente o desenho de `InvalidStatusTransitionError` e `InsufficientStockError` em
`src/shared/errors/http-errors.ts` ([09:28] Bruno). Nenhuma alteração é necessária em
`src/middlewares/error.middleware.ts`: ele já serializa qualquer `AppError` no envelope
`{ error: { code, message, details? } }` ([09:29] Bruno).

### 7.1 Erros expostos pela API

| Código | HTTP | Classe proposta | Estende | Quando ocorre | `details` |
| --- | --- | --- | --- | --- | --- |
| `WEBHOOK_NOT_FOUND` | 404 | `WebhookNotFoundError` | `AppError` (404) † | `:id` de webhook inexistente em `PATCH`, `DELETE`, `GET /deliveries` ou rotação | — |
| `WEBHOOK_INVALID_URL` | 400 | `WebhookInvalidUrlError` | `BadRequestError` | URL malformada ou com esquema diferente de `https` | `{ url, reason }` |
| `WEBHOOK_SECRET_REQUIRED` | 400 | `WebhookSecretRequiredError` | `BadRequestError` | **Reservado, sem gatilho nesta fase** — a coluna `secret` é obrigatória e sempre preenchida. Ganha uso se a Q6 do [RFC](./RFC.md#5-questões-em-aberto) levar a secret cifrada, quando a decifração pode falhar. Nomeado por Bruno ([09:28]) | `{ webhookId }` |
| `WEBHOOK_INVALID_EVENT_FILTER` | 400 | `WebhookInvalidEventFilterError` | `BadRequestError` | `subscribedStatuses` vazio ou com valor fora do enum `OrderStatus` | `{ invalidStatuses, allowed }` |
| `WEBHOOK_INACTIVE` | 409 | `WebhookInactiveError` | `ConflictError` | Rotação de secret sobre endpoint com `active = false` | `{ webhookId }` |
| `WEBHOOK_ROTATION_IN_PROGRESS` | 409 | `WebhookRotationInProgressError` | `ConflictError` | Nova rotação com janela de grace ainda aberta (**proposta — Q8 do [RFC](./RFC.md#5-questões-em-aberto)**) | `{ previousSecretExpiresAt }` |
| `WEBHOOK_PAYLOAD_TOO_LARGE` | 422 | `WebhookPayloadTooLargeError` | `UnprocessableEntityError` | Payload renderizado excede **64 KB** — propagado por `PATCH /orders/:id/status` | `{ bytes, limit: 65536 }` |
| `WEBHOOK_DEAD_LETTER_NOT_FOUND` | 404 | `WebhookDeadLetterNotFoundError` | `AppError` (404) † | Replay de id inexistente na DLQ | — |
| `WEBHOOK_ALREADY_REPLAYED` | 409 | `WebhookAlreadyReplayedError` | `ConflictError` | Replay de item da DLQ já reprocessado | `{ replayedAt, replayedById }` |

† **Por que os 404 não estendem `NotFoundError`.** `NotFoundError`
(`src/shared/errors/http-errors.ts`) fixa a mensagem em `` `${resource} not found` `` e o código em
`NOT_FOUND`, sem aceitar código customizado no construtor — diferente de `BadRequestError`,
`ConflictError` e `UnprocessableEntityError`, que recebem `code` como segundo parâmetro. Para emitir
`WEBHOOK_NOT_FOUND` sem alterar a classe existente, as duas classes de 404 estendem `AppError`
diretamente. É a única exceção à regra de herdar da classe HTTP mais específica.

### 7.2 Erros internos do worker (não trafegam por HTTP)

Registrados em `webhook_outbox.lastError`, em `webhook_deliveries.errorMessage` e no log estruturado.

| Código | Quando ocorre | Consequência |
| --- | --- | --- |
| `WEBHOOK_DELIVERY_TIMEOUT` | Cliente não respondeu em 10 s ([09:42] Diego) | Falha → escada de retry |
| `WEBHOOK_DELIVERY_FAILED` | Resposta não-2xx | Falha → escada de retry; `httpStatus` registrado |
| `WEBHOOK_DELIVERY_CONNECTION_ERROR` | DNS, conexão recusada ou erro de TLS | Falha → escada de retry |
| `WEBHOOK_RETRIES_EXHAUSTED` | 5ª retentativa falhou | Evento movido para `webhook_dead_letter` |

### 7.3 Erros existentes reaproveitados

Estes **não** ganham prefixo `WEBHOOK_` porque são produzidos por infraestrutura compartilhada já
existente, e reaproveitá-los é exatamente a decisão de [ADR-006](./adrs/ADR-006-reuso-dos-padroes-existentes-do-projeto.md).

| Código | HTTP | Produzido por | Situação no módulo de webhooks |
| --- | --- | --- | --- |
| `UNAUTHORIZED` | 401 | `authenticate` (`src/middlewares/auth.middleware.ts`) | Token ausente, inválido ou expirado |
| `FORBIDDEN` | 403 | `requireRole` (`src/middlewares/auth.middleware.ts`) | Replay de DLQ por usuário não-`ADMIN` ([09:36]) |
| `VALIDATION_ERROR` | 400 | `validate` (`src/middlewares/validate.middleware.ts`) | Falha de schema Zod, com `details` por campo |
| `NOT_FOUND` | 404 | `NotFoundError` (`src/shared/errors/http-errors.ts`) | `customerId` inexistente na criação |
| `INTERNAL_SERVER_ERROR` | 500 | Ramo genérico de `src/middlewares/error.middleware.ts` | Falha não prevista |

**Exemplo de resposta de erro** (envelope produzido por `src/middlewares/error.middleware.ts`):

```json
{
  "error": {
    "code": "WEBHOOK_INVALID_URL",
    "message": "Webhook URL must use https",
    "details": { "url": "http://hooks.atlascomercial.com.br/oms", "reason": "INSECURE_SCHEME" }
  }
}
```

---

## 8. Estratégias de resiliência

### 8.1 Timeouts

| Onde | Valor | Origem |
| --- | --- | --- |
| Chamada HTTP ao endpoint do cliente | **10 000 ms**, via `AbortSignal.timeout(10_000)` no `fetch` global (Node ≥ 20, `engines` em `package.json`) | [09:42] Diego |
| Reivindicação de evento travado em `PROCESSING` | **60 000 ms** desde `updatedAt` (6× o timeout de entrega) | Derivado — ver 5.2 |
| Transação de `changeStatus` | Mantém o default do Prisma; a publicação acrescenta apenas `SELECT` de endpoints + `INSERT`s, sem I/O externo | [09:04] Bruno (motivação para não ter HTTP na transação) |

### 8.2 Retries e backoff

Escada fixa `1min → 5min → 30min → 2h → 12h`, 5 retentativas, detalhada em 5.3 ([09:17] Diego).

- **Sem jitter.** A reunião especificou intervalos fixos. Com volume baixo e um único worker, o risco
  de *thundering herd* é desprezível; se a Q1 do [RFC](./RFC.md#5-questões-em-aberto) (rate limiting)
  for reaberta, jitter entra junto na discussão.
- **`nextAttemptAt` é a fonte da verdade**, não um timer em memória: reiniciar o worker não perde
  nem antecipa nenhuma retentativa.
- **O contador `attempts` é persistido**, então o replay de DLQ zera a escada e dá ao evento um ciclo
  completo novo (5.4).

### 8.3 Fallback

| Falha | Fallback |
| --- | --- |
| Entrega falha de forma transitória | Retry automático conforme 8.2 |
| Retentativas esgotadas | `webhook_dead_letter` com payload, motivo e timestamp ([09:18] Diego) + replay manual por `ADMIN` ([09:35] Diego; [09:36] Sofia) |
| Worker fora do ar | Nenhum evento é perdido: eles acumulam em `PENDING` na outbox e são drenados no restart ([09:06] Diego). Exige monitorar **lag** (seção 9) |
| Falha ao inserir na outbox | **Rollback da mudança de status** — falha explícita para o operador, em vez de evento silenciosamente perdido ([09:40] Bruno) |
| Cliente com problema recorrente | **Não há fallback por e-mail nesta fase** — explicitamente fora de escopo ([09:37] Larissa). O sinal disponível é o histórico de entregas (6.6) e a DLQ |

### 8.4 Isolamento e contenção

- **Falha de um endpoint não afeta outro:** cada linha da outbox tem estado de retry próprio, porque
  a granularidade é por endpoint (seção 4).
- **Falha de entrega nunca afeta o fluxo de pedidos:** a única interação síncrona com `changeStatus`
  é o `INSERT`, sem I/O externo ([09:04] Bruno).
- **Batch pequeno** por ciclo evita que um lote grande de eventos lentos monopolize o worker
  ([09:08] Diego).
- **Sem rate limiting de saída nesta fase** — questão em aberto Q1 ([09:39] Diego e Larissa). O risco
  aceito é bombardear um cliente com muitas chamadas se ele tiver muitos pedidos mudando de status
  ao mesmo tempo ([09:38] Diego).

---

## 9. Observabilidade

### 9.1 Métricas

Cada métrica existe para vigiar um risco ou validar uma decisão específica — não há métrica
decorativa.

| Métrica | Tipo | O que vigia | Alvo / alerta |
| --- | --- | --- | --- |
| `webhook_outbox_lag_seconds` | gauge | Idade do evento `PENDING` mais antigo. É a métrica-chave do risco de worker parado ([09:11] Diego) e do SLA de 10 s ([09:02] Marcos) | Alerta se > 60 s |
| `webhook_outbox_pending_count` | gauge | Profundidade da fila; vigia o crescimento da tabela sem arquivamento ([09:08] Diego) | Alerta em crescimento monotônico |
| `webhook_delivery_duration_ms` | histogram | Tempo de resposta do cliente, contra o timeout de 10 s ([09:42] Diego) | p95 monitorado |
| `webhook_delivery_total{outcome,http_status}` | counter | Taxa de sucesso e falha por endpoint | Alerta em queda abrupta |
| `webhook_delivery_attempts` | histogram | Distribuição de tentativas até o sucesso. **Valida empiricamente a escolha de 5 retentativas** ([09:15]–[09:17]) | — |
| `webhook_dead_letter_total{webhook_id}` | counter | Falhas permanentes por endpoint. É **a medição que Larissa condicionou para reabrir a decisão de alerta por e-mail** ([09:37]) | Alerta em qualquer incremento |
| `webhook_events_per_endpoint_per_minute` | counter | Volume de saída por cliente. É **o dado que falta para decidir a Q1**, rate limiting ([09:39]) | Observação |
| `webhook_status_change_publish_duration_ms` | histogram | Custo que a publicação acrescenta à transação de `changeStatus` | Vigia a regressão do fluxo de pedidos |

### 9.2 Logs

Pino, sem nada novo — "o logger, que é Pino, já tá no projeto inteiro. Não vamos botar nada novo"
([09:29] Bruno). O worker importa o mesmo `logger` de `src/shared/logger/index.ts`.

Nomes de evento em `snake_case`, seguindo a convenção já usada no código (`http_request` em
`src/middlewares/request-logger.middleware.ts`; `server_started` e `shutdown_initiated` em
`src/server.ts`):

| Evento | Nível | Campos |
| --- | --- | --- |
| `webhook_event_published` | `debug` | `eventId`, `webhookId`, `orderId`, `toStatus`, `requestId` |
| `webhook_delivery_attempt` | `info` | `eventId`, `webhookId`, `attempt`, `httpStatus`, `durationMs`, `outcome` |
| `webhook_delivery_failed` | `warn` | `eventId`, `webhookId`, `attempt`, `errorCode`, `nextAttemptAt` |
| `webhook_dead_lettered` | `error` | `eventId`, `webhookId`, `attempts`, `failureReason` |
| `webhook_dlq_replayed` | `info` | `deadLetterId`, `outboxEventId`, `replayedBy` — **auditoria exigida por Sofia** ([09:36]) |
| `webhook_secret_rotated` | `info` | `webhookId`, `previousSecretExpiresAt` (**nunca** o valor da secret) |
| `webhook_worker_cycle` | `debug` | `batchSize`, `processed`, `durationMs` |
| `worker_started` / `shutdown_initiated` | `info` | `pollIntervalMs`, `batchSize` — espelha `src/server.ts` |

**Redaction — alteração obrigatória.** `src/shared/logger/index.ts` hoje redige
`req.headers.authorization`, `req.headers.cookie`, `*.password`, `*.passwordHash`, `*.token` e
`*.accessToken`. A lista precisa ganhar `*.secret`, `*.previousSecret` e `*.signature`. Sem isso,
qualquer log acidental do objeto de endpoint vaza a secret — exatamente o incidente que Diego relatou
do lado de um cliente ([09:22]).

### 9.3 Tracing

O projeto **não tem biblioteca de tracing distribuído** (nada de OpenTelemetry ou APM no
`package.json`), e a decisão de reuso proíbe introduzir uma agora ([09:29] Bruno; [09:30] Larissa).
O rastreamento é feito por **correlação de identificadores**, aproveitando o que já existe:

- `src/middlewares/request-logger.middleware.ts` já gera ou propaga um `X-Request-Id` por request,
  guarda em `req.id` e o devolve no header de resposta.
- Esse `requestId` é **persistido na linha da outbox** (coluna `requestId`, seção 4) no momento da
  publicação, dentro da transação de `changeStatus`.
- O worker lê o `requestId` da linha da outbox e o inclui, junto de `eventId`, em todos os logs de
  entrega daquele evento.

> **Custo real desta escolha.** `req.id` não chega hoje até o service: o controller chama
> `this.orders.changeStatus(req.params.id!, req.body, req.user.id)`
> (`src/modules/orders/order.controller.ts`) e a assinatura é `changeStatus(id, input, userId)`
> (`src/modules/orders/order.service.ts`). Para a coluna ser preenchida, **dois arquivos existentes
> mudam**: `changeStatus` ganha um quarto parâmetro opcional `requestId?: string` e o controller
> passa `req.id`. O valor é gravado truncado em 36 caracteres, porque `X-Request-Id` é um header
> controlado pelo cliente e a coluna é `Char(36)`. Se a revisão técnica preferir não tocar no
> controller, a alternativa é remover a coluna e correlacionar apenas por `eventId` + `orderId` —
> perde-se o elo com o request do operador. *(Regra derivada: a reunião não tratou de tracing;
> [09:36] Sofia exigiu auditoria apenas do replay.)*

O resultado é uma cadeia rastreável de ponta a ponta com uma única busca:

```
X-Request-Id (chamada do operador em PATCH /orders/:id/status)
   └─ webhook_outbox.requestId
        └─ eventId  ──►  webhook_delivery_attempt (1..6)
                    ──►  webhook_deliveries (histórico consultável em 6.6)
                    ──►  X-Event-Id recebido pelo cliente
```

Se um cliente reclamar de um evento específico, o `X-Event-Id` que ele recebeu leva direto ao request
do operador que originou a mudança de status. Adotar tracing distribuído de verdade fica como
melhoria futura, fora do escopo desta feature.

---

## 10. Integração com o sistema existente

Esta seção mapeia **cada ponto de contato com o código já existente** neste repositório. A decisão
que a governa é [ADR-006](./adrs/ADR-006-reuso-dos-padroes-existentes-do-projeto.md): reuso máximo,
alteração mínima ([09:30] Larissa).

### 10.1 Mapa de integração

| Arquivo existente | Tipo de contato | O que acontece |
| --- | --- | --- |
| `src/modules/orders/order.service.ts` | **Alterado** | `changeStatus` ganha a chamada a `publishWebhookEvent(tx, ...)` dentro do `$transaction`, e um parâmetro opcional `requestId?` |
| `src/modules/orders/order.controller.ts` | **Alterado (1 linha)** | `changeStatus` passa a repassar `req.id` para o service, habilitando a correlação de tracing (9.3) |
| `src/modules/orders/order.status.ts` | **Consumido sem alteração** | O enum de transições define o vocabulário de eventos e o domínio válido de `subscribedStatuses` |
| `src/shared/errors/http-errors.ts` | **Estendido** | Novas classes `Webhook*Error` herdando de `BadRequestError`, `ConflictError` e `UnprocessableEntityError` — e de `AppError` nos casos 404 (ver 10.4) |
| `src/shared/errors/index.ts` | **Estendido** | Barril reexporta as classes novas |
| `src/middlewares/error.middleware.ts` | **Consumido sem alteração** | Já serializa qualquer `AppError`; os erros `WEBHOOK_*` saem no envelope padrão de graça |
| `src/middlewares/auth.middleware.ts` | **Consumido sem alteração** | `authenticate` protege todo o módulo; `requireRole('ADMIN')` protege o replay |
| `src/middlewares/validate.middleware.ts` | **Consumido sem alteração** | `validate({ body, params, query })` aplica os schemas Zod do módulo |
| `src/shared/logger/index.ts` | **Alterado (pequeno)** | `redactPaths` ganha `*.secret`, `*.previousSecret`, `*.signature` |
| `src/shared/http/response.ts` | **Consumido sem alteração** | `paginated()` monta as respostas de 6.2 e 6.6 |
| `src/config/database.ts` | **Consumido sem alteração** | `createPrismaClient()` instancia o cliente do worker |
| `src/config/env.ts` | **Estendido** | `envSchema` ganha as variáveis do worker (11.2) |
| `src/app.ts` | **Alterado** | `buildControllers` instancia o módulo; o router entra no `Controllers` |
| `src/routes/index.ts` | **Alterado** | `Controllers` ganha `webhooks`; `buildApiRouter` registra as rotas |
| `src/server.ts` | **Referência (não alterado)** | Molde do novo entrypoint `src/worker.ts` |
| `prisma/schema.prisma` | **Estendido** | Quatro modelos e dois enums novos (seção 4) + relação em `Customer` |
| `package.json` | **Alterado** | Novo script `worker`; **nenhuma dependência nova** |
| `tests/setup.ts` | **Alterado** | `beforeEach` precisa limpar as tabelas novas |
| `tests/helpers/factories.ts` | **Estendido** | Factory de webhook endpoint e de evento de outbox |

### 10.2 `src/modules/orders/order.service.ts` — a alteração crítica

É a única mudança de comportamento em código de domínio existente. Bruno a descreveu como "a
alteração crítica" ([09:40]).

Hoje, `changeStatus` (linha 126) abre `this.prisma.$transaction` (linha 131) e, dentro dele, atualiza
o pedido (linha 158) e grava o histórico (linhas 159–167) antes de reler o agregado (linhas
169–176). A publicação entra **entre a gravação do histórico e a releitura**:

```ts
// src/modules/orders/order.service.ts — dentro de changeStatus, no mesmo $transaction

await tx.order.update({ where: { id }, data: { status: to } });          // existente
await tx.orderStatusHistory.create({                                     // existente
  data: { orderId: id, fromStatus: from, toStatus: to,
          changedById: userId, reason: input.reason ?? null },
});

await publishWebhookEvent(tx, order, from, to, requestId);               // NOVO

const refreshed = await tx.order.findUnique({ /* ... */ });              // existente
```

Pontos de desenho:

- **`publishWebhookEvent` recebe o `tx`**, não um repositório injetado. Bruno propôs exatamente essa
  assinatura — `publishWebhookEvent(tx, order, fromStatus, toStatus)` ([09:41]) — e Diego aprovou na
  hora: "função pura recebendo o tx. Não precisa injetar repository inteiro" ([09:41]).
- **O tipo do primeiro parâmetro é `Prisma.TransactionClient`**, já aliasado como `TxClient` na linha
  24 do próprio arquivo e usado por `debitStock`, `replenishStock` e `reserveOrderNumber`. A
  assinatura nova é idiomática ao arquivo.
- **A assinatura do construtor de `OrderService` não muda**, então a fiação de dependências em
  `src/app.ts` (`new OrderService(orderRepository, prisma)`) permanece intacta. O **método**
  `changeStatus`, esse sim, ganha um quarto parâmetro opcional `requestId?: string`, repassado pelo
  controller a partir de `req.id` — ver o custo dessa escolha em 9.3.
- **Qualquer exceção propaga e aborta a transação**, que é o comportamento desejado ([09:40] Bruno;
  [09:41] Diego).
- **`OrderService.create` não publica evento.** A criação do pedido grava `fromStatus: null → PENDING`
  no histórico, mas a reunião tratou exclusivamente de **mudança** de status ([09:00] Marcos; [09:12]
  Larissa). Publicar na criação seria escopo inventado. **Ponto a confirmar na revisão técnica**
  ([09:50] Larissa).

### 10.3 `src/modules/orders/order.status.ts` — vocabulário de eventos

A máquina de estados é a fonte da verdade do que pode acontecer com um pedido:

```
PENDING    → PAID, CANCELLED
PAID       → PROCESSING, CANCELLED
PROCESSING → SHIPPED, CANCELLED
SHIPPED    → DELIVERED
DELIVERED  → (terminal)
CANCELLED  → (terminal)
```

Consequências para o módulo de webhooks:

- `subscribedStatuses` só aceita valores do enum `OrderStatus` de `prisma/schema.prisma`; qualquer
  outro valor produz `WEBHOOK_INVALID_EVENT_FILTER` (7.1).
- O exemplo dado por Marcos — "só quero saber quando vira SHIPPED e DELIVERED" ([09:33]) — é um
  filtro sobre `to_status`, e é assim que a filtragem de 5.1 funciona.
- Como `canTransition` já rejeita transições inválidas **antes** da publicação, nenhum evento
  impossível chega à outbox.
- Assinar `PENDING` é legal, mas nunca produz evento: `PENDING` só aparece como estado inicial na
  criação, e a criação não publica (10.2).

### 10.4 `src/shared/errors/*` — reuso da hierarquia de erro

As classes novas seguem o mesmo formato das existentes em `src/shared/errors/http-errors.ts`:

```ts
// src/shared/errors/http-errors.ts — mesmo padrão de InvalidStatusTransitionError

export class WebhookNotFoundError extends AppError {
  constructor() {
    super('Webhook not found', 404, 'WEBHOOK_NOT_FOUND');
  }
}

export class WebhookInvalidUrlError extends BadRequestError {
  constructor(url: string, reason: string) {
    super('Webhook URL must use https', 'WEBHOOK_INVALID_URL', { url, reason });
  }
}

export class WebhookPayloadTooLargeError extends UnprocessableEntityError {
  constructor(bytes: number) {
    super('Webhook payload exceeds the maximum size',
          'WEBHOOK_PAYLOAD_TOO_LARGE', { bytes, limit: 65536 });
  }
}
```

Repare na assimetria: `WebhookInvalidUrlError` e `WebhookPayloadTooLargeError` passam o código como
segundo parâmetro para a superclasse, porque `BadRequestError`, `ConflictError` e
`UnprocessableEntityError` aceitam `code` no construtor. `WebhookNotFoundError` **não** pode fazer o
mesmo, porque `NotFoundError` fixa `NOT_FOUND` — daí ela estender `AppError` diretamente (ver a nota
† da seção 7.1).

As classes são reexportadas em `src/shared/errors/index.ts`, e
`src/middlewares/error.middleware.ts` **não muda**: ele já trata `err instanceof AppError` e monta o
envelope a partir de `statusCode`, `errorCode` e `details`, exatamente como Bruno previu ([09:29]).

### 10.5 `src/middlewares/auth.middleware.ts` — autenticação e autorização

```ts
// src/modules/webhooks/webhook.routes.ts (novo) — mesmo padrão de order.routes.ts

const router = Router();
router.use(authenticate);                                        // todo o módulo autenticado

router.post('/',            validate({ body: createWebhookSchema }),   controller.create);
router.get('/',             validate({ query: listWebhooksQuerySchema }), controller.list);
router.patch('/:id',        validate({ params: idParam, body: updateWebhookSchema }), controller.update);
router.delete('/:id',       validate({ params: idParam }),             controller.delete);
router.post('/:id/secret/rotate', validate({ params: idParam }),       controller.rotateSecret);
router.get('/:id/deliveries',     validate({ params: idParam, query: listDeliveriesQuerySchema }), controller.listDeliveries);
```

O router administrativo aplica `requireRole('ADMIN')` sobre o replay, no mesmo formato já usado em
`src/modules/users/user.routes.ts`:

```ts
adminRouter.post(
  '/webhooks/dead-letter/:id/replay',
  authenticate,
  requireRole('ADMIN'),                                          // [09:36] Sofia e Larissa
  validate({ params: idParam }),
  controller.replayDeadLetter,
);
```

O `req.user.id` — populado por `authenticate` a partir do `sub` do JWT — é o valor gravado em
`webhook_dead_letter.replayedById`, atendendo à auditoria pedida por Sofia ([09:36]).

### 10.6 `src/app.ts` e `src/routes/index.ts` — registro do módulo

```ts
// src/routes/index.ts
export type Controllers = {
  auth: AuthController; users: UserController; customers: CustomerController;
  products: ProductController; orders: OrderController;
  webhooks: WebhookController;                                   // NOVO
};

router.use('/webhooks', buildWebhookRouter(controllers.webhooks));      // NOVO
router.use('/admin',    buildWebhookAdminRouter(controllers.webhooks)); // NOVO
```

```ts
// src/app.ts — dentro de buildControllers, mesmo padrão dos demais módulos
const webhookRepository = new WebhookRepository(prisma);
const webhookService    = new WebhookService(webhookRepository, prisma);
const webhookController = new WebhookController(webhookService);
```

O prefixo `/api/v1` é herdado do `app.use('/api/v1', buildApiRouter(controllers))` já existente, o
que produz os caminhos completos da seção 6.

### 10.7 `src/worker.ts` — novo entrypoint, molde de `src/server.ts`

```ts
// src/worker.ts (novo) — espelha a estrutura de bootstrap e shutdown de src/server.ts
import { createPrismaClient } from './config/database.js';
import { env } from './config/env.js';
import { logger } from './shared/logger/index.js';
import { WebhookProcessor } from './modules/webhooks/webhook.processor.js';

async function bootstrap(): Promise<void> {
  const prisma = createPrismaClient();                 // PrismaClient próprio  [09:30] Bruno
  const processor = new WebhookProcessor(prisma, logger);
  // guarda de reentrada: um ciclo lento NUNCA pode sobrepor o seguinte, senão dois ciclos
  // processam a outbox em paralelo e a ordenação por pedido (ADR-002) se perde.
  let running = false;
  const timer = setInterval(() => {
    if (running) return;
    running = true;
    // sem o .catch, uma rejeição (MySQL fora, bug no fetch) vira unhandled rejection e
    // o Node >= 20 derruba o processo — exatamente o risco RT-2, silencioso.
    void processor
      .tick()
      .catch((err) => logger.error({ err }, 'webhook_worker_cycle_failed'))
      .finally(() => { running = false; });
  }, env.WEBHOOK_WORKER_POLL_INTERVAL_MS);

  const shutdown = async (signal: string): Promise<void> => {
    logger.info({ signal }, 'shutdown_initiated');     // mesmo evento de src/server.ts
    clearInterval(timer);
    await processor.drain();                           // conclui o ciclo em andamento
    await prisma.$disconnect();
    process.exit(0);
  };
  process.on('SIGINT',  () => void shutdown('SIGINT'));
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  logger.info({ pollIntervalMs: env.WEBHOOK_WORKER_POLL_INTERVAL_MS }, 'worker_started');
}

// mesmo fecho de src/server.ts
bootstrap().catch((err) => {
  logger.fatal({ err }, 'bootstrap_failed');
  process.exit(1);
});
```

E o script correspondente em `package.json`, no mesmo formato dos existentes ([09:11] Larissa):

```json
{
  "scripts": {
    "worker":       "tsx watch --env-file=.env src/worker.ts",
    "worker:start": "node --env-file=.env dist/worker.js"
  }
}
```

`tsconfig.build.json` já compila `src/` inteiro, então `dist/worker.js` sai do `npm run build` sem
configuração adicional.

### 10.8 `prisma/schema.prisma` e migration

Além dos quatro modelos da seção 4, o modelo `Customer` ganha a relação inversa:

```prisma
model Customer {
  // ... campos existentes
  orders           Order[]
  webhookEndpoints WebhookEndpoint[]   // NOVO
}
```

A migration é gerada por `npm run db:migrate` (`prisma migrate dev`, já em `package.json`) e
convive com a `20260519182739_init` existente. **Nenhuma tabela existente é alterada** — a feature é
puramente aditiva no schema.

### 10.9 `tests/` — o que precisa mudar

- **`tests/setup.ts`**: o `beforeEach` limpa hoje `orderStatusHistory`, `orderItem`, `order`,
  `orderNumberSequence`, `product`, `customer` e `user`. Precisa passar a limpar
  `webhookDelivery`, `webhookDeadLetter`, `webhookOutbox` e `webhookEndpoint` **antes** de
  `order` e `customer`, respeitando as chaves estrangeiras.
- **`tests/helpers/factories.ts`**: ganha `createTestWebhookEndpoint()` no mesmo estilo de
  `createTestCustomer()` e `createTestProduct()`.
- **`tests/orders.test.ts`** continua passando sem alteração: sem webhook cadastrado, a publicação
  retorna cedo e o comportamento de `changeStatus` é idêntico (5.1).
- O `vitest.config.ts` existente (`fileParallelism: false`, `singleFork: true`) já garante execução
  serial, o que é adequado para testar o processador contra o banco real.

---

## 11. Dependências e compatibilidade

### 11.1 Dependências

| Necessidade | Como é atendida | Dependência nova? |
| --- | --- | --- |
| HMAC-SHA256 | `createHmac` de `node:crypto` (Node ≥ 20, `engines` em `package.json`) | **Não** |
| Geração de secret | `randomBytes` de `node:crypto` | **Não** |
| Cliente HTTP com timeout | `fetch` global + `AbortSignal.timeout()` da runtime | **Não** |
| Geração de UUID | `@default(uuid())` do Prisma; o pacote `uuid` já é dependência direta | **Não** |
| Validação de entrada | `zod` 3.23.8, já presente | **Não** |
| Log estruturado | `pino` 9.5.0, já presente ([09:29] Bruno) | **Não** |
| Persistência | `@prisma/client` 5.22.0 + MySQL 8.0 do `docker-compose.yml` | **Não** |
| Agendamento do polling | `setInterval` da runtime | **Não** |

**Nenhuma dependência nova no `package.json`** — o que concretiza o objetivo OT-6 e a diretriz de
não subir infraestrutura ([09:07] Diego).

### 11.2 Configuração

`src/config/env.ts` valida o ambiente com Zod e encerra o processo em configuração inválida. O
`envSchema` ganha, com defaults iguais aos valores decididos na reunião:

```ts
WEBHOOK_WORKER_POLL_INTERVAL_MS: z.coerce.number().int().positive().default(2000),      // [09:09]
WEBHOOK_WORKER_BATCH_SIZE:       z.coerce.number().int().positive().max(200).default(50), // [09:08]
WEBHOOK_HTTP_TIMEOUT_MS:         z.coerce.number().int().positive().default(10000),     // [09:42]
WEBHOOK_MAX_RETRIES:             z.coerce.number().int().positive().default(5),         // [09:15]
WEBHOOK_MAX_PAYLOAD_BYTES:       z.coerce.number().int().positive().default(65536),     // [09:24]
WEBHOOK_SECRET_GRACE_PERIOD_HOURS: z.coerce.number().int().positive().default(24),      // [09:21]
```

`WEBHOOK_WORKER_BATCH_SIZE` é o único valor sem número fechado na reunião — Diego especificou apenas
"batch pequeno" ([09:08]); 50 é um ponto de partida a calibrar com a métrica
`webhook_outbox_lag_seconds`.

O `.env.example` precisa ganhar as mesmas chaves, e o worker é iniciado com a mesma `DATABASE_URL`
da API ([09:30] Bruno).

### 11.3 Compatibilidade

| Aspecto | Situação |
| --- | --- |
| **Endpoints existentes** | Nenhuma alteração de contrato em `/auth`, `/users`, `/customers`, `/products`, `/orders` |
| **`PATCH /orders/:id/status`** | ⚠️ **Novo modo de falha.** Pode responder `422 WEBHOOK_PAYLOAD_TOO_LARGE` se a renderização do evento estourar 64 KB, e pode falhar se o `INSERT` na outbox falhar ([09:40] Bruno). Consequência aceita e intencional do acoplamento transacional |
| **Pedidos sem webhook cadastrado** | Comportamento **idêntico** ao atual — a publicação retorna antes de qualquer escrita (5.1) |
| **Schema do banco** | Puramente aditivo; nenhuma tabela ou coluna existente é alterada |
| **Deploy** | O worker pode subir **depois** da API sem perda: eventos acumulam em `PENDING` e são drenados quando ele entra no ar ([09:06] Diego) |
| **Rollback de deploy** | Reverter só a aplicação é seguro; as tabelas ficam órfãs e inertes. Reverter a migration exige drenar a outbox antes |
| **Runtime** | Exige Node ≥ 20, que já é o mínimo declarado em `engines` |
| **Conexões de banco** | ⚠️ **Duas pools** contra o mesmo MySQL (API + worker) — revisar `max_connections` antes do deploy ([09:30] Bruno) |

---

## 12. Critérios de aceite técnicos

### 12.1 Publicação transacional

- [ ] Mudança de status de um pedido cujo customer tem webhook ativo assinando aquele status cria
      exatamente **uma linha em `webhook_outbox` por endpoint assinante**, com `status = PENDING`.
- [ ] Mudança de status sem nenhum webhook assinante **não cria linha alguma** ([09:34] Bruno).
- [ ] Erro forçado no `INSERT` da outbox faz **rollback completo**: `orders.status` inalterado e
      nenhuma linha nova em `order_status_history` ([09:40] Bruno).
- [ ] `tests/orders.test.ts` continua passando **sem alteração**.
- [ ] O payload gravado é um **snapshot**: alterar o pedido depois da inserção não muda o conteúdo da
      linha da outbox ([09:52] Larissa).
- [ ] Payload renderizado acima de 64 KB produz `WEBHOOK_PAYLOAD_TOO_LARGE` ⇢ *derivado*: a fala
      sustenta "erro, não truncamento" ([09:24] Larissa); que o erro **aborte a transação** é
      consequência de ADR-001 + ADR-007 (ver 5.1) e está na pauta da revisão técnica.

### 12.2 Worker e entrega

- [ ] `npm run worker` sobe um processo independente que não depende de `src/server.ts` estar no ar
      ([09:11] Diego).
- [ ] Evento pendente é entregue em **até 2 s + tempo de resposta do cliente** ([09:09] Diego).
- [ ] Matar a API não interrompe a entrega; matar o worker não afeta `PATCH /orders/:id/status`.
- [ ] Reiniciar o worker com eventos acumulados **drena a fila** sem perda e sem duplicar linhas.
- [ ] Três mudanças de status do mesmo pedido em sequência rápida chegam ao cliente **na ordem de
      `created_at`** ([09:12] Diego).
- [ ] Cliente que não responde em 10 s tem a entrega tratada como falha ([09:42] Diego).
- [ ] Linha travada em `PROCESSING` há mais de 60 s volta para `PENDING` no ciclo seguinte (5.2).
- [ ] Um ciclo que demora mais que o intervalo de polling **não** sobrepõe o ciclo seguinte — a
      guarda de reentrada do worker (10.7) preserva a ordenação por pedido.

### 12.3 Retry e DLQ

- [ ] Falha de entrega agenda a próxima tentativa em `now() + BACKOFF[attempts - 1]`, com a escada
      `1min/5min/30min/2h/12h` ([09:17] Diego).
- [ ] Após a 5ª retentativa falhar, o evento aparece em `webhook_dead_letter` com `payload`,
      `failureReason` e `failedAt` ([09:18] Diego), e a linha da outbox passa a `DEAD_LETTERED`.
- [ ] Uma linha em `DEAD_LETTERED` **nunca mais é selecionada** pelo worker, por mais ciclos que
      passem — o teste roda vários ciclos e verifica que não há reenvio.
- [ ] `POST /api/v1/admin/webhooks/dead-letter/:id/replay` com JWT `ADMIN` devolve `202` e recoloca o
      evento como `PENDING` ([09:18] Diego).
- [ ] O mesmo endpoint com JWT `OPERATOR` devolve `403 FORBIDDEN`, produzido pelo `requireRole`
      existente ([09:36] Sofia).
- [ ] O replay grava `replayedById` e emite `webhook_dlq_replayed` no log ([09:36] Sofia).
- [ ] O evento reenviado por replay carrega o **mesmo `X-Event-Id`** do envio original ([09:25] Diego).

### 12.4 Segurança

- [ ] Todo request outbound carrega `X-Signature` com HMAC-SHA256 do **corpo bruto**, verificável com
      a secret daquele endpoint ([09:22] Sofia).
- [ ] Dois webhooks distintos têm secrets **distintas** ([09:21] Sofia).
- [ ] Cadastro com URL `http://` é recusado com `WEBHOOK_INVALID_URL` ([09:23] Sofia).
- [ ] Rotação devolve secret nova e mantém a anterior aceita por **24 h**; durante a janela, o header
      `X-Signature` carrega **duas assinaturas** ([09:21] Sofia).
- [ ] Passadas as 24 h, apenas a secret nova é usada ([09:21] Sofia).
- [ ] A secret **nunca** aparece em `GET /webhooks` nem em nenhum log — validado com
      `LOG_LEVEL=trace` e os `redactPaths` atualizados (9.2).
- [ ] Revisão de segurança da Sofia concluída antes do deploy, com no mínimo 2 dias úteis reservados
      ([09:46] Sofia).

### 12.5 Contratos e integração

- [ ] Os sete endpoints da seção 6 respondem os status codes documentados.
- [ ] Todo erro do módulo responde no envelope `{ error: { code, message, details? } }` com código
      prefixado por `WEBHOOK_` ([09:29] Larissa), **sem alteração** em
      `src/middlewares/error.middleware.ts`.
- [ ] `GET /api/v1/webhooks/:id/deliveries?pageSize=100` retorna até 100 entregas com sucesso/falha,
      payload, response e `durationMs` ([09:34] Marcos).
- [ ] `npm run lint`, `npm run build` e `npm test` passam.

---

## 13. Riscos técnicos e mitigação

| # | Risco técnico | Impacto | Mitigação | Origem |
| --- | --- | --- | --- | --- |
| RT-1 | **Contenção na transação de `changeStatus`** — cliente com muitos webhooks ativos multiplica `INSERT`s dentro de uma transação que já toca `orders`, `order_status_history` e `products` | Degradação do fluxo central de pedidos | Filtrar assinantes na inserção reduz linhas ([09:34] Bruno); métrica `webhook_status_change_publish_duration_ms`; limite prático de endpoints por customer a definir | [09:04] Bruno |
| RT-2 | **Worker fora do ar sem ninguém perceber** — instância única, e a taxa de erro fica em zero justamente quando nada é entregue | Clientes deixam de receber sem sinal de erro | Alertar sobre `webhook_outbox_lag_seconds`, **não** sobre taxa de erro (9.1) | [09:11] e [09:12] Diego |
| RT-3 | **Crescimento sem limite da `webhook_outbox`** — arquivamento está fora de escopo | Degradação progressiva da query do worker | Índice composto `(status, nextAttemptAt)` mantém a query seletiva; `webhook_outbox_pending_count` monitorado; arquivamento é a Q4 do [RFC](./RFC.md#5-questões-em-aberto) | [09:07] Bruno; [09:08] Diego |
| RT-4 | **Vazamento da secret em log** — a secret trafega em claro pela aplicação | Comprometimento da integração de um cliente | Estender `redactPaths` em `src/shared/logger/index.ts` (9.2); nunca logar o objeto de endpoint inteiro; Q6 do RFC sobre cifra em repouso | [09:22] Diego |
| RT-5 | **Bombardeio de um cliente** — 50 pedidos mudando de status em um minuto viram 50 chamadas | Cliente pode nos bloquear ou degradar | Sem mitigação nesta fase, por decisão. Instrumentar `webhook_events_per_endpoint_per_minute` para embasar a Q1 | [09:38] Diego; [09:39] Larissa |
| RT-6 | **Exaustão de conexões do MySQL** — duas pools (API + worker) contra o mesmo banco | Falha de conexão em ambos os processos | Revisar `max_connections` antes do deploy; batch pequeno limita concorrência do worker | [09:30] Bruno |
| RT-7 | **Duplicidade não tratada pelo cliente** — cliente que não deduplica processa o mesmo evento duas vezes | Efeito colateral no negócio do cliente | `X-Event-Id` estável ([09:25] Diego); documentação destacada no portal ([09:26] Marcos); exemplo de verificação em 6.8 | [09:25] Sofia |
| RT-8 | **Quebra de ordenação ao escalar** — subir uma segunda instância do worker quebra silenciosamente a garantia por pedido | Cliente recebe eventos fora de ordem sem aviso | Registrado como limitação conhecida ([09:13] Larissa); escalar exige antes decidir a Q3 (partição por `order_id` ou lock pessimista) | [09:12] e [09:13] Diego |
| RT-9 | **Evento travado em `PROCESSING`** após crash do worker no meio de um envio | Evento nunca mais entregue e invisível na fila | Reivindicação automática após 60 s (5.2); `webhook_outbox_lag_seconds` captura o sintoma | Derivado de [09:11] Diego |
| RT-10 | **Payload defasado entregue horas depois** — o snapshot descreve o passado, e o cliente pode interpretá-lo como estado atual | Ticket de suporte, decisão errada do lado do cliente | Comportamento intencional ([09:52] Larissa); `timestamp` no payload ([09:43] Diego); documentar no portal ([09:40] Marcos) | [09:52] Larissa |

---

## Referências

- [`TRANSCRICAO.md`](../TRANSCRICAO.md) — reunião técnica de webhooks
- [`docs/PRD.md`](./PRD.md) — problema, escopo e métricas de sucesso
- [`docs/RFC.md`](./RFC.md) — proposta técnica e questões em aberto
- [`docs/adrs/`](./adrs/) — ADR-001 a ADR-007
- [`docs/TRACKER.md`](./TRACKER.md) — rastreabilidade item a item
