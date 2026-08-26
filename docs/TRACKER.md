# Tracker de Rastreabilidade — Sistema de Webhooks de Notificação de Pedidos

Este documento é a **referência cruzada** do pacote de design docs. Cada item registrado no PRD, no
RFC, no FDD ou nos ADRs tem aqui uma linha apontando para a sua origem: uma fala da reunião
([`TRANSCRICAO.md`](../TRANSCRICAO.md)) ou um arquivo do código deste repositório.

A função do tracker é **garantir integridade contra alucinação**: se uma linha do PRD ou do FDD não
consegue preencher a coluna *Localização*, ela não tem origem identificável e não deveria estar no
documento.

## Como ler

- **ID** — identificador único do item, prefixado pelo documento e pelo tipo.
- **Documento** — arquivo onde o item aparece.
- **Tipo** — natureza do item (Requisito Funcional, Decisão, Restrição, Trade-off, Contrato, etc.).
- **Conteúdo (resumo)** — descrição de uma linha.
- **Fonte** — `TRANSCRICAO` ou `CODIGO`.
- **Localização** — para `TRANSCRICAO`, `[hh:mm] Nome` do falante. Para `CODIGO`, caminho do arquivo.

### Convenção para itens derivados

Alguns itens não são citação direta, mas **consequência necessária** de uma decisão que foi tomada —
ou detalhes de especificação que a reunião não fechou. Eles aparecem com o marcador
**`⇢ derivado`** no resumo, e a coluna *Localização* aponta para a decisão-mãe. São **25 itens**,
**todos** listados em [Itens derivados](#itens-derivados) ao final, com a justificativa de por que
não são citação literal. Nenhum item do pacote está sem origem, e a contagem é verificada
automaticamente por [`scripts/validate-docs.sh`](../scripts/validate-docs.sh).

---

## 1. PRD — `docs/PRD.md`

### 1.1 Contexto, público e cenários

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| PRD-CTX-01 | docs/PRD.md | Contexto | Três clientes B2B (Atlas Comercial, MaxDistribuição, Nova Cargo) pediram formalmente notificação em tempo real | TRANSCRICAO | `[09:00] Marcos` |
| PRD-CTX-02 | docs/PRD.md | Contexto | Hoje os clientes fazem polling em `GET /orders`, deixando a integração lenta e cara | TRANSCRICAO | `[09:00] Marcos` |
| PRD-CTX-03 | docs/PRD.md | Restrição | Atlas pode migrar para concorrente se não entregarmos até o fim do trimestre | TRANSCRICAO | `[09:00] Marcos` |
| PRD-CTX-04 | docs/PRD.md | Restrição | "Tempo real" para o cliente significa abaixo de 10 segundos | TRANSCRICAO | `[09:02] Marcos` |
| PRD-CTX-05 | docs/PRD.md | Contexto | O OMS não possui hoje nenhum mecanismo de notificação externa, evento ou webhook | CODIGO | `src/routes/index.ts` |
| PRD-CTX-06 | docs/PRD.md | Contexto | Ciclo de vida do pedido tem máquina de estados controlada | CODIGO | `src/modules/orders/order.status.ts` |
| PRD-PERS-01 | docs/PRD.md | Público-alvo | Cliente B2B integrador precisa receber notificação sem polling e validar a origem | TRANSCRICAO | `[09:19] Sofia` |
| PRD-PERS-02 | docs/PRD.md | Público-alvo | Cadastro é feito pela nossa API por usuários do nosso sistema que representam o cliente | TRANSCRICAO | `[09:32] Marcos` |
| PRD-PERS-03 | docs/PRD.md | Restrição | O `customer_id` **não** vem do JWT; é informado no body ou no path | TRANSCRICAO | `[09:32] Larissa` |
| PRD-PERS-04 | docs/PRD.md | Restrição | O JWT atual representa o usuário operador do sistema, não o cliente | TRANSCRICAO | `[09:32] Bruno` |
| PRD-PERS-05 | docs/PRD.md | Público-alvo | Administrador (`ADMIN`) reprocessa eventos com falha permanente | TRANSCRICAO | `[09:36] Sofia` |
| PRD-PERS-06 | docs/PRD.md | Público-alvo | PM documenta a integração no portal do desenvolvedor | TRANSCRICAO | `[09:40] Marcos` |
| PRD-UC-01 | docs/PRD.md | Cenário de uso | Cliente assina só `SHIPPED` e `DELIVERED` para acompanhar envio | TRANSCRICAO | `[09:34] Marcos` |
| PRD-UC-02 | docs/PRD.md | Cenário de uso | Rotação de secret após suspeita de vazamento (já ocorreu com cliente real) | TRANSCRICAO | `[09:22] Diego` |
| PRD-UC-03 | docs/PRD.md | Cenário de uso | Cliente em manutenção planejada de duas horas volta a receber sem intervenção | TRANSCRICAO | `[09:16] Diego` |
| PRD-UC-04 | docs/PRD.md | Cenário de uso | Investigação de "não recebi o evento" via histórico de entregas | TRANSCRICAO | `[09:34] Marcos` |
| PRD-UC-05 | docs/PRD.md | Cenário de uso | Recuperação de falha permanente via replay administrativo | TRANSCRICAO | `[09:35] Diego` |

### 1.2 Objetivos e métricas

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| PRD-OBJ-01 | docs/PRD.md | Objetivo / Métrica | O1 — latência p95 de notificação **< 10 segundos** | TRANSCRICAO | `[09:02] Marcos` |
| PRD-OBJ-02 | docs/PRD.md | Objetivo / Métrica | O2 — **zero** mudanças de status commitadas sem evento registrado | TRANSCRICAO | `[09:40] Bruno` |
| PRD-OBJ-03 | docs/PRD.md | Objetivo / Métrica | O3 — os **3** clientes B2B integrados até o fim de novembro | TRANSCRICAO | `[09:45] Marcos` |
| PRD-OBJ-04 | docs/PRD.md | Objetivo / Métrica | O4 — entrega dentro das 5 retentativas; **a política tem fonte, a meta numérica não** e fica a definir após medir | TRANSCRICAO | `[09:15] Diego` |
| PRD-OBJ-05 | docs/PRD.md | Objetivo / Métrica | O5 — queda no volume de `GET /orders` dos três clientes (linha de base a medir) | TRANSCRICAO | `[09:00] Marcos` |
| PRD-OBJ-06 | docs/PRD.md | Objetivo / Métrica | O6 — entrega em **3 sprints**, com a revisão de segurança incluída | TRANSCRICAO | `[09:46] Larissa` |

### 1.3 Escopo incluído

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| PRD-ESC-01 | docs/PRD.md | Escopo | E1 — CRUD de configuração de webhook | TRANSCRICAO | `[09:33] Bruno` |
| PRD-ESC-02 | docs/PRD.md | Escopo | E2 — filtro de eventos por endpoint | TRANSCRICAO | `[09:33] Marcos` |
| PRD-ESC-03 | docs/PRD.md | Escopo | E3 — entrega assíncrona garantida de eventos de mudança de status | TRANSCRICAO | `[09:06] Diego` |
| PRD-ESC-04 | docs/PRD.md | Escopo | E4 — assinatura HMAC-SHA256 com secret por endpoint | TRANSCRICAO | `[09:22] Sofia` |
| PRD-ESC-05 | docs/PRD.md | Escopo | E5 — rotação de secret com grace period de 24 h | TRANSCRICAO | `[09:21] Sofia` |
| PRD-ESC-06 | docs/PRD.md | Escopo | E6 — retentativa automática com backoff e DLQ | TRANSCRICAO | `[09:17] Larissa` |
| PRD-ESC-07 | docs/PRD.md | Escopo | E7 — consulta do histórico de entregas | TRANSCRICAO | `[09:34] Marcos` |
| PRD-ESC-08 | docs/PRD.md | Escopo | E8 — replay manual de DLQ restrito a `ADMIN` | TRANSCRICAO | `[09:36] Larissa` |

### 1.4 Fora de escopo

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| PRD-OUT-01 | docs/PRD.md | Exclusão (adiado) | F1 — alerta por e-mail ao cliente: "Email tá fora de escopo dessa fase" | TRANSCRICAO | `[09:37] Larissa` |
| PRD-OUT-02 | docs/PRD.md | Exclusão (descartado) | F2 — dashboard/painel visual: "Não, agora não. Só endpoints" | TRANSCRICAO | `[09:40] Larissa` |
| PRD-OUT-03 | docs/PRD.md | Exclusão (adiado) | F3 — rate limiting de saída: "observar e decidir depois" | TRANSCRICAO | `[09:39] Larissa` |
| PRD-OUT-04 | docs/PRD.md | Exclusão | F4 — arquivamento de linhas entregues (~30 dias) declarado fora do escopo | TRANSCRICAO | `[09:08] Diego` |
| PRD-OUT-05 | docs/PRD.md | Exclusão | F5 — webhooks inbound: "Só saindo da gente pra eles" | TRANSCRICAO | `[09:02] Marcos` |
| PRD-OUT-06 | docs/PRD.md | Exclusão (adiado) | F6 — ordenação global e múltiplos workers: "problema do futuro" | TRANSCRICAO | `[09:13] Diego` |
| PRD-OUT-07 | docs/PRD.md | Limitação conhecida | F6 — Larissa registra ordenação global como limitação documentada | TRANSCRICAO | `[09:13] Larissa` |
| PRD-OUT-08 | docs/PRD.md | Exclusão (descartado) | F7 — exactly-once descartado por exigir coordenação dos dois lados | TRANSCRICAO | `[09:25] Diego` |
| PRD-OUT-09 | docs/PRD.md | Exclusão (adiado) | F8 — endurecimento de papéis no CRUD: "Por enquanto sim. Mais pra frente a gente pode endurecer" | TRANSCRICAO | `[09:37] Sofia` |

### 1.5 Requisitos funcionais

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| PRD-FR-01 | docs/PRD.md | Requisito Funcional | Cadastrar webhook com URL, `customer_id` e lista de status; secret gerada pela plataforma | TRANSCRICAO | `[09:31] Marcos` |
| PRD-FR-02 | docs/PRD.md | Requisito Funcional | Editar webhook (`PATCH`) | TRANSCRICAO | `[09:33] Bruno` |
| PRD-FR-03 | docs/PRD.md | Requisito Funcional | Remover webhook (`DELETE`) | TRANSCRICAO | `[09:33] Bruno` |
| PRD-FR-04 | docs/PRD.md | Requisito Funcional | Listar webhooks de um customer (`GET`) | TRANSCRICAO | `[09:33] Bruno` |
| PRD-FR-05 | docs/PRD.md | Requisito Funcional | Filtro de eventos por endpoint, aplicado na inserção da outbox | TRANSCRICAO | `[09:34] Bruno` |
| PRD-FR-06 | docs/PRD.md | Requisito Funcional | Registro do evento atômico com a mudança de status; falha causa rollback | TRANSCRICAO | `[09:40] Bruno` |
| PRD-FR-07 | docs/PRD.md | Requisito Funcional | Entrega por HTTP assinado com headers de identificação e assinatura | TRANSCRICAO | `[09:44] Diego` |
| PRD-FR-08 | docs/PRD.md | Requisito Funcional | Retentativa automática: 5 tentativas, backoff 1m/5m/30m/2h/12h | TRANSCRICAO | `[09:17] Diego` |
| PRD-FR-09 | docs/PRD.md | Requisito Funcional | Falhas permanentes registradas em DLQ com payload, motivo e timestamp | TRANSCRICAO | `[09:18] Diego` |
| PRD-FR-10 | docs/PRD.md | Requisito Funcional | Replay manual de DLQ por `ADMIN`, com registro de autoria | TRANSCRICAO | `[09:35] Diego` |
| PRD-FR-11 | docs/PRD.md | Requisito Funcional | Consulta do histórico de entregas (sucesso/falha, payload, response, tempo) | TRANSCRICAO | `[09:34] Marcos` |
| PRD-FR-12 | docs/PRD.md | Requisito Funcional | Rotação de secret via API, com 24 h de convivência | TRANSCRICAO | `[09:21] Sofia` |
| PRD-FR-13 | docs/PRD.md | Requisito Funcional | Estado ativo/inativo no cadastro; efeito sobre a materialização de eventos ⇢ derivado | TRANSCRICAO | `[09:21] Bruno` |
| PRD-FR-14 | docs/PRD.md | Requisito Funcional | Recusar URL que não seja `https`, com erro de validação | TRANSCRICAO | `[09:23] Sofia` |

### 1.6 Requisitos não funcionais

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| PRD-NFR-01 | docs/PRD.md | Requisito Não Funcional | Latência de notificação abaixo de 10 segundos | TRANSCRICAO | `[09:02] Marcos` |
| PRD-NFR-02 | docs/PRD.md | Requisito Não Funcional | Polling do worker a cada 2 segundos | TRANSCRICAO | `[09:09] Diego` |
| PRD-NFR-03 | docs/PRD.md | Restrição | Latência mínima de 2 s no pior caso, aceita explicitamente | TRANSCRICAO | `[09:10] Larissa` |
| PRD-NFR-04 | docs/PRD.md | Requisito Não Funcional | Timeout de 10 segundos na chamada HTTP ao cliente | TRANSCRICAO | `[09:42] Diego` |
| PRD-NFR-05 | docs/PRD.md | Requisito Não Funcional | Limite de payload de 64 KB, com erro (não truncamento) | TRANSCRICAO | `[09:24] Larissa` |
| PRD-NFR-06 | docs/PRD.md | Restrição | Sofia é a favor de erro em vez de truncar payload grande | TRANSCRICAO | `[09:23] Sofia` |
| PRD-NFR-07 | docs/PRD.md | Requisito Não Funcional | TLS obrigatório: apenas URLs `https` | TRANSCRICAO | `[09:23] Sofia` |
| PRD-NFR-08 | docs/PRD.md | Requisito Não Funcional | Secret única por endpoint, jamais global | TRANSCRICAO | `[09:21] Sofia` |
| PRD-NFR-09 | docs/PRD.md | Requisito Não Funcional | Rotação de secret com grace period de 24 h | TRANSCRICAO | `[09:22] Sofia` |
| PRD-NFR-10 | docs/PRD.md | Requisito Não Funcional | Garantia de entrega *at-least-once* | TRANSCRICAO | `[09:24] Diego` |
| PRD-NFR-11 | docs/PRD.md | Requisito Não Funcional | Ordenação garantida por pedido enquanto houver worker único | TRANSCRICAO | `[09:12] Diego` |
| PRD-NFR-12 | docs/PRD.md | Requisito Não Funcional | Entrega de webhook nunca bloqueia a mudança de status | TRANSCRICAO | `[09:04] Bruno` |
| PRD-NFR-13 | docs/PRD.md | Requisito Não Funcional | Worker em processo separado da API | TRANSCRICAO | `[09:11] Diego` |
| PRD-NFR-14 | docs/PRD.md | Requisito Não Funcional | Auditoria: replay registra quem o executou | TRANSCRICAO | `[09:36] Sofia` |
| PRD-NFR-15 | docs/PRD.md | Requisito Não Funcional | CRUD exige autenticação (qualquer papel nesta fase); replay exige `ADMIN` | TRANSCRICAO | `[09:36] Larissa` |
| PRD-NFR-16 | docs/PRD.md | Requisito Não Funcional | Códigos de erro com prefixo `WEBHOOK_` | TRANSCRICAO | `[09:29] Larissa` |
| PRD-NFR-17 | docs/PRD.md | Requisito Não Funcional | Reuso máximo dos padrões existentes do projeto | TRANSCRICAO | `[09:30] Larissa` |
| PRD-NFR-18 | docs/PRD.md | Requisito Não Funcional | Nenhuma infraestrutura nova | TRANSCRICAO | `[09:07] Diego` |
| PRD-NFR-19 | docs/PRD.md | Requisito Não Funcional | Evento reflete o estado do pedido no momento da mudança (snapshot) | TRANSCRICAO | `[09:52] Larissa` |

### 1.7 Decisões, dependências e riscos

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| PRD-DEC-01 | docs/PRD.md | Decisão / Trade-off | Outbox no MySQL: nenhum evento perdido, ao custo de transação mais longa | TRANSCRICAO | `[09:08] Larissa` |
| PRD-DEC-02 | docs/PRD.md | Decisão / Trade-off | Worker separado em polling 2 s: isolamento, ao custo de piso de latência | TRANSCRICAO | `[09:10] Larissa` |
| PRD-DEC-03 | docs/PRD.md | Decisão / Trade-off | 5 retentativas ~15 h + DLQ: resiliência, ao custo de latência de cauda | TRANSCRICAO | `[09:17] Larissa` |
| PRD-DEC-04 | docs/PRD.md | Trade-off | Marcos aceita atraso de até ~15 h: "ele já tá com problema sério dele" | TRANSCRICAO | `[09:17] Marcos` |
| PRD-DEC-05 | docs/PRD.md | Decisão / Trade-off | HMAC por endpoint: raio de explosão mínimo, ao custo de mais segredos a gerir | TRANSCRICAO | `[09:22] Sofia` |
| PRD-DEC-06 | docs/PRD.md | Decisão / Trade-off | At-least-once: nenhum evento sacrificado, ao custo de dedup no cliente | TRANSCRICAO | `[09:26] Larissa` |
| PRD-DEC-07 | docs/PRD.md | Trade-off | Sofia registra a ressalva: "isso joga responsabilidade pro cliente" | TRANSCRICAO | `[09:25] Sofia` |
| PRD-DEC-08 | docs/PRD.md | Decisão / Trade-off | Reuso de padrões: velocidade, ao custo de modelagem sob medida | TRANSCRICAO | `[09:30] Larissa` |
| PRD-DEC-09 | docs/PRD.md | Decisão / Trade-off | Snapshot do payload: fidelidade histórica, ao custo de dado defasado | TRANSCRICAO | `[09:52] Larissa` |
| PRD-DEP-01 | docs/PRD.md | Dependência | Banco MySQL existente hospeda a outbox; sem infraestrutura nova | TRANSCRICAO | `[09:07] Diego` |
| PRD-DEP-02 | docs/PRD.md | Dependência | Worker usa a mesma `DATABASE_URL`, com `PrismaClient` próprio | TRANSCRICAO | `[09:30] Bruno` |
| PRD-DEP-03 | docs/PRD.md | Dependência | Ponto de integração no `changeStatus` do módulo de pedidos | CODIGO | `src/modules/orders/order.service.ts` |
| PRD-DEP-04 | docs/PRD.md | Dependência | Reuso do `requireRole` existente para exigir `ADMIN` no replay | CODIGO | `src/middlewares/auth.middleware.ts` |
| PRD-DEP-05 | docs/PRD.md | Dependência | Reuso de `AppError`, Pino e error middleware sem alteração | TRANSCRICAO | `[09:29] Bruno` |
| PRD-DEP-06 | docs/PRD.md | Dependência (bloqueante) | Revisão de segurança da Sofia: mínimo 2 dias úteis antes do deploy | TRANSCRICAO | `[09:46] Sofia` |
| PRD-DEP-07 | docs/PRD.md | Dependência (bloqueante) | Sessão de revisão do design com Bruno e Diego antes de codar | TRANSCRICAO | `[09:50] Larissa` |
| PRD-DEP-08 | docs/PRD.md | Dependência | Documentação da integração no portal do desenvolvedor | TRANSCRICAO | `[09:40] Marcos` |
| PRD-DEP-09 | docs/PRD.md | Dependência | Documentação destacada da garantia at-least-once no portal | TRANSCRICAO | `[09:26] Marcos` |
| PRD-DEP-10 | docs/PRD.md | Dependência | Confirmação de prazo com a Atlas | TRANSCRICAO | `[09:47] Marcos` |
| PRD-DEP-11 | docs/PRD.md | Dependência | Capacidade do time: 3 sprints com a quebra estimada por Larissa | TRANSCRICAO | `[09:46] Larissa` |
| PRD-RISK-01 | docs/PRD.md | Risco | R1 — perder a Atlas por atraso (prob. Média / impacto Alto) | TRANSCRICAO | `[09:00] Marcos` |
| PRD-RISK-02 | docs/PRD.md | Risco | R2 — vazamento de secret pelo cliente (prob. Média / impacto Alto) | TRANSCRICAO | `[09:22] Diego` |
| PRD-RISK-03 | docs/PRD.md | Risco | R3 — cliente processar evento duplicado (prob. Média / impacto Médio) | TRANSCRICAO | `[09:25] Sofia` |
| PRD-RISK-04 | docs/PRD.md | Risco | R4 — worker fora do ar sem ninguém perceber (prob. Baixa / impacto Alto) | TRANSCRICAO | `[09:11] Diego` |
| PRD-RISK-05 | docs/PRD.md | Risco | R5 — bombardear cliente com muitas chamadas (prob. Média / impacto Médio) | TRANSCRICAO | `[09:38] Diego` |
| PRD-RISK-06 | docs/PRD.md | Risco | R6 — crescimento não controlado da tabela de eventos (prob. Alta / impacto Médio) | TRANSCRICAO | `[09:07] Bruno` |
| PRD-RISK-07 | docs/PRD.md | Risco | R7 — evento chegar com até ~15 h de atraso (prob. Baixa / impacto Baixo) | TRANSCRICAO | `[09:17] Marcos` |
| PRD-RISK-08 | docs/PRD.md | Risco | R8 — mudança de status falhar por causa do webhook (prob. Baixa / impacto Alto) | TRANSCRICAO | `[09:41] Diego` |
| PRD-TEST-01 | docs/PRD.md | Estratégia de teste | Testes ponta a ponta e integração no order.service estimados em meia sprint | TRANSCRICAO | `[09:46] Larissa` |
| PRD-TEST-02 | docs/PRD.md | Estratégia de teste | Infraestrutura de teste existente (Vitest + Supertest sobre `buildApp`) | CODIGO | `tests/orders.test.ts` |
| PRD-TEST-03 | docs/PRD.md | Estratégia de teste | Execução serial dos testes já configurada | CODIGO | `vitest.config.ts` |
| PRD-TEST-04 | docs/PRD.md | Estratégia de teste | Cenário: ordem preservada por pedido em transições rápidas | TRANSCRICAO | `[09:12] Larissa` |
| PRD-TEST-05 | docs/PRD.md | Estratégia de teste | Cenário: rollback transacional em falha de registro do evento | TRANSCRICAO | `[09:40] Bruno` |
| PRD-TEST-06 | docs/PRD.md | Estratégia de teste | Cenário: convivência de secrets durante a janela de 24 h | TRANSCRICAO | `[09:21] Sofia` |
| PRD-TEST-07 | docs/PRD.md | Estratégia de teste | Revisão manual de segurança sobre HMAC e geração de secret | TRANSCRICAO | `[09:46] Sofia` |

---

## 2. RFC — `docs/RFC.md`

### 2.1 Metadados e proposta

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| RFC-META-01 | docs/RFC.md | Metadado | Larissa como autora: assumiu abrir o doc de design da feature | TRANSCRICAO | `[09:50] Larissa` |
| RFC-META-02 | docs/RFC.md | Metadado | Bruno e Diego como revisores em sessão a marcar antes de codar | TRANSCRICAO | `[09:50] Larissa` |
| RFC-META-03 | docs/RFC.md | Metadado | Sofia como revisora de segurança, com 2 dias úteis antes do deploy | TRANSCRICAO | `[09:46] Sofia` |
| RFC-META-04 | docs/RFC.md | Metadado | Marcos como revisor de escopo e prazo | TRANSCRICAO | `[09:45] Marcos` |
| RFC-PROP-01 | docs/RFC.md | Proposta | Outbox: evento gravado na mesma transação SQL da mudança de status | TRANSCRICAO | `[09:06] Diego` |
| RFC-PROP-02 | docs/RFC.md | Proposta | Falha ao gravar na outbox aborta a mudança de status | TRANSCRICAO | `[09:41] Diego` |
| RFC-PROP-03 | docs/RFC.md | Proposta | `publishWebhookEvent(tx, order, fromStatus, toStatus)` como função que recebe o tx | TRANSCRICAO | `[09:41] Bruno` |
| RFC-PROP-04 | docs/RFC.md | Proposta | Worker como novo entrypoint `src/worker.ts` + script `npm run worker` | TRANSCRICAO | `[09:11] Larissa` |
| RFC-PROP-05 | docs/RFC.md | Proposta | Polling porque o MySQL não tem `LISTEN`/`NOTIFY` como o Postgres | TRANSCRICAO | `[09:09] Diego` |
| RFC-PROP-06 | docs/RFC.md | Proposta | Backoff 1m/5m/30m/2h/12h com 5 retentativas | TRANSCRICAO | `[09:17] Diego` |
| RFC-PROP-07 | docs/RFC.md | Proposta | DLQ em tabela `webhook_dead_letter` com payload, motivo e timestamp | TRANSCRICAO | `[09:18] Diego` |
| RFC-PROP-08 | docs/RFC.md | Proposta | HMAC-SHA256 sobre o corpo, header `X-Signature`, verificado pelo cliente | TRANSCRICAO | `[09:20] Sofia` |
| RFC-PROP-09 | docs/RFC.md | Proposta | `X-Event-Id` com UUID gerado na inserção da outbox, para dedup no cliente | TRANSCRICAO | `[09:25] Diego` |
| RFC-PROP-10 | docs/RFC.md | Proposta | Módulo `src/modules/webhooks` seguindo o padrão dos módulos existentes | TRANSCRICAO | `[09:27] Bruno` |
| RFC-PROP-11 | docs/RFC.md | Proposta | Snapshot do payload renderizado na inserção | TRANSCRICAO | `[09:52] Larissa` |
| RFC-PROP-12 | docs/RFC.md | Restrição | Todas as rotas ficam sob o prefixo `/api/v1` | CODIGO | `src/app.ts` |

### 2.2 Alternativas consideradas

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| RFC-ALT-01 | docs/RFC.md | Alternativa descartada | Disparo HTTP síncrono no `changeStatus` — trava mudança de status de outros pedidos | TRANSCRICAO | `[09:04] Bruno` |
| RFC-ALT-02 | docs/RFC.md | Alternativa descartada | Síncrono também não tem rollback aceitável se o cliente estiver fora do ar | TRANSCRICAO | `[09:04] Bruno` |
| RFC-ALT-03 | docs/RFC.md | Alternativa descartada | Diego encerra: "síncrono está fora de questão" | TRANSCRICAO | `[09:06] Diego` |
| RFC-ALT-04 | docs/RFC.md | Alternativa descartada | Redis Streams — exigiria subir mais infraestrutura | TRANSCRICAO | `[09:07] Larissa` |
| RFC-ALT-05 | docs/RFC.md | Trade-off | Redis é overengineering para o time; outbox no MySQL resolve | TRANSCRICAO | `[09:07] Diego` |
| RFC-ALT-06 | docs/RFC.md | Alternativa descartada | Trigger de banco para ser mais reativo | TRANSCRICAO | `[09:09] Bruno` |
| RFC-ALT-07 | docs/RFC.md | Trade-off | Trigger só executa SQL e não notifica processo externo; MySQL sem `NOTIFY`/`LISTEN` | TRANSCRICAO | `[09:09] Diego` |
| RFC-ALT-08 | docs/RFC.md | Alternativa descartada | Exactly-once — exigiria coordenação dos dois lados | TRANSCRICAO | `[09:25] Diego` |
| RFC-ALT-09 | docs/RFC.md | Alternativa descartada | Secret global da plataforma — "se vaza uma, vaza tudo" | TRANSCRICAO | `[09:21] Sofia` |
| RFC-ALT-10 | docs/RFC.md | Alternativa descartada | DLQ como flag `failed` na própria outbox | TRANSCRICAO | `[09:17] Larissa` |
| RFC-ALT-11 | docs/RFC.md | Trade-off | Tabela separada mantém a outbox principal limpa e serve de evidência | TRANSCRICAO | `[09:18] Diego` |
| RFC-ALT-12 | docs/RFC.md | Alternativa descartada | 3 retentativas em vez de 5 — "mais agressivo" | TRANSCRICAO | `[09:16] Bruno` |
| RFC-ALT-13 | docs/RFC.md | Trade-off | 3 é pouco: cliente com indisponibilidade de manhã seria morto em 30 minutos | TRANSCRICAO | `[09:16] Diego` |
| RFC-ALT-14 | docs/RFC.md | Alternativa descartada | Retry indefinido com backoff — evento fica pendurado para sempre | TRANSCRICAO | `[09:15] Diego` |
| RFC-ALT-15 | docs/RFC.md | Alternativa descartada | Guardar só `order_id` e renderizar no envio | TRANSCRICAO | `[09:51] Bruno` |

### 2.3 Questões em aberto

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| RFC-QA-01 | docs/RFC.md | Questão em aberto | Q1 — rate limiting de saída: 50 pedidos em um minuto viram 50 chamadas? | TRANSCRICAO | `[09:38] Diego` |
| RFC-QA-02 | docs/RFC.md | Questão em aberto | Q1 — decisão: "Fica como observar e decidir depois" | TRANSCRICAO | `[09:39] Larissa` |
| RFC-QA-03 | docs/RFC.md | Questão em aberto | Q2 — endurecimento da autorização do CRUD: "Mais pra frente a gente pode endurecer" | TRANSCRICAO | `[09:37] Sofia` |
| RFC-QA-04 | docs/RFC.md | Questão em aberto | Q3 — escala com múltiplos workers: particionar por `order_id` ou lock pessimista | TRANSCRICAO | `[09:13] Diego` |
| RFC-QA-05 | docs/RFC.md | Questão em aberto | Q4 — arquivamento das linhas entregues após ~30 dias, sem política definida | TRANSCRICAO | `[09:08] Diego` |
| RFC-QA-06 | docs/RFC.md | Questão em aberto | Q5 — alerta por e-mail condicionado a "depois que a gente medir o impacto" | TRANSCRICAO | `[09:37] Larissa` |
| RFC-QA-07 | docs/RFC.md | Questão em aberto | Q6 — armazenamento da secret em repouso (claro vs. cifrado) não foi decidido ⇢ derivado | TRANSCRICAO | `[09:21] Bruno` |
| RFC-QA-08 | docs/RFC.md | Questão em aberto | Q6 — contraste: senha de usuário é armazenada como hash bcrypt | CODIGO | `prisma/schema.prisma` |
| RFC-QA-09 | docs/RFC.md | Questão em aberto | Q7 — semântica do grace period em fluxo outbound exige assinatura dupla ⇢ derivado | TRANSCRICAO | `[09:21] Sofia` |
| RFC-QA-10 | docs/RFC.md | Questão em aberto | Q8 — rotação disparada com janela de grace já aberta não foi tratada ⇢ derivado | TRANSCRICAO | `[09:21] Sofia` |

### 2.4 Impacto

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| RFC-IMP-01 | docs/RFC.md | Impacto | Alteração única em código de domínio: o `changeStatus` | CODIGO | `src/modules/orders/order.service.ts` |
| RFC-IMP-02 | docs/RFC.md | Impacto | Registro do módulo exige alterar a fiação de controllers e o router | CODIGO | `src/app.ts` |
| RFC-IMP-03 | docs/RFC.md | Impacto | Error middleware, validate, auth e logger consumidos sem alteração | TRANSCRICAO | `[09:29] Bruno` |
| RFC-IMP-04 | docs/RFC.md | Impacto | Novas tabelas no schema; nenhuma tabela existente é alterada | CODIGO | `prisma/schema.prisma` |
| RFC-IMP-05 | docs/RFC.md | Impacto | Duas pools de conexão contra o mesmo MySQL (API + worker) | TRANSCRICAO | `[09:30] Bruno` |
| RFC-IMP-06 | docs/RFC.md | Impacto | Novo artefato de deploy operado pelo time | TRANSCRICAO | `[09:11] Diego` |
| RFC-IMP-07 | docs/RFC.md | Impacto | Contrato público com garantia at-least-once, exigindo dedup no cliente | TRANSCRICAO | `[09:24] Diego` |
| RFC-IMP-08 | docs/RFC.md | Impacto | Cronograma de 3 sprints com a revisão de segurança ao final | TRANSCRICAO | `[09:47] Larissa` |

---

## 3. FDD — `docs/FDD.md`

### 3.1 Objetivos técnicos e escopo

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| FDD-OT-01 | docs/FDD.md | Objetivo técnico | OT-1 — publicar o evento na mesma transação da mudança de status | TRANSCRICAO | `[09:06] Diego` |
| FDD-OT-02 | docs/FDD.md | Objetivo técnico | OT-2 — entregar em menos de 10 s no caminho feliz | TRANSCRICAO | `[09:02] Marcos` |
| FDD-OT-03 | docs/FDD.md | Objetivo técnico | OT-3 — isolar o ciclo de vida da entrega do ciclo de vida da API | TRANSCRICAO | `[09:11] Diego` |
| FDD-OT-04 | docs/FDD.md | Objetivo técnico | OT-4 — não perder evento por falha transitória (5 retentativas + DLQ) | TRANSCRICAO | `[09:15] Diego` |
| FDD-OT-05 | docs/FDD.md | Objetivo técnico | OT-5 — assinar todo envio de forma verificável pelo cliente | TRANSCRICAO | `[09:22] Sofia` |
| FDD-OT-06 | docs/FDD.md | Objetivo técnico | OT-6 — não introduzir infraestrutura nem dependência nova | TRANSCRICAO | `[09:07] Diego` |
| FDD-OT-07 | docs/FDD.md | Objetivo técnico | OT-7 — aderir integralmente aos padrões do codebase | TRANSCRICAO | `[09:30] Larissa` |
| FDD-ESC-01 | docs/FDD.md | Escopo | Módulo, worker, HMAC, replay e gancho transacional dentro do escopo | TRANSCRICAO | `[09:48] Larissa` |
| FDD-ESC-02 | docs/FDD.md | Exclusão | Mesma lista de exclusões do PRD (F1 a F8) | TRANSCRICAO | `[09:48] Larissa` |

### 3.2 Modelo de dados

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| FDD-MODEL-01 | docs/FDD.md | Modelagem | Tabela `webhook_outbox` para os eventos pendentes de entrega | TRANSCRICAO | `[09:06] Diego` |
| FDD-MODEL-02 | docs/FDD.md | Modelagem | Estados da outbox: pendente, processando, falhou, entregue | TRANSCRICAO | `[09:08] Diego` |
| FDD-MODEL-03 | docs/FDD.md | Modelagem | Índice no campo de status e em `created_at` | TRANSCRICAO | `[09:08] Diego` |
| FDD-MODEL-04 | docs/FDD.md | Modelagem | Tabela `webhook_dead_letter` com payload, motivo da falha e timestamp | TRANSCRICAO | `[09:18] Diego` |
| FDD-MODEL-05 | docs/FDD.md | Modelagem | Cadastro armazena url + secret + customer_id + estado ativo | TRANSCRICAO | `[09:21] Bruno` |
| FDD-MODEL-06 | docs/FDD.md | Modelagem | Colunas de rotação: secret anterior e prazo de validade de 24 h | TRANSCRICAO | `[09:21] Sofia` |
| FDD-MODEL-07 | docs/FDD.md | Modelagem | Histórico de entregas com sucesso/falha, payload, response e tempo de resposta | TRANSCRICAO | `[09:34] Marcos` |
| FDD-MODEL-08 | docs/FDD.md | Decisão | Chave primária UUID, seguindo o padrão do resto do projeto | TRANSCRICAO | `[09:51] Larissa` |
| FDD-MODEL-09 | docs/FDD.md | Restrição | Padrão real do projeto: `@id @default(uuid()) @db.Char(36)` e `@@map` em snake_case | CODIGO | `prisma/schema.prisma` |
| FDD-MODEL-10 | docs/FDD.md | Modelagem | Uma linha de outbox por (evento × endpoint assinante), porque retry é por endpoint ⇢ derivado | TRANSCRICAO | `[09:44] Sofia` |
| FDD-MODEL-11 | docs/FDD.md | Modelagem | Índice composto `(status, nextAttemptAt)` para cobrir eventos em espera de retry ⇢ derivado | TRANSCRICAO | `[09:17] Diego` |
| FDD-MODEL-12 | docs/FDD.md | Restrição | `subscribedStatuses` como `Json`, seguindo o precedente de `Customer.address` | CODIGO | `prisma/schema.prisma` |
| FDD-MODEL-13 | docs/FDD.md | Restrição | Valores válidos de assinatura vêm do enum `OrderStatus` | CODIGO | `src/modules/orders/order.status.ts` |
| FDD-MODEL-14 | docs/FDD.md | Modelagem | Estado terminal `DEAD_LETTERED` para a linha de origem sair da fila de trabalho ⇢ derivado | TRANSCRICAO | `[09:18] Diego` |
| FDD-MODEL-15 | docs/FDD.md | Restrição | Relações declaradas nos dois lados, como exige o Prisma e como faz o schema atual | CODIGO | `prisma/schema.prisma` |
| FDD-MODEL-16 | docs/FDD.md | Restrição | UUID é o padrão das entidades; `OrderNumberSequence` usa `id` inteiro | CODIGO | `prisma/schema.prisma` |

### 3.3 Fluxos

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| FDD-FLUXO-01 | docs/FDD.md | Fluxo | Publicação entra no `$transaction` do `changeStatus`, após a gravação do histórico | CODIGO | `src/modules/orders/order.service.ts` |
| FDD-FLUXO-02 | docs/FDD.md | Fluxo | A transação atual já atualiza `orders`, insere no histórico e movimenta estoque | TRANSCRICAO | `[09:04] Bruno` |
| FDD-FLUXO-03 | docs/FDD.md | Fluxo | `publishWebhookEvent` recebe o transaction client, sem injetar repositório | TRANSCRICAO | `[09:41] Bruno` |
| FDD-FLUXO-04 | docs/FDD.md | Fluxo | Diego aprova a assinatura: "função pura recebendo o tx" | TRANSCRICAO | `[09:41] Diego` |
| FDD-FLUXO-05 | docs/FDD.md | Fluxo | Filtragem de assinantes acontece na inserção, não no envio | TRANSCRICAO | `[09:34] Bruno` |
| FDD-FLUXO-06 | docs/FDD.md | Fluxo | Se nenhum webhook assina aquele status, nem insere linha | TRANSCRICAO | `[09:34] Bruno` |
| FDD-FLUXO-07 | docs/FDD.md | Fluxo | Payload renderizado como snapshot no momento da inserção | TRANSCRICAO | `[09:52] Larissa` |
| FDD-FLUXO-08 | docs/FDD.md | Fluxo | Worker lê os pendentes mais antigos em batch pequeno a cada 2 s | TRANSCRICAO | `[09:09] Diego` |
| FDD-FLUXO-09 | docs/FDD.md | Fluxo | Worker instancia `PrismaClient` próprio, mesma `DATABASE_URL` | TRANSCRICAO | `[09:30] Bruno` |
| FDD-FLUXO-10 | docs/FDD.md | Fluxo | Processamento sequencial em ordem de `created_at` garante ordem por pedido | TRANSCRICAO | `[09:12] Diego` |
| FDD-FLUXO-11 | docs/FDD.md | Fluxo | Reivindicação de linha travada em `PROCESSING` após 60 s ⇢ derivado | TRANSCRICAO | `[09:42] Diego` |
| FDD-FLUXO-12 | docs/FDD.md | Fluxo | Falha é: não-2xx, timeout de 10 s ou erro de conexão | TRANSCRICAO | `[09:42] Diego` |
| FDD-FLUXO-13 | docs/FDD.md | Fluxo | Escada de retry completa: 6 envios, ~14h36min desde a primeira falha | TRANSCRICAO | `[09:17] Diego` |
| FDD-FLUXO-14 | docs/FDD.md | Fluxo | Esgotadas as retentativas, o evento vai para a DLQ | TRANSCRICAO | `[09:15] Diego` |
| FDD-FLUXO-15 | docs/FDD.md | Fluxo | Replay recoloca o evento na outbox como pendente | TRANSCRICAO | `[09:18] Diego` |
| FDD-FLUXO-16 | docs/FDD.md | Fluxo | Replay grava autoria e emite log de auditoria | TRANSCRICAO | `[09:36] Sofia` |
| FDD-FLUXO-17 | docs/FDD.md | Fluxo | Rotação move a secret atual para "anterior" com validade de 24 h | TRANSCRICAO | `[09:21] Sofia` |
| FDD-FLUXO-18 | docs/FDD.md | Restrição | Passadas as 24 h, a secret antiga morre | TRANSCRICAO | `[09:21] Sofia` |
| FDD-FLUXO-19 | docs/FDD.md | Restrição | Limite de 64 KB avaliado **dentro da transação**, propagando erro para `changeStatus` ⇢ derivado | TRANSCRICAO | `[09:24] Larissa` |
| FDD-FLUXO-20 | docs/FDD.md | Fluxo | Guarda de reentrada: um ciclo lento não pode sobrepor o seguinte, senão a ordenação se perde ⇢ derivado | TRANSCRICAO | `[09:12] Diego` |

### 3.4 Contratos públicos

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| FDD-CONTRATO-01 | docs/FDD.md | Contrato | `POST /api/v1/webhooks` — cadastro com url, customer_id e lista de status | TRANSCRICAO | `[09:31] Marcos` |
| FDD-CONTRATO-02 | docs/FDD.md | Contrato | Secret é gerada pela plataforma e devolvida na criação | TRANSCRICAO | `[09:31] Marcos` |
| FDD-CONTRATO-03 | docs/FDD.md | Contrato | `GET /api/v1/webhooks` — listar webhooks de um customer | TRANSCRICAO | `[09:33] Bruno` |
| FDD-CONTRATO-04 | docs/FDD.md | Contrato | `PATCH /api/v1/webhooks/:id` — editar | TRANSCRICAO | `[09:33] Bruno` |
| FDD-CONTRATO-05 | docs/FDD.md | Contrato | `DELETE /api/v1/webhooks/:id` — remover | TRANSCRICAO | `[09:33] Bruno` |
| FDD-CONTRATO-06 | docs/FDD.md | Contrato | `POST /api/v1/webhooks/:id/secret/rotate` — endpoint de rotação de secret | TRANSCRICAO | `[09:21] Sofia` |
| FDD-CONTRATO-07 | docs/FDD.md | Contrato | `GET /api/v1/webhooks/:id/deliveries` — histórico de entregas | TRANSCRICAO | `[09:34] Marcos` |
| FDD-CONTRATO-08 | docs/FDD.md | Contrato | `POST /api/v1/admin/webhooks/dead-letter/:id/replay` — replay administrativo | TRANSCRICAO | `[09:35] Diego` |
| FDD-CONTRATO-09 | docs/FDD.md | Restrição | Replay exige role `ADMIN`, reaproveitando o `requireRole` existente | TRANSCRICAO | `[09:36] Larissa` |
| FDD-CONTRATO-10 | docs/FDD.md | Restrição | CRUD de configuração pode ser feito por qualquer papel autenticado, por enquanto | TRANSCRICAO | `[09:37] Sofia` |
| FDD-CONTRATO-11 | docs/FDD.md | Contrato | Payload outbound: event_id, event_type, timestamp, order_id, order_number, from/to_status, customer_id, total_cents | TRANSCRICAO | `[09:43] Diego` |
| FDD-CONTRATO-12 | docs/FDD.md | Restrição | `items` não vão no payload; cliente consulta `GET /orders/:id` se precisar | TRANSCRICAO | `[09:43] Diego` |
| FDD-CONTRATO-13 | docs/FDD.md | Contrato | Header `X-Event-Id` com o UUID do evento | TRANSCRICAO | `[09:44] Diego` |
| FDD-CONTRATO-14 | docs/FDD.md | Contrato | Header `X-Signature` com o HMAC | TRANSCRICAO | `[09:44] Diego` |
| FDD-CONTRATO-15 | docs/FDD.md | Contrato | Header `X-Timestamp` para o cliente detectar replay attack | TRANSCRICAO | `[09:44] Diego` |
| FDD-CONTRATO-16 | docs/FDD.md | Contrato | Header `X-Webhook-Id` com o id do cadastro de webhook | TRANSCRICAO | `[09:44] Sofia` |
| FDD-CONTRATO-17 | docs/FDD.md | Contrato | `Content-Type: application/json` | TRANSCRICAO | `[09:44] Diego` |
| FDD-CONTRATO-18 | docs/FDD.md | Contrato | Assinatura dupla no `X-Signature` durante a janela de rotação ⇢ derivado | TRANSCRICAO | `[09:21] Sofia` |
| FDD-CONTRATO-19 | docs/FDD.md | Restrição | Todos os caminhos ganham o prefixo `/api/v1` montado no app | CODIGO | `src/app.ts` |
| FDD-CONTRATO-20 | docs/FDD.md | Restrição | Envelope de erro `{ error: { code, message, details? } }` | CODIGO | `src/middlewares/error.middleware.ts` |
| FDD-CONTRATO-21 | docs/FDD.md | Restrição | Envelope de listagem `{ data, pagination }` | CODIGO | `src/shared/http/response.ts` |
| FDD-CONTRATO-22 | docs/FDD.md | Restrição | `pageSize` máximo de 100, alinhado ao schema de listagem existente | CODIGO | `src/modules/orders/order.schemas.ts` |
| FDD-CONTRATO-23 | docs/FDD.md | Restrição | `DELETE` responde `204` sem corpo, como nos módulos existentes | CODIGO | `src/modules/orders/order.controller.ts` |
| FDD-CONTRATO-24 | docs/FDD.md | Proposta | Formato do header: `sha256=<hex>` — algoritmo e header vêm da reunião, a serialização não ⇢ derivado | TRANSCRICAO | `[09:44] Diego` |
| FDD-CONTRATO-25 | docs/FDD.md | Proposta | Formato da secret `whsec_` + 32 bytes aleatórios — a reunião definiu só que é gerada por nós ⇢ derivado | TRANSCRICAO | `[09:31] Marcos` |
| FDD-CONTRATO-26 | docs/FDD.md | Proposta | Replay responde `202 Accepted` — a reunião definiu o efeito, não o status HTTP ⇢ derivado | TRANSCRICAO | `[09:18] Diego` |
| FDD-CONTRATO-27 | docs/FDD.md | Proposta | `responseBody` truncado em 2 KB — a reunião pediu a resposta no histórico, sem definir tamanho ⇢ derivado | TRANSCRICAO | `[09:34] Marcos` |

### 3.5 Matriz de erros

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| FDD-ERRO-01 | docs/FDD.md | Restrição | Prefixo `WEBHOOK_` em todos os códigos de erro do módulo | TRANSCRICAO | `[09:29] Larissa` |
| FDD-ERRO-02 | docs/FDD.md | Erro | `WEBHOOK_NOT_FOUND` | TRANSCRICAO | `[09:28] Bruno` |
| FDD-ERRO-03 | docs/FDD.md | Erro | `WEBHOOK_INVALID_URL` | TRANSCRICAO | `[09:28] Bruno` |
| FDD-ERRO-04 | docs/FDD.md | Erro | `WEBHOOK_SECRET_REQUIRED` | TRANSCRICAO | `[09:28] Bruno` |
| FDD-ERRO-05 | docs/FDD.md | Erro | `WEBHOOK_PAYLOAD_TOO_LARGE` — payload acima de 64 KB | TRANSCRICAO | `[09:24] Larissa` |
| FDD-ERRO-06 | docs/FDD.md | Erro | `WEBHOOK_INVALID_EVENT_FILTER` — status fora do enum `OrderStatus` ⇢ derivado | TRANSCRICAO | `[09:33] Marcos` |
| FDD-ERRO-07 | docs/FDD.md | Erro | `WEBHOOK_INACTIVE` — operação sobre endpoint inativo ⇢ derivado | TRANSCRICAO | `[09:21] Bruno` |
| FDD-ERRO-08 | docs/FDD.md | Erro | `WEBHOOK_DEAD_LETTER_NOT_FOUND` — replay de id inexistente ⇢ derivado | TRANSCRICAO | `[09:35] Diego` |
| FDD-ERRO-09 | docs/FDD.md | Erro | `WEBHOOK_ALREADY_REPLAYED` — replay de item já reprocessado ⇢ derivado | TRANSCRICAO | `[09:18] Diego` |
| FDD-ERRO-10 | docs/FDD.md | Erro | `WEBHOOK_ROTATION_IN_PROGRESS` — proposta ligada à questão em aberto Q8 ⇢ derivado | TRANSCRICAO | `[09:21] Sofia` |
| FDD-ERRO-11 | docs/FDD.md | Erro (worker) | `WEBHOOK_DELIVERY_TIMEOUT` — sem resposta em 10 s | TRANSCRICAO | `[09:42] Diego` |
| FDD-ERRO-12 | docs/FDD.md | Erro (worker) | `WEBHOOK_DELIVERY_FAILED` — resposta não-2xx | TRANSCRICAO | `[09:15] Diego` |
| FDD-ERRO-13 | docs/FDD.md | Erro (worker) | `WEBHOOK_RETRIES_EXHAUSTED` — 5ª retentativa falhou | TRANSCRICAO | `[09:15] Diego` |
| FDD-ERRO-14 | docs/FDD.md | Restrição | Erros novos herdam de `AppError`, como `InsufficientStockError` | TRANSCRICAO | `[09:28] Bruno` |
| FDD-ERRO-15 | docs/FDD.md | Restrição | Padrão real das classes de erro do projeto | CODIGO | `src/shared/errors/http-errors.ts` |
| FDD-ERRO-16 | docs/FDD.md | Restrição | `AppError` com statusCode, errorCode e details | CODIGO | `src/shared/errors/app-error.ts` |
| FDD-ERRO-17 | docs/FDD.md | Restrição | Barril de exportação das classes de erro | CODIGO | `src/shared/errors/index.ts` |
| FDD-ERRO-18 | docs/FDD.md | Restrição | Middleware central já trata AppError, Zod e Prisma sem precisar mudar | TRANSCRICAO | `[09:29] Bruno` |
| FDD-ERRO-19 | docs/FDD.md | Restrição | `FORBIDDEN` no replay vem do `requireRole` existente, sem prefixo `WEBHOOK_` | CODIGO | `src/middlewares/auth.middleware.ts` |
| FDD-ERRO-20 | docs/FDD.md | Restrição | `VALIDATION_ERROR` vem do middleware de validação Zod existente | CODIGO | `src/middlewares/validate.middleware.ts` |

### 3.6 Resiliência

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| FDD-RESIL-01 | docs/FDD.md | Resiliência | Timeout de 10 s na chamada HTTP ao cliente | TRANSCRICAO | `[09:42] Diego` |
| FDD-RESIL-02 | docs/FDD.md | Resiliência | Backoff exponencial 1m/5m/30m/2h/12h | TRANSCRICAO | `[09:17] Diego` |
| FDD-RESIL-03 | docs/FDD.md | Resiliência | 5 retentativas; janela total de ~15 h entre a 1ª falha e a última tentativa | TRANSCRICAO | `[09:17] Diego` |
| FDD-RESIL-04 | docs/FDD.md | Trade-off | Cinco cobre janela de 12 a 24 h; retry indefinido deixaria evento pendurado | TRANSCRICAO | `[09:15] Diego` |
| FDD-RESIL-05 | docs/FDD.md | Resiliência | Fallback final: DLQ persistida + replay manual | TRANSCRICAO | `[09:18] Diego` |
| FDD-RESIL-06 | docs/FDD.md | Resiliência | Worker fora do ar não perde evento: acumula na outbox e drena no restart | TRANSCRICAO | `[09:06] Diego` |
| FDD-RESIL-07 | docs/FDD.md | Resiliência | Falha ao inserir na outbox faz rollback da mudança de status | TRANSCRICAO | `[09:40] Bruno` |
| FDD-RESIL-08 | docs/FDD.md | Resiliência | Batch pequeno por ciclo evita monopolizar o worker | TRANSCRICAO | `[09:08] Diego` |
| FDD-RESIL-09 | docs/FDD.md | Restrição | Sem rate limiting de saída nesta fase, por decisão | TRANSCRICAO | `[09:39] Diego` |
| FDD-RESIL-10 | docs/FDD.md | Restrição | Sem fallback por e-mail nesta fase | TRANSCRICAO | `[09:37] Larissa` |
| FDD-RESIL-11 | docs/FDD.md | Restrição | `AbortSignal.timeout` e `fetch` global disponíveis por exigir Node ≥ 20 | CODIGO | `package.json` |

### 3.7 Observabilidade

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| FDD-OBS-01 | docs/FDD.md | Observabilidade | Logger Pino já no projeto inteiro; nada novo de logging | TRANSCRICAO | `[09:29] Bruno` |
| FDD-OBS-02 | docs/FDD.md | Observabilidade | Configuração real do Pino, com `redactPaths` e base de serviço | CODIGO | `src/shared/logger/index.ts` |
| FDD-OBS-03 | docs/FDD.md | Observabilidade | Convenção de nome de evento em snake_case (`http_request`) | CODIGO | `src/middlewares/request-logger.middleware.ts` |
| FDD-OBS-04 | docs/FDD.md | Observabilidade | Eventos `server_started` e `shutdown_initiated` como molde do worker | CODIGO | `src/server.ts` |
| FDD-OBS-05 | docs/FDD.md | Observabilidade | Log de auditoria `webhook_dlq_replayed` com quem executou | TRANSCRICAO | `[09:36] Sofia` |
| FDD-OBS-06 | docs/FDD.md | Observabilidade | Redaction precisa cobrir `*.secret` para evitar vazamento em log ⇢ derivado | TRANSCRICAO | `[09:22] Diego` |
| FDD-OBS-07 | docs/FDD.md | Métrica | `webhook_outbox_lag_seconds` — vigia o SLA de 10 s e o worker parado | TRANSCRICAO | `[09:02] Marcos` |
| FDD-OBS-08 | docs/FDD.md | Métrica | `webhook_outbox_pending_count` — vigia o crescimento sem arquivamento | TRANSCRICAO | `[09:08] Diego` |
| FDD-OBS-09 | docs/FDD.md | Métrica | `webhook_delivery_duration_ms` — compara com o timeout de 10 s | TRANSCRICAO | `[09:42] Diego` |
| FDD-OBS-10 | docs/FDD.md | Métrica | `webhook_delivery_attempts` — valida empiricamente a escolha de 5 retentativas | TRANSCRICAO | `[09:16] Diego` |
| FDD-OBS-11 | docs/FDD.md | Métrica | `webhook_dead_letter_total` — é a medição que condiciona reabrir o alerta por e-mail | TRANSCRICAO | `[09:37] Larissa` |
| FDD-OBS-12 | docs/FDD.md | Métrica | `webhook_events_per_endpoint_per_minute` — insumo para decidir rate limiting | TRANSCRICAO | `[09:38] Diego` |
| FDD-OBS-13 | docs/FDD.md | Tracing | Correlação por `X-Request-Id` já gerado e propagado pelo middleware existente | CODIGO | `src/middlewares/request-logger.middleware.ts` |
| FDD-OBS-14 | docs/FDD.md | Tracing | Sem biblioteca de tracing distribuído no projeto; nada novo será adicionado | CODIGO | `package.json` |
| FDD-OBS-15 | docs/FDD.md | Tracing | Correlação por `requestId` exige `changeStatus` e o controller repassarem `req.id` ⇢ derivado | CODIGO | `src/modules/orders/order.controller.ts` |

### 3.8 Integração com o sistema existente

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| FDD-INTEG-01 | docs/FDD.md | Integração | `changeStatus` recebe a chamada a `publishWebhookEvent(tx, ...)` dentro do `$transaction` | CODIGO | `src/modules/orders/order.service.ts` |
| FDD-INTEG-02 | docs/FDD.md | Integração | A alteração crítica é dentro do service de orders, no `changeStatus` | TRANSCRICAO | `[09:40] Bruno` |
| FDD-INTEG-03 | docs/FDD.md | Integração | Tipo `TxClient = Prisma.TransactionClient` já existe e é reaproveitado na assinatura | CODIGO | `src/modules/orders/order.service.ts` |
| FDD-INTEG-04 | docs/FDD.md | Integração | Máquina de estados define o vocabulário de eventos e o domínio de assinatura | CODIGO | `src/modules/orders/order.status.ts` |
| FDD-INTEG-05 | docs/FDD.md | Integração | Classes `Webhook*Error` estendem as classes HTTP existentes | CODIGO | `src/shared/errors/http-errors.ts` |
| FDD-INTEG-06 | docs/FDD.md | Integração | Barril de erros reexporta as classes novas | CODIGO | `src/shared/errors/index.ts` |
| FDD-INTEG-07 | docs/FDD.md | Integração | Error middleware consumido sem alteração | CODIGO | `src/middlewares/error.middleware.ts` |
| FDD-INTEG-08 | docs/FDD.md | Integração | `authenticate` e `requireRole('ADMIN')` consumidos sem alteração | CODIGO | `src/middlewares/auth.middleware.ts` |
| FDD-INTEG-09 | docs/FDD.md | Integração | `validate({ body, params, query })` aplica os schemas Zod do módulo | CODIGO | `src/middlewares/validate.middleware.ts` |
| FDD-INTEG-10 | docs/FDD.md | Integração | `redactPaths` do logger ganha `*.secret`, `*.previousSecret` e `*.signature` | CODIGO | `src/shared/logger/index.ts` |
| FDD-INTEG-11 | docs/FDD.md | Integração | `paginated()` monta as respostas de listagem e histórico | CODIGO | `src/shared/http/response.ts` |
| FDD-INTEG-12 | docs/FDD.md | Integração | `createPrismaClient()` instancia o cliente do worker | CODIGO | `src/config/database.ts` |
| FDD-INTEG-13 | docs/FDD.md | Integração | `envSchema` ganha as variáveis de configuração do worker | CODIGO | `src/config/env.ts` |
| FDD-INTEG-14 | docs/FDD.md | Integração | `buildControllers` instancia o módulo de webhooks | CODIGO | `src/app.ts` |
| FDD-INTEG-15 | docs/FDD.md | Integração | `Controllers` e `buildApiRouter` registram as rotas do módulo | CODIGO | `src/routes/index.ts` |
| FDD-INTEG-16 | docs/FDD.md | Integração | `src/worker.ts` espelha o bootstrap e o shutdown de `src/server.ts` | CODIGO | `src/server.ts` |
| FDD-INTEG-17 | docs/FDD.md | Integração | Larissa propõe `src/worker.ts` como entrypoint novo, no molde do `src/server.ts` | TRANSCRICAO | `[09:11] Larissa` |
| FDD-INTEG-18 | docs/FDD.md | Integração | Bruno propõe a estrutura `src/modules/webhooks` com o padrão dos demais módulos | TRANSCRICAO | `[09:27] Bruno` |
| FDD-INTEG-19 | docs/FDD.md | Integração | Bruno propõe `webhook.worker.ts`/`webhook.processor.ts` dentro do módulo | TRANSCRICAO | `[09:28] Bruno` |
| FDD-INTEG-20 | docs/FDD.md | Integração | Padrão real de roteamento de módulo, com `authenticate` e `validate` | CODIGO | `src/modules/orders/order.routes.ts` |
| FDD-INTEG-21 | docs/FDD.md | Integração | Precedente de `requireRole('ADMIN')` aplicado em rota | CODIGO | `src/modules/users/user.routes.ts` |
| FDD-INTEG-22 | docs/FDD.md | Integração | Quatro modelos novos e relação inversa em `Customer` no schema | CODIGO | `prisma/schema.prisma` |
| FDD-INTEG-23 | docs/FDD.md | Integração | A migration nova convive com a `init` existente, sem alterar tabelas | CODIGO | `prisma/migrations/20260519182739_init/migration.sql` |
| FDD-INTEG-24 | docs/FDD.md | Integração | Script `npm run worker` acrescentado aos scripts existentes | CODIGO | `package.json` |
| FDD-INTEG-25 | docs/FDD.md | Integração | `tsconfig.build.json` já compila `src/` inteiro, então `dist/worker.js` sai do build | CODIGO | `tsconfig.build.json` |
| FDD-INTEG-26 | docs/FDD.md | Integração | `beforeEach` de teste precisa limpar as tabelas novas | CODIGO | `tests/setup.ts` |
| FDD-INTEG-27 | docs/FDD.md | Integração | Factories de teste ganham `createTestWebhookEndpoint()` | CODIGO | `tests/helpers/factories.ts` |
| FDD-INTEG-28 | docs/FDD.md | Integração | Suíte de pedidos existente continua passando sem alteração | CODIGO | `tests/orders.test.ts` |
| FDD-INTEG-29 | docs/FDD.md | Restrição | `OrderService.create` não publica evento: a reunião tratou de mudança de status ⇢ derivado | TRANSCRICAO | `[09:12] Larissa` |
| FDD-INTEG-30 | docs/FDD.md | Integração | `order.controller.ts` passa `req.id` ao service (1 linha), habilitando a correlação de tracing | CODIGO | `src/modules/orders/order.controller.ts` |

### 3.9 Dependências, configuração e compatibilidade

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| FDD-DEP-01 | docs/FDD.md | Dependência | Nenhuma dependência nova; HMAC e UUID vêm da runtime e do que já existe | CODIGO | `package.json` |
| FDD-DEP-02 | docs/FDD.md | Dependência | MySQL 8.0 provisionado por Docker Compose | CODIGO | `docker-compose.yml` |
| FDD-DEP-03 | docs/FDD.md | Configuração | `WEBHOOK_WORKER_POLL_INTERVAL_MS` = 2000 | TRANSCRICAO | `[09:09] Diego` |
| FDD-DEP-04 | docs/FDD.md | Configuração | `WEBHOOK_HTTP_TIMEOUT_MS` = 10000 | TRANSCRICAO | `[09:42] Diego` |
| FDD-DEP-05 | docs/FDD.md | Configuração | `WEBHOOK_MAX_RETRIES` = 5 | TRANSCRICAO | `[09:15] Diego` |
| FDD-DEP-06 | docs/FDD.md | Configuração | `WEBHOOK_MAX_PAYLOAD_BYTES` = 65536 | TRANSCRICAO | `[09:24] Diego` |
| FDD-DEP-07 | docs/FDD.md | Configuração | `WEBHOOK_SECRET_GRACE_PERIOD_HOURS` = 24 | TRANSCRICAO | `[09:21] Sofia` |
| FDD-DEP-08 | docs/FDD.md | Configuração | `WEBHOOK_WORKER_BATCH_SIZE` — "batch pequeno", sem número fechado na reunião ⇢ derivado | TRANSCRICAO | `[09:08] Diego` |
| FDD-DEP-09 | docs/FDD.md | Configuração | Padrão de validação de ambiente por Zod, com defaults | CODIGO | `src/config/env.ts` |
| FDD-DEP-10 | docs/FDD.md | Configuração | `.env.example` precisa ganhar as chaves novas | CODIGO | `.env.example` |
| FDD-DEP-11 | docs/FDD.md | Compatibilidade | `PATCH /orders/:id/status` ganha um novo modo de falha (payload acima de 64 KB) | TRANSCRICAO | `[09:24] Larissa` |
| FDD-DEP-12 | docs/FDD.md | Compatibilidade | Pedido sem webhook cadastrado se comporta exatamente como antes | TRANSCRICAO | `[09:34] Bruno` |
| FDD-DEP-13 | docs/FDD.md | Compatibilidade | Duas pools de conexão contra o mesmo MySQL; revisar `max_connections` | TRANSCRICAO | `[09:30] Bruno` |
| FDD-DEP-14 | docs/FDD.md | Compatibilidade | Worker pode subir depois da API sem perda de evento | TRANSCRICAO | `[09:06] Diego` |

### 3.10 Critérios de aceite técnicos e riscos técnicos

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| FDD-ACEITE-01 | docs/FDD.md | Critério de aceite | Uma linha de outbox por endpoint assinante; nenhuma se não houver assinante | TRANSCRICAO | `[09:34] Bruno` |
| FDD-ACEITE-02 | docs/FDD.md | Critério de aceite | Falha no registro do evento faz rollback completo da mudança de status | TRANSCRICAO | `[09:40] Bruno` |
| FDD-ACEITE-03 | docs/FDD.md | Critério de aceite | Entrega em até 2 s + tempo de resposta do cliente | TRANSCRICAO | `[09:09] Diego` |
| FDD-ACEITE-04 | docs/FDD.md | Critério de aceite | Matar a API não interrompe a entrega | TRANSCRICAO | `[09:11] Diego` |
| FDD-ACEITE-05 | docs/FDD.md | Critério de aceite | Transições rápidas do mesmo pedido chegam na ordem de `created_at` | TRANSCRICAO | `[09:12] Diego` |
| FDD-ACEITE-06 | docs/FDD.md | Critério de aceite | Cliente sem resposta em 10 s é tratado como falha | TRANSCRICAO | `[09:42] Diego` |
| FDD-ACEITE-07 | docs/FDD.md | Critério de aceite | Replay por `OPERATOR` devolve 403 | TRANSCRICAO | `[09:36] Sofia` |
| FDD-ACEITE-08 | docs/FDD.md | Critério de aceite | Dois webhooks distintos têm secrets distintas | TRANSCRICAO | `[09:21] Sofia` |
| FDD-ACEITE-09 | docs/FDD.md | Critério de aceite | Cadastro com URL `http` é recusado | TRANSCRICAO | `[09:23] Sofia` |
| FDD-ACEITE-10 | docs/FDD.md | Critério de aceite | Revisão de segurança concluída antes do deploy | TRANSCRICAO | `[09:46] Sofia` |
| FDD-ACEITE-11 | docs/FDD.md | Critério de aceite | `npm run lint`, `npm run build` e `npm test` continuam passando | CODIGO | `package.json` |
| FDD-RT-01 | docs/FDD.md | Risco técnico | RT-1 — contenção na transação de `changeStatus` | TRANSCRICAO | `[09:04] Bruno` |
| FDD-RT-02 | docs/FDD.md | Risco técnico | RT-2 — worker fora do ar sem ninguém perceber (taxa de erro fica em zero) | TRANSCRICAO | `[09:11] Diego` |
| FDD-RT-03 | docs/FDD.md | Risco técnico | RT-3 — crescimento sem limite da outbox sem arquivamento | TRANSCRICAO | `[09:07] Bruno` |
| FDD-RT-04 | docs/FDD.md | Risco técnico | RT-4 — vazamento de secret em log | TRANSCRICAO | `[09:22] Diego` |
| FDD-RT-05 | docs/FDD.md | Risco técnico | RT-5 — bombardeio de um cliente com muitas chamadas | TRANSCRICAO | `[09:38] Diego` |
| FDD-RT-06 | docs/FDD.md | Risco técnico | RT-6 — exaustão de conexões do MySQL com duas pools | TRANSCRICAO | `[09:30] Bruno` |
| FDD-RT-07 | docs/FDD.md | Risco técnico | RT-7 — duplicidade não tratada pelo cliente | TRANSCRICAO | `[09:25] Sofia` |
| FDD-RT-08 | docs/FDD.md | Risco técnico | RT-8 — quebra silenciosa de ordenação ao escalar workers | TRANSCRICAO | `[09:13] Diego` |
| FDD-RT-09 | docs/FDD.md | Risco técnico | RT-9 — evento travado em `PROCESSING` após crash ⇢ derivado | TRANSCRICAO | `[09:11] Diego` |
| FDD-RT-10 | docs/FDD.md | Risco técnico | RT-10 — payload defasado entregue horas depois | TRANSCRICAO | `[09:52] Larissa` |

---

## 4. ADRs — `docs/adrs/`

| ID | Documento | Tipo | Conteúdo (resumo) | Fonte | Localização |
| --- | --- | --- | --- | --- | --- |
| ADR-001 | docs/adrs/ADR-001-outbox-no-mysql.md | Decisão | Padrão Outbox no MySQL: evento gravado na mesma transação da mudança de status | TRANSCRICAO | `[09:08] Larissa` |
| ADR-001-CTX | docs/adrs/ADR-001-outbox-no-mysql.md | Contexto | Explicação do padrão outbox e da garantia transacional | TRANSCRICAO | `[09:06] Diego` |
| ADR-001-COD | docs/adrs/ADR-001-outbox-no-mysql.md | Restrição | Transação atual do `changeStatus` que recebe a inserção | CODIGO | `src/modules/orders/order.service.ts` |
| ADR-002 | docs/adrs/ADR-002-worker-em-processo-separado-com-polling.md | Decisão | Worker em processo separado, polling a cada 2 segundos | TRANSCRICAO | `[09:10] Larissa` |
| ADR-002-CTX | docs/adrs/ADR-002-worker-em-processo-separado-com-polling.md | Contexto | Worker precisa ser processo separado da instância da API | TRANSCRICAO | `[09:11] Diego` |
| ADR-002-COD | docs/adrs/ADR-002-worker-em-processo-separado-com-polling.md | Restrição | Molde do entrypoint e do shutdown gracioso | CODIGO | `src/server.ts` |
| ADR-003 | docs/adrs/ADR-003-retry-com-backoff-exponencial-e-dlq.md | Decisão | 5 retentativas, backoff 1m/5m/30m/2h/12h, DLQ em tabela separada | TRANSCRICAO | `[09:17] Larissa` |
| ADR-003-DLQ | docs/adrs/ADR-003-retry-com-backoff-exponencial-e-dlq.md | Decisão | DLQ em `webhook_dead_letter` com payload, motivo e timestamp | TRANSCRICAO | `[09:18] Diego` |
| ADR-003-COD | docs/adrs/ADR-003-retry-com-backoff-exponencial-e-dlq.md | Restrição | `requireRole` reaproveitado para exigir `ADMIN` no replay | CODIGO | `src/middlewares/auth.middleware.ts` |
| ADR-004 | docs/adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md | Decisão | HMAC-SHA256 sobre o corpo, secret por endpoint, rotação com grace de 24 h | TRANSCRICAO | `[09:22] Sofia` |
| ADR-004-ALG | docs/adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md | Decisão | SHA-256 como algoritmo, por ser padrão de mercado | TRANSCRICAO | `[09:20] Sofia` |
| ADR-004-COD | docs/adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md | Restrição | Contraste com `users.passwordHash`, que é hash bcrypt | CODIGO | `prisma/schema.prisma` |
| ADR-005 | docs/adrs/ADR-005-entrega-at-least-once-com-x-event-id.md | Decisão | Entrega at-least-once com deduplicação pelo cliente via `X-Event-Id` | TRANSCRICAO | `[09:26] Larissa` |
| ADR-005-JUST | docs/adrs/ADR-005-entrega-at-least-once-com-x-event-id.md | Trade-off | Padrão de mercado: Stripe e GitHub fazem assim | TRANSCRICAO | `[09:25] Diego` |
| ADR-005-COD | docs/adrs/ADR-005-entrega-at-least-once-com-x-event-id.md | Restrição | Uso de UUID v4 já presente no projeto | CODIGO | `src/middlewares/request-logger.middleware.ts` |
| ADR-006 | docs/adrs/ADR-006-reuso-dos-padroes-existentes-do-projeto.md | Decisão | Reuso máximo: AppError, Pino, error middleware, módulo, Zod, códigos de erro | TRANSCRICAO | `[09:30] Larissa` |
| ADR-006-PRISMA | docs/adrs/ADR-006-reuso-dos-padroes-existentes-do-projeto.md | Decisão | Worker instancia `PrismaClient` próprio, porque é por processo | TRANSCRICAO | `[09:30] Bruno` |
| ADR-006-COD | docs/adrs/ADR-006-reuso-dos-padroes-existentes-do-projeto.md | Restrição | Estrutura de módulo espelhada do módulo de pedidos | CODIGO | `src/modules/orders/order.routes.ts` |
| ADR-007 | docs/adrs/ADR-007-snapshot-do-payload-na-insercao-da-outbox.md | Decisão | Payload renderizado e gravado como snapshot na inserção | TRANSCRICAO | `[09:52] Larissa` |
| ADR-007-Q | docs/adrs/ADR-007-snapshot-do-payload-na-insercao-da-outbox.md | Contexto | Pergunta original: payload renderizado ou só `order_id`? | TRANSCRICAO | `[09:51] Bruno` |
| ADR-007-COD | docs/adrs/ADR-007-snapshot-do-payload-na-insercao-da-outbox.md | Restrição | Pedido pode ser apagado enquanto `PENDING`/`CANCELLED`, o que quebraria a renderização tardia | CODIGO | `src/modules/orders/order.service.ts` |

---

## Notas de rastreabilidade

### Itens derivados

Os itens marcados com `⇢ derivado` **não** são citação literal da reunião: são consequência
necessária de uma decisão que foi tomada, ou detalhes de especificação que a reunião não fechou.
Cada um aponta, na coluna *Localização* da tabela principal, para a decisão-mãe. A lista abaixo
cobre **todos** eles.

| ID | Item derivado | Decisão-mãe | Por que não é citação literal |
| --- | --- | --- | --- |
| RFC-QA-07 | Q6 — secret em claro vs. cifrada em repouso | `[09:21] Bruno` (a tabela armazena a secret) | Recomputar HMAC a cada entrega exige a secret recuperável; a forma de armazenamento não foi decidida |
| RFC-QA-09 | Q7 — assinatura dupla durante o grace period | `[09:21] Sofia` (a antiga fica válida por 24 h) | Em fluxo outbound quem assina somos nós; "válida em paralelo" só funciona enviando as duas assinaturas |
| RFC-QA-10 | Q8 — rotação com janela de grace já aberta | `[09:21] Sofia` (rotação com grace) | Duas rotações em menos de 24 h tornariam três secrets relevantes; caso não tratado |
| FDD-MODEL-10 | Uma linha de outbox por endpoint assinante | `[09:44] Sofia` (`X-Webhook-Id` por cadastro) | Retry e DLQ são estado por endpoint; uma linha por evento não teria onde guardar `attempts` por destino |
| FDD-MODEL-11 | Índice composto `(status, nextAttemptAt)` | `[09:17] Diego` (backoff com agendamento) | O índice literal `status` + `created_at` ([09:08]) não cobre a seleção por horário de próxima tentativa |
| FDD-MODEL-14 | Estado terminal `DEAD_LETTERED` | `[09:18] Diego` (DLQ em tabela separada) | A reunião decidiu para onde o evento morto vai, não o que acontece com a linha de origem na outbox |
| FDD-FLUXO-11 | Reivindicação de linha travada em `PROCESSING` após 60 s | `[09:42] Diego` (timeout de 10 s) | Crash entre o envio e a marcação prenderia a linha; sem isso, "restart drena o acumulado" não se sustenta |
| FDD-FLUXO-19 | Limite de 64 KB avaliado dentro da transação | `[09:24] Larissa` (erro acima de 64 KB) | A reunião falou em **não enviar**; avaliar na inserção é consequência de ADR-001 + ADR-007 e propaga o erro para `changeStatus`. **É a derivação de maior impacto — está na pauta da revisão técnica** |
| FDD-FLUXO-20 | Guarda de reentrada no loop do worker | `[09:12] Diego` (ordem por `created_at`, single-worker) | Sem a guarda, um ciclo lento sobrepõe o seguinte e dois ciclos concorrentes quebram a ordenação prometida |
| FDD-CONTRATO-18 | Assinatura dupla no `X-Signature` durante a rotação | `[09:21] Sofia` (a antiga fica válida por 24 h) | Mesma justificativa de RFC-QA-09, aplicada ao formato do header |
| FDD-CONTRATO-24 | Formato `sha256=<hex>` do header | `[09:44] Diego` (header `X-Signature` com o HMAC) | A reunião fixou algoritmo e header, não a serialização do valor |
| FDD-CONTRATO-25 | Formato da secret (`whsec_` + 32 bytes) | `[09:31] Marcos` (secret gerada por nós) | Comprimento e prefixo não foram discutidos; entram na revisão de segurança ([09:46]) |
| FDD-CONTRATO-26 | `202 Accepted` no replay | `[09:18] Diego` ("recoloca na outbox como pendente") | A reunião definiu o efeito, não o status HTTP; o projeto hoje só usa 200/201/204 |
| FDD-CONTRATO-27 | `responseBody` truncado em 2 KB | `[09:34] Marcos` (histórico guarda a response) | A reunião pediu a resposta no histórico, sem definir tamanho |
| FDD-ERRO-06 | `WEBHOOK_INVALID_EVENT_FILTER` | `[09:29] Larissa` + `[09:28] Bruno` (prefixo `WEBHOOK_`, com "etc.") | Bruno listou três códigos e disse "etc."; este cobre a validação do filtro decidido em [09:33]/[09:34] |
| FDD-ERRO-07 | `WEBHOOK_INACTIVE` | idem | Cobre o estado ativo decidido em [09:21] Bruno |
| FDD-ERRO-08 | `WEBHOOK_DEAD_LETTER_NOT_FOUND` | idem | Cobre o endpoint de replay decidido em [09:35] Diego |
| FDD-ERRO-09 | `WEBHOOK_ALREADY_REPLAYED` | idem | Cobre o replay idempotente; a reunião não tratou replay repetido |
| FDD-ERRO-10 | `WEBHOOK_ROTATION_IN_PROGRESS` | idem | Proposta ligada à questão em aberto Q8; não é decisão vigente |
| FDD-OBS-06 | Redaction de `*.secret` no logger | `[09:22] Diego` (cliente vazou secret em log) | A reunião relatou o incidente do lado do cliente; estender `redactPaths` é a consequência do nosso lado |
| FDD-OBS-15 | Correlação de tracing por `requestId` | `[09:36] Sofia` (auditoria do replay) | A reunião exigiu auditoria só do replay; a cadeia ponta a ponta exige mudar a assinatura de `changeStatus` e o controller |
| FDD-INTEG-29 | `OrderService.create` não publica evento | `[09:12] Larissa` (a discussão é sobre mudança de status) | Publicar na criação seria escopo inventado |
| FDD-DEP-08 | `WEBHOOK_WORKER_BATCH_SIZE` = 50 | `[09:08] Diego` ("batch pequeno") | Nenhum número foi fechado; 50 é ponto de partida declarado como calibrável |
| FDD-RT-09 | Risco de evento travado em `PROCESSING` | `[09:11] Diego` (processo separado pode reiniciar) | Mesma origem de FDD-FLUXO-11, registrada como risco |
| PRD-FR-13 | Efeito do estado inativo sobre eventos novos | `[09:21] Bruno` (coluna "estado ativo") | A fala sustenta a coluna; que endpoint inativo deixe de receber eventos é a consequência |

### Itens da reunião deliberadamente **não** registrados como requisito

Registrados aqui para deixar explícito que foram lidos e descartados, e não esquecidos.

| Item mencionado | Timestamp | Por que não virou requisito |
| --- | --- | --- |
| Alerta por e-mail em falhas seguidas | `[09:37] Larissa` | Explicitamente fora do escopo desta fase → registrado apenas como exclusão (PRD-OUT-01) |
| Dashboard visual para o cliente | `[09:40] Larissa` | Projeto separado do time de frontend → exclusão (PRD-OUT-02) |
| Rate limiting de saída | `[09:39] Larissa` | "Observar e decidir depois" → questão em aberto (RFC-QA-01/02), não requisito |
| Arquivamento após 30 dias | `[09:08] Diego` | "Fora do escopo dessa feature" → questão em aberto (RFC-QA-05) |
| Múltiplos workers / ordenação global | `[09:13] Diego` | "Problema do futuro" → limitação conhecida (PRD-OUT-06/07) |
| Redis Streams | `[09:07] Larissa` | Alternativa descartada → RFC-ALT-04, não proposta |
| Trigger de banco | `[09:09] Bruno` | Alternativa descartada → RFC-ALT-06 |
| Exactly-once | `[09:25] Diego` | Alternativa descartada → RFC-ALT-08 |
| 3 retentativas | `[09:16] Bruno` | Alternativa descartada → RFC-ALT-12 |
| `customer_id` implícito no JWT | `[09:31] Marcos` | **Corrigido na própria reunião** por `[09:32] Bruno` e decidido por `[09:32] Larissa` → registrado como PRD-PERS-03, com a proposta original explicitamente descartada |
| Endurecimento de papéis no CRUD | `[09:37] Sofia` | "Mais pra frente" → questão em aberto (RFC-QA-03) |

### Cobertura

Números conferidos automaticamente por [`scripts/validate-docs.sh`](../scripts/validate-docs.sh).

| Métrica | Valor | Exigência do desafio |
| --- | --- | --- |
| Linhas de rastreabilidade | **361** | — |
| Fonte = `TRANSCRICAO` | **290** (80%) | ≥ 70% |
| Fonte = `CODIGO` | **71** (19%) | ≥ 5 linhas |
| Linhas sem *Localização* | **0** | — |
| Itens marcados `⇢ derivado` | **25** — todos listados em [Itens derivados](#itens-derivados) | — |
| Citações `[hh:mm] Nome` validadas contra a transcrição | **100%** | — |
