# ADR-004 — Assinatura HMAC-SHA256 com secret por endpoint e rotação com grace period de 24h

| Campo | Valor |
| --- | --- |
| **Status** | Aceita (sujeita à revisão de segurança antes do deploy) |
| **Data** | Reunião técnica de webhooks (`TRANSCRICAO.md`, quinta-feira 09:00) |
| **Decisores** | Sofia (Eng. Segurança), Larissa (Tech Lead) |
| **Consultados** | Bruno (Eng. Pleno — Pedidos), Diego (Eng. Sênior — Plataforma) |
| **Relacionadas** | [ADR-005](./ADR-005-entrega-at-least-once-com-x-event-id.md), [ADR-006](./ADR-006-reuso-dos-padroes-existentes-do-projeto.md), [ADR-007](./ADR-007-snapshot-do-payload-na-insercao-da-outbox.md) |

## Contexto

O webhook expõe **dados de pedidos para um endpoint fora da nossa infraestrutura**. Sofia colocou o
requisito em duas partes ([09:19]):

1. o cliente precisa conseguir **provar que a requisição veio realmente de nós**; e
2. o cliente precisa conseguir **detectar adulteração do payload em trânsito**.

O fluxo é exclusivamente **outbound** — nós enviamos, o cliente recebe; não existe caminho de
entrada ([09:02] Marcos, confirmado por Sofia em [09:03]). Isso elimina toda a superfície de
autenticação de entrada e reduz o problema a assinar o que sai.

Há também um antecedente concreto: **já tivemos um cliente que vazou a secret no log de aplicação
dele** ([09:22] Diego). Qualquer desenho precisa assumir que uma secret vai vazar em algum momento
e limitar o raio de alcance quando isso acontecer.

## Decisão

**HMAC-SHA256 sobre o corpo do request, com secret única por endpoint e suporte a rotação com
grace period de 24 horas** ([09:22] Sofia).

- **Algoritmo:** HMAC com SHA-256. Escolhido por ser o padrão de mercado — "todo cliente sério tem
  biblioteca pra isso" ([09:20] Sofia). Não entra dependência nova: o `node:crypto` da runtime
  (Node ≥ 20, conforme `engines` em `package.json`) já fornece `createHmac`.
- **O que é assinado:** o corpo do request ([09:22] Sofia), transportado no header `X-Signature`
  ([09:20] Sofia).
- **Escopo da secret: por endpoint, não por plataforma.** Cada endpoint de webhook cadastrado tem a
  sua própria secret; não existe secret global. "Senão se vaza uma, vaza tudo" ([09:21] Sofia).
- **A secret é gerada por nós** e devolvida ao cliente na criação do webhook ([09:31] Marcos). O
  cadastro armazena `url + secret + customer_id + estado ativo` ([09:21] Bruno).
- **Rotação sob demanda do cliente**, via endpoint na API. Ao rotacionar, **a secret antiga
  permanece válida por 24 horas em paralelo**, dando ao cliente tempo de migrar os sistemas dele;
  depois disso a antiga morre ([09:21] Sofia).
- **`X-Timestamp` acompanha o envio**, para que o cliente que quiser possa detectar replay attack
  do lado dele ([09:44] Diego).
- **URL obrigatoriamente `https`.** Cadastro com `http` é recusado com erro de validação. Sofia
  classificou explicitamente como validação de schema Zod, **não** como decisão arquitetural
  ([09:23]) — por isso entra aqui apenas como contexto e é especificado em
  [`docs/FDD.md`](../FDD.md).

> **Nota de interpretação — o que significa "a antiga fica válida por 24 horas em paralelo".**
> Como o fluxo é outbound, quem assina somos nós; o cliente apenas verifica. "Manter a antiga
> válida" só produz o efeito desejado (o cliente migrar sem downtime) se, **durante a janela de
> 24 h, o envio carregar as duas assinaturas** — a da secret nova e a da antiga — e o cliente
> aceitar qualquer uma das duas. A leitura alternativa (continuar assinando só com a antiga por
> 24 h) inverte o problema: o cliente não teria como começar a usar a secret nova, e a janela de
> convivência não serviria para nada.
>
> A justificativa é puramente lógica, e não se apoia em nenhuma outra fala: a transcrição menciona
> Stripe e GitHub apenas a respeito da semântica de entrega *at-least-once* ([09:25] Diego), **nada
> sobre rotação de secret**. O formato do header está em [`docs/FDD.md`](../FDD.md) e este ponto
> está listado para a revisão de segurança de Sofia ([09:46]).

## Alternativas Consideradas

### A. Secret única global da plataforma — **descartada (discutida na reunião)**

Uma secret só, compartilhada com todos os clientes integrados.

- **A favor:** um segredo para guardar e rotacionar, operação trivial, nada de gestão por endpoint.
- **Contra:** o vazamento de um único cliente compromete a integração de todos — "se vaza uma, vaza
  tudo" ([09:21] Sofia). E o antecedente de vazamento em log de cliente já existe ([09:22] Diego).
- **Trade-off que motivou o descarte:** simplicidade operacional em troca de um raio de explosão
  igual à base inteira de clientes. Inaceitável para um dado que sabidamente vaza.

### B. Assinatura assimétrica (chave privada nossa, pública do cliente) — **descartada (plausível, não levantada na reunião)**

Assinar com chave privada nossa e publicar a chave pública para verificação.

- **A favor:** o cliente nunca detém material capaz de forjar nossas mensagens; um vazamento do
  lado dele não gera risco de falsificação; rotação vira publicação de nova chave pública.
- **Contra:** exige gestão de par de chaves e de um endpoint de distribuição (JWKS ou equivalente);
  bibliotecas do lado do cliente são menos triviais que um `hmac(sha256)`, o que colide diretamente
  com o critério de adoção que Sofia usou ([09:20]); e não resolve nenhum problema real do modelo
  de ameaça atual, já que o risco é vazamento no cliente, não falsificação por ele.
- **Trade-off que motivou o descarte:** garantia criptográfica mais forte em troca de fricção de
  integração para os três clientes B2B que precisam entrar até o fim do trimestre ([09:00] Marcos).

### C. mTLS entre nós e o endpoint do cliente — **descartada (plausível, não levantada na reunião)**

- **A favor:** autentica o canal de ponta a ponta, sem segredo em nível de aplicação.
- **Contra:** exige que o cliente opere uma PKI e configure certificado cliente no ingress dele —
  barreira alta para clientes B2B de porte médio; e autentica o **canal**, não a **mensagem**: não
  sobrevive a proxies TLS-terminating e não deixa evidência verificável do payload.
- **Trade-off que motivou o descarte:** segurança de transporte mais forte em troca de custo de
  integração desproporcional. TLS simples já é obrigatório ([09:23] Sofia); mTLS acrescenta pouco
  ao modelo de ameaça descrito e muito ao esforço do cliente.

## Consequências

### Positivas

- **Raio de explosão contido.** Vazamento de secret afeta exatamente um endpoint de um cliente
  ([09:21] Sofia).
- **Rotação sem downtime para o cliente**, graças à janela de 24 horas ([09:21] Sofia).
- **Barreira de integração baixa:** HMAC-SHA256 tem biblioteca pronta em qualquer stack
  ([09:20] Sofia).
- **Integridade de payload verificável**, e não apenas autenticidade de canal — o cliente detecta
  adulteração ([09:19] Sofia).
- **Zero dependência nova** no `package.json`: `node:crypto` cobre o caso.

### Negativas

- **A secret precisa ser recuperável em claro no momento do envio.** Diferente de senha de usuário
  — que o projeto armazena como hash bcrypt em `users.passwordHash` (`prisma/schema.prisma`) — a
  secret de webhook não pode ser hasheada, porque precisamos recomputar o HMAC a cada entrega. Isso
  cria uma classe de segredo em claro no banco que hoje não existe no sistema. **A forma de
  armazenamento (claro vs. cifrado em repouso) não foi decidida na reunião** e está listada como
  questão em aberto em [`docs/RFC.md`](../RFC.md), endereçada à revisão de segurança ([09:46] Sofia).
- **Risco de vazamento em log.** A secret trafega pela aplicação e pode acabar em log, exatamente
  como aconteceu com um cliente ([09:22] Diego). Exige estender a lista de `redactPaths` do logger
  em `src/shared/logger/index.ts`, que hoje cobre `password`, `passwordHash`, `token` e
  `accessToken`, mas não secret de webhook.
- **A janela de 24 h aumenta o custo por envio** durante a rotação: duas assinaturas calculadas e
  transmitidas por request.
- **A verificação é responsabilidade do cliente.** Se o cliente não validar a assinatura, o
  mecanismo não protege nada — cabe à documentação do portal do desenvolvedor deixar isso explícito
  ([09:40] Marcos).
- **Adiciona um passo bloqueante ao cronograma:** Sofia pediu no mínimo dois dias úteis para
  revisar HMAC e geração de secret antes do deploy ([09:46]).

### Trade-off explícito

Trocamos a garantia criptográfica mais forte de um esquema assimétrico e a simplicidade operacional
de um segredo único por um **modelo simétrico por endpoint**: mais material secreto para gerenciar,
em troca de **raio de explosão mínimo** e **fricção de integração mínima** para os clientes B2B que
precisam entrar dentro do trimestre. O custo assumido é o segredo em claro no banco, que fica
explicitamente pendente da revisão de segurança.

## Referências

- `TRANSCRICAO.md` — [09:02], [09:03], [09:19], [09:20], [09:21], [09:22], [09:23], [09:25],
  [09:31], [09:40], [09:44], [09:46]
- Código: `src/shared/logger/index.ts` (`redactPaths`), `prisma/schema.prisma` (`users.passwordHash`
  como contraste), `package.json` (`engines.node >= 20`)
- [`docs/FDD.md`](../FDD.md) — Formato do header `X-Signature`, geração e rotação de secret
- [`docs/RFC.md`](../RFC.md) — Questão em aberto sobre armazenamento da secret em repouso
