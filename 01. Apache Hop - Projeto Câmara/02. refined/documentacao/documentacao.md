# Projeto Câmara — camada refined

Modelo estrela construído sobre o schema `raw`, com Apache Hop e PostgreSQL (Supabase).

As seções 1 a 6 explicam o que a camada faz e não exigem conhecimento de Hop. Da 7 em diante o texto assume familiaridade com a ferramenta e com SQL.

Volumes são citados de forma relativa. Os números mudam a cada legislatura; os totais reais de cada execução aparecem no log.

> A documentação da camada raw fica em `01. raw/documentacao/`. Ela explica de onde os dados vêm. Esta aqui explica o que é feito com eles depois.

---

## 1. O que esta camada faz

A camada `raw` guarda os dados como a origem devolveu: todas as colunas, sem tratamento, textos em caixa alta, linhas vazias preservadas. É fiel à origem, mas desconfortável de consultar.

A camada `refined` reorganiza isso num **modelo estrela**: duas tabelas de dimensão, que descrevem *quem* e *onde*, e três tabelas fato, que registram *o que aconteceu* — ou, no caso de uma delas, *o que era permitido*.

```
   dim_uf                    dim_deputado              fato_despesas
   ┌─────────────────┐        ┌──────────────┐          ┌──────────────┐
   │ sg_uf           │◄──┬───│ sg_uf        │◄─────┐   │ id_despesa   │
   │ nm_uf           │   │   │ id_deputado  │◄──┐  └───│ id_deputado  │
   │ ds_url_bandeira │   │   │ nm_deputado  │   │      │ dt_documento │
   └─────────────────┘    │   │ sg_partido   │   │      │ vl_documento │
                          │   │ ds_url_foto  │   │      └──────────────┘
                          │   └──────────────┘   │
           fato_cotas     │                      │      fato_ocupacao
           ┌──────────────┐                      │      ┌──────────────┐
           │ id_cota      │                      └──────│ id_ocupacao  │
           │ sg_uf        │                             │ id_deputado  │
           │ dt_competencia│                            │ ds_titulo    │
           │ vl_cota      │                             │ nm_entidade  │
           └──────────────┘                             └──────────────┘
```

Quatro coisas acontecem aqui:

**Seleção.** Só passa adiante o que a análise usa. URIs de API, e-mail de gabinete, código de lote e número de parcela ficam na raw.

**Formatação.** O CNPJ/CPF, que vem só com dígitos, ganha máscara. O mês de competência da cota, que vem como texto, vira data.

**Padronização.** Textos que a API entrega em caixa alta passam a ter apenas as iniciais em maiúscula. O nome do estado também perde a acentuação.

**Derivação.** Uma coluna nova, `tp_pessoa`, classifica o fornecedor em pessoa física ou jurídica.

E uma limpeza: as linhas vazias que a raw guarda para deputado sem ocupação registrada são descartadas.

`fato_cotas` é diferente das outras duas fatos: não tem grão de deputado, registra o teto permitido por UF e mês, não um gasto. Serve de referência para comparar contra `fato_despesas`.

---

## 2. Como executar

Antes da primeira vez, rode `02. refined/ddl.sql` no banco. Ele derruba e recria as cinco tabelas. A camada raw precisa existir antes.

Para rodar só esta camada, abra **`03.workflows/wkf_refined_camara.hwf`**. Para a carga completa (raw e refined), abra **`03.workflows/wkf_projeto_camara.hwf`**.

| Pipeline | Peso | Tabela |
|---|---|---|
| `dim_uf` | segundos | `refined.dim_uf` |
| `fato_cotas` | segundos | `refined.fato_cotas` |
| `dim_deputado` | segundos | `refined.dim_deputado` |
| `fato_despesas` | o volume da camada | `refined.fato_despesas` |
| `fato_ocupacao` | segundos | `refined.fato_ocupacao` |

Esta camada é rápida em comparação com a raw: não acessa a internet, lê do próprio banco.

### Conferindo o resultado

Como não há chave estrangeira declarada, vale rodar as verificações depois da carga. Todas devem voltar zero:

```sql
-- despesas de deputado que não existe na dimensão
SELECT COUNT(*)
FROM   refined.fato_despesas f
LEFT   JOIN refined.dim_deputado d ON d.id_deputado = f.id_deputado
WHERE  d.id_deputado IS NULL;

-- ocupações de deputado que não existe na dimensão
SELECT COUNT(*)
FROM   refined.fato_ocupacao o
LEFT   JOIN refined.dim_deputado d ON d.id_deputado = o.id_deputado
WHERE  d.id_deputado IS NULL;

-- deputados de UF que não existe na dimensão
SELECT COUNT(*)
FROM   refined.dim_deputado d
LEFT   JOIN refined.dim_uf u ON u.sg_uf = d.sg_uf
WHERE  u.sg_uf IS NULL;

-- cotas de UF que não existe na dimensão
SELECT COUNT(*)
FROM   refined.fato_cotas c
LEFT   JOIN refined.dim_uf u ON u.sg_uf = c.sg_uf
WHERE  u.sg_uf IS NULL;

-- ocupações vazias que escaparam do filtro
SELECT COUNT(*)
FROM   refined.fato_ocupacao
WHERE  ds_titulo IS NULL AND nm_entidade IS NULL;
```

---

## 3. Visão geral

```
Start → dim_uf → fato_cotas → dim_deputado → fato_despesas → fato_ocupacao → Success
          ↓           ↓             ↓                ↓                ↓
       dim_uf    fato_cotas    dim_deputado    fato_despesas    fato_ocupacao
```

Cada seta significa "só continue se o anterior deu certo".

A ordem segue a convenção de modelo dimensional: dimensões antes das fatos. Aqui isso não é imposição do banco, porque não há chave estrangeira declarada — mas vale manter, para que nenhuma fato aponte para um deputado ou UF que a dimensão ainda não tem.

`fato_cotas` fica logo após `dim_uf` porque os dois giram em torno de UF; nenhum dos dois depende de deputado. É a única fato do modelo que não precisa esperar o `dim_deputado`.

---

## 4. As duas dimensões

`dim_uf` e `dim_deputado` têm quase a mesma forma:

| # | Caixa | O que faz |
|---|---|---|
| 1 | Ler `raw.<tabela>` | `SELECT` completo da tabela de origem |
| 2 | Selecionar e formatar | Escolhe as colunas da dimensão e fixa os tipos |
| 3 | Padronizar o nome do estado | *(só em `dim_uf`)* iniciais maiúsculas |
| 4 | Remover acentos do nome do estado | *(só em `dim_uf`)* tira acentuação |
| 5 | Gravar em `refined.<tabela>` | Truncate e insert |

`dim_deputado` não tem as caixas 3 e 4: não tem nenhum texto que precise de padronização de maiúscula ou acento.

O `SELECT` da caixa 1 traz todas as colunas de propósito, mesmo as que não seguem adiante. Assim, incluir uma coluna depois é questão de marcá-la na caixa 2, sem reescrever a consulta.

### O que cada dimensão descarta, e por quê

**`dim_uf`** fica com sigla, nome e o link da bandeira. O código da Câmara não vai adiante porque nada se liga por ele: quem faz o vínculo com o deputado é a sigla. A coluna de descrição também sai, já que a API sempre a devolve vazia. O link da bandeira (`ds_url_bandeira`) segue adiante mesmo sendo um dado de outra API, não da Câmara: é URL de imagem, com o mesmo papel de `dim_deputado.ds_url_foto` — uso em relatório, não em filtro ou agrupamento.

**`dim_deputado`** descarta as URIs de API, o e-mail de gabinete e a legislatura. São metadados de coleta: úteis na raw para rastrear a origem, sem valor analítico aqui.

---

## 5. As três fatos

### `fato_cotas`

| # | Caixa | O que faz |
|---|---|---|
| 1 | Ler raw.cotas | `SELECT` com `TRIM` em `sg_uf` |
| 2 | Selecionar e formatar | Escolhe as colunas, converte o mês de competência para data |
| 3 | Gravar em `refined.fato_cotas` | Truncate e insert |

**Granularidade:** uma linha por UF e mês de competência. **Sem deputado** — é a única fato do modelo assim. Registra o teto permitido para o estado naquele mês, não um gasto individual.

**Por que é fato, e não dimensão.** O valor muda com o tempo, por Ato da Mesa. Uma dimensão descreve um atributo estável; aqui o mesmo par (UF, mês) tem valores diferentes ao longo da série, o que é comportamento de fato.

**A conversão de data.** A raw guarda o mês de competência como texto `"mm/aaaa"`. A caixa 2 usa a máscara `MM/yyyy` para convertê-lo em `date`; como a máscara não tem dia, o Hop preenche com o primeiro dia daquele mês.

**O `TRIM` na caixa 1.** A planilha de origem é alimentada à mão. Espaço sobrando na sigla do estado é o tipo de erro que passa despercebido numa digitação e quebraria o vínculo com `dim_uf`. Fica no SQL, e não em um transform do Hop, pelo mesmo motivo do CNPJ em `fato_despesas`: o banco resolve de uma vez ao montar o resultado.

### `fato_despesas`

| # | Caixa | O que faz |
|---|---|---|
| 1 | Ler e tratar `raw.despesas` | `SELECT` com máscara de CNPJ/CPF e derivação do tipo de pessoa |
| 2 | Selecionar e formatar | Escolhe as colunas da fato e fixa os tipos |
| 3 | Padronizar o tipo de despesa | Iniciais maiúsculas na categoria |
| 4 | Gravar em `refined.fato_despesas` | Truncate e insert em lotes |

**Granularidade:** uma linha por despesa, a mesma da raw. Não há agregação.

**Máscara.** O CNPJ/CPF chega da API só com dígitos. Um `CASE` olha o tamanho e aplica o formato: 11 dígitos viram CPF (`000.000.000-00`), 14 viram CNPJ (`00.000.000/0000-00`). Outro tamanho passa como está.

**Tipo de pessoa.** Pelo mesmo critério de tamanho, uma coluna nova classifica o fornecedor em `PF` ou `PJ`.

Os dois ficam no SQL, e não em transforms do Hop, porque o banco resolve tudo de uma vez ao montar o resultado, em vez de o Hop processar linha a linha.

### `fato_ocupacao`

| # | Caixa | O que faz |
|---|---|---|
| 1 | Ler e filtrar `raw.ocupacoes` | `SELECT` com filtro das linhas vazias |
| 2 | Selecionar e formatar | Escolhe as colunas e fixa os tipos |
| 3 | Gravar em `refined.fato_ocupacao` | Truncate e insert |

**Granularidade:** uma linha por ocupação declarada. Um deputado pode ter várias, uma, ou nenhuma.

É uma **fato sem medidas**, o que na modelagem dimensional se chama *factless fact*: não há valor a somar, o que se registra é que o vínculo existiu. Serve para responder quantos deputados já foram professores, de que entidades vieram, em que período, e para cruzar profissão de origem com padrão de gasto.

O filtro da caixa 1 é o ponto principal deste fluxo:

```sql
WHERE ds_titulo   IS NOT NULL
   OR nm_entidade IS NOT NULL
```

A API devolve, para deputado sem ocupação registrada, uma linha com todos os campos nulos, em vez de uma lista vazia. A raw guarda essas linhas por fidelidade à origem; aqui elas saem, senão virariam ocupações fantasma na contagem.

O teste usa título **e** entidade, e não só um deles, porque há registros históricos em que um vem preenchido e o outro não.

---

## 6. Padronização de texto

A API entrega `nm_uf` e `ds_tipo_despesa` em caixa alta. Dois tratamentos corrigem isso: iniciais maiúsculas (todos os dois campos) e remoção de acento (só `nm_uf`, por enquanto).

### Por que isso está aqui, e não na raw

Foi uma decisão deliberada, não um acaso de onde ficou mais fácil escrever o código.

A raw existe para guardar o dado **exatamente como a origem entregou** — é o que garante que, se algo parecer errado lá na frente, dá para conferir contra a fonte sem depender de nenhuma transformação no meio do caminho. Qualquer limpeza (maiúscula, acento, trim, máscara) descaracteriza esse papel: se a raw já chegasse tratada, não haveria como distinguir "isso veio assim da Câmara" de "isso foi ajustado por um pipeline nosso".

A refined existe para o oposto: preparar o dado para quem vai consumir — Power BI, SQL ad hoc, outra ferramenta. Padronização de texto é exatamente esse tipo de preparo, então pertence aqui.

Há também um motivo prático: **buscas e comparações por texto ficam mais simples sem acento.** Um filtro ou um `JOIN` por `nm_uf = 'Sao Paulo'` não depende de o usuário digitar o "ã" corretamente, nem de o teclado ou a ferramenta de origem preservar acentuação. Isso só vale a pena resolver na camada de consumo — fazer isso na raw só empurraria o mesmo problema para dentro dela.

Por esse critério, os dois tratamentos (maiúsculas e acento) já nasceram no lugar certo desde a primeira versão deste projeto: a caixa de maiúsculas sempre esteve na refined. A remoção de acento segue a mesma regra e entrou na refined também, como caixa nova logo depois.

### Iniciais maiúsculas: `String operations`

Dois steps do tipo **String operations** corrigem a caixa alta: um no `dim_uf`, outro no `fato_despesas`.

Cada um aplica três operações encadeadas ao mesmo campo, e **a ordem em que o Hop as executa importa**:

| Ordem | Operação | Efeito |
|---|---|---|
| 1 | Trim | Remove espaços nas pontas |
| 2 | Lower | Passa tudo para minúscula |
| 3 | InitCap | Sobe a inicial de cada palavra |

O passo 2 é indispensável. O `InitCap` do Hop só levanta a primeira letra de cada palavra e deixa o resto como está — sozinho, `SÃO PAULO` continuaria `SÃO PAULO`. Passando por minúscula antes, vira `são paulo` e depois `São Paulo`.

O campo é atualizado no lugar: com o campo de saída vazio, o Hop sobrescreve a própria coluna em vez de criar outra.

### Remoção de acento: `Janino`

Só o `dim_uf` tem esse tratamento, na caixa 4, logo depois do `String operations`. Usa a fórmula:

```java
nm_uf == null ? null : java.text.Normalizer.normalize(nm_uf, java.text.Normalizer.Form.NFD)
                          .replaceAll("\\p{InCombiningDiacriticalMarks}+", "")
```

`Normalizer.normalize(..., NFD)` separa cada letra acentuada em duas partes: a letra base e uma marca de acento à parte (por exemplo, "ã" vira "a" + til). A regex descarta essas marcas. O resultado cobre qualquer acento do português sem precisar de uma lista de letra por letra, e não depende de "adivinhar" todas as combinações possíveis.

Diferente do `String operations`, o `Janino` não sobrescreve o campo de entrada: grava num campo novo, `nm_uf_sem_acento`. Quem aponta a coluna `nm_uf` da tabela para esse campo novo é a própria caixa de gravação, no mapeamento de colunas — mesmo padrão já usado no `fato_despesas` para o CNPJ formatado (seção 5). Evita depender de o Hop substituir um campo existente pelo mesmo nome, o que é um comportamento menos direto de testar do que simplesmente mapear a coluna certa na gravação.

A ordem entre as caixas 3 e 4 não muda o resultado: acento não afeta maiúscula/minúscula. Ficam em caixas separadas porque são responsabilidades diferentes, e separar facilita entender — e reaproveitar — cada uma isoladamente.

### O que esperar do resultado

```
SÃO PAULO                       →  Sao Paulo
CEARÁ                           →  Ceara
ESPÍRITO SANTO                  →  Espirito Santo
COMBUSTÍVEIS E LUBRIFICANTES.   →  Combustíveis E Lubrificantes.   (sem remoção de acento, ver abaixo)
MANUTENÇÃO DE ESCRITÓRIO        →  Manutenção De Escritório        (sem remoção de acento, ver abaixo)
```

O `InitCap` sobe a inicial de **toda** palavra, inclusive conectivos: sai `De`, `E`, `À` em maiúscula. É o comportamento padrão do transform. Deixar conectivos em minúscula exigiria uma regra com lista de exceções, que este step não faz — se algum dia for necessário, o caminho é trocar o `String operations` por uma expressão no SQL da caixa 1.

**A remoção de acento, por ora, só existe em `dim_uf.nm_uf`.** `fato_despesas.ds_tipo_despesa` continua acentuado (`Combustíveis E Lubrificantes.`). Não há uma razão técnica para a diferença — foi o que este pedido cobriu. Se algum dia fizer sentido igualar, é o mesmo padrão: uma caixa `Janino` a mais, logo depois da caixa de maiúsculas do `fato_despesas`.

Os campos de `fato_ocupacao` não passam por nenhum dos dois tratamentos: a API já os entrega em caixa mista (`Professora`, `Fundação Julita`).

`fato_cotas` também não passa: `sg_uf` é sigla (código), não nome por extenso, e não tem padrão de capitalização nem acento a corrigir.

---

## 7. Detalhes técnicos

### 7.1 Por que não há chave estrangeira

O modelo pede FK entre fato e dimensão, mas ela não pode existir aqui.

Os pipelines gravam com `truncate`, e o Postgres **recusa `TRUNCATE` numa tabela referenciada por chave estrangeira** — inclusive quando a tabela filha está vazia. Uma FK de `fato_despesas` para `dim_deputado` faria o `dim_deputado` falhar já na primeira execução, e o mesmo vale para `dim_uf` e `fato_cotas`.

Alternativas descartadas: `TRUNCATE ... CASCADE` apagaria as fatos ao recarregar uma dimensão; trocar truncate por `DELETE` seria muito mais lento no volume da fato de despesas.

A ligação é lógica, e as consultas de verificação no fim do `ddl.sql` cobrem o que a FK cobriria. A camada raw tem a mesma restrição, pelo mesmo motivo.

### 7.2 As chaves não são estáveis entre execuções

`fato_despesas.id_despesa`, `fato_ocupacao.id_ocupacao` e `fato_cotas.id_cota` vêm da raw, onde são `bigserial` gerados pelo banco. Como a raw é truncada e recarregada por completo a cada execução, **o mesmo registro recebe um número diferente a cada carga**.

Funcionam como chave dentro de uma mesma carga, e é por isso que servem de PK. Não servem para comparar cargas diferentes, nem para guardar referência em sistema externo.

Se um dia isso incomodar, o caminho é construir uma chave a partir dos atributos de negócio. Em `fato_cotas`, o par (`sg_uf`, `dt_competencia`) já é uma chave natural estável — ao contrário de `fato_despesas`, onde `cd_documento` não é único na origem.

### 7.3 A máscara de data não trunca

A caixa 2 do `fato_despesas` declara `dt_documento` como `Date` com máscara `dd/MM/yyyy`. Essa máscara é **só de exibição**: não corta a hora do valor.

Quem descarta a hora é a coluna de destino, declarada como `date` no DDL. Parte dos documentos da origem tem hora, e a análise é por dia, então o truncamento é intencional. Se um dia a hora fizer falta, basta trocar o tipo da coluna para `timestamp`.

### 7.4 A conversão de `dt_competencia` em `fato_cotas`

Vai na direção oposta da 7.3: aqui o texto vira data, não o contrário.

A caixa 2 do `fato_cotas` declara `dt_competencia` como `Date` com máscara `MM/yyyy`. Como a máscara não tem componente de dia, o Hop assume o primeiro dia do mês para todo registro — não é uma suposição arriscada, é literalmente como o `SimpleDateFormat` do Java resolve campos ausentes ao interpretar uma máscara parcial.

Na prática, isso permite comparar `fato_cotas.dt_competencia` com `date_trunc('month', fato_despesas.dt_documento)` sem manipular texto. Ver exemplo na seção 9.

### 7.5 O `ELSE` do `tp_pessoa`

O `CASE` que deriva o tipo de pessoa devolve, no `ELSE`, o próprio conteúdo do campo de CNPJ:

```sql
CASE
  WHEN LENGTH(TRIM(nr_cnpj_cpf_fornecedor)) = 11 THEN 'PF'
  WHEN LENGTH(TRIM(nr_cnpj_cpf_fornecedor)) = 14 THEN 'PJ'
  ELSE nr_cnpj_cpf_fornecedor
END AS tp_pessoa
```

Na prática isso acontece nas despesas de passagem aérea, que vêm com o campo vazio: a coluna recebe string vazia em vez de um código de tipo.

É comportamento conhecido e mantido de propósito. Ao filtrar por tipo de pessoa, considere que existem valores fora de `PF`/`PJ`:

```sql
SELECT tp_pessoa, COUNT(*)
FROM   refined.fato_despesas
GROUP  BY tp_pessoa
ORDER  BY 2 DESC;
```

### 7.6 `sg_uf_entidade` não liga com `dim_uf`

A `fato_ocupacao` tem uma coluna de estado, mas ela é o estado **da entidade** onde o deputado trabalhou, não o estado que ele representa.

São coisas diferentes: um deputado eleito por Alagoas pode ter sido professor em São Paulo. Ligar essa coluna com `dim_uf` num relatório produz um número que parece certo e não é.

O estado do mandato está em `dim_deputado.sg_uf`. É esse campo, não `fato_ocupacao.sg_uf_entidade`, que se liga com `fato_cotas.sg_uf` numa análise de teto vs. gasto.

### 7.7 Cuidado com a aba de metadados do Select values

No `Select values`, a aba de metadados só pode listar colunas que existem no fluxo. Um registro apontando para coluna inexistente **derruba o step em execução**, com `Unable to find field`.

Isso já aconteceu neste projeto: o `dim_deputado` tinha um registro de metadados para `nm_uf`, coluna que só existe no `dim_uf`, provavelmente herdado de uma cópia do pipeline. Foi removido.

O detalhe traiçoeiro é que a tela não acusa nada: o erro só aparece quando o fluxo roda.

### 7.8 Configurações que importam

| Onde | Configuração | Valor | Por quê |
|---|---|---|---|
| TableOutput (todos) | Cópias | 1 | Com `truncate=Y`, várias cópias truncariam a tabela cada uma por conta |
| TableOutput (todos) | Commit | 1000 | Tamanho do lote de insert |
| String operations | Lower antes de InitCap | — | Sem o Lower, texto em caixa alta não muda |
| `dim_uf` caixa 4 | Campo de saída do Janino | `nm_uf_sem_acento` | Nome diferente do campo de entrada; ver 7.9 |
| `fato_cotas` caixa 2 | Máscara de `dt_competencia` | `MM/yyyy` | Sem dia no texto de origem; o Hop assume dia 1 |
| `fato_despesas` | — | — | Único pipeline com volume alto; é onde se mexe se a carga estiver lenta |

### 7.9 Por que o Janino grava num campo com nome diferente

O `String operations` (caixa 3 do `dim_uf`) sobrescreve `nm_uf` no próprio lugar: o transform tem um campo de saída dedicado, e deixá-lo vazio é o sinal para substituir a entrada.

O `Janino` (caixa 4) não tem esse mecanismo dedicado. Por isso o resultado vai para `nm_uf_sem_acento`, um nome novo, e é a caixa de gravação — não o Janino — que decide que esse campo vira a coluna `nm_uf` na tabela. O mapeamento fica explícito nos "fields" do `TableOutput`, o mesmo lugar onde `fato_despesas` já faz algo parecido com o CNPJ formatado (renomeado de `cnpj_cpf_formatado` para `nr_cnpj_cpf_fornecedor` na caixa 2, via `Select values`).

A vantagem de escolher esse caminho, em vez de tentar fazer o Janino escrever direto em `nm_uf`, é eliminar qualquer ambiguidade sobre qual valor prevalece quando dois campos do fluxo têm o mesmo nome. O mapeamento explícito na gravação é sempre claro sobre qual campo alimenta qual coluna, não importa quantas caixas de tratamento existam pelo caminho.

---

## 8. Tabelas

Todas no schema `refined`, todas em carga full: truncate e regrava a cada execução.

O DDL fica em `02. refined/ddl.sql`. Os tipos espelham o que cada pipeline entrega no TableOutput — mudar um tipo lá sem mudar o "Selecionar e formatar" correspondente quebra a carga.

### `refined.dim_uf`

| Coluna | Tipo | Observação |
|---|---|---|
| `sg_uf` | text | PK. Chave da dimensão |
| `nm_uf` | text | Iniciais maiúsculas e sem acento, padronizado pelo pipeline |
| `ds_url_bandeira` | text | URL da bandeira (SVG), para uso em relatório. Herdada da raw sem tratamento. Mesmo papel de `dim_deputado.ds_url_foto` |

### `refined.dim_deputado`

| Coluna | Tipo | Observação |
|---|---|---|
| `id_deputado` | text | PK. Chave da ligação com as fatos |
| `nm_deputado` | text | Nome parlamentar |
| `sg_partido` | text | |
| `sg_uf` | text | Liga com `dim_uf`. Estado do mandato |
| `ds_url_foto` | text | Foto oficial, para uso em relatório |

### `refined.fato_cotas`

| Coluna | Tipo | Observação |
|---|---|---|
| `id_cota` | bigint | PK. **Não é estável entre execuções** |
| `sg_uf` | text | Liga com `dim_uf` |
| `dt_competencia` | date | Primeiro dia do mês de competência |
| `vl_cota` | numeric(14,2) | Teto permitido, **não** o valor gasto |

**Medida:** `vl_cota` — mas é um teto, não um gasto. **Sem grão de deputado.**

### `refined.fato_despesas`

| Coluna | Tipo | Observação |
|---|---|---|
| `id_despesa` | bigint | PK. **Não é estável entre execuções** |
| `id_deputado` | text | Liga com `dim_deputado` |
| `ds_tipo_despesa` | text | Iniciais maiúsculas, padronizado pelo pipeline |
| `ds_tipo_documento` | text | Nota fiscal, recibo… |
| `dt_documento` | date | Data de emissão, truncada para o dia |
| `vl_documento` | numeric(14,2) | Valor bruto. **Pode ser negativo** |
| `ds_url_documento` | text | Nulo em boa parte das linhas |
| `nm_fornecedor` | text | |
| `nr_cnpj_cpf_fornecedor` | text | Já mascarado |
| `tp_pessoa` | text | `PF`, `PJ` ou string vazia |
| `vl_liquido` | numeric(14,2) | Já descontada a glosa |
| `vl_glosa` | numeric(14,2) | Valor recusado |

**Medidas:** `vl_documento`, `vl_liquido`, `vl_glosa`.

### `refined.fato_ocupacao`

| Coluna | Tipo | Observação |
|---|---|---|
| `id_ocupacao` | bigint | PK. **Não é estável entre execuções** |
| `id_deputado` | text | Liga com `dim_deputado` |
| `ds_titulo` | text | Cargo ou função exercida |
| `nm_entidade` | text | Onde exerceu |
| `sg_uf_entidade` | text | Estado **da entidade**. Não liga com `dim_uf` |
| `nm_pais_entidade` | text | |
| `nr_ano_inicio` | integer | |
| `nr_ano_fim` | integer | Nulo costuma indicar vínculo ativo |

**Sem medidas.** É uma factless fact: responde perguntas de contagem.

---

## 9. Consultas de exemplo

```sql
-- gasto total por partido
SELECT d.sg_partido, SUM(f.vl_liquido) AS total
FROM   refined.fato_despesas f
JOIN   refined.dim_deputado d ON d.id_deputado = f.id_deputado
GROUP  BY d.sg_partido
ORDER  BY total DESC;

-- gasto por estado, com nome por extenso
SELECT u.nm_uf, SUM(f.vl_liquido) AS total
FROM   refined.fato_despesas f
JOIN   refined.dim_deputado d ON d.id_deputado = f.id_deputado
JOIN   refined.dim_uf       u ON u.sg_uf       = d.sg_uf
GROUP  BY u.nm_uf
ORDER  BY total DESC;

-- categorias que mais consomem a cota
SELECT ds_tipo_despesa, COUNT(*) AS qtd, SUM(vl_liquido) AS total
FROM   refined.fato_despesas
GROUP  BY ds_tipo_despesa
ORDER  BY total DESC;

-- ocupações mais comuns entre os deputados
SELECT ds_titulo, COUNT(DISTINCT id_deputado) AS qtd_deputados
FROM   refined.fato_ocupacao
GROUP  BY ds_titulo
ORDER  BY qtd_deputados DESC
LIMIT  20;

-- deputados sem nenhuma ocupação declarada
SELECT COUNT(*)
FROM   refined.dim_deputado d
LEFT   JOIN refined.fato_ocupacao o ON o.id_deputado = d.id_deputado
WHERE  o.id_deputado IS NULL;

-- cruzando as duas fatos de deputado: gasto médio por ocupação de origem
SELECT o.ds_titulo,
       COUNT(DISTINCT d.id_deputado) AS qtd_deputados,
       SUM(f.vl_liquido)             AS total_gasto
FROM   refined.fato_ocupacao o
JOIN   refined.dim_deputado  d ON d.id_deputado = o.id_deputado
JOIN   refined.fato_despesas f ON f.id_deputado = d.id_deputado
GROUP  BY o.ds_titulo
HAVING COUNT(DISTINCT d.id_deputado) > 5
ORDER  BY total_gasto DESC;

-- teto vs. gasto, por UF e mês
SELECT c.sg_uf,
       c.dt_competencia,
       c.vl_cota                       AS teto,
       COALESCE(SUM(f.vl_liquido), 0)  AS gasto
FROM   refined.fato_cotas    c
LEFT   JOIN refined.dim_deputado d ON d.sg_uf = c.sg_uf
LEFT   JOIN refined.fato_despesas f
       ON  f.id_deputado = d.id_deputado
       AND date_trunc('month', f.dt_documento) = c.dt_competencia
GROUP  BY c.sg_uf, c.dt_competencia, c.vl_cota
ORDER  BY c.sg_uf, c.dt_competencia;
```

> Atenção nas duas últimas: cruzar `fato_ocupacao` com `fato_despesas` faz um deputado com várias ocupações aparecer em várias linhas, contando o gasto uma vez por ocupação — é inerente a cruzar duas fatos de granularidades diferentes. Já em teto vs. gasto, o `LEFT JOIN` por `sg_uf` (não por `id_deputado`) soma o gasto de **todos** os deputados daquele estado contra o teto individual da UF: é uma comparação agregada, não per capita. Para totais exatos numa ou noutra, agregue antes numa subconsulta.

---

## 10. Erros comuns

**`cannot truncate a table referenced in a foreign key constraint`**
Alguém declarou uma FK entre as tabelas. Veja a seção 7.1.

**`Unable to find field [xxx]`**
A aba de metadados do `Select values` referencia coluna que não existe no fluxo. Veja a seção 7.7.

**`duplicate key value violates unique constraint`**
Chave repetida na origem. Numa dimensão, o problema está na camada raw. Em `fato_cotas`, geralmente é a mesma UF e mês aparecendo duas vezes na planilha.

**Fato com deputado que não existe na dimensão**
As duas camadas foram carregadas em momentos diferentes, ou a refined rodou isolada sobre uma raw desatualizada. Rode o `wkf_projeto_camara`.

**`tp_pessoa` com valores fora de PF/PJ**
Não é erro. Veja a seção 7.5.

**Texto continua em caixa alta depois do String operations**
O `Lower` provavelmente foi desligado. Sem ele o `InitCap` não muda nada. Veja a seção 6.

**Contagem de ocupações maior que o esperado**
Se as linhas vazias da raw estiverem entrando, o filtro da caixa 1 foi alterado. Veja a seção 5.

**`fato_cotas.dt_competencia` com data errada**
Confira a máscara `MM/yyyy` na caixa 2. Se a raw trouxer o texto em outro formato (por exemplo `aaaa-mm`), a conversão falha ou produz data errada sem lançar erro.

**`nm_uf` ainda com acento**
A caixa 4 (`Janino`) do `dim_uf` grava em `nm_uf_sem_acento`, não em `nm_uf`. Se o mapeamento da caixa de gravação for alterado para apontar de volta ao campo original, o acento volta a aparecer sem nenhum erro visível. Veja a seção 7.9.

---

## 11. Glossário

| Termo | Significado |
|---|---|
| Modelo estrela | Organização com tabelas fato centrais ligadas a tabelas de dimensão |
| Fato | Tabela dos eventos, com as medidas numéricas |
| Factless fact | Fato sem medidas: registra que algo aconteceu, sem valor a somar |
| Dimensão | Tabela que descreve os eventos: quem, onde, o quê |
| Medida | Coluna numérica que se soma |
| Granularidade | O que uma linha da fato representa |
| Chave estrangeira (FK) | Regra do banco que garante que a fato só aponte para dimensão existente |
| Schema `refined` | Camada tratada, pronta para consumo |
| Truncate | Esvaziar a tabela antes de gravar |
| Carga full | Recarregar tudo, em vez de só as novidades |
| InitCap | Operação que sobe a inicial de cada palavra |
| Teto | Valor máximo permitido, distinto do valor efetivamente gasto |
| Normalização NFD | Técnica que separa letra acentuada em letra base + marca de acento, usada para remover acentuação |

---

## 12. Arquivos

```
01. Apache Hop - Projeto Câmara/
├── 01. raw/                       coleta da API e da planilha (documentação própria)
├── 02. refined/
│   ├── ddl.sql                    cria as cinco tabelas da refined
│   ├── dim_uf.hpl
│   ├── fato_cotas.hpl
│   ├── dim_deputado.hpl
│   ├── fato_despesas.hpl
│   ├── fato_ocupacao.hpl
│   └── documentacao/
│       ├── documentacao.md
│       └── documentacao.html
├── 03.workflows/
│   ├── wkf_projeto_camara.hwf     ← carga completa; execute por aqui
│   ├── wkf_raw_camara.hwf
│   └── wkf_refined_camara.hwf
└── metadata/
```

---

Fonte dos dados: API de Dados Abertos da Câmara dos Deputados, <https://dadosabertos.camara.leg.br/swagger/api.html>, e planilha de teto de cota mantida à parte. Coleta detalhada na documentação da camada raw.
