# RFC — Sistema de Webhooks de Notificação de Pedidos

> **Documento submetido à equipe para revisão.** Responde *o que propomos e por quê*. O
> detalhamento de implementação — contratos completos, matriz de erros, modelagem de tabelas — está
> em [`docs/FDD.md`](./FDD.md); o *porquê de produto* está em [`docs/PRD.md`](./PRD.md).

## Metadados

| Campo | Valor |
| --- | --- |
| **RFC** | 001 — Sistema de Webhooks de Notificação de Pedidos |
| **Status** | **Em revisão** (aguardando sessão de revisão técnica e revisão de segurança) |
| **Autora** | Larissa — Tech Lead. Assumiu abrir o design doc da feature ao encerrar a reunião ([09:50]) |
| **Redação** | Thiago Ferronato — consolidação a partir de [`TRANSCRICAO.md`](../TRANSCRICAO.md) e do código |
| **Data** | 2026-08-26 |
| **Origem** | Reunião técnica de ~55 min (`TRANSCRICAO.md`; registra "quinta-feira, 09:00", sem data de calendário) |
| **Revisores** | **Bruno** (Eng. Pleno — Pedidos) e **Diego** (Eng. Sênior — Plataforma), em sessão a marcar antes de iniciar a codificação ([09:50]); **Sofia** (Eng. Segurança), com no mínimo 2 dias úteis para revisar HMAC e geração de secret antes do deploy ([09:46]); **Marcos** (PM), como revisor de escopo e prazo |
| **Relacionados** | [PRD](./PRD.md) · [FDD](./FDD.md) · [ADRs](./adrs/) · [Tracker](./TRACKER.md) |

---

## 1. Resumo executivo (TL;DR)

Propomos notificação **outbound** de mudança de status de pedido via webhook HTTP, sobre o **padrão
Outbox no MySQL já existente**: a mudança de status e o registro do evento acontecem na **mesma
transação**, e um **worker em processo separado**, em polling de **2 segundos**, faz a entrega.

Falha de cliente é tratada com **backoff exponencial (1min → 5min → 30min → 2h → 12h, 5
retentativas)**; esgotada a escada, o evento vai para uma **tabela de dead letter** com replay manual
restrito a `ADMIN`. Cada envio é assinado em **HMAC-SHA256** com **secret única por endpoint**,
rotacionável com **grace period de 24 horas**. A garantia é **at-least-once**, com deduplicação
delegada ao cliente via header **`X-Event-Id`**.

Nada de infraestrutura nova: sem broker, sem fila externa, sem dependência adicional no
`package.json`. O módulo `src/modules/webhooks/` segue o padrão dos módulos existentes e reaproveita
`AppError`, o error middleware central, o `validate` de Zod, o `requireRole` e o logger Pino.

**Custo estimado:** três sprints, incluindo a revisão de segurança ([09:46] Larissa).
**Prazo alvo:** fim de novembro, compromisso com a Atlas ([09:45] Marcos).

---

## 2. Contexto e problema

Três clientes B2B — **Atlas Comercial, MaxDistribuição e Nova Cargo** — pediram formalmente para ser
notificados quando o status dos pedidos deles muda ([09:00] Marcos). Hoje fazem **polling em
`GET /orders`**, o que torna a integração lenta e cara do lado deles; a Atlas sinalizou possível
migração para um concorrente se não entregarmos até o fim do trimestre ([09:00] Marcos).

O significado de "tempo real" foi apurado diretamente com os clientes: **abaixo de 10 segundos**
atende; o inaceitável é ficar pendurado e ter de atualizar manualmente ([09:02] Marcos). O escopo é
**exclusivamente outbound** — eles querem receber, não enviar ([09:02] Marcos; confirmado por Sofia
em [09:03]).

Do lado do sistema, o OMS **não tem hoje nenhum mecanismo de notificação externa, evento, fila ou
webhook**. O que existe é uma máquina de estados de pedido bem definida
(`src/modules/orders/order.status.ts`) e uma transação de mudança de status já densa em
`src/modules/orders/order.service.ts:131`, que valida a transição, movimenta estoque, atualiza
`orders` e insere em `order_status_history`.

O problema técnico central é, portanto: **como emitir um evento externo sem comprometer a
integridade nem a disponibilidade do fluxo de pedidos**, sabendo que o destino é infraestrutura de
terceiro, fora do nosso controle.

---

## 3. Proposta técnica

### 3.1 Visão geral

```
  PATCH /api/v1/orders/:id/status
            │
            ▼
  ┌──────────────────────────────────────────────┐
  │  OrderService.changeStatus  —  $transaction  │
  │  ─────────────────────────────────────────── │
  │  valida transição (order.status.ts)          │
  │  debita / repõe estoque                      │
  │  UPDATE orders                               │
  │  INSERT order_status_history                 │
  │  INSERT webhook_outbox ← 1 linha por endpoint│  falhou aqui ⇒ ROLLBACK de tudo
  └──────────────────────────────────────────────┘
            │ commit
            ▼
     [ webhook_outbox ]   PENDING | PROCESSING | FAILED | DELIVERED
            │
            │  polling 2s  (processo separado: src/worker.ts)
            ▼
  ┌──────────────────────────────────────────────┐
  │  WebhookProcessor                            │
  │  lê pendentes (batch, ordem de created_at)   │
  │  assina HMAC-SHA256 · POST · timeout 10s     │
  └──────────────────────────────────────────────┘
        │ 2xx                      │ falha / timeout
        ▼                          ▼
   DELIVERED               retry 1m→5m→30m→2h→12h
   + registro de               (5 retentativas)
     entrega                        │ esgotou
                                    ▼
                          [ webhook_dead_letter ]
                                    │ replay manual (ADMIN)
                                    └──► volta à outbox como PENDING
```

### 3.2 Pilares da proposta

**Publicação transacional (Outbox).** O evento nasce dentro da mesma transação que muda o status
([09:06] Diego): commit ⟺ evento registrado, rollback ⟺ evento inexistente. Falha ao gravar na
outbox **aborta a mudança de status** — não pode existir status mudado sem evento emitido ([09:40]
Bruno; [09:41] Diego). O gancho é uma função que recebe o *transaction client* atual,
`publishWebhookEvent(tx, order, fromStatus, toStatus)`, sem injetar um repositório inteiro no
`OrderService` ([09:41] Bruno e Diego). → [ADR-001](./adrs/ADR-001-outbox-no-mysql.md)

**Consumo desacoplado (worker separado, polling 2 s).** Entrypoint novo no molde do `src/server.ts`
existente, acionado por `npm run worker` ([09:11] Larissa), com `PrismaClient` próprio porque
`PrismaClient` é por processo ([09:30] Bruno). Polling em vez de trigger porque o MySQL não tem
`LISTEN`/`NOTIFY` ([09:09] Diego); 2 s cabem no orçamento de 10 s. →
[ADR-002](./adrs/ADR-002-worker-em-processo-separado-com-polling.md)

**Resiliência (backoff + DLQ).** Cinco retentativas em escada 1m/5m/30m/2h/12h — janela de ~14h36min
dimensionada para cobrir indisponibilidade real de cliente, inclusive manutenção planejada de duas
horas que já aconteceu ([09:16] Diego). Timeout de 10 s por tentativa ([09:42] Diego). Esgotada a
escada, o evento vai para `webhook_dead_letter` com payload, motivo e timestamp ([09:18] Diego), de
onde só sai por replay manual como `ADMIN`, com registro de autoria ([09:36] Sofia). →
[ADR-003](./adrs/ADR-003-retry-com-backoff-exponencial-e-dlq.md)

**Segurança (HMAC-SHA256 por endpoint).** Assinatura sobre o corpo do request, secret única por
endpoint — "se vaza uma, vaza tudo" ([09:21] Sofia) — e rotação com grace de 24 h para o cliente
migrar sem downtime ([09:21] Sofia). URL obrigatoriamente `https`, recusada na validação de schema
([09:23] Sofia). → [ADR-004](./adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md)

**Semântica de entrega (at-least-once).** Retry, replay e crash do worker tornam a duplicidade
inevitável; assumimos *at-least-once* e delegamos a deduplicação ao cliente via `X-Event-Id`, UUID
estável entre todas as tentativas do mesmo evento ([09:25] Diego), documentado de forma destacada no
portal do desenvolvedor ([09:26] Marcos). →
[ADR-005](./adrs/ADR-005-entrega-at-least-once-com-x-event-id.md)

**Aderência ao codebase.** Módulo `src/modules/webhooks/` com a mesma estrutura de
`src/modules/orders/`; erros herdando de `AppError` com prefixo `WEBHOOK_` ([09:29] Larissa); nada
novo de logging, e o error middleware central absorve os erros novos sem alteração ([09:29] Bruno).
→ [ADR-006](./adrs/ADR-006-reuso-dos-padroes-existentes-do-projeto.md)

**Imutabilidade do evento.** O payload é renderizado e gravado como snapshot na inserção, para que o
evento reflita o estado de quando o status mudou, não o estado no momento da entrega ([09:52]
Larissa). → [ADR-007](./adrs/ADR-007-snapshot-do-payload-na-insercao-da-outbox.md)

### 3.3 Superfície pública proposta

Três famílias de contrato, detalhadas em [`docs/FDD.md`](./FDD.md):

1. **CRUD de configuração de webhook** (autenticado, qualquer papel): criar, listar, editar, remover
   e rotacionar secret ([09:31] Marcos; [09:33] Bruno; [09:21] Sofia). O `customer_id` **não vem do
   JWT** — vai no body ou no path, porque o JWT atual representa o usuário operador do nosso sistema,
   não o cliente ([09:32] Larissa, corrigindo a proposta inicial de [09:31] Marcos).
2. **Histórico de entregas** de um webhook, com sucesso/falha, payload, response e tempo de resposta
   ([09:34] Marcos).
3. **Replay administrativo de dead letter**, restrito a `ADMIN` via `requireRole` ([09:36] Larissa),
   com auditoria de autoria ([09:36] Sofia).

Os caminhos completos, já com o prefixo `/api/v1` que o app monta em todas as rotas, estão em
[`docs/FDD.md`](./FDD.md#6-contratos-públicos).

---

## 4. Alternativas consideradas

Todas foram levantadas e descartadas na própria reunião.

| # | Alternativa | Trade-off que motivou o descarte | ADR |
| --- | --- | --- | --- |
| 1 | **Disparo HTTP síncrono dentro de `changeStatus`** — Larissa abre a questão ([09:03]), Bruno argumenta contra ([09:04]) | Trocaria disponibilidade e isolamento do core de pedidos por facilidade de implementação: um cliente lento travaria a mudança de status de **outros** pedidos, e não há rollback aceitável se o cliente estiver fora do ar. Diego: "síncrono está fora de questão" ([09:06]) | [ADR-001](./adrs/ADR-001-outbox-no-mysql.md) |
| 2 | **Redis Streams / broker dedicado** — Larissa ([09:07]) | Escalabilidade futura em troca de custo operacional imediato para um time pequeno; e publicar fora da transação MySQL reintroduziria o dual-write que o outbox resolve. Diego: "overengineering. Outbox no MySQL existente resolve" ([09:07]) | [ADR-001](./adrs/ADR-001-outbox-no-mysql.md) |
| 3 | **Trigger de banco notificando o worker** — Bruno ([09:09]) | Ganharíamos latência que **não é requisito** (SLA < 10 s) ao custo de um mecanismo frágil: MySQL não tem `LISTEN`/`NOTIFY` e trigger só executa SQL; avisar processo externo exigiria improviso ([09:09] Diego) | [ADR-002](./adrs/ADR-002-worker-em-processo-separado-com-polling.md) |
| 4 | **Garantia exactly-once** — Diego ([09:25]) | Simplicidade para o cliente em troca de complexidade desproporcional: exigiria coordenação dos dois lados. "At-least-once com event_id resolve 99% dos casos" ([09:25]) | [ADR-005](./adrs/ADR-005-entrega-at-least-once-com-x-event-id.md) |
| 5 | **Secret global da plataforma** — Sofia ([09:21]) | Simplicidade operacional em troca de raio de explosão igual à base inteira de clientes: "se vaza uma, vaza tudo" ([09:21]) | [ADR-004](./adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md) |

Outras quatro alternativas descartadas, com o trade-off registrado na ADR correspondente: **DLQ como
flag `failed` na própria outbox** ([09:17] Larissa → ADR-003), **3 retentativas em vez de 5**
([09:16] Bruno → ADR-003), **retry indefinido com backoff** ([09:15] Diego → ADR-003) e **guardar só
`order_id` e renderizar no envio** ([09:51] Bruno → ADR-007).

---

## 5. Questões em aberto

### 5.1 Levantadas na reunião e não decididas

**Q1 — Rate limiting de saída.** Diego levantou: se um cliente tem 50 pedidos mudando de status em
um minuto, nós o bombardeamos com 50 chamadas? ([09:38]). Ele mesmo avaliou que não deve entrar
agora — "a gente observa e implementa se virar problema" — mas pediu para registrar como ponto em
aberto ([09:39]). Larissa fechou como **"observar e decidir depois"** ([09:39]). *Pendente: definir
a métrica que dispara a decisão.*

**Q2 — Endurecimento da autorização do CRUD.** Marcos perguntou se o CRUD de configuração pode ser
feito por qualquer papel autenticado; Sofia respondeu **"Por enquanto sim. Mais pra frente a gente
pode endurecer"** ([09:37]). O modelo de permissão do CRUD é, portanto, provisório — só o replay de
DLQ tem papel fixado em `ADMIN` ([09:36]). *Pendente: critério e momento do endurecimento.*

**Q3 — Escala para múltiplos workers.** Com mais de um worker em paralelo perde-se a ordenação por
pedido. Diego apontou dois caminhos — particionar por `order_id` ou lock pessimista — e classificou
como **"problema do futuro, não agora"** ([09:13]); Larissa registrou como **limitação conhecida**
([09:13]). *Pendente: gatilho de volume que obriga a decidir.*

**Q4 — Arquivamento das linhas entregues.** Diego mencionou arquivar "depois de 30 dias ou assim",
declarando explicitamente **fora do escopo dessa feature** ([09:08]). *Pendente: política de
retenção, mecanismo e responsável.* Interage com Q3: sem arquivamento, a tabela cresce
indefinidamente.

**Q5 — Alerta ao cliente sobre webhook com problema.** Marcos pediu e-mail após falhas seguidas
([09:37]); Larissa respondeu **"Email tá fora de escopo dessa fase. Talvez próxima fase, depois que
a gente medir o impacto"** ([09:37]). *Pendente: a decisão está condicionada a uma medição que ainda
não existe — falta definir qual métrica.*

### 5.2 Surgidas durante a redação deste RFC

**Q6 — Armazenamento da secret em repouso.** Diferente de senha de usuário, guardada como hash
bcrypt (`users.passwordHash` em `prisma/schema.prisma`), a secret de webhook **precisa ser
recuperável em claro** para recomputar o HMAC a cada entrega. A reunião definiu que a tabela armazena
a secret ([09:21] Bruno), mas **não decidiu se em claro ou cifrada em repouso**. Dado o antecedente
de vazamento em log de cliente ([09:22] Diego), o ponto vai para a revisão de segurança ([09:46]).

**Q7 — Semântica operacional do grace period de 24 h.** Sofia definiu que "a antiga fica válida por
24 horas em paralelo" ([09:21]). Como o fluxo é outbound e quem assina somos nós, isso só produz o
efeito desejado se o envio carregar **as duas assinaturas** durante a janela. A interpretação
adotada está em [ADR-004](./adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md) e
precisa de confirmação explícita na revisão de segurança ([09:46]).

**Q8 — Rotação disparada durante uma janela de grace já aberta.** Duas rotações em menos de 24 h
tornariam três secrets teoricamente relevantes; a reunião não tratou o caso. Proposta a validar:
recusar a segunda rotação enquanto houver janela aberta.

---

## 6. Impacto e riscos

### 6.1 Impacto

| Dimensão | Impacto |
| --- | --- |
| **Código existente** | Alteração de comportamento em um único ponto de domínio: `changeStatus` em `src/modules/orders/order.service.ts`. Além dele, mudanças mecânicas de registro em `src/app.ts` e `src/routes/index.ts`, e uma linha em `src/modules/orders/order.controller.ts`. `error.middleware.ts`, `validate.middleware.ts` e `auth.middleware.ts` são **consumidos sem alteração** ([09:29] Bruno) |
| **Logger** | `src/shared/logger/index.ts` exige **uma alteração pontual obrigatória**: incluir a secret de webhook na lista de `redactPaths`, que hoje não a cobre. Sem isso, um log acidental vaza o segredo — o incidente que Diego relatou ([09:22]). Ver [FDD §9.2](./FDD.md#92-logs) |
| **Banco de dados** | Novas tabelas de configuração, outbox, entregas e dead letter em `prisma/schema.prisma` + migration. A transação de `changeStatus` ganha um `INSERT` por endpoint assinante, aumentando o tempo de lock |
| **Operação** | Um artefato de deploy novo (`npm run worker`), com ciclo de vida próprio, e **duas pools de conexão** contra o mesmo MySQL — exige revisar `max_connections` |
| **Contrato com o cliente** | Contrato público outbound com garantia at-least-once, que exige deduplicação do lado do cliente e documentação destacada no portal ([09:26] e [09:40] Marcos) |
| **Cronograma** | Três sprints, com a revisão de segurança ao final ([09:46] Larissa) |

### 6.2 Riscos de arquitetura

Aqui ficam apenas os riscos que **decorrem da forma escolhida** e que, se materializados, exigem
reabrir uma decisão. Risco de produto e comercial está em
[`docs/PRD.md`](./PRD.md#10-riscos-e-mitigação); risco técnico de implementação, em
[`docs/FDD.md`](./FDD.md#13-riscos-técnicos-e-mitigação).

| Risco de arquitetura | Decisão que o gera | Se materializar, reabre |
| --- | --- | --- |
| **A transação de `changeStatus` fica mais longa** e passa a poder falhar por causa do webhook — o fluxo central de pedidos herda um modo de falha novo ([09:04] Bruno; [09:40] Bruno) | Acoplamento transacional ([ADR-001](./adrs/ADR-001-outbox-no-mysql.md)) | ADR-001: publicar fora da transação, aceitando perda de garantia |
| **Instância única do worker é ponto único de parada** e o sintoma é silencioso: a taxa de erro fica em zero justamente quando nada é entregue ([09:11] e [09:12] Diego) | Single-worker ([ADR-002](./adrs/ADR-002-worker-em-processo-separado-com-polling.md)) | ADR-002 + **Q3**: particionar por `order_id` ou lock pessimista |
| **A outbox cresce sem limite** enquanto o arquivamento estiver fora de escopo ([09:07] Bruno; [09:08] Diego) | Fila no MySQL sem retenção ([ADR-001](./adrs/ADR-001-outbox-no-mysql.md)) | **Q4**: política de retenção |
| **O SLA de 10 s não se sustenta no pior caso** — 2 s de polling + 10 s de timeout totalizam 12 s ([09:02] Marcos; [09:42] Diego). O alvo vale como p95 no caminho feliz, não como garantia | Polling 2 s + timeout 10 s ([ADR-002](./adrs/ADR-002-worker-em-processo-separado-com-polling.md)) | ADR-002: reduzir o intervalo, ou renegociar o timeout de [09:42] |
| **A secret precisa ficar recuperável em claro** para recomputar o HMAC, criando uma classe de segredo que hoje não existe no sistema | HMAC simétrico ([ADR-004](./adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md)) | **Q6**: cifra em repouso, na revisão de segurança ([09:46]) |

---

## 7. Decisões relacionadas

| ADR | Decisão | Status |
| --- | --- | --- |
| [ADR-001](./adrs/ADR-001-outbox-no-mysql.md) | Padrão Outbox no MySQL para publicação de eventos de pedido | Aceita |
| [ADR-002](./adrs/ADR-002-worker-em-processo-separado-com-polling.md) | Worker em processo separado consumindo a outbox por polling de 2 s | Aceita |
| [ADR-003](./adrs/ADR-003-retry-com-backoff-exponencial-e-dlq.md) | Retry com backoff exponencial e DLQ em tabela separada | Aceita |
| [ADR-004](./adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md) | Assinatura HMAC-SHA256 com secret por endpoint e rotação com grace de 24 h | Aceita, sujeita à revisão de segurança ([09:46]) |
| [ADR-005](./adrs/ADR-005-entrega-at-least-once-com-x-event-id.md) | Entrega at-least-once com deduplicação delegada via `X-Event-Id` | Aceita |
| [ADR-006](./adrs/ADR-006-reuso-dos-padroes-existentes-do-projeto.md) | Reuso máximo dos padrões existentes do projeto | Aceita |
| [ADR-007](./adrs/ADR-007-snapshot-do-payload-na-insercao-da-outbox.md) | Snapshot do payload renderizado na inserção da outbox | Aceita |

---

## 8. O que se espera desta revisão

- **Bruno e Diego** — validar o gancho transacional em `changeStatus` e a granularidade da linha da
  outbox (um evento por endpoint assinante), na sessão a ser marcada ([09:50]).
- **Sofia** — decidir **Q6**, confirmar **Q7** e avaliar **Q8**, nos 2 dias úteis reservados ([09:46]).
- **Marcos** — confirmar que o escopo atende ao compromisso de fim de novembro com a Atlas ([09:45])
  e assumir a documentação da garantia at-least-once no portal ([09:26]).
- **Todos** — apontar qualquer item aqui registrado que não corresponda ao decidido na reunião. A
  rastreabilidade linha a linha está em [`docs/TRACKER.md`](./TRACKER.md).
