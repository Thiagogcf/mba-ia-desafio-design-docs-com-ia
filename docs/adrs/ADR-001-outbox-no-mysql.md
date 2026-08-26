# ADR-001 — Padrão Outbox no MySQL para publicação de eventos de pedido

| Campo | Valor |
| --- | --- |
| **Status** | Aceita |
| **Data** | Reunião técnica de webhooks (`TRANSCRICAO.md`, quinta-feira 09:00) |
| **Decisores** | Larissa (Tech Lead), Diego (Eng. Sênior — Plataforma), Bruno (Eng. Pleno — Pedidos) |
| **Consultados** | Marcos (PM), Sofia (Eng. Segurança) |
| **Relacionadas** | [ADR-002](./ADR-002-worker-em-processo-separado-com-polling.md), [ADR-003](./ADR-003-retry-com-backoff-exponencial-e-dlq.md), [ADR-007](./ADR-007-snapshot-do-payload-na-insercao-da-outbox.md) |

## Contexto

Três clientes B2B (Atlas Comercial, MaxDistribuição e Nova Cargo) pediram formalmente para ser
notificados quando o status dos pedidos deles muda; hoje eles fazem polling em `GET /orders`, o que
deixa a integração lenta e cara ([09:00] Marcos). O OMS não possui hoje nenhum mecanismo de
notificação externa, evento ou fila — o repositório não tem broker, worker nem tabela de eventos.

A primeira pergunta arquitetural da reunião foi exatamente esta: disparar o webhook sincronamente
dentro do service de pedidos, ou registrar o evento e entregar de forma assíncrona ([09:03] Larissa).

Duas restrições concretas moldam a resposta:

1. **A transação de mudança de status já é pesada.** Em `src/modules/orders/order.service.ts:131`,
   `changeStatus` abre um `prisma.$transaction` que valida a transição pela máquina de estados,
   debita ou repõe estoque (`debitStock`/`replenishStock`), atualiza `orders` e insere em
   `order_status_history`. Acrescentar uma chamada HTTP no meio disso faz qualquer cliente lento
   travar a mudança de status de outros pedidos ([09:04] Bruno).
2. **Não existe rollback aceitável para uma falha do cliente.** Se o endpoint do cliente estiver
   fora do ar, desfazer a mudança de status do pedido não é uma opção ([09:04] Bruno).

O time é pequeno e não quer assumir custo operacional de infraestrutura nova ([09:07] Diego).

## Decisão

Adotamos o **padrão Outbox sobre o MySQL já existente**.

- Na mesma transação SQL que atualiza `orders` e insere em `order_status_history`, gravamos
  também o evento numa tabela `webhook_outbox` ([09:06] Diego). Se a transação principal commitar,
  o evento está registrado; se der rollback, o evento some junto — não existe estado inconsistente.
- **A falha ao inserir na outbox aborta a mudança de status.** Não pode existir o caso de o status
  mudar e o evento não sair ([09:40] Bruno; [09:41] Diego).
- A outbox mora no **MySQL existente**, sem infraestrutura adicional ([09:07] Diego).
- A tabela é indexada por **status** (`PENDING`, `PROCESSING`, `FAILED`, `DELIVERED`) e por
  **`created_at`**; o worker lê apenas os pendentes, em batch pequeno ([09:08] Diego).
- **A filtragem de assinantes acontece na inserção, não no envio.** Se nenhum webhook ativo do
  customer assina aquele status, a linha nem é criada — economiza linha na tabela ([09:34] Bruno,
  concordado por Diego). Como retry e DLQ são estado *por endpoint* (ver
  [ADR-003](./ADR-003-retry-com-backoff-exponencial-e-dlq.md)), a granularidade da linha é
  **um evento por endpoint assinante**.
- A chave primária é **UUID**, seguindo o padrão do resto do projeto ([09:51] Larissa). Em
  `prisma/schema.prisma`, todos os modelos de entidade — `User`, `Customer`, `Product`, `Order`,
  `OrderItem`, `OrderStatusHistory` — usam `@id @default(uuid()) @db.Char(36)`; a única exceção é
  `OrderNumberSequence`, uma tabela de linha única cujo `id` é `Int`.
- **Arquivamento** das linhas entregues (~30 dias) fica **fora do escopo desta feature**
  ([09:08] Diego).

## Alternativas Consideradas

### A. Disparo HTTP síncrono dentro de `changeStatus` — **descartada**

Chamar o endpoint do cliente dentro da própria transação de mudança de status.

- **A favor:** implementação trivial, latência mínima, zero componentes novos.
- **Contra:** um cliente lento segura a transação e trava mudança de status de outros pedidos
  ([09:04] Bruno); não há resposta razoável para cliente fora do ar a não ser dar rollback numa
  operação de negócio já concluída ([09:04] Bruno).
- **Trade-off que motivou o descarte:** trocaria disponibilidade e isolamento do core de pedidos
  por simplicidade de implementação. Diego foi categórico: "síncrono está fora de questão"
  ([09:06]).

### B. Redis Streams (ou broker dedicado) — **descartada**

Publicar o evento num stream Redis e consumir de lá.

- **A favor:** desacoplamento real, throughput alto, consumer groups nativos.
- **Contra:** exige subir e operar infraestrutura nova, com um time pequeno ([09:07] Diego).
  Além disso, publicar no Redis *fora* da transação MySQL reintroduz exatamente o problema de
  consistência dual-write que o outbox resolve.
- **Trade-off que motivou o descarte:** escalabilidade futura em troca de custo operacional
  imediato. A razão que Diego deu foi o **tamanho do time**, não o volume de eventos — nenhum número
  de volume foi apresentado na reunião: "a gente é um time pequeno. Subir Redis Cluster pra isso é
  overengineering. Outbox no MySQL existente resolve" ([09:07]).

> **Nota de precisão.** Larissa levantou "Redis Streams ou alguma coisa parecida" ([09:07]) e Diego
> respondeu referindo-se a "Redis Cluster" ([09:07]). Tratamos as duas falas como a mesma
> alternativa — infraestrutura de fila dedicada — mas a palavra *overengineering* foi dita sobre o
> Cluster.

## Consequências

### Positivas

- **Consistência garantida por construção:** commit da mudança de status ⟺ evento registrado
  ([09:06] Diego). Não existe janela em que o pedido mudou e o evento sumiu.
- **Zero infraestrutura nova.** Reaproveita o MySQL 8.0 já provisionado (`docker-compose.yml`) e o
  mesmo `DATABASE_URL` (`src/config/env.ts`).
- **Reuso direto da transação existente.** O ponto de integração é uma linha a mais dentro do
  `prisma.$transaction` que já existe em `src/modules/orders/order.service.ts:131`.
- **Rastro de auditoria natural.** A outbox funciona como evidência de o que foi emitido, ao lado
  do `order_status_history` que já registra o que mudou.

### Negativas

- **A transação de `changeStatus` fica mais longa** — um `INSERT` adicional por endpoint assinante
  dentro de uma transação que já toca `orders`, `order_status_history` e `products`. O tempo de
  lock cresce proporcionalmente ao número de webhooks ativos daquele customer.
- **A tabela cresce indefinidamente** enquanto o arquivamento não for implementado, e o
  arquivamento foi explicitamente deixado fora do escopo ([09:08] Diego).
- **A latência passa a ser limitada pelo consumidor, não pelo commit** — o piso é o intervalo de
  polling do worker (ver [ADR-002](./ADR-002-worker-em-processo-separado-com-polling.md)).
- **Filtrar na inserção não faz backfill.** Um webhook criado (ou que passa a assinar um novo
  status) só recebe eventos gerados dali para frente; eventos passados nunca foram materializados.
- **O MySQL vira a fila.** Sem fan-out nativo nem consumer group, escalar consumidores exige
  particionamento em nível de aplicação ([09:13] Diego).

### Trade-off explícito

Trocamos o throughput teórico e os recursos prontos de um broker dedicado por **consistência
transacional garantida a custo operacional zero**. A troca é favorável enquanto o volume de eventos
couber confortavelmente numa tabela MySQL indexada e um único worker der conta. Se qualquer uma
dessas premissas cair, esta ADR precisa ser reaberta — o gatilho natural é a métrica de *lag* da
outbox definida no FDD.

## Referências

- `TRANSCRICAO.md` — [09:03], [09:04], [09:06], [09:07], [09:08], [09:34], [09:40], [09:41], [09:51]
- Código: `src/modules/orders/order.service.ts` (`changeStatus`), `prisma/schema.prisma`,
  `docker-compose.yml`
- [`docs/RFC.md`](../RFC.md) — Proposta técnica
- [`docs/FDD.md`](../FDD.md) — Modelagem da `webhook_outbox` e fluxo de inserção
