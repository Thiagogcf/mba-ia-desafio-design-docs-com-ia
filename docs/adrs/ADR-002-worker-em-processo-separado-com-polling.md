# ADR-002 — Worker em processo separado consumindo a outbox por polling de 2 segundos

| Campo | Valor |
| --- | --- |
| **Status** | Aceita |
| **Data** | Reunião técnica de webhooks (`TRANSCRICAO.md`, quinta-feira 09:00) |
| **Decisores** | Diego (Eng. Sênior — Plataforma), Larissa (Tech Lead), Bruno (Eng. Pleno — Pedidos) |
| **Consultados** | Marcos (PM) |
| **Relacionadas** | [ADR-001](./ADR-001-outbox-no-mysql.md), [ADR-003](./ADR-003-retry-com-backoff-exponencial-e-dlq.md), [ADR-006](./ADR-006-reuso-dos-padroes-existentes-do-projeto.md) |

## Contexto

Com a outbox decidida ([ADR-001](./ADR-001-outbox-no-mysql.md)), sobra a pergunta de como o
consumidor lê a tabela e onde ele roda ([09:08] Larissa).

Duas restrições delimitam o espaço de solução:

1. **O SLA do cliente é generoso.** Marcos perguntou diretamente aos clientes o que eles entendem
   por "tempo real": qualquer coisa **abaixo de 10 segundos** já atende; o que não pode é ficar
   pendurado ([09:02] Marcos).
2. **O banco é MySQL.** Diferente do PostgreSQL, o MySQL não tem `LISTEN`/`NOTIFY`. Existe trigger,
   mas trigger só executa SQL — ela não notifica processo externo ([09:09] Diego).

Sobre *onde* o consumidor roda: hoje o único entrypoint do projeto é `src/server.ts`, que sobe o
Express via `buildApp` e registra `SIGINT`/`SIGTERM` para shutdown gracioso. Se o loop de entrega
morar dentro dessa mesma instância, um restart da API derruba o worker junto ([09:11] Diego).

## Decisão

**O worker roda como processo separado e consome a outbox por polling a cada 2 segundos.**

- **Polling em loop:** a cada 2 segundos o worker busca os eventos pendentes mais antigos, processa
  e marca o resultado ([09:09] Diego). A latência de pior caso introduzida pelo consumidor é de
  2 segundos, o que cabe folgadamente no orçamento de 10 segundos ([09:10] Larissa; aceito por
  Marcos em [09:10]).
- **Processo separado, não thread da API.** O worker é um entrypoint novo `src/worker.ts`, no mesmo
  molde do `src/server.ts` existente, acionado por um script `npm run worker` ([09:11] Larissa).
  Mesma stack e mesmo banco — só não pode ser o mesmo processo ([09:11] Diego).
- **`PrismaClient` próprio.** Como `PrismaClient` é por processo, o worker instancia o seu via a
  mesma fábrica `createPrismaClient()` de `src/config/database.ts`, apontando para a mesma
  `DATABASE_URL` ([09:30] Bruno).
- **Single-worker por enquanto.** Rodando uma única instância, o processamento segue a ordem de
  `created_at` da outbox e o cliente recebe os eventos de um mesmo pedido na ordem correta
  ([09:12] Diego). **Não há garantia de ordenação global** — apenas ordenação implícita por
  `order_id` e apenas enquanto for single-worker. Isso fica registrado como **limitação conhecida**
  ([09:13] Larissa), e Marcos confirmou que os clientes nunca pediram ordenação global
  ([09:14] Marcos).

## Alternativas Consideradas

### A. Trigger de banco notificando o worker — **descartada**

Bruno perguntou se dava para usar trigger do MySQL e ser mais reativo ([09:09]).

- **A favor:** latência praticamente zero, sem loop ocioso batendo no banco.
- **Contra:** o MySQL não tem listener nativo equivalente ao `NOTIFY`/`LISTEN` do PostgreSQL. A
  trigger existe, mas só executa SQL — para avisar um processo externo seria preciso improvisar
  (escrever em arquivo, bater num endpoint), o que Diego classificou como "esquisito" ([09:09]).
- **Trade-off que motivou o descarte:** ganharíamos latência que **não é necessária** (o requisito
  é < 10 s) ao custo de um mecanismo frágil e não idiomático para o banco em uso.

### B. Worker embutido na instância da API — **descartada**

Rodar o loop de entrega dentro do mesmo processo Node que serve o Express.

- **A favor:** um único artefato de deploy, uma única conexão de banco, zero mudança no runbook.
- **Contra:** um restart ou deploy da API derruba o worker junto ([09:11] Diego); o loop de entrega
  passa a competir por event loop com o tráfego HTTP; e escalar a API horizontalmente
  multiplicaria os workers sem querer, quebrando a premissa de instância única desta ADR.
- **Trade-off que motivou o descarte:** simplicidade de deploy em troca de acoplar o ciclo de vida
  da entrega ao ciclo de vida da API. Como o requisito é justamente *não* ficar pendurado
  ([09:02] Marcos), o acoplamento é inaceitável.

### C. Múltiplos workers em paralelo desde o início — **adiada**

- **A favor:** throughput maior e tolerância à queda de uma instância.
- **Contra:** perde a garantia de ordenação por pedido, porque duas instâncias podem pegar dois
  eventos do mesmo `order_id` ([09:12] Diego). Resolver exige particionar por `order_id` ou usar
  lock pessimista ([09:13] Diego).
- **Trade-off:** Diego classificou explicitamente como "problema do futuro, não agora" ([09:13]).
  Fica documentado como limitação conhecida, não como decisão fechada.

## Consequências

### Positivas

- **Isolamento de falhas.** Deploy, restart ou crash da API não interrompem a entrega de webhooks,
  e vice-versa ([09:11] Diego).
- **Recuperação automática sem estado próprio.** Todo o estado de progresso vive na `webhook_outbox`;
  ao reiniciar, o worker simplesmente volta a ler os pendentes. Não há fila em memória a perder.
- **Ordenação por pedido sai de graça** enquanto for uma instância só, sem lock nem coordenação
  ([09:12] Diego).
- **Nenhuma dependência nova.** Polling é um `setInterval` sobre o mesmo Prisma; não entra
  biblioteca de fila no `package.json`.

### Negativas

- **Piso de latência de 2 segundos** somado ao tempo de entrega. Aceito explicitamente
  ([09:10] Larissa).
- **Carga constante no banco** mesmo sem eventos: uma consulta indexada a cada 2 segundos, 24/7.
- **Ponto único de falha operacional.** Com uma única instância, enquanto o processo estiver fora
  do ar nada é entregue — os eventos acumulam na outbox (não se perdem) e são drenados no restart.
  Isso exige que o *lag* da outbox seja monitorado, e não apenas a taxa de erro.
- **Escalar horizontalmente quebra a ordenação.** Subir uma segunda instância não é uma operação
  transparente: exige antes particionamento por `order_id` ou lock pessimista ([09:13] Diego).
- **Um artefato de deploy a mais** para o time operar (novo processo, novo comando, novo alvo de
  monitoração).

### Trade-off explícito

Trocamos reatividade e escalabilidade horizontal por **simplicidade e ordenação gratuita**. A troca
é defensável porque o requisito de negócio é folgado: 2 segundos de piso deixam **8 segundos** para a
entrega HTTP dentro do orçamento de 10 segundos ([09:02] Marcos).

**Isso não fecha no pior caso, e é preciso dizer.** O timeout por tentativa é de 10 segundos
([09:42] Diego), então uma entrega lenta que responde no limite totaliza ~12 segundos e **estoura o
SLA**. O compromisso é explícito: **o alvo de 10 segundos vale para o caminho feliz, medido como p95**
(objetivo O1 em [`docs/PRD.md`](../PRD.md)), não como garantia de pior caso. Cliente lento consome o
orçamento inteiro por definição — e um cliente que chega ao timeout já entrou na escada de retry
([ADR-003](./ADR-003-retry-com-backoff-exponencial-e-dlq.md)), onde a latência passa a ser de minutos
ou horas de qualquer forma.

Se o SLA virar garantia de pior caso, ou se o volume crescer a ponto de um único worker não drenar a
fila dentro da janela, esta ADR precisa ser reaberta junto com a alternativa C.

## Referências

- `TRANSCRICAO.md` — [09:02], [09:08], [09:09], [09:10], [09:11], [09:12], [09:13], [09:14], [09:30]
- Código: `src/server.ts` (molde do entrypoint), `src/config/database.ts` (`createPrismaClient`),
  `src/config/env.ts` (`DATABASE_URL`), `package.json` (scripts)
- [`docs/FDD.md`](../FDD.md) — Fluxo de processamento do worker e observabilidade de *lag*
