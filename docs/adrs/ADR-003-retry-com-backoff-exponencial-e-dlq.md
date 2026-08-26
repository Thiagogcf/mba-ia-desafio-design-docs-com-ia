# ADR-003 — Retry com backoff exponencial e Dead Letter Queue em tabela separada

| Campo | Valor |
| --- | --- |
| **Status** | Aceita |
| **Data** | Reunião técnica de webhooks (`TRANSCRICAO.md`, quinta-feira 09:00) |
| **Decisores** | Diego (Eng. Sênior — Plataforma), Larissa (Tech Lead) |
| **Consultados** | Bruno (Eng. Pleno — Pedidos), Sofia (Eng. Segurança), Marcos (PM) |
| **Relacionadas** | [ADR-001](./ADR-001-outbox-no-mysql.md), [ADR-002](./ADR-002-worker-em-processo-separado-com-polling.md), [ADR-005](./ADR-005-entrega-at-least-once-com-x-event-id.md) |

## Contexto

O endpoint de destino é **infraestrutura de terceiro**, fora do nosso controle. Larissa colocou a
pergunta de forma direta: se o cliente está offline, o que a gente faz? ([09:14]).

Diego trouxe **um fato e um cenário-limite** ([09:16]):

- **Fato relatado:** "Já tinha cliente nosso com indisponibilidade de duas horas em manutenção
  planejada".
- **Cenário-limite usado no argumento:** "**Se** o cliente teve indisponibilidade de manhã, a gente
  retentaria três vezes em 30 minutos e mataria" — uma hipótese condicional para mostrar o que três
  tentativas fariam, não um incidente registrado.

Ou seja: a janela de retry precisa cobrir uma indisponibilidade real de horas, não de minutos. Ao
mesmo tempo, retentar para sempre significa carregar eventos zumbis de clientes que simplesmente
sumiram ([09:15] Diego).

Um segundo ponto: onde o evento morto vai parar. Ou marcamos como `FAILED` na própria outbox, ou
persistimos numa tabela separada ([09:17] Larissa).

## Decisão

### Política de retry

**Backoff exponencial com 5 retentativas e progressão fixa 1min → 5min → 30min → 2h → 12h**
([09:17] Diego; ratificado por Larissa em [09:17]).

O envio inicial acontece assim que o worker pega o evento pendente. A partir da **primeira falha**,
as cinco retentativas seguem a escada acima, totalizando **~14h36min entre a primeira falha e a
última tentativa** — os "quase 15 horas" que Diego citou ao propor a escada ([09:17]) e a "janela de
até 12 ou 24 horas" que ele usou para justificar o número cinco ([09:15]).

> **Nota de interpretação.** No resumo final Larissa fala em "total 5 tentativas" ([09:48]). A
> aritmética do próprio Diego só fecha se as cinco tentativas forem as cinco **retentativas**
> (5 intervalos consumidos ⇒ 6 envios no total, ~14h36min). A leitura alternativa — 5 envios no
> total, 4 intervalos — encerraria em 2h36min e contradiria tanto os "quase 15 horas" quanto a
> justificativa da manutenção planejada de duas horas. Adotamos a leitura aritmeticamente
> consistente. O detalhamento por tentativa está em [`docs/FDD.md`](../FDD.md).

**Timeout de 10 segundos por tentativa**; cliente que não responde em 10 s é tratado como falha e
entra na escada de retry ([09:42] Diego).

### Dead Letter Queue

**Tabela `webhook_dead_letter` separada da outbox**, guardando o payload, o motivo da falha e o
timestamp ([09:18] Diego). Razões dadas: mantém a leitura da outbox principal limpa e o registro
serve como evidência para debug e reprocessamento.

**Reprocessamento é manual, via endpoint administrativo** `POST /admin/webhooks/dead-letter/:id/replay`,
que recoloca o evento na outbox como pendente ([09:18] e [09:35] Diego). O endpoint **exige role
`ADMIN`** — mexer em fila de entrega de notificação não é atividade de operador — e **registra
quem executou o replay, para auditoria** ([09:36] Sofia; ratificado por Larissa em [09:36]). A
verificação de papel reaproveita o `requireRole` já existente em
`src/middlewares/auth.middleware.ts` ([09:36] Larissa).

## Alternativas Consideradas

### A. Três retentativas em vez de cinco — **descartada**

Bruno propôs uma política mais agressiva: "3 não é melhor? Mais agressivo" ([09:16]).

- **A favor:** libera o evento mais rápido, menos linhas em estado pendente, feedback mais rápido
  de que o cliente está quebrado.
- **Contra:** com a escada proposta, três tentativas encerram em ~36 minutos. Diego apontou o caso
  concreto: cliente com indisponibilidade de manhã seria morto em 30 minutos, e já houve cliente
  com duas horas de manutenção planejada ([09:16]).
- **Trade-off que motivou o descarte:** liberar a fila rápido em troca de descartar eventos de
  clientes que voltariam sozinhos. Como o custo de uma linha parada na outbox é baixíssimo e o
  custo de um evento perdido é uma reclamação de cliente B2B, cinco venceu ([09:16] Larissa).

### B. Retry indefinido com backoff — **descartada**

Diego registrou que "algumas pessoas defendem retry indefinido com backoff" ([09:15]).

- **A favor:** nenhum evento é perdido por decisão nossa; o cliente sempre recebe eventualmente.
- **Contra:** evento fica pendurado para sempre se o cliente sumiu de vez ([09:15] Diego); a outbox
  nunca drena; e a ausência de um teto elimina o sinal operacional de "este endpoint está morto".
- **Trade-off que motivou o descarte:** garantia de entrega eterna em troca de uma fila que cresce
  sem fim e nunca produz alerta acionável. O teto de cinco transforma a falha permanente em um
  registro consultável na DLQ.

### C. Marcar `FAILED` na própria outbox em vez de tabela separada — **descartada**

Alternativa levantada pela própria Larissa ao abrir o ponto ([09:17]).

- **A favor:** um modelo a menos, sem cópia de payload, replay vira um `UPDATE` de status.
- **Contra:** polui a leitura da outbox principal, que é o caminho quente do worker; e mistura
  "trabalho a fazer" com "evidência histórica" na mesma tabela ([09:18] Diego).
- **Trade-off que motivou o descarte:** economia de um modelo em troca de sujar a tabela mais
  consultada do fluxo. Como a outbox já vai crescer sem arquivamento ([09:08] Diego), manter o
  caminho quente enxuto pesou mais.

## Consequências

### Positivas

- **Tolerância a indisponibilidade real do cliente:** a janela de ~14h36min cobre manutenção
  planejada e incidentes de várias horas ([09:16] Diego).
- **Backoff protege o cliente em recuperação.** A escada crescente evita martelar um endpoint que
  acabou de voltar e ainda está frágil.
- **Falha permanente vira um artefato consultável**, com payload, motivo e timestamp, em vez de
  virar log perdido ([09:18] Diego).
- **Existe caminho de recuperação sem deploy:** o replay administrativo devolve o evento à outbox
  ([09:18] Diego).
- **Caminho quente do worker permanece limpo** — a query de pendentes não precisa filtrar eventos
  mortos.

### Negativas

- **O último evento pode chegar quase 15 horas atrasado.** Aceito por Marcos: "se um cliente meu
  cair por 15 horas, ele já tá com problema sério dele" ([09:17]).
- **Payload duplicado.** O evento passa a existir na outbox e na DLQ, dobrando o armazenamento
  daquele evento.
- **Replay é trabalho manual.** Não há reprocessamento automático nem em lote; um incidente que
  gere centenas de itens na DLQ vira centenas de chamadas administrativas.
- **Replay reabre a janela de duplicidade.** Reenfileirar um evento que talvez tenha sido entregue
  e apenas falhou na resposta produz uma segunda entrega — o que só é aceitável porque a garantia
  é *at-least-once* com deduplicação por `X-Event-Id`
  ([ADR-005](./ADR-005-entrega-at-least-once-com-x-event-id.md)).
- **Eventos em retry longo ocupam a outbox por horas**, competindo com a varredura de pendentes;
  a query do worker precisa considerar `next_attempt_at`, não apenas o status.

### Trade-off explícito

Trocamos **latência de cauda** (um evento pode demorar ~15 h) e **duplicação de armazenamento** por
**resiliência a falhas reais de terceiros** e por um **teto operacional claro**. O número cinco é
deliberadamente um meio-termo: alto o bastante para cobrir a indisponibilidade de duas horas que já
aconteceu, baixo o bastante para que a fila sempre drene e produza um sinal acionável.

## Referências

- `TRANSCRICAO.md` — [09:08], [09:14], [09:15], [09:16], [09:17], [09:18], [09:35], [09:36],
  [09:42], [09:48]
- Código: `src/middlewares/auth.middleware.ts` (`requireRole`)
- [`docs/FDD.md`](../FDD.md) — Escada de retry detalhada, fluxo de DLQ e contrato do replay
