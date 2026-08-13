-- ---------------------------------------------------------------------------
-- Camada refined do projeto Camara
--
-- Modelo estrela: duas dimensoes e duas fatos, alimentadas a partir do schema
-- raw. Aqui os dados ja passaram por selecao de colunas, formatacao (CNPJ
-- mascarado, iniciais maiusculas) e derivacao (tipo de pessoa).
--
-- Os tipos abaixo espelham o que cada pipeline entrega no TableOutput.
-- Alterar um tipo aqui sem alterar o "Selecionar e formatar" correspondente
-- quebra a carga.
--
-- SEM chave estrangeira, pelo mesmo motivo da camada raw: os pipelines gravam
-- com truncate, e o Postgres recusa TRUNCATE numa tabela referenciada por FK,
-- inclusive quando a tabela filha esta vazia. Declarar a FK quebraria a carga
-- das dimensoes. As ligacoes sao logicas; as consultas de verificacao estao
-- no fim deste arquivo.
--
-- Carga full: todos os pipelines gravam com truncate.
--
-- Execucao: rode o arquivo inteiro. Ele derruba e recria as cinco tabelas.
-- Rode 01. raw/ddl.sql antes, na primeira vez.
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS refined;

DROP TABLE IF EXISTS refined.fato_ocupacao;
DROP TABLE IF EXISTS refined.fato_despesas;
DROP TABLE IF EXISTS refined.fato_cotas;
DROP TABLE IF EXISTS refined.dim_deputado;
DROP TABLE IF EXISTS refined.dim_uf;


-- ---------------------------------------------------------------------------
-- refined.dim_uf
-- Dimensao de unidade federativa. Origem: raw.uf
--
-- A chave e a sigla, nao o codigo: e por ela que dim_deputado se relaciona,
-- e e ela que aparece nos relatorios. O codigo da Camara nao e usado em
-- lugar nenhum a jusante, entao nao foi trazido.
-- ---------------------------------------------------------------------------
CREATE TABLE refined.dim_uf (
    sg_uf           text  NOT NULL,

    -- Padronizado pelo pipeline: a raw guarda "SAO PAULO", aqui vira
    -- "Sao Paulo" (iniciais maiusculas e sem acento).
    nm_uf           text,

    -- Vem direto da raw, sem tratamento: ja e uma URL.
    ds_url_bandeira text,

    CONSTRAINT pk_dim_uf PRIMARY KEY (sg_uf)
);

COMMENT ON TABLE  refined.dim_uf                 IS 'Dimensao de unidade federativa.';
COMMENT ON COLUMN refined.dim_uf.sg_uf           IS 'Sigla do estado. Chave da dimensao.';
COMMENT ON COLUMN refined.dim_uf.nm_uf           IS 'Nome do estado com iniciais maiusculas e sem acento, padronizado pelo pipeline a partir da caixa alta da raw. Ex.: "Sao Paulo", "Ceara".';
COMMENT ON COLUMN refined.dim_uf.ds_url_bandeira IS 'URL da imagem da bandeira (SVG), para uso em relatorio. Herdada da raw sem tratamento. Mesmo papel de dim_deputado.ds_url_foto.';


-- ---------------------------------------------------------------------------
-- refined.fato_cotas
-- Fato de teto da cota parlamentar. Origem: raw.cotas
--
-- Granularidade: uma linha por UF e mes de competencia. Diferente das outras
-- duas fatos, nao tem grao de deputado: registra o teto permitido para o
-- estado naquele mes, nao um gasto individual. Entra como fato, e nao como
-- dimensao, porque o valor muda com o tempo (por Ato da Mesa).
--
-- Uso tipico: comparar, por UF e mes, o total gasto (refined.fato_despesas,
-- agregado via refined.dim_deputado.sg_uf) contra o teto permitido aqui.
-- ---------------------------------------------------------------------------
CREATE TABLE refined.fato_cotas (
    -- Herdado de raw.cotas.id_cota. Mesma ressalva das outras fatos:
    -- renumera a cada recarga da raw, entao nao e estavel entre execucoes.
    id_cota         bigint          NOT NULL,

    sg_uf           text            NOT NULL,

    -- Convertido pelo pipeline a partir do texto "mm/aaaa" da raw. Fica no
    -- primeiro dia do mes de competencia.
    dt_competencia  date            NOT NULL,

    -- Teto permitido para a UF naquele mes. Nao e gasto: e o limite.
    vl_cota         numeric(14,2),

    CONSTRAINT pk_fato_cotas PRIMARY KEY (id_cota)
);

COMMENT ON TABLE  refined.fato_cotas                IS 'Fato de teto da cota parlamentar por UF e mes. Sem grao de deputado.';
COMMENT ON COLUMN refined.fato_cotas.id_cota         IS 'Herdado da raw. Nao e estavel entre execucoes.';
COMMENT ON COLUMN refined.fato_cotas.sg_uf           IS 'Liga com refined.dim_uf.';
COMMENT ON COLUMN refined.fato_cotas.dt_competencia  IS 'Primeiro dia do mes de competencia. Convertido pelo pipeline a partir do texto "mm/aaaa" da raw.';
COMMENT ON COLUMN refined.fato_cotas.vl_cota         IS 'Teto permitido para a UF naquele mes, nao o valor gasto.';

CREATE UNIQUE INDEX uk_fato_cotas_uf_competencia ON refined.fato_cotas (sg_uf, dt_competencia);


-- ---------------------------------------------------------------------------
-- refined.dim_deputado
-- Dimensao de deputado. Origem: raw.deputados
--
-- Traz so o que os relatorios usam. URI de API, e-mail de gabinete e
-- legislatura ficaram na raw: sao metadados de coleta, nao atributos de
-- analise.
-- ---------------------------------------------------------------------------
CREATE TABLE refined.dim_deputado (
    id_deputado   text  NOT NULL,
    nm_deputado   text,
    sg_partido    text,
    sg_uf         text,
    ds_url_foto   text,

    CONSTRAINT pk_dim_deputado PRIMARY KEY (id_deputado)
);

COMMENT ON TABLE  refined.dim_deputado             IS 'Dimensao de deputado, com os atributos usados em analise.';
COMMENT ON COLUMN refined.dim_deputado.id_deputado IS 'Codigo do deputado na Camara. Chave da dimensao e da ligacao com as fatos.';
COMMENT ON COLUMN refined.dim_deputado.sg_uf       IS 'Estado que o deputado representa. Liga com refined.dim_uf.';
COMMENT ON COLUMN refined.dim_deputado.ds_url_foto IS 'Foto oficial, para uso em relatorio.';

CREATE INDEX ix_dim_deputado_uf      ON refined.dim_deputado (sg_uf);
CREATE INDEX ix_dim_deputado_partido ON refined.dim_deputado (sg_partido);


-- ---------------------------------------------------------------------------
-- refined.fato_despesas
-- Fato de despesa da cota parlamentar. Origem: raw.despesas
--
-- Granularidade: uma linha por despesa individual, a mesma da raw.
-- Medidas: vl_documento, vl_liquido, vl_glosa.
-- ---------------------------------------------------------------------------
CREATE TABLE refined.fato_despesas (
    -- Herdado de raw.despesas.id_despesa. ATENCAO: aquele valor e um
    -- bigserial que se renumera a cada recarga da raw, entao NAO e um
    -- identificador estavel entre execucoes. Serve como chave dentro de uma
    -- mesma carga, nao para comparar cargas diferentes.
    id_despesa              bigint          NOT NULL,

    id_deputado             text            NOT NULL,

    -- Padronizado pelo pipeline: a raw guarda "COMBUSTIVEIS E LUBRIFICANTES.",
    -- aqui vira "Combustiveis E Lubrificantes.". O InitCap sobe a inicial de
    -- toda palavra, inclusive conectivos.
    ds_tipo_despesa         text,
    ds_tipo_documento       text,

    -- date, nao timestamp: parte dos documentos da origem tem hora, mas a
    -- analise e por dia. A hora e descartada aqui de proposito.
    dt_documento            date,

    -- Aceita negativo: estornos de passagem aerea aparecem assim.
    vl_documento            numeric(14,2),

    -- Nulo quando nao ha documento digitalizado.
    ds_url_documento        text,

    nm_fornecedor           text,

    -- Ja mascarado pelo pipeline: 000.000.000-00 ou 00.000.000/0000-00.
    -- Quando a origem nao tem 11 nem 14 digitos, vem como estava.
    nr_cnpj_cpf_fornecedor  text,

    -- 'PF', 'PJ', ou o proprio conteudo do campo de CNPJ quando o tamanho
    -- nao permite classificar (caso das passagens aereas, que vem vazias).
    tp_pessoa               text,

    vl_liquido              numeric(14,2),
    vl_glosa                numeric(14,2),

    CONSTRAINT pk_fato_despesas PRIMARY KEY (id_despesa)
);

COMMENT ON TABLE  refined.fato_despesas                        IS 'Fato de despesa da cota parlamentar. Uma linha por despesa.';
COMMENT ON COLUMN refined.fato_despesas.id_despesa             IS 'Herdado da raw. Nao e estavel entre execucoes, porque a raw renumera a cada carga.';
COMMENT ON COLUMN refined.fato_despesas.id_deputado            IS 'Liga com refined.dim_deputado.';
COMMENT ON COLUMN refined.fato_despesas.ds_tipo_despesa        IS 'Categoria com iniciais maiusculas, padronizada pelo pipeline.';
COMMENT ON COLUMN refined.fato_despesas.dt_documento           IS 'Data de emissao, truncada para o dia.';
COMMENT ON COLUMN refined.fato_despesas.vl_documento           IS 'Valor bruto. Pode ser negativo em caso de estorno.';
COMMENT ON COLUMN refined.fato_despesas.vl_liquido             IS 'Valor efetivamente reembolsado, ja descontada a glosa.';
COMMENT ON COLUMN refined.fato_despesas.nr_cnpj_cpf_fornecedor IS 'Mascarado pelo pipeline a partir do numero cru da raw.';
COMMENT ON COLUMN refined.fato_despesas.tp_pessoa              IS 'PF ou PJ, derivado do tamanho do CNPJ/CPF. Nao classificado quando o campo de origem vem vazio.';

CREATE INDEX ix_fato_despesas_deputado ON refined.fato_despesas (id_deputado);
CREATE INDEX ix_fato_despesas_data     ON refined.fato_despesas (dt_documento);
CREATE INDEX ix_fato_despesas_tipo     ON refined.fato_despesas (ds_tipo_despesa);
CREATE INDEX ix_fato_despesas_pessoa   ON refined.fato_despesas (tp_pessoa);
CREATE INDEX ix_fato_despesas_cnpj     ON refined.fato_despesas (nr_cnpj_cpf_fornecedor);


-- ---------------------------------------------------------------------------
-- refined.fato_ocupacao
-- Fato de ocupacao profissional. Origem: raw.ocupacoes
--
-- Granularidade: uma linha por ocupacao declarada pelo deputado.
--
-- Fato SEM medidas, o que na modelagem dimensional se chama factless fact:
-- nao ha valor a somar, o que se registra e que o vinculo existiu. Responde
-- perguntas de contagem e permite cruzar profissao de origem com padrao de
-- gasto, via dim_deputado.
--
-- As linhas totalmente nulas que a raw guarda (deputado sem ocupacao
-- registrada) sao descartadas pelo pipeline e nao chegam aqui.
-- ---------------------------------------------------------------------------
CREATE TABLE refined.fato_ocupacao (
    -- Herdado de raw.ocupacoes.id_ocupacao. Mesma ressalva do id_despesa:
    -- renumera a cada recarga da raw, entao nao e estavel entre execucoes.
    id_ocupacao             bigint          NOT NULL,

    id_deputado             text            NOT NULL,

    ds_titulo               text,
    nm_entidade             text,
    sg_uf_entidade          text,

    -- Ano de fim nulo costuma indicar vinculo ainda ativo.
    nr_ano_inicio           integer,
    nr_ano_fim              integer,

    CONSTRAINT pk_fato_ocupacao PRIMARY KEY (id_ocupacao)
);

COMMENT ON TABLE  refined.fato_ocupacao                  IS 'Fato de ocupacao profissional, sem medidas (factless fact). Uma linha por ocupacao declarada.';
COMMENT ON COLUMN refined.fato_ocupacao.id_ocupacao      IS 'Herdado da raw. Nao e estavel entre execucoes.';
COMMENT ON COLUMN refined.fato_ocupacao.id_deputado      IS 'Liga com refined.dim_deputado.';
COMMENT ON COLUMN refined.fato_ocupacao.ds_titulo        IS 'Cargo ou funcao exercida.';
COMMENT ON COLUMN refined.fato_ocupacao.sg_uf_entidade   IS 'Estado da entidade. Nao necessariamente o estado que o deputado representa, entao nao ligue com dim_uf sem pensar.';
COMMENT ON COLUMN refined.fato_ocupacao.nr_ano_fim       IS 'Nulo costuma indicar vinculo ainda ativo.';

CREATE INDEX ix_fato_ocupacao_deputado ON refined.fato_ocupacao (id_deputado);
CREATE INDEX ix_fato_ocupacao_titulo   ON refined.fato_ocupacao (ds_titulo);
CREATE INDEX ix_fato_ocupacao_entidade ON refined.fato_ocupacao (nm_entidade);
CREATE INDEX ix_fato_ocupacao_anos     ON refined.fato_ocupacao (nr_ano_inicio, nr_ano_fim);


-- ---------------------------------------------------------------------------
-- Verificacao pos-carga
--
-- Como nao ha FK declarada (ver comentario no topo), rode isto depois da
-- carga para checar o que a FK checaria. Todas devem voltar zero.
-- ---------------------------------------------------------------------------

-- Despesas de deputado que nao existe na dimensao
-- SELECT COUNT(*)
-- FROM   refined.fato_despesas f
-- LEFT   JOIN refined.dim_deputado d ON d.id_deputado = f.id_deputado
-- WHERE  d.id_deputado IS NULL;

-- Ocupacoes de deputado que nao existe na dimensao
-- SELECT COUNT(*)
-- FROM   refined.fato_ocupacao o
-- LEFT   JOIN refined.dim_deputado d ON d.id_deputado = o.id_deputado
-- WHERE  d.id_deputado IS NULL;

-- Deputados de UF que nao existe na dimensao
-- SELECT COUNT(*)
-- FROM   refined.dim_deputado d
-- LEFT   JOIN refined.dim_uf u ON u.sg_uf = d.sg_uf
-- WHERE  u.sg_uf IS NULL;

-- Cotas de UF que nao existe na dimensao
-- SELECT COUNT(*)
-- FROM   refined.fato_cotas c
-- LEFT   JOIN refined.dim_uf u ON u.sg_uf = c.sg_uf
-- WHERE  u.sg_uf IS NULL;

-- Ocupacoes vazias que escaparam do filtro do pipeline
-- SELECT COUNT(*)
-- FROM   refined.fato_ocupacao
-- WHERE  ds_titulo IS NULL AND nm_entidade IS NULL;

-- Exemplo: gasto do mes contra o teto, por UF (ilustra o cruzamento entre
-- fato_despesas e fato_cotas via dim_deputado)
-- SELECT
--     c.sg_uf,
--     c.dt_competencia,
--     c.vl_cota,
--     COALESCE(SUM(f.vl_liquido), 0) AS vl_gasto
-- FROM   refined.fato_cotas c
-- LEFT   JOIN refined.dim_deputado d ON d.sg_uf = c.sg_uf
-- LEFT   JOIN refined.fato_despesas f
--        ON  f.id_deputado = d.id_deputado
--        AND date_trunc('month', f.dt_documento) = c.dt_competencia
-- GROUP  BY c.sg_uf, c.dt_competencia, c.vl_cota
-- ORDER  BY c.sg_uf, c.dt_competencia;
