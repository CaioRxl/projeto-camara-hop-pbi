# Projeto Câmara — Apache Hop + Power BI

## Sobre o projeto

Pipeline de engenharia de dados que extrai, trata e modela os dados abertos da Câmara dos Deputados do Brasil. O objetivo é montar uma base pronta para análise de gastos parlamentares (a cota para exercício da atividade parlamentar), composição da Casa e histórico profissional dos deputados — a partir de dados públicos que, na origem, vêm crus e espalhados em várias chamadas de API.

É um projeto de estudo/portfólio: a ideia foi simular, em escala pequena, o mesmo tipo de pipeline que se constrói em um ambiente de dados real — extração de API, tratamento em camadas, modelagem dimensional e carga em banco relacional — usando ferramentas de mercado (Apache Hop, PostgreSQL) de ponta a ponta.

## Origem dos dados

- API de Dados Abertos da Câmara dos Deputados (dadosabertos.camara.leg.br) — deputados em exercício, despesas da cota parlamentar, ocupações profissionais declaradas e unidades federativas.
- API de bandeiras dos estados (Codante) — imagens de bandeira por UF. A Câmara não disponibiliza isso em nenhum endpoint, então é a única origem externa do projeto que não é o Dados Abertos.
- Planilha mantida à parte com o teto da cota parlamentar por UF e mês de competência — esse valor também não está disponível via API.

## Como foi construído

- Ferramenta de ETL: Apache Hop, open source. Pipelines (.hpl) fazem a extração e carga; workflows (.hwf) orquestram os pipelines na ordem certa.
- Banco: PostgreSQL hospedado no Supabase.
- Duas camadas, seguindo o padrão raw/refined comum em arquiteturas de dados modernas:
  - raw — dado exatamente como a origem devolveu, sem tratamento nenhum. Cada uma das cinco entidades (UF, cotas, deputados, despesas, ocupações) tem seu próprio pipeline: monta a URL, chama a API (ou lê a planilha), quebra a resposta em linhas, renomeia os campos para o padrão de nomenclatura do projeto e grava com truncate — toda carga é full, substituindo o conteúdo anterior por inteiro.
  - refined — modelo estrela construído em cima da raw: duas dimensões (dim_uf, dim_deputado) e três fatos (fato_cotas, fato_despesas, fato_ocupacao), já com limpeza aplicada (remoção de acento e padronização de texto, conversão de datas e números) e pronto para consumo em ferramentas de análise.
- Workflows orquestram os pipelines respeitando as dependências reais entre eles — por exemplo, get_deputados roda antes de get_despesas, porque é de lá que o pipeline de despesas tira a lista de quem consultar e a legislatura corrente.
- Todo o código (descrições de pipelines, comentários, documentação) foi escrito em português, com numeração de passos e explicação do "porquê" de cada decisão — não só o "o quê".

## Funcionalidades

- Carga completa (full load) de cinco entidades da Câmara dos Deputados.
- Junção de duas fontes externas diferentes dentro de um único pipeline (get_uf cruza a API da Câmara com a API de bandeiras pela sigla do estado).
- Modelo dimensional pronto para responder perguntas como: quanto cada deputado, partido ou UF gastou, em que tipo de despesa, ao longo do tempo — e comparar contra o teto de cota vigente em cada mês.
- Documentação própria de cada camada — esquema das tabelas, decisões de modelagem e erros encontrados durante o desenvolvimento (e como foram resolvidos) — em 01. raw/documentacao/ e 02. refined/documentacao/.

## Estrutura

- 01. Apache Hop - Projeto Câmara/ — projeto completo de extração e modelagem em Hop, com duas camadas:
  - 01. raw/ — dados exatamente como a origem devolveu, sem tratamento.
  - 02. refined/ — modelo estrela (dimensões e fatos) construído sobre a raw, pronto para consumo.
  - 03.workflows/ — orquestradores que chamam os pipelines em ordem. wkf_projeto_camara.hwf é o ponto de entrada para a carga completa.
  - Documentação detalhada de cada camada (pipelines, esquema das tabelas, erros comuns, glossário) está em 01. raw/documentacao/ e 02. refined/documentacao/.
- 02. Power BI - Projeto Câmara/ (em breve) — modelo de análise construído sobre a camada refined.

## Configuração antes de rodar (Apache Hop)

Este repositório não inclui credenciais. Antes da primeira execução:

1. Copie DEV-config.json.example para DEV-config.json e preencha host, porta, banco e usuário do seu Supabase.
2. Copie metadata/rdbms/supabase.json.example para metadata/rdbms/supabase.json, abra o projeto no Hop e edite a conexão supabase para digitar sua senha ali — o Hop grava a versão ofuscada por conta própria.
3. Rode 01. raw/ddl.sql e depois 02. refined/ddl.sql no banco.
4. Se for usar o get_cotas, ajuste o caminho da planilha na variável P_ARQUIVO_COTAS em project-config.json para o caminho real na sua máquina.
