

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


# Série histórica  exantematicas agregada ---------------------------------------------------------

base_saramp_rub <- base_exantematicas %>% group_by(atencao,
                                                   cid_rubeola,
                                                   cid_sarampo,
                                                   queixa_rubeola,
                                                   queixa_sarampo) %>%
  summarise(n = n())


#Listagem de CIDs registrados nos atendimentos classificados pelas queixas como rubéola e sarampo

sarampo_cids_alt <- unique(base_exantematicas[base_exantematicas$cid_sarampo == FALSE &  base_exantematicas$queixa_sarampo == TRUE, "cid_str"])

rubeola_cids_alt <- unique(base_exantematicas[base_exantematicas$cid_rubeola == FALSE &  base_exantematicas$queixa_rubeola == TRUE, "cid_str"]) 

# Listar os CIDs separados por rubeola e sarampo
listagem_cids_alt <- list(
  "CIDs com queixa de rubeola, mas CID não confirmado" = rubeola_cids_alt,
  "CIDs com queixa de sarampo, mas CID não confirmado" = sarampo_cids_alt
)

# Plot --------------------------------------------------------------------

## Exantematicas

### Filtrar dados para rubéola ----
rubeola_data <- base_saramp_rub[base_saramp_rub$atencao == "rubeola", ]

### Contagem para rubéola
rubeola_counts <- list(
  "CID" = sum(rubeola_data$n[rubeola_data$cid_rubeola == TRUE], na.rm = TRUE),
  "Queixa" = sum(rubeola_data$n[rubeola_data$queixa_rubeola == TRUE], na.rm = TRUE),
  "CID_Queixa" = sum(rubeola_data$n[rubeola_data$cid_rubeola == TRUE] & rubeola_data$n[rubeola_data$queixa_rubeola == TRUE], na.rm = TRUE)
)


### Criar Venn diagram para rubéola
venn.plot.rubeola <- draw.pairwise.venn(
  area1 = rubeola_counts$CID,
  area2 = rubeola_counts$Queixa,
  cross.area = rubeola_counts$CID_Queixa,
  category = c("CID Rubéola", "Queixa Rubéola"),
  fill = c("grey60","gray20"),
  alpha = 0.8,
  ext.text = FALSE,
  lwd = 0,
  rotation.degree = 45,
  rotation.centre = c(0.5, 0.5),
  # euler.d = TRUE,
  scaled = TRUE,
  cex = 1,
  cat.cex = 1,
  cat.pos = c(153, 153),
  cat.dist = .04,
  fontfamily = rep("serif", 3),
  label.col = c("black","white","white")
)



## Filtrar dados para sarampo ----
sarampo_data <- base_saramp_rub[base_saramp_rub$atencao == "sarampo", ]

### Contagem para sarampo
sarampo_counts <- list(
  "CID" = sum(sarampo_data$n[sarampo_data$cid_sarampo == TRUE], na.rm = TRUE),
  "Queixa" = sum(sarampo_data$n[sarampo_data$queixa_sarampo == TRUE], na.rm = TRUE),
  "CID_Queixa" = sum(sarampo_data$n[sarampo_data$cid_sarampo == TRUE & sarampo_data$queixa_sarampo == TRUE], na.rm = TRUE)
)


### Criar Venn diagram para sarampo
venn.plot.sarampo <- draw.pairwise.venn(
  area1 = sarampo_counts$CID,
  area2 = sarampo_counts$Queixa,
  cross.area = sarampo_counts$CID_Queixa,
  category = c("CID Sarampo", "Queixa Sarampo"),
  fill = c("grey60","gray20"),
  alpha = 0.8,
  ext.text = FALSE,
  lwd = 0,
  rotation.degree = 45,
  rotation.centre = c(0.5, 0.5),
  # euler.d = TRUE,
  scaled = TRUE,
  cex = 1,
  cat.cex = 1,
  cat.pos = c(150, 155),
  fontfamily = rep("serif", 3), 
  inverted = TRUE,
  cat.dist = .05,
  label.col = c("black", "white", "white")
)


## Visualizar os dois diagramas em conjunto
grid.newpage()
grid.arrange(
  grobs = list(venn.plot.sarampo, venn.plot.rubeola),
  ncol = 2 # 2 colunas para colocar os diagramas lado a lado
)


# Exportar a imagem em formato PNG
png("venn_diagrams.png", width = 8, height = 4, res = 600, units = "in")
grid.arrange(
  grobs = list(venn.plot.sarampo, venn.plot.rubeola),
  ncol = 2
)
dev.off()


## Síndrome gripal e diarreia--------------


# Filtrar os dados para as combinações de séries
df_diarreia <- base_grip_diar %>% filter(serie %in% c("cid_diarreia", "diarreia"))
df_sg <- base_grip_diar %>% filter(serie %in% c("sg_garganta_tosse", "cid_sindrome_gripal"))


##Síndrome gripal----------

### Separando as séries cid_sg e sg
cid_sg <- df_sg[df_sg$serie == 'cid_sindrome_gripal', 'n']
sg <- df_sg[df_sg$serie == 'sg_garganta_tosse', 'n']

### Calculando a diferença (diff) de cada série
diff_cid_sg <- diff(cid_sg)
diff_sg <- diff(sg)

## Criar gráfico 2: sg_garganta_tosse e cid_sindrome_gripal

### criando a variavel semana_anoepi
df_sg <- df_sg %>%
  mutate(ano_semana_epi = as.factor(paste(
    ano_epi, sprintf("%02d", semana_epi), sep = "-"
  )))

#datas das intervencoes
# Converter "2023-10-31" e "2024-03-15" para semanas epidemiológicas
data_1 <- as.Date("2023-10-31")
data_2 <- as.Date("2024-03-15")

# Calcular a semana epidemiológica dessas datas

semana_data_1 <- epiweek(data_1)  # Semana epidemiológica da data "2023-10-31"
ano_data_1 <- year(data_1)        # Ano da data "2023-10-31"

semana_data_2 <- epiweek(data_2)  # Semana epidemiológica da data "2024-03-15"
ano_data_2 <- year(data_2)        # Ano da data "2024-03-15"

# Combinar as semanas epidemiológicas com o ano para comparar com `ano_semana_epi`
data_1_str <- paste(ano_data_1, sprintf("%02d", semana_data_1), sep = "-")
data_2_str <- paste(ano_data_2, sprintf("%02d", semana_data_2), sep = "-")

## Encontrar a posição no eixo `ano_semana_epi`
df_filtered <- df_sg %>% filter(serie == "cid_sindrome_gripal")

pos_data_1 <- match(data_1_str, df_filtered$ano_semana_epi)
pos_data_2 <- match(data_2_str, df_filtered$ano_semana_epi)

## Ver os índices das semanas epidemiológicas
print(pos_data_1)  # Exemplo: 44
print(pos_data_2)  # Exemplo: 64

## plot SG 
plot_sindrome_gripal <- ggplot(df_sg, aes(x = ano_semana_epi, y = n, color = serie, group = serie, linetype = serie)) +
  geom_line(size = .4) +
 geom_vline(xintercept = pos_data_1,  linetype = "dotted" , color = "grey10", linewidth = 0.3) +  # Linha vertical
 geom_vline(xintercept = pos_data_2, linetype = "dotted", color = "grey10", linewidth = 0.3) +  # Linha vertical
 annotate("text", x = pos_data_1 -15, y = 14800,  # Ajustar a posição do texto
         label = "CID R05\u00B9 \ndescontinuado", color = "black", hjust = 0,family = "Times New Roman", size = 2.8) +
 annotate("text", x = pos_data_2 -15, y = 14800,  # Ajustar a posição do texto
      label = "CID B34.9\u00B2 \ndescontinuado", color = "black", hjust = 0,family = "Times New Roman", size = 2.8) +
  annotate(x = 5, y = 15000, geom = "text", label = "A", color = "black", hjust = 0,family = "Times New Roman", size = 3.9) +
  scale_color_manual(values = c("cid_sindrome_gripal" = "grey40", "sg_garganta_tosse" = "black"),
                     labels = c("cid_sindrome_gripal" = "CID SG", "sg_garganta_tosse" = "Queixa SG"))+
  labs(title = "", x = "Ano-SE", y = "Número de Casos", caption = "\u00B9Tosse aguda ou crônica; \U00B2Infecção viral não especificada") +
  scale_linetype_manual(values = c("cid_sindrome_gripal" = "dashed", "sg_garganta_tosse" = "solid"),
                        labels = c("cid_sindrome_gripal" = "CID SG", "sg_garganta_tosse" = "Queixa SG"))+
  scale_x_discrete(breaks = levels(df_sg$ano_semana_epi)[seq(1, length(levels(df_sg$ano_semana_epi)), by = 14)]) + # Define um intervalo para breaks
  theme_minimal() +
  theme(text = element_text(family = "Times New Roman", size = 9, color = "black"),
        axis.text = element_text(family = "Times New Roman", size = 9, color = "black"),
        axis.text.x = element_text(hjust = 0.5),
         legend.position = c(0.98, 0.22),  # Posiciona a legenda no canto superior direito
         legend.justification = c(1, 1),   # Ajusta a justificativa para que fique ancorada no canto superior direito         legend.title = element_blank(),
         panel.border = element_rect(color = "black", fill = NA, linewidth = 0.3),
         panel.grid = element_blank(),
         legend.title = element_blank(), 
         legend.text = element_text(family = "Times New Roman", size = 8, color = "black"), 
         axis.ticks.x = element_line(),
        plot.caption = element_text(family = "Times New Roman",hjust = 0))

## plot all
plot_sindrome_gripal_all <- ggplot(df_sg, aes(x = ano_semana_epi, y = n, color = serie, group = serie, linetype = serie)) +
  geom_line(size = .4) +
 geom_vline(xintercept = pos_data_1,  linetype = "dotted" , color = "grey10", linewidth = 0.3) +  # Linha vertical
 geom_vline(xintercept = pos_data_2, linetype = "dotted", color = "grey10", linewidth = 0.3) +  # Linha vertical
 annotate("text", x = pos_data_1 -15, y = 14800,  # Ajustar a posição do texto
         label = "CID R05\u00B9 \ndescontinuado", color = "black", hjust = 0,family = "Times New Roman", size = 2.8) +
 annotate("text", x = pos_data_2 -15, y = 14800,  # Ajustar a posição do texto
      label = "CID B34.9\u00B2 \ndescontinuado", color = "black", hjust = 0,family = "Times New Roman", size = 2.8) +
  annotate(x = 5, y = 15000, geom = "text", label = "C", color = "black", hjust = 0,family = "Times New Roman", size = 3.9) +
  scale_color_manual(values = c("cid_sindrome_gripal" = "grey40", "sg_garganta_tosse" = "black"),
                     labels = c("cid_sindrome_gripal" = "CID SG", "sg_garganta_tosse" = "Queixa SG"))+
  labs(title = "", x = "Ano-SE", y = "Número de Casos", caption = "\u00B9Tosse aguda ou crônica; \U00B2Infecção viral não especificada") +
  scale_linetype_manual(values = c("cid_sindrome_gripal" = "dashed", "sg_garganta_tosse" = "solid"),
                        labels = c("cid_sindrome_gripal" = "CID SG", "sg_garganta_tosse" = "Queixa SG"))+
  scale_x_discrete(breaks = levels(df_sg$ano_semana_epi)[seq(1, length(levels(df_sg$ano_semana_epi)), by = 14)]) + # Define um intervalo para breaks
  theme_minimal() +
  theme(text = element_text(family = "Times New Roman", size = 9, color = "black"),
        axis.text = element_text(family = "Times New Roman", size = 9, color = "black"),
        axis.text.x = element_text(hjust = 0.5),
         legend.position = c(0.98, 0.22),  # Posiciona a legenda no canto superior direito
         legend.justification = c(1, 1),   # Ajusta a justificativa para que fique ancorada no canto superior direito         legend.title = element_blank(),
         panel.border = element_rect(color = "black", fill = NA, linewidth = 0.3),
         panel.grid = element_blank(),
         legend.title = element_blank(), 
         legend.text = element_text(family = "Times New Roman", size = 8, color = "black"), 
         axis.ticks.x = element_line(),
        plot.caption = element_text(family = "Times New Roman",hjust = 0))



# Calculando a CCF entre as duas séries
ccf_sg <- ccf(diff_cid_sg, diff_sg, main = "CCF Síndrome Gripal CID e Queixas", col = "black", lty = 1, plot = FALSE)

# Extraindo os lags e as autocorrelações
lags <- ccf_sg$lag
acf_values <- ccf_sg$acf

# Criando um dataframe para o ggplot
df_ccf_sg <- data.frame(lag = as.numeric(lags), acf = as.numeric(acf_values))

# Definindo o limite de significância
n_obs <- length(df_diarreia$n)
conf_level <- 1.96 / sqrt(n_obs)

# Criando o gráfico no ggplot2 para cross-correlation function (CCF)
ccf_sg <- ggplot(df_ccf_sg, aes(x = lag, y = acf)) +
  geom_bar(stat = "identity", fill = "NA", color = "black", width = 0.00001) +   # Gráfico de barras
  geom_hline(yintercept = conf_level, linetype = "dashed", color = "grey20", linewidth = 0.3) +   # Linha superior de significância
  geom_hline(yintercept = -conf_level, linetype = "dashed", color = "grey20", linewidth = 0.3) +
  geom_hline(yintercept = 0, color = "black", linewidth = 0.2) +  # Linha no eixo x (y = 0)
  labs(title = "", x = "Lag", y = "CCF") +
  annotate(x = -15, y = 0.95, geom = "text", label = "B", color = "black", hjust = 0,family = "Times New Roman", size = 3.9) +
  theme_minimal() +
  theme(text = element_text(family = "Times New Roman", size = 9, color = "black"),
        axis.text = element_text(family = "Times New Roman", size = 9, color = "black"),
        panel.border = element_rect(color = "black", fill = NA, linewidth = 0.3),
        axis.ticks.x = element_line(),
        panel.grid = element_blank())

# Criando o gráfico no ggplot2 ALL

ccf_sg_all <- ggplot(df_ccf_sg, aes(x = lag, y = acf)) +
  geom_bar(stat = "identity", fill = "NA", color = "black", width = 0.00001) +   # Gráfico de barras
  geom_hline(yintercept = conf_level, linetype = "dashed", color = "grey20", linewidth = 0.3) +   # Linha superior de significância
  geom_hline(yintercept = -conf_level, linetype = "dashed", color = "grey20", linewidth = 0.3) +
  geom_hline(yintercept = 0, color = "black", linewidth = 0.2) +  # Linha no eixo x (y = 0)
  labs(title = "", x = "Lag", y = "CCF") +
  annotate(x = -15, y = 0.95, geom = "text", label = "D", color = "black", hjust = 0,family = "Times New Roman", size = 3.9) +
  theme_minimal() +
  theme(text = element_text(family = "Times New Roman", size = 9, color = "black"),
        axis.text = element_text(family = "Times New Roman", size = 9, color = "black"),
        panel.border = element_rect(color = "black", fill = NA, linewidth = 0.3),
        axis.ticks.x = element_line(),
        panel.grid = element_blank())



# Diarreia ---------

# Separando as séries cid_sg e sg
cid_diarreia <- df_diarreia[df_diarreia$serie == 'cid_diarreia', 'n']
diarreia <- df_diarreia[df_diarreia$serie == 'diarreia', 'n']

# Calculando a diferença (diff) de cada série
diff_cid_diarreia <- diff(cid_diarreia)
diff_diarreia <- diff(diarreia)


# Criar gráfico: cid_diarreia e queixa

## criando a variavel semana_anoepi
df_diarreia <- df_diarreia %>%
  mutate(ano_semana_epi = as.factor(paste(ano_epi, sprintf("%02d", semana_epi), sep = "-")))


##plot diarreia
plot_diarreia <- ggplot(df_diarreia, aes(x = ano_semana_epi, y = n, color = serie, group = serie, linetype = serie)) +
  geom_line(size = .4) +
  scale_color_manual(values = c("cid_diarreia" = "grey40", "diarreia" = "black"),
                     labels = c("cid_diarreia" = "CID diarreia", "diarreia" = "Queixa diarreia"))+
  scale_linetype_manual(values = c("cid_diarreia" = "dashed", "diarreia" = "solid"),
                        labels = c("cid_diarreia" = "CID diarreia", "diarreia" = "Queixa diarreia"))+
  labs(title = "", x = "Ano-SE", y = "Número de Casos") + 
  annotate(x = 5, y = 6800, geom = "text", label = "A", color = "black", hjust = 0,family = "Times New Roman", size = 3.9) +
  scale_x_discrete(breaks = levels(df_diarreia$ano_semana_epi)[seq(1, length(levels(df_diarreia$ano_semana_epi)), by = 14)]) + # Define um intervalo para breaks
  theme_minimal() +
  theme(text = element_text(family = "Times New Roman", size = 9, color = "black"),
        axis.text.x = element_text(hjust = 0.5),
        axis.text = element_text(family = "Times New Roman", size = 9, color = "black"),
        legend.position = c(0.98, 0.22),  # Posiciona a legenda no canto superior direito
         legend.justification = c(1, 1),   # Ajusta a justificativa para que fique ancorada no canto superior direito         legend.title = element_blank(),
         panel.border = element_rect(color = "black", fill = NA, linewidth = 0.3),
         panel.grid = element_blank(),
         legend.title = element_blank(),
        axis.ticks.x = element_line(),
        legend.text = element_text(family = "Times New Roman", size = 9, color = "black"))

ggplotly(plot_diarreia)

# Calculando a CCF entre as duas séries
ccf_diarreia <- ccf(diff_cid_diarreia, diff_diarreia, main = "CCF Diarreia CID e Queixas", col = "black", lty = 1, plot = FALSE)

# Extraindo os lags e as autocorrelações
lags <- ccf_diarreia$lag
acf_values <- ccf_diarreia$acf

# Criando um dataframe para o ggplot
df_ccf_diarreia <- data.frame(lag = as.numeric(lags), acf = as.numeric(acf_values))

# Definindo o limite de significância
n_obs <- length(df_diarreia$n)
conf_level <- 1.96 / sqrt(n_obs)

# Criando o gráfico no ggplot2

ccf_diarreia <- ggplot(df_ccf_diarreia, aes(x = lag, y = acf)) +
  geom_bar(stat = "identity", fill = "NA", color = "black", width = 0.00000001) +  
  geom_hline(yintercept = conf_level, linetype = "dashed", color = "grey20", linewidth = 0.3) +   # Linha superior de significância
  geom_hline(yintercept = -conf_level, linetype = "dashed", color = "grey20", linewidth = 0.3) +  # Linha inferior de significância
  geom_hline(yintercept = 0, color = "black", linewidth = 0.2) +  # Linha no eixo x (y = 0)
  annotate(x = -15, y = 0.95, geom = "text", label = "B", color = "black", hjust = 0,family = "Times New Roman", size = 3.9) +
  labs(title = "", x = "Lag", y = "CCF") +
  #theme_minimal() +
  theme(text = element_text(family = "Times New Roman", size = 9, color = "black"),
        axis.text = element_text(family = "Times New Roman", size = 9, color = "black"),
        panel.border = element_rect(color = "black", fill = NA, linewidth = 0.3),
        panel.background = element_blank(),
        axis.ticks.x = element_line(),
        panel.grid = element_blank())



# Combinando graficos diarreia
plot_comb_diarreia <- plot_diarreia + ccf_diarreia + plot_layout(ncol=2, widths = c(2,1))
plot_comb_sg <- plot_sindrome_gripal + ccf_sg + plot_layout(ncol=2, widths = c(2,1))
plot_comb_all <-  plot_diarreia + ccf_diarreia +  plot_sindrome_gripal_all + ccf_sg_all + plot_layout(ncol=2, widths = c(2,1)) 

# Exportar a imagem em formato PNG
png("serie_sg.png", width = 8, height = 4, res = 600, units = "in")
plot_comb_sg
dev.off()

# Exportar a imagem em formato tiff
tiff("serie_sg.tiff", width = 8, height = 4, res = 600, units = "in")
plot_comb_sg
dev.off()

# Exportar a imagem em formato PNG
png("serie_diar.png", width = 8, height = 4, res = 600, units = "in")
plot_comb_diarreia
dev.off()

# Exportar a imagem em formato PNG
png("serie_diar_sg_all.png", width = 10, height = 7, res = 600, units = "in")
plot_comb_all
dev.off()




