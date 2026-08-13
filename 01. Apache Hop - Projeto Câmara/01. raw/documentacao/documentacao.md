# Projeto Câmara — camada raw

Extração dos dados abertos da Câmara dos Deputados com Apache Hop, carregando um PostgreSQL (Supabase).

As seções 1 a 8 explicam o que a camada faz e não exigem conhecimento de Hop. Da 9 em diante o texto assume familiaridade com a ferramenta e com SQL.

Os volumes citados aqui são relativos de propósito. O número de deputados, de despesas e de páginas muda a cada legislatura, e qualquer número absoluto escrito neste documento envelheceria mal. Os totais reais de cada execução aparecem no log.

> A documentação da camada refined fica em `02. refined/documentacao/`. Esta aqui explica de onde os dados vêm; a de lá explica o que é feito com eles depois.

---

## 1. O que esta camada faz

Deputados federais têm direito a uma verba de custeio do mandato, a cota parlamentar, usada para passagens, combustível, aluguel de escritório, telefone e divulgação. Cada gasto é comprovado por nota fiscal e a Câmara publica tudo.

Os dados são públicos, mas inconvenientes de usar: é preciso consultar deputado por deputado, e as despesas vêm fatiadas em páginas.

Esta camada automatiza a coleta e grava cinco tabelas com os dados **crus**: unidades federativas, teto da cota parlamentar por UF e mês, deputados em exercício, despesas da legislatura corrente e ocupações profissionais declaradas.

Quatro dessas tabelas vêm da API da Câmara, exatamente como ela devolveu. A quinta, o teto da cota, não: a Câmara não publica esse valor no Dados Abertos, então a origem é uma planilha mantida à parte. Mesmo assim, o princípio se mantém — a tabela guarda o dado como veio da origem, sem tratamento.

Uma das tabelas, `raw.uf`, vai além: a maior parte das colunas vem da Câmara, mas a URL da imagem da bandeira de cada estado vem de uma terceira origem, uma API pública diferente — a Câmara também não publica isso. É a única coluna do projeto inteiro que combina duas APIs distintas dentro da mesma tabela.

Nada é limpo, corrigido ou padronizado aqui. Textos vêm em caixa alta, campos vêm nulos, linhas vazias são preservadas. O tratamento é papel da camada refined.

---

## 2. Como executar

Antes da primeira vez, rode `01. raw/ddl.sql` no banco. Ele derruba e recria as cinco tabelas.

Para rodar só esta camada, abra **`03.workflows/wkf_raw_camara.hwf`**. Para a carga completa (raw e refined), abra **`03.workflows/wkf_projeto_camara.hwf`**.

| Fluxo | Peso | Origem | Tabela |
|---|---|---|---|
| `get_uf` | segundos | API | `raw.uf` |
| `get_cotas` | segundos | planilha | `raw.cotas` |
| `get_deputados` | segundos | API | `raw.deputados` |
| `get_despesas` | ordens de grandeza maior | API | `raw.despesas` |
| `get_ocupacoes` | minutos | API | `raw.ocupacoes` |

Praticamente todo o tempo de execução está no `get_despesas`, que faz uma chamada HTTP por página de despesa.

### Sobre o `get_cotas`

É o único fluxo que não acessa a internet. Ele lê a planilha `cota_parlamentar_ceap_2023_2026.xlsx`, cujo caminho fica na variável `P_ARQUIVO_COTAS`, definida em `project-config.json` — não escrito à mão no pipeline. Se o arquivo mudar de lugar, troca-se a variável nesse arquivo, e não dentro do `.hpl`.

Se o passo falhar com erro de arquivo não encontrado, é isso: o caminho configurado não existe naquela máquina.

### Sobre a bandeira em `get_uf`

O endereço da API de bandeiras fica na variável `P_URL_BANDEIRAS_ESTADOS`, também em `project-config.json`, mesmo padrão do endereço da Câmara. É uma origem externa nova: se um dia trocar de provedor, ou a Codante mudar o domínio, o ajuste é nessa variável, não dentro do `get_uf.hpl`.

### Acompanhando pelo log

O `get_despesas` escreve o próprio andamento. Três marcos:

```
Deputados a consultar        → assim que a consulta ao banco termina
Paginas a baixar             → quando a coleta começa
Paginas baixadas ate agora   → a cada N páginas durante a coleta
```

O intervalo é o parâmetro `P_INTERVALO_LOG_PAGINAS`, que vem com 250. Comparar "páginas baixadas até agora" com "páginas a baixar" dá a fração concluída.

O `get_ocupacoes` escreve só o total de deputados a consultar. Como não há paginação, o número de chamadas é o próprio número de deputados, e o passo é curto o bastante para não precisar de acompanhamento contínuo.

O `get_cotas` não escreve log de andamento: lê uma planilha inteira de uma vez, é questão de segundos.

### Conferindo o resultado

```sql
SELECT COUNT(*) FROM raw.uf;
SELECT COUNT(*) FROM raw.cotas;
SELECT COUNT(*) FROM raw.deputados;
SELECT COUNT(*) FROM raw.despesas;
SELECT COUNT(*) FROM raw.ocupacoes;

-- despesas órfãs: deve voltar zero
SELECT COUNT(*)
FROM   raw.despesas d
LEFT   JOIN raw.deputados p ON p.id_deputado = d.id_deputado
WHERE  p.id_deputado IS NULL;

-- ocupações órfãs: deve voltar zero
SELECT COUNT(*)
FROM   raw.ocupacoes o
LEFT   JOIN raw.deputados p ON p.id_deputado = o.id_deputado
WHERE  p.id_deputado IS NULL;

-- cotas com UF que não existe em raw.uf: deve voltar zero
-- (normalmente sinal de sigla digitada errado na planilha)
SELECT COUNT(*)
FROM   raw.cotas c
LEFT   JOIN raw.uf u ON u.sg_uf = c.sg_uf
WHERE  u.sg_uf IS NULL;

-- deputados sem ocupação registrada: informativo, não é erro
SELECT COUNT(*)
FROM   raw.ocupacoes
WHERE  ds_titulo IS NULL AND nm_entidade IS NULL;

-- UF sem bandeira encontrada na segunda origem: informativo, não deveria acontecer
SELECT cd_uf, sg_uf, nm_uf
FROM   raw.uf
WHERE  ds_url_bandeira IS NULL OR ds_url_bandeira = '';
```

---

## 3. Visão geral

```
Start → get_uf → get_cotas → get_deputados → get_despesas → get_ocupacoes → Success
          ↓          ↓             ↓               ↓               ↓
        raw.uf   raw.cotas   raw.deputados   raw.despesas   raw.ocupacoes
```

Cada seta significa **"só continue se o passo anterior deu certo"**. Se algo falhar no meio, o workflow para e não executa o resto — é proposital: melhor parar com a carga incompleta do que seguir gravando dados inconsistentes.

### Por que essa ordem

`get_despesas` e `get_ocupacoes` precisam saber **quem** são os deputados antes de consultá-los. Ambos leem essa lista da tabela que `get_deputados` acabou de gravar.

`get_ocupacoes` depende do `get_deputados`, não do `get_despesas`. Está por último apenas para não competir por conexão com a coleta pesada.

`get_uf` e `get_cotas` não dependem de ninguém e ninguém depende deles. Estão no início por serem baratos e por serem, os dois, tabelas de apoio — referência, não coleta de evento.

---

## 4. `get_uf`

Fluxo de referência do projeto — com uma particularidade que os outros três não têm: duas origens diferentes se juntam num só fluxo.

`get_deputados`, `get_despesas` e `get_ocupacoes` seguem a estrutura simples das caixas 1 a 4 abaixo. O `get_uf` acrescenta uma segunda fila, que roda em paralelo, e um ponto de junção.

### A fila principal, da Câmara

| # | Caixa | O que faz |
|---|---|---|
| 1 | Montar o endereço | Monta a URL a partir da configuração do projeto |
| 2 | Chamar a API | Requisição HTTP; a resposta vai para o campo `result` |
| 3 | Abrir a resposta | Isola o nó `dados` |
| 4 | Separar um estado por linha | Quebra a lista em linhas: código, sigla, nome, descrição |

São duas caixas para ler a resposta (3 e 4) porque a API devolve tudo num pacote só: a 3 abre o pacote e isola a lista, a 4 quebra a lista em linhas.

### A fila da bandeira, de uma segunda API

A Câmara não expõe imagem de bandeira em nenhum lugar do Dados Abertos. A origem é outra API pública, a [Bandeiras dos Estados Brasileiros da Codante](https://docs.apis.codante.io/bandeiras-dos-estados), sem autenticação, com imagens de [Pierre Lapalu](https://github.com/pierrelapalu/icones-bandeiras-br-uf).

| Caixa | O que faz |
|---|---|
| Montar o endereço das bandeiras | Monta a URL a partir da configuração do projeto |
| Chamar a API de bandeiras | Uma chamada só traz as 27 unidades federativas |
| Separar as bandeiras | Quebra a lista em uma linha por estado: sigla (`uf`) e link da bandeira (`flag_url`) |

Só uma caixa para ler a resposta, e não duas como na fila da Câmara: essa API devolve a lista diretamente, sem um nó como "dados" envolvendo tudo. Não há o que isolar antes de quebrar em linhas.

A API também devolve versões arredondada, quadrada e circular da bandeira; nenhuma delas é usada aqui — só a original (`flag_url`).

### A junção e o resto do fluxo

| # | Caixa | O que faz |
|---|---|---|
| 5 | Buscar a bandeira do estado | Junta as duas filas pela sigla |
| 6 | Renomear as colunas | Aplica os nomes do banco |
| 7 | Gravar em raw.uf | Truncate e insert |

A caixa 5 é um `Stream lookup`: para cada linha da fila principal, procura na fila de bandeiras a linha cuja sigla bate, e traz o link. Estado sem bandeira encontrada não derruba o fluxo — fica com o valor em branco. Na prática isso não deveria acontecer, já que as duas origens cobrem as mesmas 27 unidades federativas, mas o fluxo não quebra se algum dia cobrir.

O nome do estado vem em caixa alta (`SÃO PAULO`) e é gravado assim, junto com o link da bandeira, sem tratamento nenhum. Quem padroniza as iniciais e remove o acento é a camada refined.

---

## 5. `get_cotas`

O único fluxo da camada que não chama a API. O teto da cota parlamentar por UF não está no Dados Abertos, então a origem é uma planilha mantida à parte, com uma linha por UF e mês de competência.

Sem paginação, sem chamada HTTP — é o fluxo mais curto do projeto.

| # | Caixa | O que faz |
|---|---|---|
| 1 | Ler a planilha de cotas | Lê a aba "Cota Parlamentar CEAP" do arquivo apontado por `P_ARQUIVO_COTAS` |
| 2 | Selecionar as colunas | Fixa as três colunas e descarta o que estiver fora delas |
| 3 | Gravar em raw.cotas | Truncate e insert |

### O que a planilha traz

Três colunas: mês de competência, sigla do estado e o valor de teto vigente naquele mês.

| Coluna da planilha | Vira na tabela | Observação |
|---|---|---|
| Mês de competência | `dt_competencia` | Texto `"mm/aaaa"`, gravado como veio |
| Sigla do estado | `sg_uf` | |
| Valor de teto | `vl_cota` | |

`dt_competencia` fica como **texto** aqui de propósito, e não como data: a planilha não traz um dia, só mês e ano, e a raw não inventa dado que a origem não tem. A conversão para data — assumindo o primeiro dia do mês — é feita na camada refined, não aqui.

### Por que o teto muda com o tempo

O valor de cota por UF é definido por Ato da Mesa da Câmara e pode ser reajustado. Por isso a granularidade é UF **e** mês, não só UF: o mesmo estado pode ter tetos diferentes em meses diferentes.

---

## 6. `get_deputados`

Mesma estrutura do `get_uf`. Traz código, nome, partido, estado, legislatura, foto e e-mail.

| # | Caixa | O que faz |
|---|---|---|
| 1 | Montar o endereço | Monta a URL |
| 2 | Chamar a API | Uma chamada traz todos os deputados |
| 3 | Abrir a resposta | Isola o nó `dados` |
| 4 | Separar um deputado por linha | Quebra a lista em linhas |
| 5 | Renomear as colunas | Renomeia e converte `id_legislatura` para inteiro |
| 6 | Gravar em raw.deputados | Truncate e insert |

**Legislatura** é o período de mandato. `get_despesas` e `get_ocupacoes` usam o maior valor dessa coluna para filtrar a legislatura corrente.

A conversão para inteiro na caixa 5 não é cosmética: `MAX` sobre texto ordenaria `"9"` acima de `"57"`.

A API devolve todos os deputados numa resposta só, então aqui não há paginação a tratar.

---

## 7. `get_despesas`

O fluxo mais complexo do projeto.

### O problema

A API entrega as despesas em páginas de tamanho limitado e **não informa quantas páginas existem**. O único jeito de descobrir é pedir a primeira e ler o rodapé da resposta, onde vem o endereço da *última* página.

### A solução

Duas voltas.

**Contar (caixas 1 a 6).** Uma chamada por deputado, só para ler o rodapé. Os dados que vêm nessa chamada são descartados; interessa apenas a contagem.

**Coletar (caixas 7 a 13).** Sabendo o total, a linha de cada deputado é duplicada uma vez por página. Cada linha vira uma tarefa independente que busca a sua própria página.

Daí as duas chamadas HTTP do fluxo, nas caixas 4 e 9.

### As caixas

| # | Caixa | O que faz |
|---|---|---|
| 1 | Ler os deputados | Lê do banco quem consultar e a legislatura |
| 2 | Pegar endereço e tamanho de página | Anexa configurações a cada linha |
| 3 | Montar endereço de teste | URL da página 1 de cada deputado |
| 4 | Perguntar quantas páginas existem | Sonda: uma chamada por deputado |
| 5 | Achar o link da última página | Procura o atalho `last` no rodapé |
| 6 | Contar as páginas | Recorta o número do endereço |
| 7 | Criar uma linha por página | Duplica a linha, uma por página |
| 8 | Montar o endereço de cada página | URL definitiva de cada página |
| 9 | Baixar as despesas | Coleta real, 4 cópias em paralelo |
| 10 | Abrir a resposta | Isola `dados` e numera as páginas lidas |
| 11 | Separar uma despesa por linha | Quebra em linhas e tipa as colunas |
| 12 | Renomear as colunas | Aplica nomes do banco, descarta apoio |
| 13 | Gravar em raw.despesas | Truncate e insert em lotes |

Fora da fila principal ficam cinco caixas que só escrevem no log: `Contar deputados`, `Log: total de deputados`, `Contar páginas`, `Log: total de páginas` e, no meio da coleta, `Marcar o intervalo de log` → `Separar os marcos` → `Log: páginas baixadas`.

---

## 8. `get_ocupacoes`

Busca o histórico profissional declarado por cada deputado: cargo, entidade, estado e país da entidade, ano de início e ano de fim.

Ao contrário do `get_despesas`, **este endpoint não tem paginação**. Uma chamada por deputado traz o histórico inteiro, então o fluxo é direto.

| # | Caixa | O que faz |
|---|---|---|
| 1 | Ler os deputados | Lê do banco quem consultar |
| 2 | Pegar o endereço base | Anexa a configuração a cada linha |
| 3 | Montar o endereço | URL de ocupações de cada deputado |
| 4 | Buscar as ocupações | Uma chamada por deputado, 4 cópias em paralelo |
| 5 | Abrir a resposta | Isola o nó `dados` |
| 6 | Separar uma ocupação por linha | Quebra a lista em linhas |
| 7 | Renomear as colunas | Aplica os nomes do banco |
| 8 | Gravar em raw.ocupacoes | Truncate e insert |

Mais `Contar deputados` → `Log: total de deputados`, fora da fila principal.

### A pegadinha das linhas vazias

Deputado sem ocupação registrada **não devolve uma lista vazia**. Devolve uma linha com todos os campos nulos:

```json
{"dados":[{"titulo":null,"entidade":null,"entidadeUF":null,
           "entidadePais":null,"anoInicio":null,"anoFim":null}]}
```

Essas linhas são gravadas aqui **de propósito**, por fidelidade à origem: elas registram que a API foi consultada e não tinha nada a informar. Quem descarta é a camada refined.

Se você consultar `raw.ocupacoes` diretamente, filtre:

```sql
WHERE ds_titulo IS NOT NULL OR nm_entidade IS NOT NULL
```

---

## 9. Detalhes técnicos

### 9.1 Paginação: probe + fan-out

A API de despesas não retorna contagem no corpo. O bloco `links` traz um item com `rel="last"` cujo `href` contém o número da última página:

```json
"links": [
  { "rel": "self",  "href": "...&pagina=1&itens=100" },
  { "rel": "next",  "href": "...&pagina=2&itens=100" },
  { "rel": "first", "href": "...&pagina=1&itens=100" },
  { "rel": "last",  "href": "...&pagina=7&itens=100" }
]
```

O padrão implementado:

1. **Probe** (caixa 4) — um `GET` por deputado com `pagina=1`.
2. **Extração** (caixa 5) — JsonInput com JSONPath `$.links[?(@.rel=='last')].href`.
3. **Contagem** (caixa 6) — Janino com regex sobre o href, menos um.
4. **Fan-out** (caixa 7) — `Clone row` com número de clones vindo de campo.
5. **Coleta** (caixas 8–9) — um `GET` por linha resultante.

O padrão existe porque não há laço dentro de um pipeline do Hop. A repetição precisa ser materializada como linhas, o que tem a vantagem de cada linha virar uma tarefa paralelizável.

O `menos um` da caixa 6 é porque `Clone row` mantém a linha original e cria N cópias adicionais.

`get_ocupacoes` e `get_cotas` não precisam de nada disso: o primeiro porque o endpoint devolve tudo de uma vez, o segundo porque nem é uma chamada HTTP.

### 9.2 Armadilhas

**A ordem dos itens em `links` muda.** Na primeira página é `[self, next, first, last]`; na última, `next` some e surge `previous`. Por isso o JSONPath filtra por `rel` e nunca por índice. Trocar por `$.links[3].href` não gera erro: apenas passa a contar páginas erradas, e despesas somem em silêncio.

**`defaultPathLeafToNull` precisa ficar `Y`** nas caixas que quebram listas em linhas, tanto em despesas quanto em ocupações. Vários campos vêm nulos com frequência (URL de nota, ano de fim de vínculo ativo). Com a flag desligada, o JsonInput não emite placeholder para o ausente: os arrays paralelos encurtam e ficam desalinhados entre si, colando o valor de uma linha em outra. Não dá erro, produz dado errado.

**`cd_documento` não é único e nem sempre é numérico.** Despesas SIGEPA repetem o mesmo código em linhas de valores diferentes, e algumas vêm como GUID. Daí a coluna ser `text` e a PK ser surrogate.

**Valores negativos são legítimos.** Existem estornos. Não filtre por `> 0`.

**`numRessarcimento` quase sempre vem vazio.** Só é preenchido quando houve devolução. Não é falha de extração.

**`idLegislatura` é obrigatório em despesas.** Sem ele, ou com apenas `ano`, o endpoint devolve `{"dados": []}` sem erro.

**Ocupações devolvem linha de nulos, não lista vazia.** Ver seção 8.

**`get_cotas` depende de um arquivo local.** Ao contrário dos outros quatro fluxos, ele não roda em qualquer máquina sem ajuste: o caminho em `P_ARQUIVO_COTAS` precisa apontar para um arquivo que existe ali.

**`get_uf` depende de duas APIs de propósitos diferentes.** Se a API de bandeiras (Codante) sair do ar, a fila da Câmara continua funcionando sozinha — o `Stream lookup` só deixa a bandeira em branco, não derruba o fluxo. Ver seção 9.7.

### 9.3 Por que a legislatura sai de subquery

As caixas de leitura de `get_despesas` e `get_ocupacoes` usam:

```sql
WHERE id_legislatura = (SELECT MAX(id_legislatura) FROM raw.deputados)
```

Uma versão anterior recebia esse valor de uma variável de escopo JVM definida pelo `get_deputados`. Dois problemas: o pipeline não rodava isolado, e a GUI do Hop dava erro ao desenhar o diagrama — ela percorre a cadeia para trás e pede ao Postgres os campos da query, e como a variável não existe no espaço da GUI, o literal `${...}` ia para o banco, gerando `syntax error at or near "$"`.

Com a subquery o resultado é idêntico, porque o `get_deputados` acabou de truncar e recarregar a tabela. A dependência entre os pipelines passou a ser de dados, não de variável.

### 9.4 Como o log de andamento funciona

No `get_despesas`, a caixa 10 é um JsonInput com `rownum` ligado, gravando em `nr_pagina_lida`. Como ela emite uma linha por página baixada, esse campo é um contador global de páginas.

Em seguida:

- `Marcar o intervalo de log` (Janino) calcula `nr_pagina_lida % V_INTERVALO_LOG`.
- `Separar os marcos` (FilterRows) manda resto zero para o `Write to log` e o resto direto para a caixa 11.
- `Log: páginas baixadas` (WriteToLog) escreve e devolve a linha para a caixa 11.

Nada é descartado: os dois caminhos reconvergem. Os totais no início vêm de ramos laterais com `MemoryGroupBy` contando linhas, o que exige `distribute=N` (modo Copiar) nas caixas que alimentam esses ramos — sem isso as linhas seriam divididas entre a fila principal e o contador.

O `get_ocupacoes` usa a mesma técnica de ramo lateral, só que apenas para o total inicial.

### 9.5 Configurações que importam

| Onde | Configuração | Valor | Por quê |
|---|---|---|---|
| `get_despesas` caixa 4 | Cópias | 2 | Paraleliza as sondas |
| `get_despesas` caixa 9 | Cópias | 4 | Paraleliza a coleta. Não passe de 8 ou a API devolve 429 |
| `get_ocupacoes` caixa 4 | Cópias | 4 | Mesmo limite |
| TableOutput (todos) | Cópias | 1 | Com `truncate=Y`, várias cópias truncariam a tabela cada uma por conta |
| TableOutput (todos) | Commit | 1000 | Tamanho do lote de insert |
| REST (`get_uf`, `get_despesas`, `get_ocupacoes`) | applicationType | JSON | `TEXT PLAIN` pode corromper acentuação |
| REST (`get_uf`, `get_despesas`, `get_ocupacoes`) | readTimeout | 30000 ms | O padrão de 10s é curto para páginas cheias |

### 9.6 Ajuste de performance

Se a execução estiver lenta, o gargalo raramente é a rede:

1. Aumentar o commit do TableOutput de despesas.
2. Dar 2 cópias à caixa que quebra o JSON em linhas, já que o parse é CPU-bound.
3. Só então mexer nas cópias do REST, sem passar de 8.

O `get_cotas` não entra nesse ajuste: lê um arquivo local pequeno, não há rede nem paginação a otimizar.

### 9.7 Stream lookup: juntando duas origens em `get_uf`

É a única caixa do projeto do tipo `Stream lookup`, e o único ponto onde duas chamadas de API completamente independentes se encontram no mesmo pipeline.

**Por que duas filas, e não uma chamada dentro da outra.** As despesas e ocupações usam o padrão "uma chamada por deputado" porque a API da Câmara não tem outro jeito. Aqui não é o caso: a API de bandeiras devolve as 27 UFs numa chamada só, igual à API de referências de estado. Encadear (chamar a bandeira depois de cada estado, um por um) seria 27 chamadas onde uma basta. Buscar as duas listas em paralelo e juntar depois é mais simples e mais barato.

**Como a junção funciona.** A caixa `5. Buscar a bandeira do estado` recebe duas entradas: a fila principal (caixa 4, à esquerda no diagrama) e a fila de bandeiras (a fila de consulta, a direita). O campo `from` do `Stream lookup` aponta para o nome da caixa que é a fila de consulta — aqui, `Separar as bandeiras`. Sem isso, o Hop não sabe qual das duas entradas é a principal e qual é a tabela de consulta.

**A chave de junção não precisa de tratamento.** `sigla` (fila da Câmara) e `uf` (fila de bandeiras) já vêm no mesmo formato — sigla de duas letras, maiúscula — então a comparação funciona direto, sem `TRIM` nem ajuste de caixa.

**Estado sem bandeira não é erro.** O `Stream lookup` tem uma coluna de valor padrão para quando a chave não é encontrada na fila de consulta; aqui ela fica vazia. Se um dia a API de bandeiras parar de cobrir alguma UF, o `get_uf` continua rodando — só aquela linha fica sem `ds_url_bandeira`.

---

## 10. Tabelas

Todas no schema `raw`, com dados crus, sem tratamento. Todas em carga full: truncate e regrava a cada execução.

O DDL fica em `01. raw/ddl.sql`. Os tipos espelham o que cada pipeline entrega no TableOutput — mudar um tipo lá sem mudar o "Renomear as colunas" (ou "Selecionar as colunas") correspondente quebra a carga.

Não há chave estrangeira entre as tabelas. Os pipelines gravam com truncate, e o Postgres recusa `TRUNCATE` numa tabela referenciada por FK, inclusive com a filha vazia. As ligações são lógicas; as consultas de verificação estão no fim do `ddl.sql`.

### `raw.uf`

| Coluna | Tipo | Observação |
|---|---|---|
| `cd_uf` | text | PK. Código da Câmara, não do IBGE |
| `sg_uf` | text | Unique |
| `nm_uf` | text | Caixa alta, como a API entrega |
| `ds_uf` | text | A API devolve sempre vazio |
| `ds_url_bandeira` | text | URL da bandeira (SVG). **Vem de outra API, não da Câmara.** Vazio se a sigla não for encontrada nela |

### `raw.cotas`

| Coluna | Tipo | Observação |
|---|---|---|
| `id_cota` | bigserial | PK artificial. Renumera a cada carga |
| `dt_competencia` | text | `"mm/aaaa"`, exatamente como vem na planilha |
| `sg_uf` | text | Liga com `raw.uf.sg_uf` |
| `vl_cota` | numeric(14,2) | Teto vigente naquele mês para a UF |
| `dt_carga` | timestamptz | Default do banco |

Único par (`sg_uf`, `dt_competencia`) por UF e mês — reforçado por um índice único, que é a forma de o banco acusar linha duplicada vinda da planilha.

### `raw.deputados`

| Coluna | Tipo | Observação |
|---|---|---|
| `id_deputado` | text | PK. Texto porque é concatenado em URLs |
| `uri_deputado` | text | |
| `nm_deputado` | text | Nome parlamentar |
| `sg_partido` | text | |
| `uri_partido` | text | |
| `sg_uf` | text | Liga com `raw.uf.sg_uf` |
| `id_legislatura` | integer | Base do filtro de legislatura corrente |
| `ds_url_foto` | text | |
| `ds_email` | text | |

### `raw.despesas`

| Coluna | Tipo | Observação |
|---|---|---|
| `id_despesa` | bigserial | PK artificial. Renumera a cada carga |
| `id_deputado` | text | Não vem da API; propagado pelo pipeline |
| `nr_ano` / `nr_mes` | integer | Competência, não a data do documento |
| `ds_tipo_despesa` | text | Caixa alta, como a API entrega |
| `cd_documento` | text | Não é único; pode ser número ou GUID |
| `ds_tipo_documento` | text | |
| `cd_tipo_documento` | integer | |
| `dt_documento` | timestamp | |
| `nr_documento` | text | |
| `vl_documento` | numeric(14,2) | Pode ser negativo |
| `ds_url_documento` | text | Nulo em boa parte das linhas |
| `nm_fornecedor` | text | |
| `nr_cnpj_cpf_fornecedor` | text | Só dígitos, sem máscara |
| `vl_liquido` | numeric(14,2) | Já descontada a glosa |
| `vl_glosa` | numeric(14,2) | |
| `nr_ressarcimento` | text | Vazio na maioria |
| `cd_lote` | bigint | |
| `nr_parcela` | integer | |
| `dt_carga` | timestamptz | Default do banco |

### `raw.ocupacoes`

| Coluna | Tipo | Observação |
|---|---|---|
| `id_ocupacao` | bigserial | PK artificial. Renumera a cada carga |
| `id_deputado` | text | Não vem da API; propagado pelo pipeline |
| `ds_titulo` | text | Cargo ou função. **Nulo nas linhas vazias** |
| `nm_entidade` | text | **Nulo nas linhas vazias** |
| `sg_uf_entidade` | text | Estado da entidade, não o do mandato |
| `nm_pais_entidade` | text | |
| `nr_ano_inicio` | integer | |
| `nr_ano_fim` | integer | Nulo costuma indicar vínculo ativo |
| `dt_carga` | timestamptz | Default do banco |

### Sobre o `dt_carga`

A coluna é `timestamptz`, não `timestamp`, e isso importa. O servidor do Supabase roda em UTC: com `timestamp` simples, `now()` gravaria a hora de Londres e a coluna não teria como registrar isso. Com `timestamptz` o instante fica absoluto e cada cliente — psql, DBeaver, Power BI — exibe no próprio fuso.

O valor é preenchido pelo default do banco, não pelo pipeline.

---

## 11. Erros comuns

**`syntax error at or near "$"` ao clicar num step.** Uma query com `${VARIAVEL}` sendo enviada literal ao banco pela GUI. Não afeta a execução, só o desenho da tela. Resolve-se tirando a variável do SQL.

**`Error finding field [xxx] in incoming stream!`** O step anterior não criou o campo. Em transforms Janino costuma ser XML mal formado: as tags são `field_name` e `formula_string` dentro de um elemento `<formula>`, sem envelope `<fields>`. O Hop ignora tag desconhecida em silêncio e carrega o step vazio.

**Erros com logger `...Meta@hash`.** Não são erros de execução. Erro real aparece como `NomeDoStep.0 - ERROR:`. Os com hash de objeto vêm da GUI resolvendo metadados.

**HTTP 429 na coleta.** Chamadas simultâneas demais. Reduza as cópias do REST.

**`raw.despesas` vazia sem erro.** Ou `raw.deputados` está vazia, ou `idLegislatura` não está indo na URL.

**`raw.ocupacoes` com muitas linhas nulas.** Não é erro. Ver seção 8.

**`get_cotas` falha com arquivo não encontrado.** O caminho em `P_ARQUIVO_COTAS` (`project-config.json`) não existe naquela máquina. É o único fluxo com dependência de arquivo local, então é o único que quebra ao trocar de computador sem ajustar configuração.

**`raw.uf.ds_url_bandeira` sempre vazio.** A API de bandeiras pode estar fora do ar, ou a variável `P_URL_BANDEIRAS_ESTADOS` pode estar apontando para o lugar errado. Não derruba o fluxo (ver seção 9.7), então passa despercebido se ninguém checar a coluna depois da carga — use a consulta de verificação da seção 2.

**`StreamLookupMeta.CheckResult.NeedAtLeast2InputStreams` ou aviso parecido na caixa 5 do `get_uf`.** O `Stream lookup` precisa de duas entradas ligadas nele: a fila principal e a fila de bandeiras. Se um dos dois hops for apagado sem querer, a caixa reclama.

**`RuntimeException: Endless loop detected for substitution of variable` ao rodar um pipeline.** Um parâmetro de pipeline com o mesmo nome de uma variável de projeto, e valor padrão apontando para si mesmo (`<default_value>${MESMO_NOME}</default_value>`), faz o Hop entrar em loop tentando resolver a variável. Aconteceu duas vezes neste projeto: em `get_uf` com `P_URL_BANDEIRAS_ESTADOS`, e em `get_cotas` com `P_ARQUIVO_COTAS`. Nos dois casos a variável de projeto já é o valor completo (URL ou caminho de arquivo), sem nada para concatenar, então o parâmetro de pipeline era desnecessário — foi removido, e as caixas passaram a usar `${P_URL_BANDEIRAS_ESTADOS}` e `${P_ARQUIVO_COTAS}` direto, sem passar por parâmetro. Compare com a caixa 1 de `get_uf`, que combina a base do projeto com um sufixo através do parâmetro `P_URL_DADOS_ABERTOS_CAMARA` — nome diferente da variável de projeto que ele usa (`P_URL_BASE_DADOS_ABERTOS_CAMARA`), por isso não tem esse problema. Regra geral: um parâmetro de pipeline nunca deve ter o mesmo nome da variável de projeto no seu próprio valor padrão.

---

## 12. Glossário

| Termo | Significado |
|---|---|
| API | Endereço que devolve dados em formato de máquina |
| JSON | Formato de texto para troca de dados entre sistemas |
| Paginação | Devolver resultados em pedaços |
| Pipeline (`.hpl`) | Fluxo de transformação de dados |
| Workflow (`.hwf`) | Orquestrador que chama pipelines em ordem |
| Transform, step, "caixa" | Cada quadradinho dentro de um pipeline |
| Hop | A seta que liga dois steps |
| Schema `raw` | Camada de dados crus |
| Truncate | Esvaziar a tabela antes de gravar |
| Carga full | Recarregar tudo, em vez de só as novidades |
| Legislatura | Período de mandato |
| Cota parlamentar | Verba de custeio do mandato |
| CEAP | Cota para o Exercício da Atividade Parlamentar, nome oficial da cota |
| Mês de competência | Mês a que um valor se refere, podendo ser diferente do mês em que foi registrado |
| Stream lookup | Transform que junta duas filas de dados dentro do mesmo pipeline, buscando um valor de uma pela chave da outra |
| Fila de consulta (info stream) | Na junção de duas filas, a que fornece o valor buscado, e não a que dá o volume de linhas do resultado |

---

## 13. Arquivos

```
01. Apache Hop - Projeto Câmara/
├── 01. raw/
│   ├── ddl.sql                cria as cinco tabelas da raw
│   ├── get_uf.hpl
│   ├── get_cotas.hpl
│   ├── get_deputados.hpl
│   ├── get_despesas.hpl
│   ├── get_ocupacoes.hpl
│   └── documentacao/
│       ├── documentacao.md
│       └── documentacao.html
├── 02. refined/               modelo estrela (documentação própria)
├── 03.workflows/
│   ├── wkf_projeto_camara.hwf ← carga completa; execute por aqui
│   ├── wkf_raw_camara.hwf
│   └── wkf_refined_camara.hwf
└── metadata/
```

---

Fonte: API de Dados Abertos da Câmara dos Deputados, <https://dadosabertos.camara.leg.br/swagger/api.html>. Dados públicos, sem autenticação. A tabela `raw.cotas` é exceção: vem de planilha mantida à parte.
