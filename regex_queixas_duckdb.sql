-- Este script importa e trata o campo textual de queixas da RUE dentro do duckdb via postgres_scan

-- set limite de memoria
--SET memory_limit='4GB';
PRAGMA memory_limit='8GB';

-- set numero de processos paralelos
-- SET threads TO 6;
PRAGMA threads=6;


SET enable_progress_bar=false;

INSTALL postgres_scanner;
LOAD postgres_scanner;

-- cria a tabela rue original

create table if not exists tb_unidades as (
    select
        a.id as unidade_id,
        a.cnes as unidade_cnes,
        a.nome as unidade_nome,
        a.sigla as unidade_sigla,
        a.ap as unidade_ap,
        b.lat as lat,
        b.lng as lng,
        date_trunc('day', a.dt_inicio_registros) as dt_inicio_registros
        from postgres_scan('dbname=dbname user=user host=host password= password','rue' , 'ta_unidades') as a
        left join postgres_scan('dbname=dbname user=user host=host password= password','auxiliares' , 'ta_unidades') as b
        on a.cnes = b.cod_ub
        order by unidade_id ASC
);



create or replace table tb_rue as (
select
        hash(concat(paciente_id, date_trunc('day', a.entrada_dt), a.unidade_id)) as hash_id,
        date_trunc('day', a.entrada_dt) as data_entrada,
        a.paciente_id,
        a.unidade_id,
        b.unidade_cnes as unidade_cnes,
        b.unidade_nome as unidade_nome,
        max(a.paciente_dt_nascimento) as dt_nascimento,
        a.idade,
        case
            --when a.idade < 10 then '0-9'
            --when a.idade < 15 then '10-14'
            when a.idade < 12 then '0-11'
            when a.idade < 20 then '12-19'
            when a.idade < 40 then '20-39'
            when a.idade < 60 then '40-59'
            --when a.idade < 80 then '60-79'
            when a.idade >= 60 then '60+'
        end as faixa_etaria,
        a.paciente_sexo_biologico as sexo,
        case
            when a.atendimento_especialidade LIKE 'CLINICA MEDICA' then 'CLINICA MEDICA'
            when a.atendimento_especialidade LIKE 'PEDIATRIA' then 'PEDIATRIA'
            when a.atendimento_especialidade LIKE 'CLINICO GERAL' then 'CLINICA MEDICA'
            else NULL
        end as especialidade,
        string_agg(a.diagnostico_tipo, '|') as diagnostico_tipo_str,
        string_agg(a.cid_codigo, '|') as cid_str,
        count(*) as num_atend
        from (select *,
            extract('year' from age(entrada_dt, paciente_dt_nascimento)) as idade
            from postgres_scan('dbname=dbname user=user host=host password= password','rue' , 'tb_atendimento')) as a
        left join tb_unidades as b on a.unidade_id = b.unidade_id
        where a.entrada_dt >= '2020-01-01'
        and a.unidade_id != 7 -- tira ronaldo gazola
        group by data_entrada, date_trunc('day', a.entrada_dt), a.paciente_id, a.unidade_id, b.unidade_cnes, b.unidade_nome, a.paciente_sexo_biologico, a.idade, faixa_etaria, especialidade
        order by data_entrada, a.paciente_id
);


-- tabela detalhes dos pacientes

create or replace table tb_pac_detalhes as (
    select
        paciente_id,
        date_trunc('day', entrada_dt) as data_entrada,
        last(paciente_nome) as paciente_nome,
        last(paciente_nome_mae) as paciente_nome_mae,
        last(paciente_cpf) as paciente_cpf,
        last(paciente_resid_bairro) as paciente_resid_bairro,
        last(paciente_telefone) as paciente_telefone,
        rtrim(concat(
            last(paciente_resid_logradouro_tipo), ' ',
            last(paciente_resid_logradouro_descricao), ', ',
            last(paciente_resid_numero), ' ',
            last(paciente_resid_complemento)
        )) as paciente_endereco
    from postgres_scan('dbname=dbname user=user host=host password= password','rue' , 'tb_atendimento')
    where entrada_dt >= '2023-01-01'
    and unidade_id != 7 -- tira ronaldo gazola
    group by paciente_id, data_entrada
    order by data_entrada, paciente_id
);

-- cria tabela rue com campo queixa

create or replace table tb_classificacao_risco as(

select * from postgres_scan('dbbname=dbname user=user host=host password= password', 'rue', 'tb_classificacao_risco')
);

-- criar tabela com um atendimento por dia

create or replace view vw_classificacao_risco_dia as (
    select
    data_inico,
    paciente_id,
    unidade_id,
    ds_queixa,
    ds_descritor,
from (
    select
        date_trunc('day', dt_inicio) as data_inico,
        paciente_id,
        unidade_id,
        ds_queixa,
        ds_descritor,
        row_number() over (partition by date_trunc('day', dt_inicio), paciente_id, unidade_id order by dt_inicio asc) as row_num
        from tb_classificacao_risco
) where row_num = 1
);

-- junta as duas tabelas

create or replace table tb_rue_queixa as (
    select a.*,
    b.ds_queixa, b.ds_descritor
    from tb_rue as a
    left join (select
    hash_id,
    ds_queixa,
    ds_descritor
from (
    select
        hash(concat(paciente_id, date_trunc('day', dt_inicio), unidade_id)) as hash_id,
        date_trunc('day', dt_inicio) as data_inicio,
        paciente_id,
        unidade_id,
        ds_queixa,
        ds_descritor,
        row_number() over (partition by date_trunc('day', dt_inicio), paciente_id, unidade_id order by dt_inicio asc) as row_num
        from tb_classificacao_risco
) where row_num = 1) as b
 on a.hash_id = b.hash_id
 where a.data_entrada >= '2023-01-01'
 order by a.data_entrada, a.paciente_id, a.unidade_id
);

--text mining e regex

--remove acentos, caracteres, espaços e numeros
create or replace table tb_queixa_classif as (
    select
        *,
        regexp_replace(regexp_replace(regexp_replace(strip_accents(ds_queixa), '\n|,', ' ', 'g'), '[^A-Za-z ]', '', 'g'), '\s+', ' ', 'g') as queixa_clean
        from tb_rue_queixa
        order by data_entrada, paciente_id,unidade_id
);


-- sobrescreve removendo stop words e espaços

create or replace table tb_queixa_classif as (
    select
        *,
        regexp_replace(
            regexp_replace(
                regexp_replace(queixa_clean, '\b\s*A\s*\b|\b\s*ACERCA\s*\b|\b\s*ADEUS\s*\b|\b\s*AGORA\s*\b|\b\s*AINDA\s*\b|\b\s*ALEM\s*\b|\b\s*ALGMAS\s*\b|\b\s*ALGO\s*\b|\b\s*ALGUMAS\s*\b|\b\s*ALGUNS\s*\b|\b\s*ALI\s*\b|\b\s*ALEM\s*\b|\b\s*AMBAS\s*\b|\b\s*AMBOS\s*\b|\b\s*ANO\s*\b|\b\s*ANOS\s*\b|\b\s*ANTES\s*\b|\b\s*AO\s*\b|\b\s*AONDE\s*\b|\b\s*AOS\s*\b|\b\s*APENAS\s*\b|\b\s*APOIO\s*\b|\b\s*APONTAR\s*\b|\b\s*APOS\s*\b|\b\s*APOS\s*\b|\b\s*AQUELA\s*\b|\b\s*AQUELAS\s*\b|\b\s*AQUELE\s*\b|\b\s*AQUELES\s*\b|\b\s*AQUI\s*\b|\b\s*AQUILO\s*\b|\b\s*AS\s*\b|\b\s*ASSIM\s*\b|\b\s*ATRAVES\s*\b|\b\s*ATRAS\s*\b|\b\s*ATE\s*\b|\b\s*AI\s*\b|\b\s*BAIXO\s*\b|\b\s*BASTANTE\s*\b|\b\s*BEM\s*\b|\b\s*BOA\s*\b|\b\s*BOAS\s*\b|\b\s*BOM\s*\b|\b\s*BONS\s*\b|\b\s*BREVE\s*\b|\b\s*CADA\s*\b|\b\s*CAMINHO\s*\b|\b\s*CATORZE\s*\b|\b\s*CEDO\s*\b|\b\s*CENTO\s*\b|\b\s*CERTAMENTE\s*\b|\b\s*CERTEZA\s*\b|\b\s*CIMA\s*\b|\b\s*CINCO\s*\b|\b\s*COISA\s*\b|\b\s*COM\s*\b|\b\s*COMO\s*\b|\b\s*COMPRIDO\s*\b|\b\s*CONHECIDO\s*\b|\b\s*CONSELHO\s*\b|\b\s*CONTRA\s*\b|\b\s*CONTUDO\s*\b|\b\s*CORRENTE\s*\b|\b\s*CUJA\s*\b|\b\s*CUJAS\s*\b|\b\s*CUJO\s*\b|\b\s*CUJOS\s*\b|\b\s*CUSTA\s*\b|\b\s*CA\s*\b|\b\s*DA\s*\b|\b\s*DAQUELA\s*\b|\b\s*DAQUELAS\s*\b|\b\s*DAQUELE\s*\b|\b\s*DAQUELES\s*\b|\b\s*DAR\s*\b|\b\s*DAS\s*\b|\b\s*DE\s*\b|\b\s*DEBAIXO\s*\b|\b\s*DELA\s*\b|\b\s*DELAS\s*\b|\b\s*DELE\s*\b|\b\s*DELES\s*\b|\b\s*DEMAIS\s*\b|\b\s*DENTRO\s*\b|\b\s*DEPOIS\s*\b|\b\s*DESDE\s*\b|\b\s*DESLIGADO\s*\b|\b\s*DESSA\s*\b|\b\s*DESSAS\s*\b|\b\s*DESSE\s*\b|\b\s*DESSES\s*\b|\b\s*DESTA\s*\b|\b\s*DESTAS\s*\b|\b\s*DESTE\s*\b|\b\s*DESTES\s*\b|\b\s*DEVE\s*\b|\b\s*DEVEM\s*\b|\b\s*DEVERA\s*\b|\b\s*DEZ\s*\b|\b\s*DEZANOVE\s*\b|\b\s*DEZASSEIS\s*\b|\b\s*DEZASSETE\s*\b|\b\s*DEZOITO\s*\b|\b\s*DIA\s*\b|\b\s*DIANTE\s*\b|\b\s*DIREITA\s*\b|\b\s*DISPOE\s*\b|\b\s*DISPOEM\s*\b|\b\s*DIVERSA\s*\b|\b\s*DIVERSAS\s*\b|\b\s*DIVERSOS\s*\b|\b\s*DIZ\s*\b|\b\s*DIZEM\s*\b|\b\s*DIZER\s*\b|\b\s*DO\s*\b|\b\s*DOIS\s*\b|\b\s*DOS\s*\b|\b\s*DOZE\s*\b|\b\s*DUAS\s*\b|\b\s*DURANTE\s*\b|\b\s*DA\s*\b|\b\s*DAO\s*\b|\b\s*DUVIDA\s*\b|\b\s*E\s*\b|\b\s*ELA\s*\b|\b\s*ELAS\s*\b|\b\s*ELE\s*\b|\b\s*ELES\s*\b|\b\s*EM\s*\b|\b\s*EMBORA\s*\b|\b\s*ENQUANTO\s*\b|\b\s*ENTAO\s*\b|\b\s*ENTRE\s*\b|\b\s*ENTAO\s*\b|\b\s*ERA\s*\b|\b\s*ERAM\s*\b|\b\s*ESSA\s*\b|\b\s*ESSAS\s*\b|\b\s*ESSE\s*\b|\b\s*ESSES\s*\b|\b\s*ESTA\s*\b|\b\s*ESTADO\s*\b|\b\s*ESTAMOS\s*\b|\b\s*ESTAR\s*\b|\b\s*ESTARA\s*\b|\b\s*ESTAS\s*\b|\b\s*ESTAVA\s*\b|\b\s*ESTAVAM\s*\b|\b\s*ESTE\s*\b|\b\s*ESTEJA\s*\b|\b\s*ESTEJAM\s*\b|\b\s*ESTEJAMOS\s*\b|\b\s*ESTES\s*\b|\b\s*ESTEVE\s*\b|\b\s*ESTIVE\s*\b|\b\s*ESTIVEMOS\s*\b|\b\s*ESTIVER\s*\b|\b\s*ESTIVERA\s*\b|\b\s*ESTIVERAM\s*\b|\b\s*ESTIVEREM\s*\b|\b\s*ESTIVERMOS\s*\b|\b\s*ESTIVESSE\s*\b|\b\s*ESTIVESSEM\s*\b|\b\s*ESTIVESTE\s*\b|\b\s*ESTIVESTES\s*\b|\b\s*ESTIVERAMOS\s*\b|\b\s*ESTIVESSEMOS\s*\b|\b\s*ESTOU\s*\b|\b\s*ESTA\s*\b|\b\s*ESTAS\s*\b|\b\s*ESTAVAMOS\s*\b|\b\s*ESTAO\s*\b|\b\s*EU\s*\b|\b\s*EXEMPLO\s*\b|\b\s*FARA\s*\b|\b\s*FAVOR\s*\b|\b\s*FAZ\s*\b|\b\s*FAZEIS\s*\b|\b\s*FAZEM\s*\b|\b\s*FAZEMOS\s*\b|\b\s*FAZER\s*\b|\b\s*FAZES\s*\b|\b\s*FAZIA\s*\b|\b\s*FACO\s*\b|\b\s*FEZ\s*\b|\b\s*FIM\s*\b|\b\s*FINAL\s*\b|\b\s*FOI\s*\b|\b\s*FOMOS\s*\b|\b\s*FOR\s*\b|\b\s*FORA\s*\b|\b\s*FORAM\s*\b|\b\s*FOREM\s*\b|\b\s*FORMA\s*\b|\b\s*FORMOS\s*\b|\b\s*FOSSE\s*\b|\b\s*FOSSEM\s*\b|\b\s*FOSTE\s*\b|\b\s*FOSTES\s*\b|\b\s*FUI\s*\b|\b\s*FORAMOS\s*\b|\b\s*FOSSEMOS\s*\b|\b\s*GERAL\s*\b|\b\s*GRANDE\s*\b|\b\s*GRANDES\s*\b|\b\s*GRUPO\s*\b|\b\s*HA\s*\b|\b\s*HAJA\s*\b|\b\s*HAJAM\s*\b|\b\s*HAJAMOS\s*\b|\b\s*HAVEMOS\s*\b|\b\s*HAVIA\s*\b|\b\s*HEI\s*\b|\b\s*HOJE\s*\b|\b\s*HORA\s*\b|\b\s*HORAS\s*\b|\b\s*HOUVE\s*\b|\b\s*HOUVEMOS\s*\b|\b\s*HOUVER\s*\b|\b\s*HOUVERA\s*\b|\b\s*HOUVERAM\s*\b|\b\s*HOUVEREI\s*\b|\b\s*HOUVEREM\s*\b|\b\s*HOUVEREMOS\s*\b|\b\s*HOUVERIA\s*\b|\b\s*HOUVERIAM\s*\b|\b\s*HOUVERMOS\s*\b|\b\s*HOUVERA\s*\b|\b\s*HOUVERAO\s*\b|\b\s*HOUVERIAMOS\s*\b|\b\s*HOUVESSE\s*\b|\b\s*HOUVESSEM\s*\b|\b\s*HOUVERAMOS\s*\b|\b\s*HOUVESSEMOS\s*\b|\b\s*HA\s*\b|\b\s*HAO\s*\b|\b\s*INICIAR\s*\b|\b\s*INICIO\s*\b|\b\s*IR\s*\b|\b\s*IRA\s*\b|\b\s*ISSO\s*\b|\b\s*ISTA\s*\b|\b\s*ISTE\s*\b|\b\s*ISTO\s*\b|\b\s*JA\s*\b|\b\s*LADO\s*\b|\b\s*LHE\s*\b|\b\s*LHES\s*\b|\b\s*LIGADO\s*\b|\b\s*LOCAL\s*\b|\b\s*LOGO\s*\b|\b\s*LONGE\s*\b|\b\s*LUGAR\s*\b|\b\s*LA\s*\b|\b\s*MAIOR\s*\b|\b\s*MAIORIA\s*\b|\b\s*MAIORIAS\s*\b|\b\s*MAIS\s*\b|\b\s*MAL\s*\b|\b\s*MAS\s*\b|\b\s*ME\s*\b|\b\s*MEDIANTE\s*\b|\b\s*MEIO\s*\b|\b\s*MENOR\s*\b|\b\s*MENOS\s*\b|\b\s*MESES\s*\b|\b\s*MESMA\s*\b|\b\s*MESMAS\s*\b|\b\s*MESMO\s*\b|\b\s*MESMOS\s*\b|\b\s*MEU\s*\b|\b\s*MEUS\s*\b|\b\s*MIL\s*\b|\b\s*MINHA\s*\b|\b\s*MINHAS\s*\b|\b\s*MOMENTO\s*\b|\b\s*MUITO\s*\b|\b\s*MUITOS\s*\b|\b\s*MAXIMO\s*\b|\b\s*MES\s*\b|\b\s*NA\s*\b|\b\s*NADA\s*\b|\b\s*NAQUELA\s*\b|\b\s*NAQUELAS\s*\b|\b\s*NAQUELE\s*\b|\b\s*NAQUELES\s*\b|\b\s*NAS\s*\b|\b\s*NEM\s*\b|\b\s*NENHUMA\s*\b|\b\s*NESSA\s*\b|\b\s*NESSAS\s*\b|\b\s*NESSE\s*\b|\b\s*NESSES\s*\b|\b\s*NESTA\s*\b|\b\s*NESTAS\s*\b|\b\s*NESTE\s*\b|\b\s*NESTES\s*\b|\b\s*NO\s*\b|\b\s*NOITE\s*\b|\b\s*NOME\s*\b|\b\s*NOS\s*\b|\b\s*NOSSA\s*\b|\b\s*NOSSAS\s*\b|\b\s*NOSSO\s*\b|\b\s*NOSSOS\s*\b|\b\s*NOVA\s*\b|\b\s*NOVAS\s*\b|\b\s*NOVE\s*\b|\b\s*NOVO\s*\b|\b\s*NOVOS\s*\b|\b\s*NUM\s*\b|\b\s*NUMA\s*\b|\b\s*NUMAS\s*\b|\b\s*NUNCA\s*\b|\b\s*NUNS\s*\b|\b\s*NAO\s*\b|\b\s*NIVEL\s*\b|\b\s*NOS\s*\b|\b\s*NUMERO\s*\b|\b\s*O\s*\b|\b\s*OBRA\s*\b|\b\s*OBRIGADA\s*\b|\b\s*OBRIGADO\s*\b|\b\s*OITAVA\s*\b|\b\s*OITAVO\s*\b|\b\s*OITO\s*\b|\b\s*ONDE\s*\b|\b\s*ONTEM\s*\b|\b\s*ONZE\s*\b|\b\s*OS\s*\b|\b\s*OU\s*\b|\b\s*OUTRA\s*\b|\b\s*OUTRAS\s*\b|\b\s*OUTRO\s*\b|\b\s*OUTROS\s*\b|\b\s*PARA\s*\b|\b\s*PARECE\s*\b|\b\s*PARTE\s*\b|\b\s*PARTIR\s*\b|\b\s*PAUCAS\s*\b|\b\s*PEGAR\s*\b|\b\s*PELA\s*\b|\b\s*PELAS\s*\b|\b\s*PELO\s*\b|\b\s*PELOS\s*\b|\b\s*PERANTE\s*\b|\b\s*PERTO\s*\b|\b\s*PESSOAS\s*\b|\b\s*PODE\s*\b|\b\s*PODEM\s*\b|\b\s*PODER\s*\b|\b\s*PODERA\s*\b|\b\s*PODIA\s*\b|\b\s*POIS\s*\b|\b\s*PONTO\s*\b|\b\s*PONTOS\s*\b|\b\s*POR\s*\b|\b\s*PORQUE\s*\b|\b\s*PORQUE\s*\b|\b\s*PORTANTO\s*\b|\b\s*POSICAO\s*\b|\b\s*POSSIVELMENTE\s*\b|\b\s*POSSO\s*\b|\b\s*POSSIVEL\s*\b|\b\s*POUCA\s*\b|\b\s*POUCO\s*\b|\b\s*POUCOS\s*\b|\b\s*POVO\s*\b|\b\s*PRIMEIRA\s*\b|\b\s*PRIMEIRAS\s*\b|\b\s*PRIMEIRO\s*\b|\b\s*PRIMEIROS\s*\b|\b\s*PROMEIRO\s*\b|\b\s*PROPIOS\s*\b|\b\s*PROPRIO\s*\b|\b\s*PROPRIA\s*\b|\b\s*PROPRIAS\s*\b|\b\s*PROPRIO\s*\b|\b\s*PROPRIOS\s*\b|\b\s*PROXIMA\s*\b|\b\s*PROXIMAS\s*\b|\b\s*PROXIMO\s*\b|\b\s*PROXIMOS\s*\b|\b\s*PUDERAM\s*\b|\b\s*PODE\s*\b|\b\s*POE\s*\b|\b\s*POEM\s*\b|\b\s*QUAIS\s*\b|\b\s*QUAL\s*\b|\b\s*QUALQUER\s*\b|\b\s*QUANDO\s*\b|\b\s*QUANTO\s*\b|\b\s*QUARTA\s*\b|\b\s*QUARTO\s*\b|\b\s*QUATRO\s*\b|\b\s*QUE\s*\b|\b\s*QUEM\s*\b|\b\s*QUER\s*\b|\b\s*QUEREIS\s*\b|\b\s*QUEREM\s*\b|\b\s*QUEREMAS\s*\b|\b\s*QUERES\s*\b|\b\s*QUERO\s*\b|\b\s*QUESTAO\s*\b|\b\s*QUIETO\s*\b|\b\s*QUINTA\s*\b|\b\s*QUINTO\s*\b|\b\s*QUINZE\s*\b|\b\s*QUAIS\s*\b|\b\s*QUE\s*\b|\b\s*RELACAO\s*\b|\b\s*SABE\s*\b|\b\s*SABEM\s*\b|\b\s*SABER\s*\b|\b\s*SE\s*\b|\b\s*SEGUNDA\s*\b|\b\s*SEGUNDO\s*\b|\b\s*SEI\s*\b|\b\s*SEIS\s*\b|\b\s*SEJA\s*\b|\b\s*SEJAM\s*\b|\b\s*SEJAMOS\s*\b|\b\s*SEMPRE\s*\b|\b\s*SENDO\s*\b|\b\s*SER\s*\b|\b\s*SEREI\s*\b|\b\s*SEREMOS\s*\b|\b\s*SERIA\s*\b|\b\s*SERIAM\s*\b|\b\s*SERA\s*\b|\b\s*SERAO\s*\b|\b\s*SERIAMOS\s*\b|\b\s*SETE\s*\b|\b\s*SEU\s*\b|\b\s*SEUS\s*\b|\b\s*SEXTA\s*\b|\b\s*SEXTO\s*\b|\b\s*SIM\s*\b|\b\s*SISTEMA\s*\b|\b\s*SOB\s*\b|\b\s*SOBRE\s*\b|\b\s*SOIS\s*\b|\b\s*SOMENTE\s*\b|\b\s*SOMOS\s*\b|\b\s*SOU\s*\b|\b\s*SUA\s*\b|\b\s*SUAS\s*\b|\b\s*SAO\s*\b|\b\s*SETIMA\s*\b|\b\s*SETIMO\s*\b|\b\s*SO\s*\b|\b\s*TAL\s*\b|\b\s*TALVEZ\s*\b|\b\s*TAMBEM\s*\b|\b\s*TAMBEM\s*\b|\b\s*TANTA\s*\b|\b\s*TANTAS\s*\b|\b\s*TANTO\s*\b|\b\s*TARDE\s*\b|\b\s*TE\s*\b|\b\s*TEM\s*\b|\b\s*TEMOS\s*\b|\b\s*TEMPO\s*\b|\b\s*TENDES\s*\b|\b\s*TENHA\s*\b|\b\s*TENHAM\s*\b|\b\s*TENHAMOS\s*\b|\b\s*TENHO\s*\b|\b\s*TENS\s*\b|\b\s*TENTAR\s*\b|\b\s*TENTARAM\s*\b|\b\s*TENTE\s*\b|\b\s*TENTEI\s*\b|\b\s*TER\s*\b|\b\s*TERCEIRA\s*\b|\b\s*TERCEIRO\s*\b|\b\s*TEREI\s*\b|\b\s*TEREMOS\s*\b|\b\s*TERIA\s*\b|\b\s*TERIAM\s*\b|\b\s*TERA\s*\b|\b\s*TERAO\s*\b|\b\s*TERIAMOS\s*\b|\b\s*TEU\s*\b|\b\s*TEUS\s*\b|\b\s*TEVE\s*\b|\b\s*TINHA\s*\b|\b\s*TINHAM\s*\b|\b\s*TIPO\s*\b|\b\s*TIVE\s*\b|\b\s*TIVEMOS\s*\b|\b\s*TIVER\s*\b|\b\s*TIVERA\s*\b|\b\s*TIVERAM\s*\b|\b\s*TIVEREM\s*\b|\b\s*TIVERMOS\s*\b|\b\s*TIVESSE\s*\b|\b\s*TIVESSEM\s*\b|\b\s*TIVESTE\s*\b|\b\s*TIVESTES\s*\b|\b\s*TIVERAMOS\s*\b|\b\s*TIVESSEMOS\s*\b|\b\s*TODA\s*\b|\b\s*TODAS\s*\b|\b\s*TODO\s*\b|\b\s*TODOS\s*\b|\b\s*TRABALHAR\s*\b|\b\s*TRABALHO\s*\b|\b\s*TREZE\s*\b|\b\s*TRES\s*\b|\b\s*TU\s*\b|\b\s*TUA\s*\b|\b\s*TUAS\s*\b|\b\s*TUDO\s*\b|\b\s*TAO\s*\b|\b\s*TEM\s*\b|\b\s*TEM\s*\b|\b\s*TINHAMOS\s*\b|\b\s*UM\s*\b|\b\s*UMA\s*\b|\b\s*UMAS\s*\b|\b\s*UNS\s*\b|\b\s*USA\s*\b|\b\s*USAR\s*\b|\b\s*VAI\s*\b|\b\s*VAIS\s*\b|\b\s*VALOR\s*\b|\b\s*VEJA\s*\b|\b\s*VEM\s*\b|\b\s*VENS\s*\b|\b\s*VER\s*\b|\b\s*VERDADE\s*\b|\b\s*VERDADEIRO\s*\b|\b\s*VEZ\s*\b|\b\s*VEZES\s*\b|\b\s*VIAGEM\s*\b|\b\s*VINDO\s*\b|\b\s*VINTE\s*\b|\b\s*VOCE\s*\b|\b\s*VOCES\s*\b|\b\s*VOS\s*\b|\b\s*VOSSA\s*\b|\b\s*VOSSAS\s*\b|\b\s*VOSSO\s*\b|\b\s*VOSSOS\s*\b|\b\s*VARIOS\s*\b|\b\s*VAO\s*\b|\b\s*VEM\s*\b|\b\s*VOS\s*\b|\b\s*ZERO\s*\b|\b\s*A\s*\b|\b\s*AS\s*\b|\b\s*AREA\s*\b|\b\s*E\s*\b|\b\s*ERAMOS\s*\b|\b\s*ES\s*\b|\b\s*ULTIMO\s*\b|\b\s*RELATA\s*\b|\b\s*RELATOS\s*\b|\b\s*RELATANDO\s*\b|\b\s*RELATOU\s*\b|\b\s*PACIENTE\s*\b|\b\s*REFERE\s*\b|\b\s*REFERINDO\s*\b|\b\s*RELATO\s*\b|\b\s*APRESENTA\s*\b|\b\s*APRESENTANDO\s*\b|\b\s*ENTRADA\s*\b|\b\s*QUADRO\s*\b|\b\s*USO\s*\b|\b\s*INFORMA\s*\b|\b\s*ALEGA\s*\b|\b\s*MAE\s*\b|\b\s*SIC\s*\b|\b\s*DIAS\s*\b|\b\s*UNIDADE\s*\b|\b\s*DIAGNOSTICO\s*\b|\b\s*CLIENTE\s*\b|\b\s*EPISODIO\s*\b|\b\s*EPISODIOS\s*\b|\b\s*EXAME\s*\b|\b\s*CLINICA\s*\b|\b\s*QUEIXA\s*\b|\b\s*MADRUGADA\s*\b|\b\s*INICIOU\s*\b|\b\s*HJ\s*\b|\b\s*PCT\s*\b|\b\s*SAMU\s*\b|\b\s*DEU\s*\b|\b\s*APRESENTOU\s*\b|\b\s*TRAZIDO\s*\b|\b\s*REGIAO\s*\b', ' ', 'g'),
                '\s+',
                ' ',
                'g'),
            '^\s+|\s+$',
            '',
            'g') as queixa_clean2
        from tb_queixa_classif
);


-- padronizacao de palavras de 13 em 13 (pois há limitacao de aninhamento)

create or replace table tb_queixa_classif as (
    SELECT
        *,
        regexp_replace(
            regexp_replace(
                regexp_replace(
                    regexp_replace(
                        regexp_replace(
                            regexp_replace(
                                regexp_replace(
                                    regexp_replace(
                                        regexp_replace(
                                            regexp_replace(
                                                regexp_replace(
                                                    regexp_replace(
                                                        regexp_replace(
                                                            queixa_clean2, -- febre
                                                            '\bfebr(e|il|is|es|icula)?\b',
                                                            'FEBRE',
                                                            'ig'
                                                        ),
                                                        '\bdo(r|endo|res)\b', -- dor
                                                        'DOR',
                                                        'ig'
                                                    ),
                                                    '\bcorpo(ral)\b?', -- corpo
                                                    'CORPO',
                                                    'ig'
                                                ),
                                                '\bcabe(c|ç)a\b', -- cabeça
                                                'CABECA',
                                                'ig'
                                            ),
                                            '\babd(ominal)?\b', -- abdominal
                                            'ABDOMINAL',
                                            'ig'
                                        ),
                                        '\bmuscular(es)?\b', -- muscular
                                        'MUSCULAR',
                                        'ig'
                                    ),
                                    '\be(c|qui)?(x|z)antema(s|tica(s)?)?\b', -- exantema
                                    'EXANTEMA',
                                    'ig'
                                ),
                                '\bconjuntivite\b', -- conjuntivite
                                'CONJUNTIVITE',
                                'ig'
                            ),
                            '\btoss(e|iu|indo)\b', -- tosse
                            'TOSSE',
                            'ig'
                        ),
                        '\bgrip(e|ais|al)\b', -- gripe
                        'GRIPE',
                        'ig'
                    ),
                    '\bfaring(ea|ite)\b', -- faringite
                    'FARINGITE',
                    'ig'
                ),
                '\bami(g)?dalite\b', -- amidalite
                'AMIDALITE',
                'ig'
            ),
            '\bresfriado\b', -- resfriado
            'RESFRIADO',
            'ig'
        ) AS queixa_clean3
    FROM tb_queixa_classif
);

-- segunda parte

create or replace table tb_queixa_classif as (
SELECT
    *,
    regexp_replace(
        regexp_replace(
            regexp_replace(
                regexp_replace(
                    regexp_replace(
                        regexp_replace(
                            regexp_replace(
                                regexp_replace(
                                    regexp_replace(
                                        queixa_clean3,
                                            '\b(congestao|cori(s|z)|escorrendo|entupido|rinorreia)\b', -- coriza
                                            'CORIZA',
                                            'ig'
                                        ),
                                        '\ba(r)?tralgia(s)?\b', -- artralgia
                                        'ARTRALGIA',
                                        'ig'
                                    ),
                                    '\bastenia(s)?\b|\bfraq[eu]e?u?(s|z)a(s)?\b|\bmole(z|s)a\b', -- astenia
                                    'ASTENIA',
                                    'ig'
                                ),
                                '\b(mialgia(a)?(s)?)\b', -- mialgia
                                'MIALGIA',
                                'ig'
                            ),
                            '\b(diar(r)?eia(s)?)\b', -- diarreia
                            'DIARREIA',
                            'ig'
                        ),
                        '\b(cefale(i)?a(s)?)\b', -- cefaleia
                        'CEFALEIA',
                        'ig'
                    ),
                     '\b(vomito(s)?)\b|\bvomitando\b|\bvomitou\b', -- vomito
                    'VOMITO',
                    'ig'
                ),
                '\bpetequ(e)?(i)?a(s)?\b|\bpetecas\b', -- petequias
                'PETEQUIAS',
                'ig'
            ),
            '\bnaus(e|i)a(s)?\b|\benjoo(s)?\b', -- nausea
            'NAUSEA',
            'ig'
        ) AS queixa_clean4
    from tb_queixa_classif
);

-- terceira parte

create or replace table tb_queixa_classif as (
SELECT
    *,
    regexp_replace(
        regexp_replace(
            regexp_replace(
                regexp_replace(
                    regexp_replace(
                        regexp_replace(
                            regexp_replace(
                                regexp_replace(
                                    regexp_replace(
                                        queixa_clean4,
                                            '\bsincope\b', -- sincope
                                            'SINCOPE',
                                            'ig'
                                        ),
                                        '\bsudorese\b|\bsu(or|ando|a)(\s*\w*\s*)?(excessiv(o|a|amente)|intens(a|o|amente))\b|\bsudoreic(o|a)\b', -- sudorese
                                        'SUDORESE',
                                        'ig'
                                    ),
                                    '\btont(u|ei)ra\b', -- tontura
                                    'TONTURA',
                                    'ig'
                                ),
                                '\bedema\b', -- edema
                                'EDEMA',
                                'ig'
                            ),
                            '\bdisp(i)?neia\b', -- dispneia
                            'DISPNEIA',
                            'ig'
                        ),
                        '\bhipotens(ao|o|a)\b', -- hipotensao
                        'HIPOTENSAO',
                        'ig'
                    ),
                    '\bvertigem\b', -- vertigem
                    'VERTIGEM',
                    'ig'
                ),
                '\bcaxumba\b', -- caxumba
                'CAXUMBA',
                'ig'
            ),
            '\bgu(i(n|l){1,2}h?(ain|aim|an|a|iam|ian|anin|e))[\s-]?bar(r)?e', -- guillain-barre
            'GUILLAIN-BARRE',
            'ig'
     ) AS queixa_clean5
from tb_queixa_classif
);


--novas variaveis de classificacao

 create or replace table tb_queixa_classif as (
    SELECT * exclude (queixa_clean, queixa_clean2, queixa_clean3, queixa_clean4),

       -- nega febre
        CASE WHEN regexp_matches(queixa_clean5, '(\bnega\b|\bnao\b|\bsem\b)\s*\bfebre\b|\bfebre\b.*\bnao\s*(\w+\s*)?(referida|aferida|mensurada)\b|\bafebril\b|\bapiretic[oa]\b', 'i') THEN true ELSE false END AS nega_febre,

       -- febre (menciona ou nao)
        CASE WHEN regexp_matches(queixa_clean5, '\bfebre\b|\bhipertermia\b|\bpiretic[oa]\b|\btemperatura(\s*\w*\s*)?(alta|elevada)\b|\btax(\s*\w*\s*)?(alt[ao]|elevad[ao])\b|\bcorpo(\s*\w*\s*)?quente\b', 'i') THEN true ELSE false END AS febre,

       --dor de cabeca
        CASE WHEN regexp_matches(queixa_clean5, '\bdor(\s*\w*\s*)?(na|de)?(\s*)?cabeca\b', 'i') THEN true
            ELSE false  END AS dor_cabeca,

       --dor de cabeca e cefaleia
        CASE WHEN regexp_matches(queixa_clean5, '\bdor(\s*\w*\s*)?(na|de)?(\s*)?cabeca\b|\bcefal(eia|gia)\b', 'i') THEN true
            ELSE false  END AS cef_dorcabeca,

      
       --dor de barriga
        CASE WHEN regexp_matches(queixa_clean5, '\bdor(\s*\w*\s*)?(na|de|no)?(\s*)?barriga\b', 'i') THEN true
            ELSE false END AS dor_barriga,

     
    --Outros sintomas
      --manchas vermelhas
        CASE WHEN regexp_matches(queixa_clean5, '\b(mancha[s]?\s*(vermelha[s]?|vermelhidao))\s*[?:na|no|em|do|pela|pelo]?\s*[pele|corpo]?\b|\b(mancha(s)?|pele|placa(s)?|pint(as|inhas))\s*(a)?vermelha(da)?(s)?\b|\beritema(tosa)?(s)?\b|\be(qui|x|c)zema(s)?\b', 'i') THEN true
            ELSE false END AS mancha_vermelha,

      --diarreia
        CASE WHEN regexp_matches(queixa_clean5, '\bdiarreia\b', 'i') THEN true ELSE false END AS diarreia,

      --cefaleia
        CASE WHEN regexp_matches(queixa_clean5, '\bcefaleia\b', 'i') THEN true ELSE false END AS cefaleia,
     
      --manchas_petequias
        CASE WHEN regexp_matches(queixa_clean5, '\bpetequias\b|\bmancha[s]?\s*[vermelha[s]?]?\s*[?:na|no|em|do|pela|pelo]?\s*[pele|corpo]?\b', 'i') THEN true ELSE false END AS manchas_petequias,

      --exantemas
        CASE WHEN regexp_matches(queixa_clean5, '\bexantema\b', 'i') THEN true ELSE false END AS exantema,

      --conjuntivite
        CASE WHEN regexp_matches(queixa_clean5, '\bconjuntivite\b|\b(olho(s)?|conjuntiva|vistas)(\s*\w*\s*)?(irritad[oa](s)?|(a)?vermelh[a|o](do)?s?|cocando|remela(ndo)?|ramelent[oa](s)?|lacrimejan(do|tes|te)|arden(do|te|tes)|arranhando)\b|\b(coceira|prurido|irritacao|incomodo|ardencia|secrecao|inflamacao|hiperemia|infeccao)(\s*\w*\s*)?(olho(s)?|conjuntiva(l)?|ocular|vista(s)?)\b', 'i') THEN true ELSE false END AS conjuntivite,

      --tosse
        CASE WHEN regexp_matches(queixa_clean5, '\btosse\b', 'i') THEN true ELSE false END AS tosse,

      --gripe
       CASE WHEN regexp_matches(queixa_clean5, '\bgripe\b', 'i') THEN true ELSE false END AS gripe,

      --faringite
       CASE WHEN regexp_matches(queixa_clean5, '\bfaringite\b', 'i') THEN true ELSE false END AS faringite,

      --amidalite
       CASE WHEN regexp_matches(queixa_clean5, '\bamidalite\b', 'i') THEN true ELSE false END AS amidalite,

      --resfriado
       CASE WHEN regexp_matches(queixa_clean5, '\bresfriado\b', 'i') THEN true ELSE false END AS resfriado,

      --espirro
       CASE WHEN regexp_matches(queixa_clean5, '\bespirr(o|ando|ou)\b', 'i') THEN true ELSE false END AS espirro,

      --sinusite
       CASE WHEN regexp_matches(queixa_clean5, '\bsinusite\b', 'i') THEN true ELSE false END AS sinusite,

      --coriza
        CASE WHEN regexp_matches(queixa_clean5, '\bcoriza\b', 'i') THEN true ELSE false END AS coriza,

      --sintomas gripais
        CASE WHEN regexp_matches(queixa_clean5, '\bresfriado\b|\bgripe\b|\bcoriza\b|\bsinusite\b|\bespirro\b', 'i') THEN true ELSE false END AS sintomas_gripais,

      --sintomas gripais com dor de garganta
        CASE WHEN regexp_matches(queixa_clean5, '\bresfriado\b|\bgripe\b|\bcoriza\b|\bsinusite\b|\bespirr(o|ando|ou)\b|\b(dor|incomodo|desconforto|algia|queimacao|irritacao|vermelhidao)(\s*\w*\s*)?(na|de|para)?(\s*)?(garganta|engolir)\b|\bgarganta(\s*)(inflamada|doendo|arranhando|infeccionada|ardendo|vermelha|dolorida)\b|\bfaringite\b|\bamidalite\b', 'i') THEN true ELSE false END AS sg_garganta,

      --sintomas gripais com dor de garganta e tosse
        CASE WHEN regexp_matches(queixa_clean5, '\bresfriado\b|\bgripe\b|\bcoriza\b|\bsinusite\b|\bespirr(o|ando|ou)\b|\btosse\b|\b(dor|incomodo|desconforto|algia|queimacao|irritacao|vermelhidao)(\s*\w*\s*)?(na|de|para)?(\s*)?(garganta|engolir)\b|\bgarganta(\s*)(inflamada|doendo|arranhando|infeccionada|ardendo|vermelha|dolorida)\b|\bfaringite\b|\bamidalite\b', 'i') THEN true ELSE false END AS sg_garganta_tosse,


      --garganta inflamada
        CASE WHEN regexp_matches(queixa_clean5, '\bgarganta(\s*)(inflamada|doendo)\b|\balgia(\s*)?(na|da)*(\s*)garganta\b', 'i') THEN true
            ELSE false END AS garganta_inflam,

    


        FROM tb_queixa_classif);

--classificacao por CID de interesse


 create or replace table tb_queixa_classif as (
    SELECT *,
    --sindrome gripal
    case when regexp_matches(cid_str, 'J11|J0[0-9]|J10') then true else false end as cid_sindrome_gripal,

    --arbovirose
    case when regexp_matches(cid_str, 'A90|A91|A92|A93|A94|A98|A99') then true else false end as cid_arbo,

    --covid
    case when regexp_matches(cid_str, 'B34.2|U07') then true else false end as cid_covid,

    --virose nao especificada
    case when regexp_matches(cid_str, 'B34.9') then true else false end as cid_viroseNE,

    --febre
    case when regexp_matches(cid_str, 'A68.9|R50') then true else false end as cid_febre,

    --tosse
    case when regexp_matches(cid_str, 'R05') then true else false end as cid_tosse,

    --diarreia
    case when regexp_matches(cid_str, 'A09|K52|K59') then true else false end as cid_diarreia,

    --nausea
    case when regexp_matches(cid_str, 'R11') then true else false end as cid_nausea,

    --cefaleia
    case when regexp_matches(cid_str, 'R51') then true else false end as cid_cefaleia,

    --mialgia
    case when regexp_matches(cid_str, 'M79.1') then true else false end as cid_mialgia,

    --artralgia
    case when regexp_matches(cid_str, 'M25.5') then true else false end as cid_artralgia,

    --bronquiolite
    case when regexp_matches(cid_str, 'J21.0|J21.8') then true else false end as cid_bronquiolite

    FROM
  tb_queixa_classif);


-- cria view de series diarias

create or replace view vw_queixa_dia as (
    unpivot (
    select data_entrada,
      week(data_entrada + 1) as semana_epi,
      cast(left(cast(yearweek(data_entrada + 1) as VARCHAR), 4) as INT) as ano_epi,
      sum(cast(febre as integer)) - sum(cast(nega_febre as integer)) as febre,
      sum(cast(nega_febre as integer)) as nega_febre,
      sum(cast(dor_olhos as integer)) as dor_olhos,
      sum(cast(dor_abdominal as integer)) as dor_abdominal,
      sum(cast(dor_cabeca as integer)) as dor_cabeca,
      sum(cast(cef_dorcabeca as integer)) as cef_dorcabeca,
      sum(cast(dor_garganta as integer)) as dor_garganta,
      sum(cast(garg_dor_infla as integer)) as garg_dor_infla,
      sum(cast(dor_gastrica as integer)) as dor_gastrica,
      sum(cast(dor_barriga as integer)) as dor_barriga,
      sum(cast(dor_peito as integer)) as dor_peito,
      sum(cast(dor_corpo as integer)) as dor_corpo,
      sum(cast(mialgia_dorcorpo as integer)) as mialgia_dorcorpo,
      sum(cast(dor_ouvido as integer)) as dor_ouvido,
      sum(cast(mancha_vermelha as integer)) as mancha_vermelha,
      sum(cast(mialgia as integer)) as mialgia,
      sum(cast(diarreia as integer)) as diarreia,
      sum(cast(cefaleia as integer)) as cefaleia,
      sum(cast(vomito as integer)) as vomito,
      sum(cast(petequias as integer)) as petequias,
      sum(cast(nausea as integer)) as nausea,
      sum(cast(exantema as integer)) as exantema,
      sum(cast(conjuntivite as integer)) as conjuntivite,
      sum(cast(tosse as integer)) as tosse,
      sum(cast(gripe as integer)) as gripe,
      sum(cast(faringite as integer)) as faringite,
      sum(cast(amidalite as integer)) as amidalite,
      sum(cast(resfriado as integer)) as resfriado,
      sum(cast(espirro as integer)) as espirro,
      sum(cast(sinusite as integer)) as sinusite,
      sum(cast(coriza as integer)) as coriza,
      sum(cast(artralgia as integer)) as artralgia,
      sum(cast(astenia as integer)) as astenia,
      sum(cast(garganta_inflam as integer)) as garganta_inflam,
      sum(cast(sincope as integer)) as sincope,
      sum(cast(sudorese as integer)) as sudorese,
      sum(cast(tontura as integer)) as tontura,
      sum(cast(edema as integer)) as edema,
      sum(cast(dispneia as integer)) as dispneia,
      sum(cast(hipotensao as integer)) as hipotensao,
      sum(cast(vertigem as integer)) as vertigem,
      sum(cast(caxumba as integer)) as caxumba,
      -- efeitos combinados
      sum(cast(manchas_petequias as integer)) as manchas_petequias,
      sum(cast(sintomas_gripais as integer)) as sintomas_gripais,
      sum(cast(sg_garganta as integer)) as sg_garganta,
      sum(cast(sg_garganta_tosse as integer)) as sg_garganta_tosse,
      sum(cast(tontura_vertigem as integer)) as tontura_vertigem,
      sum(cast(efeitos_calor as integer)) as efeitos_calor,
      sum(cast(sintomas_urinarios as integer)) as sintomas_urinarios,

      -- cids
      sum(cast(cid_sindrome_gripal as integer)) as cid_sindrome_gripal,
      sum(cast(cid_arbo as integer)) as cid_arbo,
      sum(cast(cid_covid as integer)) as cid_covid,
      sum(cast(cid_viroseNE as integer)) as cid_viroseNE,
      sum(cast(cid_febre as integer)) as cid_febre,
      sum(cast(cid_tosse as integer)) as cid_tosse,
      sum(cast(cid_diarreia as integer)) as cid_diarreia,
      sum(cast(cid_nausea as integer)) as cid_nausea,
      sum(cast(cid_cefaleia as integer)) as cid_cefaleia,
      sum(cast(cid_mialgia as integer)) as cid_mialgia,
      sum(cast(cid_artralgia as integer)) as cid_artralgia,
      sum(cast(cid_bronquiolite as integer)) as cid_bronquiolite

     from tb_queixa_classif
     group by data_entrada, semana_epi, ano_epi) on
     columns(* exclude (data_entrada, semana_epi, ano_epi))
     into name serie value n
     order by data_entrada
);

-- serie semanal

create or replace view vw_queixa_sem as (
    select
    semana_epi,
    ano_epi,
    serie,
    sum(n) as n
    from vw_queixa_dia
    group by semana_epi, ano_epi, serie
    order by ano_epi, semana_epi, serie
);

create or replace view vw_sem_cont as (
    select
        semana_epi,
        ano_epi,
        row_number() over (order by ano_epi, semana_epi) as week_num,
        count(*) as n
        from vw_queixa_dia
        where serie like 'febre'
        group by ano_epi, semana_epi
        order by ano_epi desc, semana_epi desc
);


-- view tokenizada

create or replace view vw_queixa_token as (

select hash_id,
cid_str,
unnest(regexp_split_to_array(regexp_replace(queixa_clean5, '\bDOR ', 'DOR-', 'ig'), ' ')) as token
from tb_queixa_classif

);

-- tabela queixas de atencao

create or replace view vw_queixa_atencao as(
    SELECT *,
    CASE
        WHEN
            (exantema OR regexp_matches(lower(cid_str), 'r21') OR mancha_vermelha) AND
            (regexp_matches(lower(cid_str), 'b30') OR conjuntivite) AND
            (regexp_matches(lower(cid_str), 'r50') OR febre) AND
            (coriza OR tosse OR regexp_matches(lower(cid_str), 'r05')) OR
            regexp_matches(lower(queixa_clean5), 'sarampo') OR
            regexp_matches(lower(cid_str), 'b05')
        THEN 'sarampo'


        WHEN
            (exantema OR regexp_matches(lower(cid_str), 'r21') OR mancha_vermelha) AND
            (regexp_matches(lower(cid_str), 'r50') OR febre) AND
            (regexp_matches(lower(queixa_clean5), 'linfoadeno') OR
             regexp_matches(lower(queixa_clean5), 'ganglio') OR
             regexp_matches(lower(queixa_clean5), 'caroco')) OR
            regexp_matches(lower(queixa_clean5), 'rubeola') OR
            regexp_matches(lower(cid_str), 'b06')
        THEN 'rubeola'


        ELSE ''
    END AS atencao
FROM tb_queixa_classif
WHERE atencao != ''
);
