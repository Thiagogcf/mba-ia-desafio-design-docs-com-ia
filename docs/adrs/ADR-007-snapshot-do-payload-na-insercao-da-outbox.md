# ADR-007 — Snapshot do payload renderizado no momento da inserção na outbox

| Campo | Valor |
| --- | --- |
| **Status** | Aceita |
| **Data** | Reunião técnica de webhooks (`TRANSCRICAO.md`, quinta-feira 09:00 — encerramento) |
| **Decisores** | Larissa (Tech Lead), Diego (Eng. Sênior — Plataforma), Bruno (Eng. Pleno — Pedidos) |
| **Consultados** | — (ponto levantado após a saída de Marcos e Sofia da call, [09:50]) |
| **Relacionadas** | [ADR-001](./ADR-001-outbox-no-mysql.md), [ADR-003](./ADR-003-retry-com-backoff-exponencial-e-dlq.md), [ADR-005](./ADR-005-entrega-at-least-once-com-x-event-id.md) |

## Contexto

Fechada a arquitetura, sobrou uma pergunta de modelagem que Bruno levantou no encerramento da call:
o evento da outbox guarda o **payload já renderizado**, ou guarda apenas o `order_id` e renderiza na
hora do envio? ([09:51] Bruno).

A pergunta não é cosmética, porque existe um intervalo real entre inserção e envio:

- o worker só lê a outbox a cada 2 segundos
  ([ADR-002](./ADR-002-worker-em-processo-separado-com-polling.md));
- em caso de falha, a última tentativa pode acontecer ~14h36min depois da primeira
  ([ADR-003](./ADR-003-retry-com-backoff-exponencial-e-dlq.md));
- o replay administrativo de DLQ é **manual**, acionado por um administrador ([09:18] Diego) e,
  por consequência, **sem prazo definido** — pode ocorrer dias depois (⇢ *derivado*: a fala
  estabelece o mecanismo manual, não fala em prazo).

Nesse intervalo o pedido continua vivo: ele pode mudar de status de novo, ser cancelado e ter
estoque reposto (`shouldReplenishStock` em `src/modules/orders/order.status.ts`) ou ter qualquer
outro campo alterado. O payload definido para o evento inclui campos que mudam ao longo do ciclo de
vida — `from_status`, `to_status`, `total_cents` ([09:43] Diego).

## Decisão

**O payload é renderizado e persistido como snapshot no momento da inserção na outbox**
([09:52] Larissa; concordado por Diego em [09:52] e ratificado por Bruno em [09:52]:
"Beleza, snapshot. Decidido").

- A linha da `webhook_outbox` guarda o **corpo JSON completo do evento**, montado dentro da mesma
  transação de `changeStatus` que originou o evento ([ADR-001](./ADR-001-outbox-no-mysql.md)).
- O worker **envia o que está gravado**, sem reconsultar `orders`. A entrega passa a ser uma função
  apenas da linha da outbox.
- Razão declarada: "se o pedido mudar depois, o evento ainda reflete o estado de quando o status
  mudou. Senão tem caso esquisito" ([09:52] Larissa).
- O snapshot cobre os campos definidos para o payload: `event_id`, `event_type`, `timestamp`,
  `order_id`, `order_number`, `from_status`, `to_status`, `customer_id` e `total_cents`
  ([09:43] Diego). **Os `items` do pedido ficam de fora**, para não inflar o payload; o cliente que
  precisar de detalhe consulta `GET /orders/:id` ([09:43] Diego, endpoint existente em
  `src/modules/orders/order.routes.ts`).

## Alternativas Consideradas

### A. Guardar apenas o `order_id` e renderizar no momento do envio — **descartada (discutida na reunião)**

Foi literalmente a segunda metade da pergunta de Bruno ([09:51]).

- **A favor:** linha da outbox mínima, sem duplicação de dados que já vivem em `orders`; e o cliente
  sempre recebe o estado mais recente do pedido, sem defasagem.
- **Contra:** produz eventos temporalmente inconsistentes. Um evento `PENDING → PAID` que só
  consegue ser entregue depois de o pedido já ter sido cancelado chegaria descrevendo um pedido
  `CANCELLED` — o "caso esquisito" apontado por Larissa ([09:52]). Além disso, cada tentativa de
  envio passaria a exigir um `SELECT` extra em `orders`, e o replay de um evento cujo pedido foi
  removido (`OrderService.delete` em `src/modules/orders/order.service.ts` permite deletar pedidos
  `PENDING`/`CANCELLED`) simplesmente falharia por ausência do registro.
- **Trade-off que motivou o descarte:** economia de armazenamento e frescor do dado em troca da
  perda de fidelidade histórica do evento. Como o evento representa **um fato que aconteceu em um
  instante**, e não o estado atual do pedido, fidelidade venceu.

### B. Snapshot parcial: alguns campos gravados, outros resolvidos no envio — **descartada (plausível, não levantada na reunião)**

Congelar apenas o que muda (`from_status`, `to_status`, `total_cents`) e resolver o resto na hora.

- **A favor:** payload menor sem perder o essencial da fotografia.
- **Contra:** cria duas classes de campo com semânticas temporais diferentes dentro do mesmo JSON —
  parte é "no momento do evento", parte é "no momento do envio". Isso é praticamente impossível de
  documentar sem confundir o cliente, e transforma qualquer bug de payload em investigação de
  ordem de leitura.
- **Trade-off que motivou o descarte:** economia marginal de bytes em troca de um contrato público
  ambíguo. O payload já é deliberadamente enxuto ([09:43] Diego), então o ganho seria irrelevante.

## Consequências

### Positivas

- **O evento é imutável e temporalmente correto.** O que o cliente recebe descreve o instante em que
  o status mudou, independentemente de quando a entrega ocorreu ([09:52] Larissa).
- **Retry e replay ficam idempotentes em conteúdo.** Todas as tentativas do mesmo `event_id`
  carregam exatamente os mesmos bytes, o que também torna a assinatura HMAC estável entre
  tentativas ([ADR-004](./ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md)).
- **O worker fica desacoplado do domínio de pedidos.** Ele lê a outbox e envia; não precisa conhecer
  o modelo `Order`, nem lidar com pedido apagado.
- **Um `SELECT` a menos por tentativa**, o que importa no caminho quente de um worker em polling.
- **Debug direto.** O que foi enviado está gravado; não é preciso reconstruir o estado passado do
  pedido para investigar uma reclamação.

### Negativas

- **Duplicação de dados.** Cada linha da outbox carrega um JSON com informação que também está em
  `orders`, e a tabela cresce sem arquivamento ([09:08] Diego).
- **Payload gravado não é corrigível retroativamente.** Se descobrirmos um bug no conteúdo do
  evento, os eventos já enfileirados continuarão errados — corrigir exige script de migração sobre
  a outbox.
- **Evolução de formato exige versionamento.** Eventos gravados sob o formato antigo podem ser
  entregues depois de um deploy que mudou o formato, então a outbox pode conter, ao mesmo tempo,
  payloads de versões diferentes. O `event_type` (`order.status_changed`, [09:43] Diego) precisa
  absorver essa versão, ou um campo de versão precisa entrar no payload — detalhamento em
  [`docs/FDD.md`](../FDD.md).
- **O cliente pode receber informação desatualizada** em relação ao pedido no momento em que ele
  lê. Isso é intencional, mas precisa ser explícito na documentação do portal ([09:40] Marcos),
  senão vira ticket de suporte.
- **Interage com o limite de 64 KB.** Como o payload é materializado na inserção, a validação de
  tamanho ([09:24] Larissa) acontece **dentro da transação de `changeStatus`** — ou seja, um evento
  grande demais falha a mudança de status, e não apenas a entrega. Consequência do acoplamento
  transacional de [ADR-001](./ADR-001-outbox-no-mysql.md), tratada explicitamente em
  [`docs/FDD.md`](../FDD.md).

### Trade-off explícito

Trocamos **espaço em disco e frescor do dado** por **fidelidade histórica e simplicidade do
worker**. A troca é claramente favorável neste desenho porque o payload é pequeno por decisão
([09:43] Diego) e porque a janela entre inserção e entrega pode chegar a horas
([ADR-003](./ADR-003-retry-com-backoff-exponencial-e-dlq.md)) — quanto maior essa janela, mais a
alternativa A produziria eventos enganosos.

## Referências

- `TRANSCRICAO.md` — [09:08], [09:18], [09:24], [09:40], [09:43], [09:50], [09:51], [09:52]
- Código: `src/modules/orders/order.service.ts` (`changeStatus`, `delete`),
  `src/modules/orders/order.status.ts` (`shouldReplenishStock`),
  `src/modules/orders/order.routes.ts` (`GET /:id`)
- [`docs/FDD.md`](../FDD.md) — Estrutura da `webhook_outbox` e formato do payload
