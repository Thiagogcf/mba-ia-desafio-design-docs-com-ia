# ADR-006 — Reuso máximo dos padrões existentes do projeto para o módulo de webhooks

| Campo | Valor |
| --- | --- |
| **Status** | Aceita |
| **Data** | Reunião técnica de webhooks (`TRANSCRICAO.md`, quinta-feira 09:00) |
| **Decisores** | Larissa (Tech Lead), Bruno (Eng. Pleno — Pedidos) |
| **Consultados** | Diego (Eng. Sênior — Plataforma), Sofia (Eng. Segurança) |
| **Relacionadas** | [ADR-002](./ADR-002-worker-em-processo-separado-com-polling.md), [ADR-003](./ADR-003-retry-com-backoff-exponencial-e-dlq.md), [ADR-004](./ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md) |

## Contexto

Webhooks são a primeira capacidade assíncrona do OMS. A tentação natural em uma feature assim é
tratar o módulo como um subsistema à parte, com convenções próprias — e é exatamente isso que
Bruno colocou na mesa para decidir de forma consciente ([09:27]).

O código existente tem convenções bem estabelecidas e uniformes:

| Convenção | Onde vive hoje |
| --- | --- |
| Um módulo por domínio, com `controller` / `service` / `repository` / `routes` / `schemas` | `src/modules/orders/`, `src/modules/customers/`, `src/modules/products/`, `src/modules/users/` |
| Hierarquia de erro única a partir de `AppError` | `src/shared/errors/app-error.ts`, `src/shared/errors/http-errors.ts`, barril em `src/shared/errors/index.ts` |
| Código de erro em `SCREAMING_SNAKE_CASE` no construtor do erro | `INSUFFICIENT_STOCK`, `INVALID_STATUS_TRANSITION` em `src/shared/errors/http-errors.ts` |
| Tratamento centralizado de erro, com envelope `{ error: { code, message, details? } }` | `src/middlewares/error.middleware.ts` |
| Validação de entrada por Zod aplicada como middleware | `src/middlewares/validate.middleware.ts` (`validate({ body, query, params })`) |
| Autenticação JWT e autorização por papel | `src/middlewares/auth.middleware.ts` (`authenticate`, `requireRole`) |
| Log estruturado com Pino, com redaction configurada | `src/shared/logger/index.ts` |
| Resposta paginada padronizada | `src/shared/http/response.ts` (`paginated`, `PaginatedResponse`) |
| Registro de rotas sob `/api/v1` e injeção manual de dependências | `src/app.ts` (`buildControllers`, `buildApp`), `src/routes/index.ts` (`Controllers`, `buildApiRouter`) |
| Identificadores UUID e nome de tabela em `snake_case` via `@@map` | `prisma/schema.prisma` |

## Decisão

**Reuso máximo do que já existe. O módulo de webhooks é um módulo como os outros**
([09:30] Larissa).

1. **Estrutura de módulo idêntica aos demais.** Nasce `src/modules/webhooks/` com
   `webhook.controller.ts`, `webhook.service.ts`, `webhook.repository.ts`, `webhook.routes.ts` e
   `webhook.schemas.ts`, espelhando `src/modules/orders/` ([09:27] Bruno).
2. **A lógica de processamento fica dentro do módulo**, em
   `src/modules/webhooks/webhook.processor.ts`; o entrypoint `src/worker.ts` apenas o aciona
   ([09:28] Bruno; ver [ADR-002](./ADR-002-worker-em-processo-separado-com-polling.md)).
3. **Erros herdam de `AppError`.** As classes novas seguem o mesmo desenho de
   `InvalidStatusTransitionError` e `InsufficientStockError` em `src/shared/errors/http-errors.ts`:
   subclasses tipadas que fixam status HTTP, código e `details` ([09:28] Bruno).
4. **Prefixo `WEBHOOK_` para todos os códigos de erro do módulo** ([09:29] Larissa) —
   `WEBHOOK_NOT_FOUND`, `WEBHOOK_INVALID_URL`, `WEBHOOK_SECRET_REQUIRED` e os demais listados em
   [`docs/FDD.md`](../FDD.md) ([09:28] Bruno).
5. **Nada novo de logging.** O Pino de `src/shared/logger/index.ts` já está no projeto inteiro e é o
   que o módulo e o worker usam ([09:29] Bruno).
6. **O error middleware não muda.** `src/middlewares/error.middleware.ts` já trata `AppError`,
   `ZodError` e erros conhecidos do Prisma; como os erros de webhook herdam de `AppError`, eles são
   serializados corretamente **sem nenhuma alteração no middleware** ([09:29] Bruno).
7. **Validação por Zod via `validate`**, como em `src/modules/orders/order.routes.ts`
   ([09:30] Larissa).
8. **Autorização reaproveita `requireRole`.** O endpoint de replay exige `ADMIN` usando o mesmo
   `requireRole` já aplicado em `src/modules/users/user.routes.ts` ([09:36] Larissa).
9. **Identificadores UUID**, seguindo o padrão dos modelos de entidade em `prisma/schema.prisma`
   ([09:51] Larissa) — a única exceção do schema atual é `OrderNumberSequence`, tabela de sequência
   de linha única com `id` inteiro.
10. **O worker instancia o próprio `PrismaClient`**, pela fábrica `createPrismaClient()` de
    `src/config/database.ts`, apontando para a mesma `DATABASE_URL` — porque `PrismaClient` é por
    processo ([09:30] Bruno).

## Alternativas Consideradas

### A. Worker compartilhando a instância `prisma` exportada por `src/config/database.ts` — **descartada (discutida na reunião)**

Diego levantou o ponto diretamente: o worker abre o mesmo `PrismaClient` ou um separado? ([09:29]).

- **A favor:** um único ponto de configuração de pool, um único `$disconnect` no shutdown.
- **Contra:** não é fisicamente possível compartilhar. `PrismaClient` mantém pool de conexões em
  memória do processo; API e worker são **processos Node distintos**
  ([ADR-002](./ADR-002-worker-em-processo-separado-com-polling.md)), então cada um instancia o seu
  ([09:30] Bruno).
- **Trade-off que motivou o descarte:** não há trade-off real — a alternativa é inviável. O que
  sobra é a consequência operacional: **duas pools contra o mesmo MySQL**, que precisa ser
  considerada no dimensionamento de `max_connections`.

### B. Subsistema com arquitetura própria (camadas/eventos internos dedicados) — **descartada (plausível, não levantada na reunião)**

Tratar webhooks como bounded context separado, com estrutura de pastas e abstrações próprias.

- **A favor:** modelagem mais expressiva para um domínio assíncrono; caminho mais curto para
  extrair o módulo num serviço próprio no futuro.
- **Contra:** introduz um segundo dialeto arquitetural num codebase pequeno e uniforme; qualquer
  pessoa do time passaria a navegar duas convenções. E não há requisito de extração — o time é
  pequeno e prefere não subir infra ([09:07] Diego).
- **Trade-off que motivou o descarte:** expressividade e opcionalidade futura em troca de custo
  cognitivo imediato para todo o time. Larissa fechou na direção oposta: "webhook fica como módulo
  igual aos outros" ([09:30]).

### C. Hierarquia de erros própria do módulo, independente de `AppError` — **descartada (plausível, não levantada na reunião)**

Um `WebhookError` base, desacoplado de HTTP, com tradução para resposta na borda.

- **A favor:** os erros do worker não são erros HTTP — o worker não tem request nem resposta, e um
  `statusCode` ali é semanticamente vazio.
- **Contra:** `src/middlewares/error.middleware.ts` só reconhece `AppError`, `ZodError` e
  `Prisma.PrismaClientKnownRequestError`; qualquer outra coisa cai no ramo genérico de 500. Uma
  hierarquia paralela **obrigaria a alterar o middleware central**, contrariando frontalmente
  "vai pegar nossos erros sem precisar mudar nada" ([09:29] Bruno).
- **Trade-off que motivou o descarte:** pureza semântica em troca de alteração no caminho crítico de
  erro de toda a API. A saída pragmática está registrada nas consequências negativas abaixo.

## Consequências

### Positivas

- **Curva de aprendizado zero.** Quem já mexeu em `src/modules/orders/` sabe onde está cada coisa
  em `src/modules/webhooks/`.
- **Superfície de mudança mínima em código existente.** O error middleware, o `validate`, o
  `authenticate`/`requireRole` e o logger são consumidos como estão, sem alteração
  ([09:29] Bruno).
- **Envelope de erro consistente para o cliente da API.** `WEBHOOK_*` chega ao consumidor no mesmo
  formato `{ error: { code, message, details? } }` de `INSUFFICIENT_STOCK`
  (`src/middlewares/error.middleware.ts`).
- **Testabilidade imediata.** A infraestrutura de teste existente — `tests/setup.ts`,
  `tests/helpers/factories.ts` e o `buildApp` reusável — cobre o módulo novo sem adaptação
  estrutural.
- **Nenhuma dependência nova** no `package.json`: HMAC vem de `node:crypto` e HTTP do `fetch` global
  da runtime (Node ≥ 20, conforme `engines`).

### Negativas

- **`statusCode` é ruído no contexto do worker.** Erros levantados durante a entrega herdam um
  status HTTP de `AppError` que ninguém consome, porque não há request associado. É o preço de não
  criar a hierarquia paralela da alternativa C.
- **O prefixo `WEBHOOK_` não é uniforme entre os módulos.** Os módulos atuais usam códigos sem
  prefixo de domínio (`INSUFFICIENT_STOCK`, `INVALID_STATUS_TRANSITION`); webhooks passa a usar
  prefixo ([09:29] Larissa). O projeto fica com duas convenções de nomenclatura de código de erro
  convivendo.
- **Duas pools de conexão contra o mesmo MySQL** (API e worker), consequência direta da alternativa
  A — exige revisar `max_connections` do banco antes do deploy.
- **O padrão de módulo não tem lugar natural para o processo de background.** `src/worker.ts` fica
  na raiz de `src/`, ao lado de `src/server.ts`, que é o único precedente de entrypoint
  ([09:11] Larissa) — uma extensão do padrão, não uma aplicação dele.
- **Herdamos as limitações dos padrões atuais.** Injeção manual de dependências em
  `src/app.ts` (`buildControllers`) e ausência de camada de use case seguem valendo aqui; qualquer
  dívida existente é replicada, não corrigida.

### Trade-off explícito

Trocamos **modelagem sob medida** por **consistência e velocidade**. Para um time pequeno
([09:07] Diego), com prazo de três sprints ([09:46] Larissa) e um codebase uniforme, a
previsibilidade vale mais do que a expressividade — mesmo pagando com um `statusCode` sem
significado no worker e com duas convenções de código de erro no projeto.

## Referências

- `TRANSCRICAO.md` — [09:07], [09:11], [09:27], [09:28], [09:29], [09:30], [09:36], [09:46], [09:51]
- Código: `src/modules/orders/*`, `src/shared/errors/app-error.ts`,
  `src/shared/errors/http-errors.ts`, `src/shared/errors/index.ts`,
  `src/middlewares/error.middleware.ts`, `src/middlewares/validate.middleware.ts`,
  `src/middlewares/auth.middleware.ts`, `src/modules/users/user.routes.ts`,
  `src/shared/logger/index.ts`, `src/shared/http/response.ts`, `src/config/database.ts`,
  `src/app.ts`, `src/routes/index.ts`, `src/server.ts`, `prisma/schema.prisma`, `package.json`,
  `tests/setup.ts`, `tests/helpers/factories.ts`
- [`docs/FDD.md`](../FDD.md) — Seção "Integração com o sistema existente"
