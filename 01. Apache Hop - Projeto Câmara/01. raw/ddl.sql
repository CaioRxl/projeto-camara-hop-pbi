-- ---------------------------------------------------------------------------
-- Camada raw do projeto Camara
--
-- Dados como vieram da API de Dados Abertos, sem tratamento. Os pipelines
-- gravam com truncate, entao rodar de novo substitui o conteudo inteiro.
--
-- Os tipos abaixo espelham exatamente o que cada pipeline entrega no
-- TableOutput. Alterar um tipo aqui sem alterar o "Renomear as colunas"
-- correspondente quebra a carga.
--
-- Nao ha chave estrangeira entre as tabelas. Os pipelines gravam com
-- truncate, e o Postgres recusa TRUNCATE numa tabela referenciada por FK,
-- inclusive quando a tabela filha esta vazia. As ligacoes sao logicas; as
-- consultas de verificacao estao no fim deste arquivo.
--
-- Execucao: rode o arquivo inteiro. Ele derruba e recria as cinco tabelas.
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS raw;

DROP TABLE IF EXISTS raw.ocupacoes;
DROP TABLE IF EXISTS raw.despesas;
DROP TABLE IF EXISTS raw.deputados;
DROP TABLE IF EXISTS raw.cotas;
DROP TABLE IF EXISTS raw.uf;


-- ---------------------------------------------------------------------------
-- raw.uf
-- Unidades federativas. Tabela de apoio, usada para traduzir sigla em nome.
-- Origem: GET /referencias/uf (Camara) + API de bandeiras dos estados
-- (Codante, https://apis.codante.io/bandeiras-dos-estados), casadas pela
-- sigla. A Camara nao expoe imagem de bandeira; a coluna ds_url_bandeira
-- vem inteiramente da segunda origem.
-- ---------------------------------------------------------------------------
CREATE TABLE raw.uf (
    cd_uf           text  NOT NULL,
    sg_uf           text  NOT NULL,
    nm_uf           text,
    ds_uf           text,
    ds_url_bandeira text,
    dt_carga        timestamptz     NOT NULL DEFAULT now(),

    CONSTRAINT pk_uf PRIMARY KEY (cd_uf)
);

COMMENT ON TABLE  raw.uf                 IS 'Unidades federativas (GET /referencias/uf), casadas com a API de bandeiras pela sigla.';
COMMENT ON COLUMN raw.uf.cd_uf           IS 'Codigo da UF na Camara. Nao e o codigo do IBGE.';
COMMENT ON COLUMN raw.uf.nm_uf           IS 'Nome em caixa alta, como a API entrega. A camada refined padroniza as iniciais e remove acento.';
COMMENT ON COLUMN raw.uf.ds_uf           IS 'A API devolve sempre vazio. Mantido por fidelidade a origem.';
COMMENT ON COLUMN raw.uf.ds_url_bandeira IS 'URL da imagem da bandeira (SVG). Origem: API de bandeiras dos estados (Codante), nao a Camara. Fica vazio (nao nulo) se a sigla nao for encontrada na segunda origem.';

CREATE UNIQUE INDEX uk_uf_sigla ON raw.uf (sg_uf);


-- ---------------------------------------------------------------------------
-- raw.cotas
-- Teto da cota parlamentar por UF e mes de competencia.
-- Origem: planilha mantida a parte (cota_parlamentar_ceap_2023_2026.xlsx),
-- nao a API. O Dados Abertos nao expoe esse valor.
--
-- Tabela de apoio, como raw.uf: uma linha por UF e mes de competencia, com o
-- valor de teto vigente naquele mes (o teto muda ao longo do tempo por Ato
-- da Mesa).
-- ---------------------------------------------------------------------------
CREATE TABLE raw.cotas (
    id_cota         bigserial       NOT NULL,

    -- Texto "mm/aaaa", exatamente como vem na planilha. A camada refined
    -- converte para data.
    dt_competencia  text            NOT NULL,

    sg_uf           text            NOT NULL,
    vl_cota         numeric(14,2),
    dt_carga        timestamptz     NOT NULL DEFAULT now(),

    CONSTRAINT pk_cotas PRIMARY KEY (id_cota)
);

COMMENT ON TABLE  raw.cotas                 IS 'Teto da cota parlamentar por UF e mes de competencia. Origem: planilha, nao a API.';
COMMENT ON COLUMN raw.cotas.dt_competencia  IS 'Mes de competencia no formato "mm/aaaa", como vem na planilha. A camada refined converte para date.';
COMMENT ON COLUMN raw.cotas.sg_uf           IS 'Liga com raw.uf.sg_uf.';
COMMENT ON COLUMN raw.cotas.vl_cota         IS 'Valor de teto vigente naquele mes de competencia para a UF.';

CREATE UNIQUE INDEX uk_cotas_uf_competencia ON raw.cotas (sg_uf, dt_competencia);


-- ---------------------------------------------------------------------------
-- raw.deputados
-- Deputados em exercicio no momento da carga.
-- Origem: GET /deputados
-- ---------------------------------------------------------------------------
CREATE TABLE raw.deputados (
    id_deputado     text     NOT NULL,
    uri_deputado    text,
    nm_deputado     text,
    sg_partido      text,
    uri_partido     text,
    sg_uf           text,
    id_legislatura  integer,
    ds_url_foto     text,
    ds_email        text,
    dt_carga        timestamptz     NOT NULL DEFAULT now(),

    CONSTRAINT pk_deputados PRIMARY KEY (id_deputado)
);

COMMENT ON TABLE  raw.deputados                IS 'Deputados em exercicio (GET /deputados). Reflete a composicao da Casa no momento da carga.';
COMMENT ON COLUMN raw.deputados.id_deputado    IS 'Codigo do deputado. Guardado como texto porque e concatenado em URLs pelos pipelines de despesas e ocupacoes.';
COMMENT ON COLUMN raw.deputados.id_legislatura IS 'Periodo de mandato. Os pipelines de despesas e ocupacoes usam o maior valor desta coluna para filtrar a legislatura corrente.';
COMMENT ON COLUMN raw.deputados.sg_uf          IS 'Liga com raw.uf.sg_uf.';

CREATE INDEX ix_deputados_uf      ON raw.deputados (sg_uf);
CREATE INDEX ix_deputados_partido ON raw.deputados (sg_partido);
CREATE INDEX ix_deputados_legis   ON raw.deputados (id_legislatura);


-- ---------------------------------------------------------------------------
-- raw.despesas
-- Despesas da cota parlamentar, legislatura corrente.
-- Origem: GET /deputados/{id}/despesas
-- ---------------------------------------------------------------------------
CREATE TABLE raw.despesas (
    id_despesa              bigserial       NOT NULL,

    -- Nao vem no corpo da resposta. E o pipeline que carrega este valor
    -- desde a leitura inicial de raw.deputados.
    id_deputado             text            NOT NULL,

    nr_ano                  integer,
    nr_mes                  integer,

    -- Caixa alta, como a API entrega. A camada refined padroniza as iniciais.
    ds_tipo_despesa         text,

    -- Nao e unico e nao e sempre numerico: despesas SIGEPA repetem o mesmo
    -- codigo em linhas de valores diferentes, e algumas vem como GUID.
    cd_documento            text,
    ds_tipo_documento       text,
    cd_tipo_documento       integer,

    dt_documento            timestamp,
    nr_documento            text,

    -- Aceita negativo: estornos de passagem aerea aparecem assim.
    vl_documento            numeric(14,2),

    -- Nulo quando nao ha documento digitalizado.
    ds_url_documento        text,

    nm_fornecedor           text,
    -- Vazio nas despesas de passagem aerea.
    nr_cnpj_cpf_fornecedor  text,

    vl_liquido              numeric(14,2),
    vl_glosa                numeric(14,2),

    -- So preenchido quando houve devolucao de valor.
    nr_ressarcimento        text,

    cd_lote                 bigint,
    nr_parcela              integer,

    -- timestamptz, nao timestamp. O servidor do Supabase roda em UTC: com
    -- timestamp simples, now() gravaria a hora de Londres e a coluna nao teria
    -- como saber disso. Com timestamptz o instante fica absoluto e cada cliente
    -- exibe no proprio fuso.
    dt_carga                timestamptz     NOT NULL DEFAULT now(),

    CONSTRAINT pk_despesas PRIMARY KEY (id_despesa)
);

COMMENT ON TABLE  raw.despesas                        IS 'Despesas da cota parlamentar por deputado (GET /deputados/{id}/despesas), legislatura corrente.';
COMMENT ON COLUMN raw.despesas.id_despesa             IS 'Chave artificial. Nao ha chave natural confiavel na origem. Renumera a cada carga.';
COMMENT ON COLUMN raw.despesas.id_deputado            IS 'Ligacao logica com raw.deputados.id_deputado. Nao vem da API, e propagado pelo pipeline.';
COMMENT ON COLUMN raw.despesas.nr_ano                 IS 'Competencia da despesa, nao a data do documento.';
COMMENT ON COLUMN raw.despesas.ds_tipo_despesa        IS 'Caixa alta, como a API entrega. A camada refined padroniza as iniciais.';
COMMENT ON COLUMN raw.despesas.cd_documento           IS 'Nao e unico e pode vir como numero ou GUID.';
COMMENT ON COLUMN raw.despesas.vl_documento           IS 'Valor bruto. Pode ser negativo em caso de estorno.';
COMMENT ON COLUMN raw.despesas.vl_liquido             IS 'Valor efetivamente reembolsado, ja descontada a glosa.';
COMMENT ON COLUMN raw.despesas.ds_url_documento       IS 'Nulo em boa parte das linhas, quando nao ha nota digitalizada.';
COMMENT ON COLUMN raw.despesas.nr_ressarcimento       IS 'Vazio na maioria das linhas. Nao e falha de extracao.';
COMMENT ON COLUMN raw.despesas.dt_carga               IS 'Preenchido pelo banco, nao pelo pipeline. timestamptz: guarda o instante absoluto e cada cliente exibe no proprio fuso.';

CREATE INDEX ix_despesas_deputado ON raw.despesas (id_deputado);
CREATE INDEX ix_despesas_ano_mes  ON raw.despesas (nr_ano, nr_mes);
CREATE INDEX ix_despesas_tipo     ON raw.despesas (ds_tipo_despesa);
CREATE INDEX ix_despesas_cnpj     ON raw.despesas (nr_cnpj_cpf_fornecedor);
CREATE INDEX ix_despesas_data     ON raw.despesas (dt_documento);


-- ---------------------------------------------------------------------------
-- raw.ocupacoes
-- Ocupacoes profissionais declaradas pelos deputados.
-- Origem: GET /deputados/{id}/ocupacoes
--
-- ATENCAO: deputado sem ocupacao registrada NAO devolve lista vazia. Devolve
-- uma linha com todos os campos nulos, e ela e gravada aqui de proposito,
-- por fidelidade a origem. A camada refined descarta essas linhas.
-- Consulte-as com: WHERE ds_titulo IS NULL AND nm_entidade IS NULL
-- ---------------------------------------------------------------------------
CREATE TABLE raw.ocupacoes (
    id_ocupacao             bigserial       NOT NULL,

    -- Nao vem no corpo da resposta. E o pipeline que carrega este valor
    -- desde a leitura inicial de raw.deputados.
    id_deputado             text            NOT NULL,

    ds_titulo               text,
    nm_entidade             text,
    sg_uf_entidade          text,
    nm_pais_entidade        text,

    -- Ano de fim nulo costuma indicar vinculo ainda ativo.
    nr_ano_inicio           integer,
    nr_ano_fim              integer,

    dt_carga                timestamptz     NOT NULL DEFAULT now(),

    CONSTRAINT pk_ocupacoes PRIMARY KEY (id_ocupacao)
);

COMMENT ON TABLE  raw.ocupacoes                  IS 'Ocupacoes profissionais declaradas (GET /deputados/{id}/ocupacoes). Inclui linhas totalmente nulas para deputado sem ocupacao registrada.';
COMMENT ON COLUMN raw.ocupacoes.id_ocupacao      IS 'Chave artificial. Renumera a cada carga.';
COMMENT ON COLUMN raw.ocupacoes.id_deputado      IS 'Ligacao logica com raw.deputados.id_deputado. Nao vem da API, e propagado pelo pipeline.';
COMMENT ON COLUMN raw.ocupacoes.ds_titulo        IS 'Cargo ou funcao exercida. Nulo nas linhas de deputado sem ocupacao.';
COMMENT ON COLUMN raw.ocupacoes.sg_uf_entidade   IS 'Estado da entidade. Nao necessariamente o estado que o deputado representa.';
COMMENT ON COLUMN raw.ocupacoes.nr_ano_fim       IS 'Nulo costuma indicar vinculo ainda ativo.';
COMMENT ON COLUMN raw.ocupacoes.dt_carga         IS 'Preenchido pelo banco, nao pelo pipeline.';

CREATE INDEX ix_ocupacoes_deputado ON raw.ocupacoes (id_deputado);
CREATE INDEX ix_ocupacoes_titulo   ON raw.ocupacoes (ds_titulo);
CREATE INDEX ix_ocupacoes_entidade ON raw.ocupacoes (nm_entidade);


-- ---------------------------------------------------------------------------
-- Verificacao pos-carga
--
-- Como nao ha FK declarada, rode isto depois da carga para checar o que a FK
-- checaria. As tres primeiras devem voltar zero.
-- ---------------------------------------------------------------------------

-- Despesas de deputado que nao existe na tabela de deputados
-- SELECT COUNT(*)
-- FROM   raw.despesas d
-- LEFT   JOIN raw.deputados p ON p.id_deputado = d.id_deputado
-- WHERE  p.id_deputado IS NULL;

-- Ocupacoes de deputado que nao existe na tabela de deputados
-- SELECT COUNT(*)
-- FROM   raw.ocupacoes o
-- LEFT   JOIN raw.deputados p ON p.id_deputado = o.id_deputado
-- WHERE  p.id_deputado IS NULL;

-- Cotas de UF que nao existe na tabela de UF (planilha com sigla digitada errado)
-- SELECT COUNT(*)
-- FROM   raw.cotas c
-- LEFT   JOIN raw.uf u ON u.sg_uf = c.sg_uf
-- WHERE  u.sg_uf IS NULL;

-- Quantos deputados nao tem ocupacao registrada (informativo, nao e erro)
-- SELECT COUNT(*)
-- FROM   raw.ocupacoes
-- WHERE  ds_titulo IS NULL AND nm_entidade IS NULL;

-- UF sem bandeira encontrada na segunda origem (informativo; nao deveria
-- acontecer, as duas origens cobrem as mesmas 27 unidades federativas)
-- SELECT cd_uf, sg_uf, nm_uf
-- FROM   raw.uf
-- WHERE  ds_url_bandeira IS NULL OR ds_url_bandeira = '';
