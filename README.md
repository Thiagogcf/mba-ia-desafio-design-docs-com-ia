# Da Reunião ao Documento — Design Docs Gerados por IA

Pacote de design docs da feature **Sistema de Webhooks de Notificação de Pedidos**, produzido a
partir da transcrição de uma reunião técnica ([`TRANSCRICAO.md`](./TRANSCRICAO.md)) e do código de um
Order Management System em produção, usando IA como ferramenta principal de produção.

> O enunciado original do desafio está preservado em
> [`docs/ENUNCIADO.md`](./docs/ENUNCIADO.md).

---

## Sobre o desafio

O ponto de partida é uma situação bastante comum: uma decisão técnica importante foi tomada em uma
call de 55 minutos, e a única coisa que sobrou dela foi a transcrição literal. Cinco pessoas — tech
lead, PM, dois engenheiros e uma engenheira de segurança — fecharam a arquitetura de um sistema de
webhooks de notificação de pedidos, discutiram alternativas, descartaram ideias, adiaram outras e se
despediram. Nada foi registrado em documento. A tarefa é transformar essa conversa, somada ao código
da aplicação existente, em um pacote de documentação técnica acionável o suficiente para o time
começar a implementar.

O que torna o exercício interessante não é gerar texto — a IA faz isso sem esforço. É o filtro. A
transcrição contém decisões fechadas, mas também contém ideias explicitamente rejeitadas, pontos
adiados para "a próxima fase", perguntas que ficaram sem resposta e detalhes secundários que não
merecem virar documento. Identificar **o que não entra** é tão importante quanto identificar o que
entra, e é exatamente aí que uma IA sem direção falha: ela transforma tudo que foi mencionado em
requisito. Meu papel foi o de maestro — definir o recorte, formular prompts dirigidos, revisar
criticamente cada saída e cortar tudo que não tivesse origem rastreável na transcrição ou no código.

---

## Ferramentas de IA utilizadas

| Ferramenta | Papel no processo |
| --- | --- |
| **Claude Code** (Claude Opus 5, contexto de 1M tokens) | Ferramenta principal. Leu **a transcrição inteira e os 47 arquivos de `src/`, `prisma/` e `tests/`** em uma única janela de contexto, sem RAG e sem chunking. Isso é o que permitiu citar `changeStatus`, `requireRole`, `redactPaths` e `AppError` com precisão de arquivo, em vez de descrever "o service de pedidos" genericamente |
| **Subagentes de verificação adversarial** (Claude Code) | Após a redação, agentes independentes releram cada documento contra a transcrição e o código com a instrução de **refutar**, não de confirmar. Cada um recebeu um recorte diferente: citações, caminhos de código, critérios de aceite e itens fora de escopo |
| **Bash + scripts de validação** | A IA não é confiável como sua própria auditora. Escrevi [`scripts/validate-docs.sh`](./scripts/validate-docs.sh), que checa mecanicamente cada citação `[hh:mm] Nome` contra a transcrição e cada caminho de arquivo contra o repositório. É a rede de segurança que não depende de julgamento de modelo |

Não usei ChatGPT, Cursor, Copilot nem Gemini neste desafio: o fator decisivo foi manter transcrição e
código simultaneamente em contexto durante toda a redação, e uma ferramenta com acesso direto ao
repositório resolvia isso sem colar trechos manualmente.

---

## Workflow adotado

Segui a ordem sugerida no enunciado — **decisões primeiro, produto por último** — porque ela resolve
um problema real de altitude: escrevendo o PRD primeiro, a IA inventa justificativas de negócio para
decisões técnicas que ela ainda não conhece.

```
  0. Contextualização        ler TRANSCRICAO.md + os 47 arquivos de src/ prisma/ tests/
        │                    → mapa de ganchos reais no código
        ▼
  1. Extração dirigida       separar decisões FECHADAS / DESCARTADAS / ADIADAS / EM ABERTO
        │                    → cada item com timestamp e falante
        ▼
  2. ADRs (7)                uma decisão por arquivo, com alternativa real e trade-off explícito
        │
        ▼
  3. RFC                     consolida as decisões em proposta; alternativas e questões em aberto
        │                    → links para os ADRs
        ▼
  4. FDD                     desce ao detalhe: contratos, erros, fluxos, integração com o código
        │
        ▼
  5. PRD                     com tudo em mãos, vira consolidação de produto, não especulação
        │
        ▼
  6. TRACKER                 varredura dos documentos prontos, item a item, com origem
        │
        ▼
  7. Validação               script automático + subagentes adversariais → correções → nova rodada
        │
        ▼
  8. README                  documentado por último, quando o processo já existia de fato
```

### Princípios que guiaram a interação com a IA

**Um prompt, um recorte.** Nunca pedi "gere o FDD". Pedi a seção de fluxos, depois a de contratos,
depois a de integração — cada uma com o material de origem explicitado e o formato de saída definido.
Prompt largo produz documento vago.

**Nada sem origem.** A regra que atravessou todos os prompts: se um item não tem timestamp da
transcrição ou caminho de arquivo do repositório, ele não entra. Quando a IA produzia algo sem
âncora, a instrução era remover, não reescrever.

**O tracker como porta de qualidade, não como entregável final.** Montei o tracker enquanto revisava
os documentos, e não depois. Toda vez que uma linha não conseguia preencher a coluna *Localização*,
isso era o sinal de que aquele trecho do PRD ou do FDD tinha sido inventado. Foi assim que várias
frases genéricas saíram dos documentos.

**Marcar o derivado como derivado.** Alguns itens são consequência necessária de uma decisão, sem
serem citação literal — por exemplo, a regra de destravar eventos presos em `PROCESSING` após um
crash. Em vez de fingir que estavam na transcrição ou de descartá-los, marquei cada um com `⇢
derivado` no tracker, apontando para a decisão-mãe. São **32 itens**, todos listados em
[Itens derivados](./docs/TRACKER.md#itens-derivados) — e o script de validação falha se a contagem
de marcadores divergir da tabela de notas, para a lista não envelhecer em silêncio.

---

## Prompts customizados

### 1. Extração dirigida — separar o que entra do que não entra

Este foi o prompt mais importante do desafio. A primeira tentativa, genérica ("extraia os requisitos
da transcrição"), devolveu uma lista onde alerta por e-mail e dashboard apareciam como requisitos —
justamente as duas coisas que a Larissa recusou na reunião. O que resolveu foi **forçar quatro
categorias e exigir a fala literal** que justifica cada classificação:

```
Você tem a transcrição completa de uma reunião técnica em TRANSCRICAO.md.

Classifique CADA item técnico ou de produto mencionado em exatamente uma destas categorias:

  A) DECIDIDO      — alguém fechou explicitamente. Cite quem fechou e com que palavras.
  B) DESCARTADO    — foi proposto e rejeitado. Cite o motivo e quem rejeitou.
  C) ADIADO        — reconhecido como válido, mas empurrado para depois. Cite a palavra
                     exata que indica adiamento ("próxima fase", "problema do futuro",
                     "observar e decidir depois", "fora do escopo dessa feature").
  D) EM ABERTO     — levantado e NÃO resolvido até o fim da call.

Formato de saída, uma linha por item:
  CATEGORIA | item | [hh:mm] Falante | citação literal que justifica a classificação

Regras absolutas:
- Se você não consegue colar a citação literal, o item NÃO existe. Não o inclua.
- Um item mencionado por alguém e corrigido por outra pessoa depois vale pela CORREÇÃO,
  não pela menção original. Sinalize esses casos explicitamente.
- Não agrupe, não resuma, não interprete. Categorize.
```

A última regra ("vale pela correção") foi acrescentada na terceira iteração e é o que capturou o
caso do `customer_id` descrito abaixo.

### 2. Mapeamento de ganchos reais no código

Para que o FDD citasse arquivos que existem de verdade, e não uma arquitetura plausível inventada:

```
Leia o código-fonte deste repositório (src/, prisma/, tests/) e produza um mapa de
integração para uma feature nova de webhooks outbound.

Para cada ponto de contato, responda em uma linha:
  caminho/real/do/arquivo.ts | símbolo exato (classe, função, constante) | ALTERADO ou
  CONSUMIDO SEM ALTERAÇÃO | por quê

Restrições:
- Só liste arquivos que existem. Se você não abriu o arquivo, não o cite.
- Cite o nome exato do símbolo como está escrito no código, não uma paráfrase.
- Para cada arquivo marcado como ALTERADO, mostre o trecho atual e onde exatamente a
  alteração entraria.
- Diga também o que NÃO precisa mudar e por quê — isso é tão informativo quanto o que muda.
```

A última instrução foi o que revelou o achado mais útil do mapeamento: o
`src/middlewares/error.middleware.ts` não precisa de nenhuma alteração, porque ele já trata qualquer
`AppError` — o que confirma, no código, a afirmação do Bruno em `[09:29]`.

### 3. Auditoria antialucinação (usado nos subagentes de verificação)

Rodado sobre cada documento pronto, com a instrução deliberadamente adversarial:

```
Você é um revisor cético. Seu objetivo é REFUTAR o documento abaixo, não aprová-lo.

Para cada afirmação factual em {DOCUMENTO}, verifique contra TRANSCRICAO.md e contra o
código, e classifique:

  CONFIRMADO   — a fonte diz exatamente isso. Cite a linha da fonte.
  DISTORCIDO   — existe fonte parecida, mas o documento exagera, generaliza ou inverte
                 o sentido. Mostre a diferença lado a lado.
  INVENTADO    — não há fonte alguma.
  CONTRADITÓRIO — o documento contradiz a transcrição ou o código.

Preste atenção especial a:
  - números (quantidades, prazos, tamanhos, timeouts) — confira a aritmética, não só o valor;
  - atribuição de falas — a pessoa citada disse mesmo aquilo, ou foi outra?
  - itens que a reunião descartou aparecendo como se fossem requisitos;
  - caminhos de arquivo e nomes de símbolo que não existem no repositório.

Na dúvida, classifique como DISTORCIDO. Não dê o benefício da dúvida ao documento.
```

### 4. Correção de altitude entre documentos

Usado quando o FDD começou a repetir conteúdo que já estava no RFC:

```
Compare docs/RFC.md e docs/FDD.md.

Liste todo conteúdo que aparece nos DOIS. Para cada duplicação, decida a qual documento
ele pertence usando este critério:

  RFC responde "o que propomos e por quê"  → decisão, alternativa, trade-off, questão aberta
  FDD responde "como construir, em detalhe" → contrato, schema, algoritmo, código de erro

Devolva: trecho duplicado | onde deve ficar | o que remover do outro documento.
Não reescreva nada ainda. Só o diagnóstico.
```

O `Não reescreva nada ainda` importa: sem essa restrição, o modelo "resolve" a duplicação
reescrevendo os dois documentos de uma vez, e você perde a chance de revisar a decisão.

---

## Iterações e ajustes

Foram **sete ciclos principais** de geração → revisão crítica → ajuste de prompt → nova geração. Os
momentos em que a IA errou e precisei corrigir — as duas rodadas de auditoria adversarial, no fim,
foram de longe as mais produtivas:

### Iteração 1 — A IA transformou itens descartados em requisitos

**O que aconteceu.** A primeira extração da transcrição devolveu, na lista de requisitos funcionais,
"notificar o cliente por e-mail quando o webhook falhar" e "dashboard de acompanhamento". Ambos foram
**recusados** na reunião: Larissa disse "Não. Email tá fora de escopo dessa fase" (`[09:37]`) e "Não,
agora não. Só endpoints. Painel é projeto separado do time de frontend" (`[09:40]`). O modelo pegou a
**pergunta** do Marcos e ignorou a **resposta** da Larissa.

**Como corrigi.** Reescrevi o prompt de extração com as quatro categorias obrigatórias
(DECIDIDO / DESCARTADO / ADIADO / EM ABERTO) e a exigência de citação literal justificando cada
classificação — é o prompt nº 1 acima. Os dois itens foram para a seção "Fora de escopo" do PRD, com
a fala que os descartou transcrita na tabela, e a validação automatizada passou a checar que nenhum
requisito funcional menciona e-mail, dashboard ou rate limiting.

### Iteração 2 — O `customer_id` que a IA achou que vinha do JWT

**O que aconteceu.** O primeiro rascunho do contrato de cadastro dizia que o `customer_id` era
derivado do JWT. Está literalmente na transcrição — Marcos diz "Customer_id implícito do JWT"
(`[09:31]`). O problema é o que vem **uma fala depois**: Bruno aponta que "o JWT atual é do usuário
operador, não do cliente" (`[09:32]`) e Larissa fecha em sentido oposto: "o customer_id é passado no
body ou no path. **Não vem do JWT**" (`[09:32]`).

**Por que isso importa.** É a armadilha mais perigosa de trabalhar com transcrição: a IA trata a
conversa como um conjunto de afirmações independentes, quando ela é uma **sequência em que falas
posteriores revogam anteriores**. Nenhuma das duas falas é falsa isoladamente; só a ordem revela qual
vale.

**Como corrigi.** Acrescentei ao prompt de extração a regra "um item corrigido por outra pessoa
depois vale pela CORREÇÃO, não pela menção original — sinalize esses casos". Depois varri manualmente
a transcrição procurando outros pares pergunta/correção. A decisão final está no PRD (`PRD-PERS-03`)
e no FDD §6.1, e o tracker registra o caso explicitamente na tabela de itens deliberadamente **não**
registrados.

### Iteração 3 — "5 tentativas" não fecha com "quase 15 horas"

**O que aconteceu.** Todo rascunho gerado repetia "5 tentativas, backoff 1m/5m/30m/2h/12h", que é
exatamente o que a Larissa resume no fim da call (`[09:48]`). Quando fui montar a tabela de escada
de retry para o FDD, a conta não fechou: 5 tentativas consomem 4 intervalos e terminam em **2h36min**,
mas o Diego, ao propor a escada, quantifica o resultado como "total de quase 15 horas entre primeira
falha e última tentativa" (`[09:17]`) e justifica o número cinco por cobrir "uma janela de até 12 ou
24 horas" (`[09:15]`).

**Por que a IA não pegou.** Ela reproduziu fielmente as duas falas em parágrafos diferentes e nunca
as confrontou. Consistência textual é fácil; **consistência aritmética entre duas falas separadas por
30 linhas de transcrição** é o tipo de coisa que só aparece quando alguém tenta materializar o número
em uma tabela.

**Como corrigi.** As cinco tentativas são as cinco **retentativas** (6 envios, ~14h36min) — é a
única leitura que fecha com os "quase 15 horas" e com a justificativa da manutenção planejada de duas
horas (`[09:16]`). A escada está detalhada linha a linha no [FDD §5.3](./docs/FDD.md#53-retry-com-backoff-exponencial),
com nota de interpretação explícita, e a mesma nota aparece na
[ADR-003](./docs/adrs/ADR-003-retry-com-backoff-exponencial-e-dlq.md). Marquei como ponto a confirmar
na revisão técnica em vez de esconder a ambiguidade. Passei a incluir "confira a aritmética, não só o
valor" no prompt de auditoria.

### Iteração 4 — O grace period de 24h que não funcionava

**O que aconteceu.** Sofia decide que, ao rotacionar a secret, "a antiga fica válida por 24 horas em
paralelo, pra ele ter tempo de migrar os sistemas dele" (`[09:21]`). A IA escreveu, sem hesitar, que
continuaríamos assinando com a secret antiga durante 24 horas.

**O erro.** Isso inverte o objetivo. Como o fluxo é **outbound** — quem assina somos nós, o cliente
só verifica (`[09:03]` Sofia) — continuar assinando com a antiga significa que o cliente **nunca
conseguiria** começar a usar a nova. "Válida em paralelo" só produz o efeito desejado se o envio
carregar as **duas assinaturas** durante a janela.

**Como corrigi.** Documentei a interpretação de forma explícita, com as duas leituras lado a lado, na
[ADR-004](./docs/adrs/ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md) e no
[FDD §6.8](./docs/FDD.md#68-contrato-outbound--o-request-que-nós-enviamos-ao-cliente), e registrei o
ponto como **questão em aberto Q7** no RFC, endereçada à revisão de segurança que a Sofia pediu
(`[09:46]`). A lição de prompt: pedir para a IA **simular o comportamento** ("descreva passo a passo
o que o cliente faz durante a janela de 24h") expõe incoerências que a leitura do texto não expõe.

### Iteração 5 — Documentos citando caminhos que não existem, e RFC longo demais

**O que aconteceu — parte A.** Rascunhos citavam caminhos verossímeis mas inexistentes — um arquivo
`webhook-errors.ts` dentro de `src/shared/errors/`, que o projeto não tem, porque todas as classes
de erro vivem em [`http-errors.ts`](./src/shared/errors/http-errors.ts) — e endpoints sem o prefixo `/api/v1`, que o
[`src/app.ts`](./src/app.ts) monta em todas as rotas. A transcrição registra
`POST /admin/webhooks/dead-letter/:id/replay` (`[09:35]` Diego) — o caminho real precisa do prefixo,
e essa diferença só aparece cruzando transcrição com código.

**Como corrigi.** Escrevi o [`scripts/validate-docs.sh`](./scripts/validate-docs.sh), que extrai
todo caminho de arquivo e toda citação `[hh:mm] Nome` dos documentos e valida mecanicamente contra o
repositório e contra a transcrição. Rodei até zerar. Não confio na IA para auditar a IA em algo que
um `grep` resolve com certeza. A nota de compatibilidade de caminhos ficou no
[FDD §6](./docs/FDD.md#6-contratos-públicos); o [RFC §3.3](./docs/RFC.md#33-superfície-pública-proposta)
apenas remete a ela, para não duplicar altitude.

**O que aconteceu — parte B.** O RFC saiu com quase 3.000 palavras e uma tabela de nove alternativas
detalhadas — conteúdo correto, altitude errada. O enunciado pede um documento conciso de 2 a 4
páginas, e o detalhamento pertence ao FDD.

**Como corrigi.** Rodei o prompt nº 4 (correção de altitude) para diagnosticar as duplicações, mantive
no RFC as cinco alternativas com maior peso arquitetural com o trade-off completo e reduzi as outras
quatro a uma linha apontando para a ADR correspondente. O RFC ficou em pouco mais de 2.600 palavras,
sem perder nenhuma alternativa.

### Iteração 6 — A auditoria adversarial, que foi a mais produtiva de todas

Com o pacote aparentemente pronto e o script passando, rodei quatro subagentes independentes com o
prompt nº 3, cada um com uma lente diferente: **citações**, **código**, **critérios de aceite do
enunciado** e **escopo/altitude**. Nenhum deles viu os documentos como "meus"; a instrução era
refutar. Voltaram com 58 achados, e os relevantes foram exatamente aqueles que nem eu nem o `grep`
pegaríamos:

**Uma meta inventada.** O PRD tinha o objetivo O4 com meta "**≥ 99%** dos eventos entregues dentro
das retentativas", citando `[09:15]–[09:17] Diego`. Aquelas falas não têm percentual nenhum. O único
"99%" da transcrição é `[09:25]` Diego — "at-least-once com event_id resolve 99% dos casos" — que
fala de **cobertura da deduplicação**, não de taxa de entrega. Pior: oito linhas abaixo o próprio PRD
pregava que "inventar um baseline seria pior do que admitir que ele precisa ser medido". Removi o
número e deixei a meta como "a definir após medir a linha de base", com uma nota explicando o falso
positivo, para ninguém reintroduzi-lo.

**Uma contradição que quebraria a DLQ na prática.** O modelo do FDD declarava
`nextAttemptAt DateTime @default(now())` — não-nulável — mas o fluxo de dead letter gravava
`nextAttemptAt: null` para tirar a linha da fila. No Prisma isso é erro de tipo; e se o campo
mantivesse o valor antigo, a query do worker voltaria a selecionar a linha **a cada 2 segundos, para
sempre**, reentregando eventos já mortos. Corrigi com um estado terminal `DEAD_LETTERED` no enum,
excluído da query — o que de quebra resolve o duplo sentido de `FAILED` ("aguardando retry" e
"morto").

**A contagem que o próprio pacote vendia sobre si.** O tracker afirmava "São 9 itens derivados, todos
listados". Eram 16 marcados, a tabela cobria 13, e três nunca apareciam. Isso atinge exatamente a
garantia que o documento existe para dar. Reescrevi a tabela com todos (hoje 32, depois das outras
correções) e **acrescentei ao script uma checagem que compara a contagem de marcadores com a de
linhas da tabela** — o erro não pode voltar em silêncio.

**Três citações que não sustentavam o que eu afirmava.** A ADR-005 dizia que "os clientes já integram
com Stripe e GitHub" — Diego disse que *Stripe e GitHub fazem assim*, nunca que os três clientes
integram com eles. A ADR-004 atribuía o mecanismo de assinatura dupla à Stripe usando `[09:25]`, uma
fala que trata só de semântica de entrega. E a ADR-003 convertia uma **hipótese** de Diego ("**Se** o
cliente teve indisponibilidade de manhã...") em fato consumado ("Já houve caso..."), inflando de um
para dois os "fatos concretos" que sustentavam a escolha de 5 retentativas. Todas as três eram
citações reais, usadas para sustentar afirmações que elas não sustentam — o modo de falha mais
difícil de pegar, porque passa em qualquer verificação mecânica.

**Um "todos" falso, repetido em três ADRs.** Eu escrevia que "todos os modelos em
`prisma/schema.prisma` usam UUID". `OrderNumberSequence` usa `id Int`. Passou a "todos os modelos de
entidade, com a exceção de `OrderNumberSequence`, que é tabela de sequência".

**Uma cadeia de tracing que não funcionava.** A seção de observabilidade prometia correlacionar o
`X-Request-Id` do operador até a entrega, via uma coluna `requestId` na outbox — mas `req.id` nunca
chega ao service: `changeStatus(id, input, userId)` não tem esse parâmetro. Ou a coluna ficava vazia
para sempre, ou dois arquivos existentes precisavam mudar. Documentei o custo real (o método ganha um
quarto parâmetro e o controller passa `req.id`) e a alternativa de abrir mão do elo.

**Um `setInterval` que quebraria a garantia de ordenação.** O esboço do worker agendava
`setInterval(() => processor.tick(), 2000)` sem guarda. Um ciclo que demore mais de 2 segundos
sobrepõe o seguinte, dois ciclos passam a consumir a outbox em paralelo e a ordenação por pedido —
vendida como RNF-09 e como o benefício central da ADR-002 — evapora. Entrou uma guarda de reentrada.

**Uma aritmética que se autorrefutava.** A ADR-002 dizia que 2 s de polling contra um SLA de 10 s
"deixa 8 segundos de margem para a entrega, cujo timeout é justamente de 10 segundos". 2 + 10 = 12.
O trade-off provava o contrário do que afirmava. Reescrevi assumindo o que é verdade: o alvo de 10 s
vale como **p95 no caminho feliz**, não como garantia de pior caso — e um cliente que chega ao
timeout já entrou na escada de retry de qualquer forma.

Também saíram daí: o RFC afirmando que o logger é "consumido sem alteração" enquanto o resto do
pacote (corretamente) exige estender o `redactPaths`; a nota de compatibilidade de caminhos
duplicada palavra por palavra entre RFC e FDD; a matriz de riscos repetida em três documentos, agora
separada por altitude (produto no PRD, arquitetura no RFC, técnico no FDD); um item "fora de escopo"
que era inferência minha sob um cabeçalho que prometia "nada aqui é suposição"; e a atribuição do
filtro `SHIPPED`/`DELIVERED` à Atlas quando Marcos deu o exemplo sem nomear cliente.

**A lição.** O script mecânico e a auditoria semântica pegam coisas disjuntas. O `grep` provou que os
82 pares `[hh:mm] Nome` existem; nenhum dos oito problemas acima seria pego por ele, porque todos
usavam citações **verdadeiras** para sustentar afirmações **falsas**. Quem só valida a forma acha
que terminou cedo demais.

### Iteração 7 — A rodada que auditou as próprias correções

Depois de aplicar tudo da iteração 6, rodei uma **segunda** leva de auditores, agora com duas
perguntas: *cada correção foi mesmo aplicada?* e *alguma correção quebrou outra coisa?* Os três
voltaram REPROVADO — e estavam certos.

**O bug de verdade, que sobreviveu a todas as leituras anteriores.** O `X-Event-Id` é o eixo do
contrato: é por ele que o cliente deduplica ([ADR-005](./docs/adrs/ADR-005-entrega-at-least-once-com-x-event-id.md)).
O FDD também estabelece que a outbox tem **uma linha por (evento × endpoint assinante)**, porque
retry e DLQ são estado por endpoint. As duas coisas estavam certas isoladamente — e juntas produziam
um bug. Meu algoritmo de publicação renderizava o payload **uma vez, antes** do laço de inserção:

```
4. payload ← renderEventPayload(order, from, to)     ← UMA vez
5. verifica 64 KB
6. para cada assinante: create({ ..., payload })     ← MESMO payload, ids de linha diferentes
```

Um cliente com dois webhooks receberia duas entregas com o **mesmo** `X-Event-Id`. Ele dedupica,
como mandamos ele deduplicar, e **descarta a segunda em silêncio** — o evento se perde exatamente no
mecanismo criado para não perder eventos. A correção foi mover a geração do id para dentro do laço,
render o payload por linha e passar o id explicitamente no `create`, de modo que
`event_id === webhook_outbox.id`. Nenhuma verificação mecânica pegaria isso: não há citação errada,
não há caminho inexistente, não há link quebrado. É uma contradição entre duas decisões corretas.

**Duas correções que introduziram defeitos novos.** Ao reescrever a nota da DLQ, escrevi entre aspas
que Diego disse que a alternativa *"polui a leitura da outbox principal, que é o caminho quente do
worker"* — atribuindo a ele a **minha** paráfrase. Diego disse: *"Mais limpa a leitura da outbox
principal, e fica como evidence pra debug e reprocessamento"* (`[09:18]`). E ao corrigir o cenário C1
para não atribuir o filtro à Atlas, troquei o timestamp errado: o exemplo "só quero saber quando vira
SHIPPED e DELIVERED" é `[09:33]` Marcos, não `[09:34]` Marcos — que naquele minuto está pedindo outra
coisa, o histórico de entregas. O erro se espalhou por seis lugares.

**Correções aplicadas em um documento só.** Tirei do RFC a afirmação de que o logger é "consumido sem
alteração", mas ela continuava viva na ADR-006, na dependência D4 do PRD e na linha `RFC-IMP-03` do
tracker. Mesma coisa com a recontagem de itens derivados: corrigida no tracker e num parágrafo do
README, esquecida na tabela de navegação — que voltou a dizer "9 itens" na mesma página que dizia
"25". A lição: **uma correção não está feita enquanto não for propagada para todos os documentos que
repetem a afirmação**, e o tracker é o índice que diz quais são.

**E um punhado de incoerências de especificação** que só aparecem quando alguém lê o FDD como se
fosse implementar: `WEBHOOK_INACTIVE` sem nenhum caminho de execução; o campo `attempt` do histórico
sem regra de cálculo; o esboço do worker sem `.catch`, o que no Node ≥ 20 derruba o processo na
primeira falha de conexão — justo o risco RT-2, o silencioso; a função `bootstrap()` declarada e
nunca chamada; `secretRotatedAt` devolvido em algumas respostas e não em outras.

Depois dessa rodada, estendi o script para checar também os marcadores `⇢ derivado` fora do tracker,
e passei a **regerar** o bloco de saída do README a partir da execução real, em vez de digitá-lo.

### Resultado da validação final

```
$ bash scripts/validate-docs.sh
1. Citações da transcrição
  ✓ 82 pares [hh:mm] Nome distintos usados nos docs existem entre os 128 pares da TRANSCRICAO.md
     (esta checagem prova EXISTÊNCIA do par, não fidelidade do conteúdo citado)

2. Caminhos de arquivo citados
  ✓ 45 caminhos de arquivos existentes conferem

3b. Cobertura dos itens rotulados dos documentos
  ✓ 122 itens rotulados, cobertura 100% (exigido >= 80%)

3. Cobertura do TRACKER.md
     linhas: 373 | TRANSCRICAO: 302 (80%) | CODIGO: 71
  ✓ TRANSCRICAO >= 70% (80%)
  ✓ CODIGO >= 5 linhas (71)
  ✓ itens ⇢ derivado: 32 marcados = 32 documentados nas notas
     (7 marcadores ⇢ derivado nos documentos, fora do tracker — cada um deve ter linha no tracker)
  ✓ nenhuma linha com Localização vazia

4. Estrutura do pacote
  ✓ README.md
  ✓ TRANSCRICAO.md
  ✓ docs/PRD.md
  ✓ docs/RFC.md
  ✓ docs/FDD.md
  ✓ docs/TRACKER.md
  ✓ docs/adrs/ contém 7 ADRs (entre 5 e 8)
  ✓ todos os ADRs têm Status, Contexto, Decisão, Alternativas e Consequências

5. Itens descartados não aparecem como requisito
  ✓ nenhum item descartado na reunião virou requisito funcional

6. Links e âncoras internas entre os documentos
  ✗ README.md: ancora inexistente -> ./docs/TRACKER.md#regra-de-contagem-e-denominador
  ✗ README.md: ancora inexistente -> ./docs/TRACKER.md#varredura-reversa--o-que-a-reunião-produziu-e-onde-foi-parar

VALIDAÇÃO FALHOU
```

O que o script **não** prova, e por isso a iteração 6 existiu: ele confere que o par
`[hh:mm] Nome` existe na transcrição, não que a pessoa disse o que o documento afirma. Fidelidade de
conteúdo só sai com leitura.

---

## Como navegar a entrega

```
.
├── README.md                        ← você está aqui (processo de produção)
├── TRANSCRICAO.md                   fonte primária: a reunião (não alterado)
├── docs/
│   ├── PRD.md                       problema, escopo, requisitos, métricas, riscos
│   ├── RFC.md                       proposta técnica, alternativas, questões em aberto
│   ├── FDD.md                       contratos, fluxos, erros, integração com o código
│   ├── TRACKER.md                   rastreabilidade item a item (373 linhas, cobertura 100% dos 122 itens rotulados)
│   ├── ENUNCIADO.md                 enunciado original do desafio
│   └── adrs/
│       ├── README.md                índice das decisões
│       ├── ADR-001-outbox-no-mysql.md
│       ├── ADR-002-worker-em-processo-separado-com-polling.md
│       ├── ADR-003-retry-com-backoff-exponencial-e-dlq.md
│       ├── ADR-004-assinatura-hmac-sha256-com-secret-por-endpoint.md
│       ├── ADR-005-entrega-at-least-once-com-x-event-id.md
│       ├── ADR-006-reuso-dos-padroes-existentes-do-projeto.md
│       └── ADR-007-snapshot-do-payload-na-insercao-da-outbox.md
├── scripts/
│   └── validate-docs.sh             porta de qualidade antialucinação
└── src/ prisma/ tests/              aplicação existente (não alterados)
```

### Ordem de leitura sugerida

| # | Leia | Por quê |
| --- | --- | --- |
| 1 | [`docs/PRD.md`](./docs/PRD.md) | Entenda o problema, quem pediu, o que entra e — principalmente — **o que ficou de fora e por quê** |
| 2 | [`docs/RFC.md`](./docs/RFC.md) | A proposta técnica em nível de arquitetura, com as alternativas descartadas e as 8 questões ainda em aberto |
| 3 | [`docs/adrs/`](./docs/adrs/) | Comece pela [ADR-001](./docs/adrs/ADR-001-outbox-no-mysql.md), que é a decisão da qual todas as outras dependem. O [índice](./docs/adrs/README.md) mostra o mapa |
| 4 | [`docs/FDD.md`](./docs/FDD.md) | O detalhe de implementação. Se você é a pessoa que vai codar, comece pela [§10, Integração com o sistema existente](./docs/FDD.md#10-integração-com-o-sistema-existente) |
| 5 | [`docs/TRACKER.md`](./docs/TRACKER.md) | Consulte quando quiser saber de onde veio qualquer item. O [denominador](./docs/TRACKER.md#o-denominador-o-que-este-tracker-trata-como-item) está declarado antes da contagem, e a [conferência na direção contrária](./docs/TRACKER.md#a-conferência-na-direção-contrária) parte da reunião e pergunta onde cada item foi parar. As [notas de rastreabilidade](./docs/TRACKER.md#notas-de-rastreabilidade) explicam os 32 itens derivados e o que foi deliberadamente descartado |

### Atalhos por interesse

- **"O que foi decidido, resumido?"** → [RFC §1, TL;DR](./docs/RFC.md#1-resumo-executivo-tldr)
- **"O que a reunião descartou?"** → [PRD §5.2, Fora de escopo](./docs/PRD.md#52-fora-de-escopo)
- **"O que ainda não foi decidido?"** → [RFC §5, Questões em aberto](./docs/RFC.md#5-questões-em-aberto)
- **"Como isso encosta no código atual?"** → [FDD §10](./docs/FDD.md#10-integração-com-o-sistema-existente)
- **"Qual é o contrato que o cliente vai integrar?"** → [FDD §6.8, contrato outbound](./docs/FDD.md#68-contrato-outbound--o-request-que-nós-enviamos-ao-cliente)
- **"De onde veio esse requisito?"** → [`docs/TRACKER.md`](./docs/TRACKER.md)

---

## Escopo da entrega

Esta entrega é **puramente documental**. Nenhum arquivo de `src/`, `prisma/` ou `tests/` foi
alterado — o código serve de contexto e referência, e os documentos descrevem como a feature se
integraria a ele. As únicas adições fora de `docs/` são este README e o script de validação.
