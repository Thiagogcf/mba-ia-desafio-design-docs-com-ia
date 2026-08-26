# ADR-005 — Entrega at-least-once com deduplicação delegada ao cliente via `X-Event-Id`

| Campo | Valor |
| --- | --- |
| **Status** | Aceita |
| **Data** | Reunião técnica de webhooks (`TRANSCRICAO.md`, quinta-feira 09:00) |
| **Decisores** | Diego (Eng. Sênior — Plataforma), Larissa (Tech Lead) |
| **Consultados** | Bruno (Eng. Pleno — Pedidos), Sofia (Eng. Segurança), Marcos (PM) |
| **Relacionadas** | [ADR-001](./ADR-001-outbox-no-mysql.md), [ADR-003](./ADR-003-retry-com-backoff-exponencial-e-dlq.md), [ADR-004](./ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md) |

## Contexto

O desenho escolhido torna a duplicidade **inevitável, não acidental**. Três mecanismos já decididos
produzem entrega repetida por construção:

- **Retry sobre falha ambígua** ([ADR-003](./ADR-003-retry-com-backoff-exponencial-e-dlq.md)): um
  timeout de 10 s ([09:42] Diego) não distingue "o cliente não recebeu" de "o cliente processou e a
  resposta se perdeu". Retentar é a única opção segura, e ela duplica.
- **Replay administrativo da DLQ** ([09:18] Diego): recolocar o evento na outbox reenvia algo que
  pode já ter sido processado do outro lado.
- **Crash do worker entre o envio e a marcação da linha** como entregue: ao reiniciar, o evento
  ainda consta como pendente.

Diego trouxe a consequência para a mesa de forma explícita: "a gente vai garantir at-least-once.
Pode acontecer de o cliente receber o mesmo evento duas vezes. Ele tem que estar preparado"
([09:24]). Bruno perguntou o óbvio: e como ele diferencia? ([09:25]).

## Decisão

**Garantimos entrega *at-least-once* e delegamos a deduplicação ao cliente, através de um
identificador único de evento transportado no header `X-Event-Id`** ([09:26] Larissa).

- **`X-Event-Id` carrega um UUID gerado no momento em que o evento entra na outbox** e é único por
  evento ([09:25] Diego). Ele é estável entre todas as tentativas do mesmo evento — retry e replay
  reenviam o **mesmo** `X-Event-Id`, que é justamente o que torna a deduplicação possível.
- **O cliente deduplica pelo `event_id` do lado dele** ([09:25] Diego). O mesmo identificador vai
  também no corpo do payload, no campo `event_id` ([09:43] Diego), para clientes que preferem
  persistir só o corpo.
- **`X-Webhook-Id` acompanha o envio** com o id do cadastro de webhook, para que um cliente com
  vários endpoints saiba qual cadastro originou aquele envio ([09:44] Sofia).
- **A responsabilidade é documentada de forma destacada no portal do desenvolvedor.** Marcos assumiu
  esse item ([09:26] Marcos).
- O UUID segue o padrão de identificadores do projeto ([09:51] Larissa) — todos os modelos de
  entidade em `prisma/schema.prisma` usam `@default(uuid()) @db.Char(36)` (a exceção é
  `OrderNumberSequence`, tabela de sequência com `id` inteiro), e o pacote `uuid` já é dependência
  direta (`package.json`), usado hoje em `src/middlewares/request-logger.middleware.ts`.

## Alternativas Consideradas

### A. Garantia *exactly-once* — **descartada (discutida na reunião)**

Assegurar que cada evento chegue exatamente uma vez ao cliente.

- **A favor:** o cliente não precisa implementar nada; a semântica é a mais simples possível para
  quem consome.
- **Contra:** exigiria coordenação dos dois lados — protocolo de confirmação, janela de
  deduplicação negociada e tratamento de resposta perdida — o que Diego resumiu como "fica muito
  mais complexo" ([09:25]). Na prática, *exactly-once* sobre HTTP sem transação distribuída é
  inalcançável: sempre existe o caso da resposta perdida após o processamento.
- **Trade-off que motivou o descarte:** simplicidade para o cliente em troca de complexidade
  desproporcional (e tecnicamente inatingível) do nosso lado. "At-least-once com event_id resolve
  99% dos casos" ([09:25] Diego), e é o que Stripe e GitHub fazem ([09:25] Diego).

### B. Deduplicação do nosso lado, com controle de entregas já confirmadas — **descartada (plausível, não levantada na reunião)**

Manter registro do que já foi confirmado e suprimir reenvio.

- **A favor:** tira o trabalho do cliente sem exigir protocolo novo.
- **Contra:** não resolve o caso que realmente gera duplicidade. Se a resposta do cliente se
  perdeu, do nosso lado a entrega consta como falha — não temos como saber que ele processou. A
  supressão só funcionaria para o caso em que já sabemos que deu certo, que é exatamente o caso em
  que não retentaríamos de qualquer forma.
- **Trade-off que motivou o descarte:** custo de estado adicional em troca de zero redução real de
  duplicidade. A informação que falta está do lado do cliente, e só ele pode usá-la.

### C. Sem identificador de evento, deduplicação por conteúdo — **descartada (plausível, não levantada na reunião)**

Deixar o cliente deduplicar comparando `order_id` + `to_status` + `timestamp`.

- **A favor:** um header a menos.
- **Contra:** ambíguo por natureza — um pedido pode legitimamente voltar a um mesmo par de status
  em fluxos distintos, e comparar payload inteiro é frágil a qualquer evolução do formato.
- **Trade-off que motivou o descarte:** economia irrelevante em troca de uma chave de deduplicação
  não confiável.

## Consequências

### Positivas

- **Nenhum evento é perdido** para preservar unicidade: na dúvida, reenviamos ([09:24] Diego).
- **Alinhamento com o padrão de mercado** — é a semântica que Stripe e GitHub adotam ([09:25]
  Diego), o que tende a reduzir a fricção para times de integração já familiarizados com ela. A
  reunião não registra se os três clientes deste caso integram com esses provedores.
- **Retry e replay ficam seguros por construção**, porque o identificador é estável entre
  tentativas. Sem isso, [ADR-003](./ADR-003-retry-com-backoff-exponencial-e-dlq.md) seria perigosa.
- **Diagnóstico ponta a ponta:** o mesmo `event_id` aparece na outbox, no log do worker, no
  histórico de entregas e do lado do cliente — uma única chave para investigar um incidente.
- **Custo de implementação praticamente nulo:** o UUID já é gerado na inserção da outbox.

### Negativas

- **Transfere responsabilidade para o cliente**, como Sofia apontou na hora ([09:25]). Cliente que
  não deduplicar vai processar o mesmo evento duas vezes, com efeito colateral no negócio dele.
- **Cria uma dependência de documentação.** A garantia só funciona se estiver claramente comunicada;
  o item virou compromisso do PM no portal do desenvolvedor ([09:26] Marcos).
- **Duplicidade pode chegar com horas de distância.** Com a escada de retry de até ~14h36min
  ([ADR-003](./ADR-003-retry-com-backoff-exponencial-e-dlq.md)) e replay manual sem prazo definido
  (⇢ *derivado*: a reunião definiu o replay manual em [09:18] Diego, não um prazo), a janela
  de deduplicação do cliente não pode ser curta — o que precisa ser dito explicitamente na
  documentação.
- **Sem ordenação global** ([ADR-002](./ADR-002-worker-em-processo-separado-com-polling.md)), a
  deduplicação por id não protege contra reordenação; o cliente que quiser reconstruir a linha do
  tempo precisa usar o `timestamp` do payload ([09:43] Diego).

### Trade-off explícito

Trocamos **simplicidade para o cliente** por **simplicidade e robustez do nosso lado**. A escolha só
se sustenta porque (a) *exactly-once* sobre HTTP não é de fato alcançável, (b) o padrão é
amplamente conhecido pelos integradores e (c) o PM assumiu o custo de comunicação. Se algum cliente
não conseguir deduplicar, a resposta correta é apoio na integração — não mudar a garantia.

## Referências

- `TRANSCRICAO.md` — [09:18], [09:24], [09:25], [09:26], [09:42], [09:43], [09:44], [09:51]
- Código: `prisma/schema.prisma` (padrão `@default(uuid())`), `package.json` (dependência `uuid`),
  `src/middlewares/request-logger.middleware.ts` (uso de `uuidv4`)
- [`docs/FDD.md`](../FDD.md) — Headers do envio e formato do payload
