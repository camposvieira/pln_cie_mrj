

# Header CIE Rio -------------------------------------------------
#
# Nome do script:     data_analysis_pln_MRJ.R     
#
# Caminho arquivo:        
#
# Autor(a):               Gabriel Campos Vieira
#
# Data criação:              
# 
# Data atualização:       2025-01-24
#
# Descrição:  Carrega os dados de atendimentos de urgência e emergência do Rio de Janeiro via DuckDB e 
# realiza análises de séries temporais de síndrome gripal e diarreia, bem como a contagem de 
# casos suspeitos de sarampo e rubéola, a partir de queixas e CIDs registrados nos atendimentos.
#
#            
#----------------------------------------------------------------

# Packages ----------------------------------------------------------------
library(VennDiagram)
library(tidyverse)
library(ggplot2)
library(duckdb)
library(odbc)
library(DBI)
library(kableExtra)
library(forecast)
library(feasts)
library(tsibble)
library(TSstudio)
library(plotly)
library(timetk)
library(cowplot)
library(patchwork)
library(gridExtra)


# Base de dados  --------------
con <- dbConnect(duckdb::duckdb(), 'rue_queixa.duckdb')


##Sarampo e Rubéola-----------
base_exantematicas <- dbGetQuery(
  con,
  "select data_entrada, atencao, cid_str, ds_queixa,
                    queixa_clean5,
                   regexp_matches(lower(cid_str), 'b05') as cid_sarampo,
                   ((exantema OR mancha_vermelha) AND conjuntivite AND febre AND
            (coriza OR tosse) OR
            regexp_matches(lower(queixa_clean5), 'sarampo')) as queixa_sarampo,
                   regexp_matches(lower(cid_str), 'b06') as cid_rubeola,
                   ((exantema OR mancha_vermelha) AND febre AND
            (regexp_matches(lower(queixa_clean5), 'linfoadeno') OR
             regexp_matches(lower(queixa_clean5), 'ganglio') OR
             regexp_matches(lower(queixa_clean5), 'caroco')) OR
            regexp_matches(lower(queixa_clean5), 'rubeola')) as queixa_rubeola,
                    from vw_queixa_atencao where atencao in ('rubeola', 'sarampo');"
) %>% filter(data_entrada <= "2024-09-30")


## Sindrome gripal e diarreia - serie semanal 

base_grip_diar <- dbGetQuery(
  con,
  "select a.* from vw_queixa_sem as a
  where serie in ('sg_garganta_tosse', 'sintomas_gripais', 'diarreia', 'cid_sindrome_gripal', 'cid_diarreia')"
) %>%
  mutate(dt_sem = aweek::get_date(semana_epi, ano_epi)) 

##Sindrome gripal e diarreia para serie de intersecao entre cid e queixas

base_grip_diar_intersec <- dbGetQuery(
  con,
  "unpivot(SELECT 
   week(data_entrada + 1) as semana_epi,
  cast(left(cast(yearweek(data_entrada + 1) as VARCHAR), 4) as INT) as ano_epi,
  SUM(CASE WHEN diarreia = TRUE AND cid_diarreia = FALSE THEN 1 ELSE 0 END) AS diarreia_queixa,
  SUM(CASE WHEN diarreia = FALSE AND cid_diarreia = TRUE THEN 1 ELSE 0 END) AS diarreia_cid,
  SUM(CASE WHEN diarreia = TRUE AND cid_diarreia = TRUE THEN 1 ELSE 0 END) AS total_diarreia_cid_queixa,
  SUM(CASE WHEN cid_sindrome_gripal = TRUE AND sg_garganta_tosse = TRUE THEN 1 ELSE 0 END) AS total_sg_cid_queixa,
  SUM(CASE WHEN cid_sindrome_gripal = TRUE AND sg_garganta_tosse = FALSE THEN 1 ELSE 0 END) AS sg_cid,
  SUM(CASE WHEN cid_sindrome_gripal = FALSE AND sg_garganta_tosse = TRUE THEN 1 ELSE 0 END) AS sg_queixa
  FROM tb_queixa_classif
  GROUP BY semana_epi, ano_epi) on
  columns(* exclude(semana_epi, ano_epi))
  into name serie value n
  ORDER BY ano_epi, semana_epi;") %>%  mutate(dt_sem = aweek::get_date(semana_epi, ano_epi),
                                              ano_semana_epi = as.factor(paste(ano_epi, sprintf("%02d", semana_epi), sep = "-"))) 

#Define a ultima semana
max_sem <- max(base_grip_diar$dt_sem)
  
#Filtra a ultima semana incompleta e fechar a data de anélise até a SE 40 de 2024 para o artigo
base_grip_diar <- base_grip_diar %>% filter(dt_sem < max_sem) %>% filter(dt_sem <= "2024-09-30")

#Desconecta do banco de dados
dbDisconnect(con)






