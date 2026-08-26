# PRD — Sistema de Webhooks de Notificação de Pedidos

> **Documento de produto.** Responde *por que* e *o quê*. A proposta técnica está em
> [`docs/RFC.md`](./RFC.md), o desenho de implementação em [`docs/FDD.md`](./FDD.md), e cada decisão
> arquitetural isolada em [`docs/adrs/`](./adrs/). A rastreabilidade item a item está em
> [`docs/TRACKER.md`](./TRACKER.md).

| Campo | Valor |
| --- | --- |
| **Feature** | Sistema de Webhooks de Notificação de Pedidos |
| **Produto** | Order Management System (OMS) |
| **Status** | Aprovado para implementação, pendente de revisão técnica e de segurança |
| **PM responsável** | Marcos |
| **Tech Lead** | Larissa |
| **Data** | 2026-08-26 |
| **Prazo alvo** | Fim de novembro ([09:45] Marcos) · **3 sprints**, incluindo revisão de segurança ([09:46] Larissa) |
| **Base** | [`TRANSCRICAO.md`](../TRANSCRICAO.md) + código do OMS neste repositório |

---

## 1. Resumo e contexto da feature

O OMS passa a **notificar ativamente os clientes B2B** sempre que o status de um pedido deles muda,
por meio de webhooks HTTP assinados criptograficamente.

Hoje o sistema é totalmente passivo: o cliente que quer saber se algo mudou precisa consultar
`GET /orders` repetidamente. Não existe no produto nenhum mecanismo de notificação externa, evento
ou webhook.

Com a feature, o cliente cadastra uma URL, escolhe **quais status quer ouvir** e passa a receber uma
chamada HTTP a cada transição relevante, em **menos de 10 segundos**, com assinatura HMAC-SHA256 que
permite validar origem e integridade. O sistema garante que **nenhum evento se perde**: falhas de
entrega são retentadas ao longo de ~15 horas e, se ainda assim falharem, ficam registradas para
reprocessamento manual.

A decisão de construir a feature e a forma de construí-la foram fechadas em uma reunião técnica de
~55 minutos com Tech Lead, PM, dois engenheiros e uma engenheira de segurança
([`TRANSCRICAO.md`](../TRANSCRICAO.md)).

---

## 2. Problema e motivação

### 2.1 O problema do cliente

Três clientes B2B — **Atlas Comercial**, **MaxDistribuição** e **Nova Cargo** — apresentaram um
pedido formal na semana anterior à reunião: querem ser notificados em tempo real quando o status dos
pedidos deles muda ([09:00] Marcos).

Hoje eles resolvem isso com **polling**: batem em `GET /orders` de tempos em tempos para descobrir se
algo mudou. Nas palavras do PM, isso "tá deixando a integração lenta e cara pra eles" ([09:00]
Marcos). O custo recai inteiramente sobre o cliente — em infraestrutura, em latência de reação e em
trabalho manual de acompanhamento.

### 2.2 A pressão comercial

A **Atlas Comercial sinalizou que pode migrar para um concorrente** se a funcionalidade não for
entregue até o fim do trimestre ([09:00] Marcos). O prazo não é uma preferência de roadmap: é um
compromisso comercial com risco de churn associado.

### 2.3 O que "tempo real" significa aqui

O PM apurou o requisito diretamente com os clientes: **qualquer coisa abaixo de 10 segundos já é
"tempo real"** para eles. O que não pode acontecer é "ficar pendurado" e obrigá-los a atualizar
manualmente ([09:02] Marcos).

Essa definição é o que torna a solução viável sem infraestrutura pesada — é o requisito que
sustenta praticamente todas as decisões técnicas do [RFC](./RFC.md).

---

## 3. Público-alvo e cenários de uso

### 3.1 Público-alvo

| Persona | Quem é | O que precisa |
| --- | --- | --- |
| **Cliente B2B integrador** | Time técnico de Atlas, MaxDistribuição e Nova Cargo | Receber notificação de mudança de status sem fazer polling, e conseguir validar que a chamada veio mesmo de nós |
| **Usuário que representa o cliente** | Usuário do nosso sistema que administra a integração do cliente ([09:32] Marcos) | Cadastrar, editar, remover webhooks e rotacionar secret pela nossa API |
| **Administrador da plataforma** | Usuário com papel `ADMIN` | Reprocessar eventos que falharam de forma permanente ([09:36] Sofia) |
| **Product Manager** | Marcos | Documentar a integração no portal do desenvolvedor ([09:40] Marcos) e medir a adoção |

> **Nota importante de modelagem:** a proposta inicial era derivar o cliente do JWT ([09:31]
> Marcos), mas Bruno apontou que **o JWT atual representa o usuário operador do nosso sistema, não o
> cliente** ([09:32]). Marcos confirmou que o cadastro é feito pela nossa API, autenticado com JWT do
> nosso sistema, por usuários que representam o cliente ([09:32]), e Larissa fechou: **o
> `customer_id` é informado explicitamente, não vem do JWT** ([09:32]).

### 3.2 Cenários de uso

**C1 — Acompanhar o envio de um pedido.** Um cliente assina apenas `SHIPPED` e `DELIVERED` — o
exemplo que Marcos usou para descrever o filtro de eventos: "só quero saber quando vira SHIPPED e
DELIVERED" ([09:34]). Quando um pedido dele é despachado, o sistema do cliente recebe a notificação
em segundos e dispara automaticamente o aviso ao cliente final, sem nenhuma consulta ao nosso
`GET /orders`.

**C2 — Integração de um novo cliente.** O time técnico do cliente cadastra a URL do webhook, recebe
a secret na resposta da criação e implementa a verificação da assinatura antes de ir a produção.

**C3 — Rotação de secret após incidente.** O cliente suspeita que a secret vazou — cenário real, já
aconteceu com um cliente que a expôs no log da aplicação dele ([09:22] Diego). Ele pede a rotação
pela API, recebe a nova secret e tem **24 horas** para migrar os sistemas dele antes de a antiga
deixar de valer ([09:21] Sofia).

**C4 — Cliente em manutenção planejada.** O endpoint do cliente fica fora do ar por duas horas —
situação que já ocorreu ([09:16] Diego). As notificações são retentadas automaticamente e chegam
quando ele volta, sem intervenção de ninguém.

**C5 — Investigação de "não recebi o evento".** O cliente reclama. O time consulta o histórico de
entregas daquele webhook e vê tentativa a tentativa: sucesso ou falha, payload enviado, resposta
recebida e tempo de resposta ([09:34] Marcos).

**C6 — Recuperação de falha permanente.** Um endpoint ficou fora do ar por mais de 15 horas e os
eventos esgotaram as retentativas. Depois de o cliente restabelecer o serviço, um administrador
reprocessa manualmente os eventos parados ([09:18] e [09:35] Diego).

---

## 4. Objetivos e métricas de sucesso

| # | Objetivo | Métrica | Meta | Origem |
| --- | --- | --- | --- | --- |
| **O1** | Notificar o cliente em tempo real, conforme a definição dele | Latência p95 entre o commit da mudança de status e a resposta do cliente | **< 10 segundos** | [09:02] Marcos |
| **O2** | Não perder nenhum evento por falha do sistema | Mudanças de status commitadas sem evento registrado para endpoints assinantes | **0 ocorrências** | [09:40] Bruno: "Não pode ter caso de status mudar e evento não sair" |
| **O3** | Reter os três clientes B2B que motivaram a feature | Atlas Comercial, MaxDistribuição e Nova Cargo integrados e recebendo webhooks em produção | **3 de 3 até o fim de novembro** | [09:00] e [09:45] Marcos |
| **O4** | Absorver indisponibilidade transitória do cliente sem intervenção | Proporção de eventos entregues dentro da janela de 5 retentativas, sem chegar à dead letter | **Meta a definir após medir a linha de base no primeiro mês.** A reunião fixou a política de retry, não um alvo numérico de entrega | [09:15]–[09:17] Diego |
| **O5** | Eliminar a necessidade de polling dos clientes integrados | Volume de `GET /orders` originado dos três clientes | **Queda relevante** frente à linha de base — *linha de base a medir antes do lançamento* | [09:00] Marcos |
| **O6** | Entregar dentro do compromisso comercial | Sprints consumidos, incluindo a revisão de segurança | **3 sprints** | [09:46] Larissa e Sofia |

**O1 é a métrica-âncora**: é ela que traduz o pedido do cliente em número. As decisões de polling de
2 segundos ([09:09] Diego) e timeout de 10 segundos ([09:42] Diego) foram tomadas com esse orçamento
em mente.

Sobre **O4 e O5**: as metas dependem de uma linha de base que **ainda não existe** — nenhum número
histórico foi apresentado na reunião, e nenhum alvo percentual foi discutido. Registrar essa lacuna é
deliberado; inventar um baseline ou um alvo seria pior do que admitir que ambos precisam ser medidos.
O instrumento de medição está definido em [`docs/FDD.md`](./FDD.md#91-métricas).

> Cuidado com um falso positivo: o único percentual dito na reunião é "at-least-once com event_id
> resolve 99% dos casos" ([09:25] Diego), que se refere à **cobertura da estratégia de deduplicação**
> — não é meta de taxa de entrega e não foi reaproveitado aqui como se fosse.

---

## 5. Escopo

### 5.1 Incluído

| # | Item | Origem |
| --- | --- | --- |
| E1 | Cadastro, edição, listagem e remoção de webhooks por cliente | [09:31] Marcos; [09:33] Bruno |
| E2 | Filtro de eventos por endpoint — o cliente escolhe quais status quer receber | [09:33] Bruno; [09:34] Marcos |
| E3 | Entrega assíncrona e garantida de eventos de mudança de status | [09:06] Diego; [09:40] Bruno |
| E4 | Assinatura HMAC-SHA256 com secret por endpoint | [09:22] Sofia |
| E5 | Rotação de secret com período de convivência de 24 h | [09:21] Sofia |
| E6 | Retentativa automática com backoff e fila de falhas permanentes | [09:15]–[09:18] Diego |
| E7 | Consulta do histórico de entregas de um webhook | [09:34] Marcos |
| E8 | Reprocessamento manual de falhas permanentes, restrito a `ADMIN` | [09:35] Diego; [09:36] Sofia |

### 5.2 Fora de escopo

Tudo o que segue foi **explicitamente descartado ou adiado durante a reunião**, com a fala que o
descartou transcrita na última coluna. Nada aqui é suposição do redator.

| # | Item | Status | Quem decidiu, e o que disse |
| --- | --- | --- | --- |
| **F1** | **Alerta por e-mail ao cliente quando o webhook dele falha repetidamente** | **Adiado** para a próxima fase | Marcos pediu ([09:37]); **Larissa: "Não. Email tá fora de escopo dessa fase. Talvez próxima fase, depois que a gente medir o impacto"** ([09:37]) |
| **F2** | **Dashboard / painel visual para o cliente acompanhar os webhooks** | **Descartado** desta fase | Marcos perguntou ([09:39]); **Larissa: "Não, agora não. Só endpoints. Painel é projeto separado do time de frontend"** ([09:40]) |
| **F3** | **Rate limiting de saída** (limitar a taxa de chamadas a um mesmo cliente) | **Adiado** — observar e decidir depois | Diego levantou ([09:38]) e ele mesmo avaliou que não entra: "a gente observa e implementa se virar problema" ([09:39]); **Larissa: "Fica como 'observar e decidir depois'"** ([09:39]) |
| **F4** | **Arquivamento das linhas de evento já entregues** (~30 dias) | **Fora do escopo** desta feature | **Diego: "Linhas entregues a gente arquiva depois de 30 dias ou assim, fora do escopo dessa feature"** ([09:08]) |
| **F5** | **Webhooks inbound** (cliente enviando eventos para nós) | **Nunca esteve no escopo** | Sofia perguntou ([09:02]); **Marcos: "Só saindo da gente pra eles. Eles querem receber, não mandar"** ([09:02]) |
| **F6** | **Ordenação global garantida entre pedidos diferentes** e execução com múltiplos workers em paralelo | **Adiado** — limitação conhecida | **Diego: "Mas isso é problema do futuro, não agora"** ([09:13]); **Larissa: "Documentamos como limitação conhecida"** ([09:13]); Marcos confirmou que os clientes nunca pediram ([09:14]) |
| **F7** | **Garantia de entrega exactly-once** | **Descartada** | **Diego: "Garantir exactly-once exigiria coordenação dos dois lados e fica muito mais complexo"** ([09:25]) |
| **F8** | **Endurecimento dos papéis no CRUD de configuração** | **Adiado** | Marcos perguntou ([09:36]); **Sofia: "Por enquanto sim. Mais pra frente a gente pode endurecer"** ([09:37]) |

---

## 6. Requisitos funcionais

| # | Requisito | Detalhe de produto | Origem |
| --- | --- | --- | --- |
| **RF-01** | **Cadastrar webhook** | O usuário informa a URL de destino, o `customer_id` e a lista de status que deseja receber. A **secret é gerada pela plataforma** e devolvida na resposta da criação | [09:31] Marcos; [09:32] Larissa |
| **RF-02** | **Editar webhook** | Permite alterar URL, lista de status assinados e o estado ativo/inativo | [09:33] Bruno |
| **RF-03** | **Remover webhook** | Remove o cadastro de webhook | [09:33] Bruno |
| **RF-04** | **Listar webhooks de um cliente** | Retorna os webhooks cadastrados de um `customer_id`, **sem expor a secret** | [09:33] Bruno |
| **RF-05** | **Filtrar eventos por endpoint** | Cada endpoint assina uma lista de status — por exemplo, "só quero saber quando vira `SHIPPED` e `DELIVERED`". O filtro é aplicado **no momento em que o evento é registrado**, e não no envio | [09:33] Bruno; [09:34] Marcos; [09:34] Bruno e Diego |
| **RF-06** | **Registrar o evento de forma atômica com a mudança de status** | Quando o status de um pedido muda, o evento é registrado na mesma transação. Se o registro falhar, **a mudança de status é desfeita** | [09:40] Bruno; [09:41] Diego |
| **RF-07** | **Entregar o evento por HTTP assinado** | O envio carrega o identificador do evento, a assinatura, o timestamp do envio e o identificador do webhook | [09:44] Diego; [09:44] Sofia |
| **RF-08** | **Retentar automaticamente em caso de falha** | Cinco retentativas com intervalos crescentes de 1 min, 5 min, 30 min, 2 h e 12 h | [09:17] Diego |
| **RF-09** | **Registrar falhas permanentes em fila de erro** | Esgotadas as retentativas, o evento é preservado com payload, motivo da falha e horário | [09:18] Diego |
| **RF-10** | **Reprocessar manualmente uma falha permanente** | Um administrador (`ADMIN`) pode recolocar o evento na fila de entrega; **quem executou fica registrado** | [09:18] e [09:35] Diego; [09:36] Sofia |
| **RF-11** | **Consultar o histórico de entregas de um webhook** | Retorna as entregas recentes com sucesso/falha, payload enviado, resposta recebida e tempo de resposta | [09:34] Marcos |
| **RF-12** | **Rotacionar a secret de um webhook** | O cliente solicita nova secret pela API; a anterior continua válida por **24 horas** e depois deixa de valer | [09:21] Sofia |
| **RF-13** | **Ativar e desativar um webhook** ⇢ *derivado* | O cadastro tem estado ativo ([09:21] Bruno, confirmado por Sofia); que endpoint inativo deixe de receber eventos novos é a consequência da coluna, não uma fala da reunião | [09:21] Bruno |
| **RF-14** | **Recusar URL insegura** | Cadastro com URL que não seja `https` é rejeitado com erro de validação | [09:23] Sofia |

**14 requisitos funcionais**, todos com origem identificável na reunião.

---

## 7. Requisitos não funcionais

| # | Requisito | Valor / critério | Origem |
| --- | --- | --- | --- |
| **RNF-01** | **Latência de notificação** | Abaixo de 10 segundos entre a mudança de status e a chegada ao cliente | [09:02] Marcos |
| **RNF-02** | **Intervalo de verificação de eventos pendentes** | 2 segundos; latência mínima aceita de 2 s no pior caso | [09:09] Diego; [09:10] Larissa |
| **RNF-03** | **Tempo limite de resposta do cliente** | 10 segundos; sem resposta é tratado como falha | [09:42] Diego |
| **RNF-04** | **Tamanho máximo do payload** | 64 KB. Acima disso o evento é rejeitado com erro — **não** truncado ([09:23] Sofia é explícita: "Eu sou a favor de erra") | [09:23] Sofia; [09:24] Diego e Larissa |
| **RNF-05** | **Transporte seguro** | TLS obrigatório: apenas URLs `https` | [09:23] Sofia |
| **RNF-06** | **Isolamento de segredo** | Secret única por endpoint, jamais global — "se vaza uma, vaza tudo" | [09:21] Sofia |
| **RNF-07** | **Rotação de segredo** | Suportada sob demanda, com convivência de 24 h entre a secret nova e a anterior | [09:21] e [09:22] Sofia |
| **RNF-08** | **Garantia de entrega** | *At-least-once*: o cliente pode receber o mesmo evento mais de uma vez e precisa deduplicar pelo identificador do evento | [09:24] e [09:25] Diego |
| **RNF-09** | **Ordenação** | Garantida **por pedido** enquanto houver um único processador. **Não há** garantia de ordenação global | [09:12] e [09:13] Diego; [09:13] Larissa |
| **RNF-10** | **Isolamento do fluxo de pedidos** | A entrega de webhook nunca pode bloquear ou atrasar a mudança de status de um pedido | [09:04] Bruno |
| **RNF-11** | **Independência operacional** | O processador de entregas roda em processo separado da API; reiniciar a API não interrompe entregas | [09:11] Diego e Larissa |
| **RNF-12** | **Auditoria de reprocessamento** | Todo reprocessamento manual registra quem o executou | [09:36] Sofia |
| **RNF-13** | **Controle de acesso** | CRUD de configuração exige autenticação (qualquer papel, nesta fase); reprocessamento exige papel `ADMIN` | [09:36] Larissa; [09:37] Sofia |
| **RNF-14** | **Padrões do projeto** | A feature reaproveita os padrões existentes de módulo, erro, log e validação. Códigos de erro com prefixo `WEBHOOK_` | [09:29] e [09:30] Larissa; [09:28] Bruno |
| **RNF-15** | **Custo de infraestrutura** | Nenhuma infraestrutura nova; a solução usa o banco já existente | [09:07] Diego |
| **RNF-16** | **Fidelidade histórica do evento** | O conteúdo do evento reflete o estado do pedido **no momento da mudança**, não no momento da entrega | [09:52] Larissa |

---

## 8. Decisões e trade-offs principais

Cada decisão tem o registro completo em [`docs/adrs/`](./adrs/). O que segue é a leitura de produto —
o que ganhamos e o que aceitamos perder.

| Decisão | Ganho para o produto | Custo aceito | ADR |
| --- | --- | --- | --- |
| **Registrar o evento na mesma transação da mudança de status** (padrão outbox no banco existente) | Nenhum evento se perde e nenhum evento é emitido para uma mudança que não aconteceu ([09:06] Diego) | A transação de pedido fica um pouco mais longa, e uma falha ao registrar o evento derruba a mudança de status ([09:40] Bruno) | [ADR-001](./adrs/ADR-001-outbox-no-mysql.md) |
| **Processador separado verificando a cada 2 segundos** | A entrega nunca trava o fluxo de pedidos, e reiniciar a API não interrompe notificação ([09:11] Diego) | Piso de 2 segundos de latência ([09:10] Larissa) e um componente a mais para operar | [ADR-002](./adrs/ADR-002-worker-em-processo-separado-com-polling.md) |
| **5 retentativas ao longo de ~15 horas, depois fila de erro** | Absorve indisponibilidade real do cliente sem ninguém intervir ([09:16] Diego) | O último evento pode chegar quase 15 horas atrasado — aceito por Marcos: "se um cliente meu cair por 15 horas, ele já tá com problema sério dele" ([09:17]) | [ADR-003](./adrs/ADR-003-retry-com-backoff-exponencial-e-dlq.md) |
| **Assinatura HMAC-SHA256 com secret por endpoint** | Vazamento afeta um único endpoint de um único cliente ([09:21] Sofia); integração simples, com biblioteca pronta em qualquer stack ([09:20] Sofia) | Mais segredos para gerenciar, e a secret precisa ficar recuperável no banco (ver **Q6** no [RFC](./RFC.md#5-questões-em-aberto)) | [ADR-004](./adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md) |
| **Entrega at-least-once, com deduplicação pelo cliente** | Nenhum evento é sacrificado em nome de unicidade; é o padrão que Stripe e GitHub usam ([09:25] Diego) | O cliente precisa implementar deduplicação — Sofia registrou a ressalva: "isso joga responsabilidade pro cliente" ([09:25]). Marcos assumiu documentar de forma destacada ([09:26]) | [ADR-005](./adrs/ADR-005-entrega-at-least-once-com-x-event-id.md) |
| **Reaproveitar integralmente os padrões do projeto** | Time entrega mais rápido, com menos risco e sem dependências novas ([09:30] Larissa) | Abrimos mão de uma modelagem sob medida para um domínio assíncrono | [ADR-006](./adrs/ADR-006-reuso-dos-padroes-existentes-do-projeto.md) |
| **Congelar o conteúdo do evento no momento da mudança** | O evento sempre descreve o fato como ele aconteceu, mesmo entregue horas depois ([09:52] Larissa) | O cliente pode receber informação que já não corresponde ao estado atual do pedido | [ADR-007](./adrs/ADR-007-snapshot-do-payload-na-insercao-da-outbox.md) |

---

## 9. Dependências

| # | Dependência | Tipo | Detalhe | Origem |
| --- | --- | --- | --- | --- |
| D1 | **Banco MySQL já existente** | Técnica | A fila de eventos vive no banco atual; não há infraestrutura nova ([09:07] Diego). O worker usa a mesma `DATABASE_URL` ([09:30] Bruno) | [09:07] Diego; [09:30] Bruno |
| D2 | **Módulo de pedidos** | Técnica | A feature depende do ponto de mudança de status em `src/modules/orders/order.service.ts` ([09:40] Bruno) | [09:40] Bruno |
| D3 | **Controle de acesso por papel existente** | Técnica | O reprocessamento reaproveita o `requireRole` já implementado ([09:36] Larissa) | [09:36] Larissa |
| D4 | **Padrões compartilhados do projeto** | Técnica | Classes de erro, logger Pino e middleware de erro central são consumidos como estão ([09:29] Bruno) | [09:29] Bruno |
| D5 | **Revisão de segurança da Sofia** | **Bloqueante para o deploy** | Mínimo de **2 dias úteis** reservados para revisar HMAC e geração de secret **antes de subir** ([09:46] Sofia) | [09:46] Sofia |
| D6 | **Sessão de revisão do design com Bruno e Diego** | Bloqueante para o início da codificação | Larissa se comprometeu a marcar antes de começar a codar ([09:50]) | [09:50] Larissa |
| D7 | **Documentação no portal do desenvolvedor** | De lançamento | Marcos documenta como integrar via API ([09:40]) e destaca a garantia at-least-once ([09:26]) | [09:26] e [09:40] Marcos |
| D8 | **Confirmação de prazo com os clientes** | Comercial | Marcos confirma o prazo com a Atlas ([09:47]) | [09:45] e [09:47] Marcos |
| D9 | **Capacidade do time por 3 sprints** | De planejamento | Modelagem (1 sprint), worker e retry (1 sprint), CRUD e histórico (½), integração e testes ponta a ponta (½), HMAC e validações (restante) ([09:46] Larissa) | [09:46] Larissa |

---

## 10. Riscos e mitigação

Probabilidade e impacto são avaliações de produto sobre fatos registrados na reunião; a coluna
**Origem** aponta o fato que sustenta cada linha.

| # | Risco | Probabilidade | Impacto | Mitigação | Origem |
| --- | --- | --- | --- | --- | --- |
| **R1** | **Perder a Atlas Comercial por atraso na entrega** — o cliente sinalizou que pode migrar para o concorrente | **Média** | **Alto** — perda de receita e efeito de referência sobre os outros dois clientes | Escopo deliberadamente enxuto: e-mail, dashboard e rate limiting ficaram fora ([09:37], [09:39], [09:40] Larissa). Plano em 3 sprints já com a revisão de segurança dentro ([09:46] Larissa). Marcos confirma o prazo com o cliente ([09:47]) | [09:00] Marcos |
| **R2** | **Vazamento de secret pelo lado do cliente** — já aconteceu: um cliente expôs a secret no log de aplicação dele | **Média** | **Alto** — terceiro passa a conseguir forjar notificações para aquele endpoint | Secret **por endpoint**, nunca global, limita o raio a um cadastro ([09:21] Sofia); rotação sob demanda com 24 h de convivência ([09:21] Sofia); revisão de segurança antes do deploy ([09:46] Sofia) | [09:22] Diego |
| **R3** | **Cliente processar o mesmo evento duas vezes** por não implementar deduplicação | **Média** | **Médio** — efeito colateral no negócio do cliente (envio duplicado, cobrança duplicada) | Identificador único e estável em todo envio ([09:25] Diego); documentação destacada no portal do desenvolvedor, assumida pelo PM ([09:26] Marcos) | [09:25] Sofia levanta a ressalva |
| **R4** | **Processador de entregas fora do ar sem ninguém perceber** — é instância única | **Baixa** | **Alto** — nenhum cliente recebe notificação e o sintoma é silencioso, porque a taxa de erro fica em zero | Nenhum evento se perde: eles acumulam e são entregues quando o processo volta ([09:06] Diego). O monitoramento é sobre o **atraso da fila**, não sobre erro ([`FDD` §9.1](./FDD.md#91-métricas)) | [09:11] e [09:12] Diego |
| **R5** | **Bombardear um cliente com muitas chamadas** — 50 pedidos mudando de status em um minuto viram 50 chamadas | **Média** | **Médio** — o cliente pode nos bloquear ou degradar | **Sem mitigação nesta fase, por decisão** ([09:39] Diego e Larissa). Instrumentamos o volume por cliente para embasar a decisão futura ([`RFC` Q1](./RFC.md#5-questões-em-aberto)) | [09:38] Diego |
| **R6** | **Crescimento não controlado da tabela de eventos** — arquivamento ficou fora do escopo | **Alta** (é certo que cresce; a dúvida é o prazo) | **Médio** — degradação progressiva da entrega | Índices e leitura em lote pequeno seguram a performance no curto prazo ([09:08] Diego); definição de política de retenção como questão em aberto ([`RFC` Q4](./RFC.md#5-questões-em-aberto)) | [09:07] Bruno; [09:08] Diego |
| **R7** | **Evento chegar com até ~15 horas de atraso** após indisponibilidade longa do cliente | **Baixa** | **Baixo** — aceito explicitamente pelo PM | Marcos: "se um cliente meu cair por 15 horas, ele já tá com problema sério dele. Acho aceitável" ([09:17]). O histórico de entregas permite ao cliente entender o que houve ([09:34] Marcos) | [09:17] Marcos |
| **R8** | **Mudança de status de pedido falhar por causa do webhook** — o registro do evento é transacional | **Baixa** | **Alto** — impacto no fluxo central do produto, não apenas na feature nova | É o comportamento desejado: falhar explicitamente é melhor que perder evento silenciosamente ([09:40] Bruno; [09:41] Diego). O registro é uma escrita local, sem chamada externa ([09:04] Bruno) | [09:40] Bruno |

---

## 11. Critérios de aceitação

A feature é considerada pronta quando **todos** os itens abaixo forem verdadeiros. Os critérios
técnicos correspondentes estão em [`docs/FDD.md`](./FDD.md#12-critérios-de-aceite-técnicos).

### Funcionalidade

- [ ] Um cliente consegue cadastrar, listar, editar e remover webhooks pela API (RF-01 a RF-04).
- [ ] O cliente escolhe quais status quer receber e recebe **apenas** esses (RF-05).
- [ ] Uma mudança de status gera notificação ao cliente em **menos de 10 segundos** no caminho feliz
      (O1, RNF-01).
- [ ] Cliente indisponível volta a receber os eventos automaticamente quando retorna, dentro da
      janela de retentativas (RF-08).
- [ ] Falhas permanentes ficam registradas e podem ser reprocessadas por um `ADMIN`, com registro de
      autoria (RF-09, RF-10, RNF-12).
- [ ] O cliente consegue consultar o histórico de entregas de um webhook (RF-11).
- [ ] O cliente consegue rotacionar a secret e tem 24 horas de convivência entre a antiga e a nova
      (RF-12, RNF-07).

### Integridade e segurança

- [ ] Não existe mudança de status commitada sem evento registrado para os endpoints assinantes
      (O2, RF-06).
- [ ] Todo envio é assinado e verificável pelo cliente com a secret daquele endpoint (RF-07, RNF-06).
- [ ] Cadastro com URL `http` é rejeitado (RF-14, RNF-05).
- [ ] A secret não aparece em nenhuma listagem nem em nenhum log.
- [ ] Reprocessamento por usuário sem papel `ADMIN` é negado (RNF-13).
- [ ] **Revisão de segurança da Sofia concluída e aprovada antes do deploy** (D5).

### Não regressão

- [ ] Nenhum endpoint existente muda de contrato, **com uma exceção documentada**:
      `PATCH /orders/:id/status` passa a poder responder `422 WEBHOOK_PAYLOAD_TOO_LARGE` e a falhar
      se o registro do evento falhar — consequência intencional de RF-06 e do risco R8
      (ver [FDD §11.3](./FDD.md#113-compatibilidade)).
- [ ] Pedidos de clientes **sem** webhook cadastrado se comportam exatamente como antes.
- [ ] Os testes existentes (`tests/auth.test.ts` e `tests/orders.test.ts`) continuam passando sem
      alteração; `tests/setup.ts` ganha apenas a limpeza das tabelas novas.
- [ ] Nenhuma dependência nova foi adicionada ao projeto (RNF-15).

### Escopo

- [ ] Nenhum item da seção 5.2 (Fora de escopo) foi implementado.

---

## 12. Estratégia de testes e validação

Larissa estimou "integração no order.service e testes ponta a ponta" como meio sprint dedicado
([09:46]), o que posiciona teste como parte do escopo, não como sobra.

### 12.1 Camadas de teste

| Camada | O que valida | Base existente |
| --- | --- | --- |
| **Unitário** | Cálculo da assinatura HMAC; escada de backoff (intervalo correto por tentativa); filtro de assinantes por status; renderização do payload | Vitest já configurado (`vitest.config.ts`) |
| **Integração (API)** | Os endpoints de configuração, rotação, histórico e reprocessamento, incluindo códigos de erro e controle de acesso por papel | `tests/` com Supertest sobre `buildApp` e banco real, como em `tests/orders.test.ts` |
| **Integração (transacional)** | Que a falha ao registrar o evento **desfaz a mudança de status**, e que pedido sem webhook assinante não gera evento algum | Mesma infraestrutura de `tests/orders.test.ts` |
| **Ponta a ponta** | Mudança de status → registro do evento → processamento → entrega HTTP a um receptor de teste → marcação de entregue, incluindo assinatura verificável no receptor | Estimado por Larissa como parte de meia sprint ([09:46]) |
| **Resiliência** | Receptor de teste que devolve erro e depois passa a responder: valida a escada de retentativas e a ida para a fila de erro após a última | — |
| **Revisão de segurança** | HMAC e geração de secret, revisados manualmente por Sofia com no mínimo 2 dias úteis antes do deploy | [09:46] Sofia |

### 12.2 Cenários críticos de validação

1. **Ordem preservada por pedido:** um pedido que passa por `PAID → PROCESSING → SHIPPED` em
   sequência rápida chega ao cliente nessa ordem ([09:12] Diego).
2. **Rollback transacional:** falha forçada no registro do evento mantém o pedido no status anterior
   ([09:40] Bruno).
3. **Filtro respeitado:** webhook que assina apenas `SHIPPED` e `DELIVERED` não recebe `PAID`
   ([09:34] Marcos).
4. **Retentativa e recuperação:** receptor fora do ar na primeira tentativa e no ar na segunda —
   evento entregue sem intervenção ([09:15] Diego).
5. **Falha permanente e reprocessamento:** receptor sempre fora do ar — evento vai para a fila de
   erro; `ADMIN` reprocessa e a entrega ocorre ([09:18] e [09:35] Diego).
6. **Convivência de secrets:** durante a janela de 24 h, o receptor valida o envio tanto com a secret
   antiga quanto com a nova ([09:21] Sofia).
7. **Isolamento entre endpoints:** um cliente com dois webhooks, um saudável e outro fora do ar —
   o saudável continua recebendo normalmente.
8. **Não regressão:** cliente sem webhook cadastrado tem comportamento idêntico ao atual.

### 12.3 Validação pós-lançamento

- Acompanhar **O1** (latência p95) e **O4** (taxa de entrega dentro das retentativas) nas duas
  primeiras semanas, com as métricas definidas em [`FDD` §9.1](./FDD.md#91-métricas).
- Medir a **linha de base de O5** (volume de `GET /orders` dos três clientes) **antes** do
  lançamento, para que a queda seja demonstrável.
- Usar `webhook_dead_letter_total` como o insumo que Larissa condicionou para reabrir a decisão de
  alerta por e-mail — "depois que a gente medir o impacto" ([09:37]).
- Usar `webhook_events_per_endpoint_per_minute` para reabrir, ou não, a decisão de rate limiting de
  saída ([09:39] Diego e Larissa).

> **Proposta não discutida na reunião:** validar o contrato com o time técnico de um dos três
> clientes antes do lançamento geral, usando um endpoint de homologação. Não há registro dessa
> combinação na transcrição — fica como sugestão para a sessão de revisão ([09:50] Larissa).
