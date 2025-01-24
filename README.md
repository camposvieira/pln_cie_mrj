# Processamento de Linguagem Natural aplicado a registros eletrônicos: monitoramento e detecção de eventos em saúde
[Artigo pre-print na revista Ciência & Saúde Coletiva]()

Este repositório tem o objetivo de compartilhar os códigos utilizados no referido artigo para ampliar a identificação de casos suspeitos e reforçar o monitoramento de tendências de doenças de interesse em saúde pública, por meio do uso de processamento de linguagem natural, aplicado à Registros eletrônicos em saúde, no Município do Rio de Janeiro (MRJ). Este foi um trabalho desenvolvido no [Centro de Inteligência Epidemiológica](https://epirio.svs.rio.br/) do MRJ.

Como os dados originais são de uso restrito, não serão aqui disponibilizados. Ainda assim, os arquivos abaixo apontam os caminhos possíveis para o tratamento de campos textuais de queixas de pacientes.

`regex_queixas_duckdb.sql` Este script importa e trata o campo textual de queixas da Rede de Urgência e Emergência (RUE) dentro do duckdb, acessando os dados originais e restritos via postgres_scan.

`data_analysis_pln_MRJ.R` Este script arrega os dados de atendimentos de urgência e emergência do Rio de Janeiro via DuckDB e realiza análises de séries temporais de síndrome gripal e diarreia, bem como a contagem de casos suspeitos de sarampo e rubéola, a partir de queixas e CIDs registrados nos atendimentos.
