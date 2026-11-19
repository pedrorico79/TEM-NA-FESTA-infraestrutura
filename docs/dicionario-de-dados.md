# Dicionário de dados do Tem Na Festa

Este dicionário descreve a coleta ativa de produtos do sistema com Google Trends, as tabelas Glue/Athena do bronze e o banco MySQL. A coleta lê os produtos ativos pela API do backend e envia `produto_nome` como termo de busca; não consulta a planilha externa de aquisição alimentar.

**Sensibilidade:** *pessoal* é dado pessoal pela LGPD; *segredo* nunca aparece em exemplo nem sai do banco; *interna* é dado do negócio sem identificação de pessoa; *pública* é o índice retornado pelo Google Trends.

## 1. Coleta raw: produtos ativos e Google Trends

A Lambda `tnf-<env>-tendencias` busca os produtos ativos no backend e gera uma carga completa por ambiente e data de coleta. A coleta local gera o mesmo layout sob `arquivos-gerados/datasets/tendencias_produtos/`; na AWS, os arquivos são gravados no bucket bronze.

```text
datasets/tendencias_produtos/{bruto,resumo,serie,rejeicoes}/env={env}/data_coleta=AAAA-MM-DD/
```

O CSV bruto é UTF-8 com BOM, separador `;` e fim de linha `\r\n`. Os JSONL contêm um objeto por linha. O mês de busca é `produto_nome` exatamente como cadastrado no sistema; não há coluna separada `termo_trends`.

### `tendencias_produtos.bruto`

Uma linha por produto com dados suficientes no Trends. Campos mensais `AAAA-MM` cobrem os 12 meses mais recentes; o mês corrente é parcial.

| Papel no projeto | Nome do campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo | Descrição |
|---|---|---|---|---|---|---|---|
| Chave do produto | `produto_id` | inteiro | 10 | sim | ID do produto retornado pela API; não nulo e sem repetição | 12 | Identificador do produto no sistema |
| Nome e termo de busca | `produto_nome` | texto | 100 | sim | Nome do produto ativo, sem espaços nas pontas; enviado ao Trends sem canonicalização | Bolo de pote | Nome cadastrado no sistema e termo pesquisado |
| Preço cadastrado | `preco_venda` | decimal | 10,2 | não | Numérico quando fornecido; pode ser nulo | 12.50 | Preço informado pela API |
| Data da coleta | `data_coleta` | data | 10 | sim | `YYYY-MM-DD`, fuso de São Paulo | 2026-11-19 | Data de execução e partição |
| Popularidade mensal | coluna dinâmica `AAAA-MM` | decimal | 5,2 | não | Índice de 0 a 100; célula vazia se não houver observação no mês | 44.0 | Média mensal do Google Trends |
| Média do período | `popularidade_media` | decimal | 5,2 | sim | Média dos valores mensais disponíveis, 0 a 100 | 31.4 | Média da popularidade mensal |
| Pico do período | `popularidade_pico` | decimal | 5,2 | sim | Máximo mensal, 0 a 100 | 100.0 | Maior popularidade mensal |
| Mês do pico | `mes_pico` | inteiro | 2 | sim | Mês de 1 a 12; em empate prevalece o primeiro mês cronológico | 12 | Mês associado ao pico |
| Sazonalidade | `fator_sazonalidade` | decimal | variável, 2 casas | sim | `popularidade_pico / popularidade_media`, arredondado a duas casas | 3.18 | Pico dividido pela média |
| Classificação do pico | `tipo_feriado_pico` | texto | 30 | sim | Atualmente fixo como `Sazonalidade Comercial` | Sazonalidade Comercial | Tipo do evento associado |
| Evento do calendário | `evento_associado` | texto | 60 | sim | Um dos rótulos comerciais definidos pelo mês do pico | Festas de Fim de Ano / Natal | Evento associado ao mês do pico |

### `resumo.jsonl`

Uma linha JSON por produto e coleta. Contém os campos fixos do CSV bruto, exceto as 12 colunas mensais. Produtos sem dados suficientes no Trends são registrados como aviso em `rejeicoes.jsonl` e ficam fora do resumo.

### `serie.jsonl`

Uma linha JSON por produto e mês de referência; até 12 linhas por produto e coleta.

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo | Descrição |
|---|---|---|---|---|---|---|
| `produto_id` | inteiro | 10 | sim | ID do produto retornado pela API | 12 | Relaciona ao produto do resumo |
| `mes_referencia` | texto | 7 | sim | `YYYY-MM`, em ordem cronológica | 2026-10 | Mês da observação |
| `popularidade` | decimal ou nulo | 5,2 | não | Índice de 0 a 100; nulo sem observação no mês | 44.0 | Média mensal do Trends |
| `mes_parcial` | booleano | — | sim | `true` no mês corrente; `false` nos anteriores | true | Indica mês incompleto |
| `data_coleta` | data | 10 | sim | `YYYY-MM-DD`, fuso de São Paulo | 2026-11-19 | Versão da coleta |

Chave lógica da série: `produto_id` + `mes_referencia` + `data_coleta`.

### `rejeicoes.jsonl`

Uma linha JSON por validação ou aviso. Campos: `produto_id` (inteiro ou nulo), `produto` (texto ou nulo), `regra` (texto), `motivo` (texto), `severidade` (`bloqueante` ou `aviso`) e `data_ocorrencia` (timestamp ISO 8601 com fuso de São Paulo). O arquivo vazio indica que não houve rejeições.

Tabelas Glue/Athena sobre os objetos do bronze. `env` e `data_coleta` são partições lidas do caminho e expostas pelo catálogo; não se repetem no schema de colunas.

## 2. Tabelas do Athena (banco `tnf_bronze`)

Tabelas declaradas no Glue sobre o bronze, com *partition projection* (10, seção 6.1). As colunas de partição (`data_coleta`, `env`, `year`, `month`, `day`) vêm do caminho e não se repetem no schema. Os tipos são os do Glue/Athena.

### `tnf_bronze.tendencias_produtos_resumo`

Produtos ativos do sistema por coleta; partições `env` e `data_coleta`. Produtos sem dados no Trends ficam nas rejeições como aviso e aparecem como "Sem dados suficientes" na visão `vw_tendencias_produtos_atual`.

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `produto_id` | int | 10 | sim | `produto.id` do banco, único por coleta | 12 | Produto do sistema | PK (com `env` e `data_coleta`); FK → `tem_na_festa.produto.id` | interna |
| `produto_nome` | string | 100 | sim | `produto.nome`, sem espaços nas pontas | Bolo de pote | Termo pesquisado no Trends | | interna |
| `preco_venda` | double | 10,2 | não | Maior ou igual a zero | 12.5 | Preço cadastrado | | interna |
| `popularidade_media` | double | 5,2 | sim | Maior ou igual a zero | 31.4 | Média mensal | | pública |
| `popularidade_pico` | double | 5,2 | sim | 0 a 100 | 100.0 | Pico mensal | | pública |
| `mes_pico` | int | 2 | não | 1 a 12 | 12 | Mês do pico | | pública |
| `fator_sazonalidade` | double | 5,2 | não | Maior que zero; vazio com média zero | 3.18 | Pico ÷ média | | pública |
| `tipo_feriado_pico` | string | 30 | sim | `Sazonalidade Comercial` | Sazonalidade Comercial | Tipo do evento | | pública |
| `evento_associado` | string | 60 | não | Calendário comercial da seção 1 | Festas de Fim de Ano / Natal | Evento do mês do pico | | pública |

### `tnf_bronze.tendencias_produtos_serie`

Formato longo da base dos produtos; partições `env` e `data_coleta`.

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `produto_id` | int | 10 | sim | `produto.id` do banco | 12 | Produto do sistema | PK (com `mes_referencia`, `env` e `data_coleta`) | interna |
| `mes_referencia` | string | 7 | sim | `YYYY-MM`, os últimos 12 meses | 2026-10 | Mês da popularidade | PK | pública |
| `popularidade` | double | 5,2 | não | 0 a 100; vazio sem dado no mês | 44.0 | Popularidade média do mês | | pública |
| `mes_parcial` | boolean | 1 | sim | `true` só no mês corrente | true | Mês ainda incompleto na coleta | | interna |

### `tnf_bronze.tendencias_produtos_rejeicoes`

Rejeições e avisos da base dos produtos; partições `env` e `data_coleta`. Mesmo contrato JSONL de rejeições da coleta do sistema.

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `produto_id` | int | 10 | não | `produto.id`, vazio em falha geral | 7 | Produto afetado | | interna |
| `produto` | string | 100 | não | Nome do produto | Brigadeiro | Produto afetado | | interna |
| `regra` | string | 30 | sim | Camadas da EBD 4.2 | coleta externa | Regra que falhou | | interna |
| `motivo` | string | 300 | sim | Texto livre, sem email, senha nem cookie | Sem dados suficientes no Google Trends nos últimos 12 meses | O que aconteceu | | interna |
| `severidade` | string | 10 | sim | `bloqueante` ou `aviso` | aviso | Se interrompeu a coleta | | interna |
| `data_ocorrencia` | string | 25 | sim | ISO 8601 com fuso de São Paulo | 2026-11-02T10:15:40-03:00 | Quando a regra falhou | | interna |

### `tnf_bronze.logs_docker`

Saída dos containers dos nós web e app, gravada pelo Fluent Bit (02, seção 7.1; 05, B4); partições `env`, `year`, `month` e `day` (UTC).

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `date` | string | 30 | sim | ISO 8601 em UTC | 2026-11-02T12:00:01.512Z | Hora do registro (use `"date"` entre aspas no Athena) | | interna |
| `log` | string | livre | sim | Linha do container | GET / HTTP/1.1 200 | Mensagem | | pessoal (pode conter dados do sistema) |
| `stream` | string | 6 | sim | `stdout` ou `stderr` | stdout | Saída do container | | interna |
| `attrs` | map<string,string> | livre | não | Rótulos do Swarm (`com.docker.swarm.service.name`, `com.docker.stack.namespace`) | {"com.docker.swarm.service.name":"tnf-web_frontend"} | Serviço e stack | | interna |
| `host` | string | 63 | sim | Hostname do nó | tem-na-festa-dev-web-1 | Nó de origem | | interna |
| `role` | string | 7 | sim | `web` ou `app` | web | Papel do nó | | interna |
| `log_file` | string | 255 | sim | Caminho do arquivo de log do container | /var/lib/docker/containers/ab12/ab12-json.log | Arquivo lido | | interna |

### `tnf_bronze.logs_auth`

`auth.log` de todas as instâncias, inclusive o bastion (05, B4).

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `date` | string | 30 | sim | ISO 8601 em UTC | 2026-11-02T12:03:44.000Z | Hora do registro | | interna |
| `ident` | string | 30 | não | Programa que registrou | sshd | Origem da linha | | interna |
| `pid` | string | 10 | não | Número do processo | 1432 | Processo | | interna |
| `message` | string | livre | sim | Linha do auth.log | Accepted publickey for ubuntu from 10.0.0.10 | Mensagem | | pessoal (IP de acesso) |
| `host` | string | 63 | sim | Hostname do nó | tem-na-festa-dev-bastion | Nó de origem | | interna |
| `role` | string | 7 | sim | `web`, `app` ou `bastion` | bastion | Papel do nó | | interna |

### `tnf_bronze.logs_systemd`

Unidades do systemd da lista de 02, seção 7.1 (docker, ssh, fluent-bit, cloud-init, tnf-converge).

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `date` | string | 30 | sim | ISO 8601 em UTC | 2026-11-02T12:00:30.000Z | Hora do registro | | interna |
| `message` | string | livre | sim | Mensagem da unidade (`MESSAGE`) | converge: ready | Mensagem | | interna |
| `systemd_unit` | string | 60 | sim | Uma das unidades de 02, seção 7.1 (`_SYSTEMD_UNIT`) | tnf-converge.service | Unidade de origem | | interna |
| `priority` | string | 1 | não | 0 a 7 (syslog) | 6 | Prioridade | | interna |
| `host` | string | 63 | sim | Hostname do nó | tem-na-festa-dev-app-1 | Nó de origem | | interna |
| `role` | string | 7 | sim | `web`, `app` ou `bastion` | app | Papel do nó | | interna |

## 3. Banco MySQL `tem_na_festa`

Tabelas do script `script-bd-tem-na-festa.sql` do repositório `TEM-NA-FESTA-database`, na tag `db_schema_ref` (05, B5). É a "base interna" que a EBD, seção 5, prevê cruzar no futuro com o Trends. O tipo é o do script.

```mermaid
erDiagram
  endereco ||--o{ cliente : "endereço principal"
  endereco ||--o{ pedido : "endereço de entrega"
  perfil ||--o{ usuario : perfil
  cliente ||--o{ pedido : faz
  usuario ||--o{ pedido : registra
  evento ||--o{ pedido : agrupa
  pedido ||--o{ item_pedido : contém
  produto ||--o{ item_pedido : "vendido em"
  pedido ||--o{ pagamento : recebe
  metodo_pagamento ||--o{ pagamento : "forma de"
  usuario ||--o{ pagamento : registra
  pedido ||--o{ historico_status_pedido : "muda de status"
  usuario ||--o{ historico_status_pedido : altera
  usuario ||--o{ lembrete : cria
```

### `tem_na_festa.endereco`

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `id` | BIGINT | 19 | sim | Gerado pelo banco | 3 | Identificador | PK | interna |
| `cep` | VARCHAR(8) | 8 | sim | 8 dígitos, sem traço | 01310100 | CEP | | pessoal |
| `logradouro` | VARCHAR(150) | 150 | sim | Texto | Avenida Paulista | Rua ou avenida | | pessoal |
| `numero` | VARCHAR(10) | 10 | sim | Texto (aceita "s/n") | 1578 | Número | | pessoal |
| `complemento` | VARCHAR(100) | 100 | não | Texto | Apto 12 | Complemento | | pessoal |
| `bairro` | VARCHAR(100) | 100 | sim | Texto | Bela Vista | Bairro | | pessoal |
| `cidade` | VARCHAR(100) | 100 | sim | Texto | São Paulo | Cidade | | pessoal |
| `estado` | CHAR(2) | 2 | sim | Sigla da UF | SP | Estado | | pessoal |

### `tem_na_festa.cliente`

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `id` | BIGINT | 19 | sim | Gerado pelo banco | 14 | Identificador | PK | interna |
| `nome` | VARCHAR(100) | 100 | sim | Texto | Maria Souza | Nome do cliente | | pessoal |
| `telefone` | VARCHAR(20) | 20 | não | Com DDI e DDD | +55 11 98765-4321 | Telefone | | pessoal |
| `whatsapp` | VARCHAR(20) | 20 | não | Com DDI e DDD; destino das notificações | +55 11 98765-4321 | WhatsApp | | pessoal |
| `instagram` | VARCHAR(50) | 50 | não | Usuário, com ou sem @ | @mariasouza | Instagram | | pessoal |
| `data_cadastro` | DATE | 10 | sim | `YYYY-MM-DD` | 2026-09-15 | Data do cadastro | | interna |
| `anotacoes` | TEXT | 65535 | não | Texto livre | Prefere retirar à tarde | Observações internas | | pessoal |
| `endereco_id` | BIGINT | 19 | não | Endereço existente | 3 | Endereço principal | FK → endereco.id | interna |
| `is_ativo` | BOOLEAN | 1 | sim | Padrão verdadeiro | 1 | Cliente ativo | | interna |
| `is_deletado` | BOOLEAN | 1 | sim | Padrão falso (exclusão lógica) | 0 | Excluído | | interna |

### `tem_na_festa.perfil`

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `id` | BIGINT | 19 | sim | Gerado pelo banco | 1 | Identificador | PK | interna |
| `nome` | VARCHAR(50) | 50 | sim | `ADMIN` dá o papel `ROLE_ADMIN` no backend | ADMIN | Nome do perfil | | interna |
| `descricao` | TEXT | 65535 | não | Texto | Administrador | Descrição | | interna |

### `tem_na_festa.usuario`

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `id` | BIGINT | 19 | sim | Gerado pelo banco | 2 | Identificador | PK | interna |
| `nome` | VARCHAR(100) | 100 | sim | Texto | Ana Lima | Nome do usuário | | pessoal |
| `email` | VARCHAR(100) | 100 | sim | Único, em minúsculas | ana@temnafesta.com.br | Login | | pessoal |
| `senha` | VARCHAR(255) | 255 | sim | Hash BCrypt (`$2a$`), senha de 8 a 72 caracteres | *(nunca exibido)* | Hash da senha | | segredo |
| `is_ativo` | BOOLEAN | 1 | sim | Padrão verdadeiro | 1 | Usuário ativo | | interna |
| `is_deletado` | BOOLEAN | 1 | sim | Padrão falso | 0 | Excluído | | interna |
| `data_criacao` | DATETIME | 19 | sim | `YYYY-MM-DD HH:MM:SS`, horário de São Paulo | 2026-10-20 14:02:11 | Criação | | interna |
| `perfil_id` | BIGINT | 19 | sim | Perfil existente | 1 | Perfil | FK → perfil.id | interna |

### `tem_na_festa.evento`

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `id` | BIGINT | 19 | sim | Gerado pelo banco | 4 | Identificador | PK | interna |
| `nome` | VARCHAR(100) | 100 | sim | Texto | Páscoa 2027 | Nome do evento | | interna |
| `data_inicio` | DATE | 10 | sim | `YYYY-MM-DD`, até `data_fim` | 2027-03-15 | Início | | interna |
| `data_fim` | DATE | 10 | sim | `YYYY-MM-DD` | 2027-03-28 | Fim | | interna |
| `is_ativo` | BOOLEAN | 1 | sim | Padrão verdadeiro | 1 | Evento ativo | | interna |
| `is_deletado` | BOOLEAN | 1 | sim | Padrão falso | 0 | Excluído | | interna |

### `tem_na_festa.pedido`

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `id` | BIGINT | 19 | sim | Gerado pelo banco | 120 | Identificador | PK | interna |
| `data_pedido` | DATETIME | 19 | sim | Horário de São Paulo | 2026-10-28 10:15:00 | Quando foi feito | | interna |
| `data_entrega` | DATETIME | 19 | sim | Igual ou depois de `data_pedido` | 2026-11-01 16:00:00 | Entrega ou retirada | | interna |
| `valor_total` | DECIMAL(10,2) | 10,2 | sim | Maior ou igual a zero | 245.00 | Valor do pedido | | interna |
| `desconto_pedido` | DECIMAL(10,2) | 10,2 | sim | Padrão 0.00; maior ou igual a zero | 10.00 | Desconto aplicado ao pedido (script do banco v1.0.1) | | interna |
| `taxa_entrega` | DECIMAL(10,2) | 10,2 | não | Padrão 0.00 | 15.00 | Taxa de entrega | | interna |
| `observacao` | TEXT | 65535 | não | Texto livre | Escrever "Parabéns, Lia" | Observação | | pessoal |
| `status_producao` | VARCHAR(50) | 50 | sim | RASCUNHO, AGUARDANDO_SINAL, CONFIRMADO, EM_PRODUCAO, PRONTO_PARA_ENTREGA, ENTREGUE ou CANCELADO (`StatusProducaoEnum` do backend; o banco guarda texto livre) | CONFIRMADO | Situação da produção | | interna |
| `cliente_id` | BIGINT | 19 | sim | Cliente existente | 14 | Cliente | FK → cliente.id | interna |
| `usuario_id` | BIGINT | 19 | sim | Usuário existente | 2 | Quem registrou | FK → usuario.id | interna |
| `evento_id` | BIGINT | 19 | não | Evento existente | 4 | Evento do pedido | FK → evento.id | interna |
| `endereco_entrega_id` | BIGINT | 19 | não | Vazio = retirada no local | 3 | Endereço de entrega | FK → endereco.id | interna |
| `is_ativo` | BOOLEAN | 1 | sim | Padrão verdadeiro | 1 | Pedido ativo | | interna |
| `is_deletado` | BOOLEAN | 1 | sim | Padrão falso | 0 | Excluído | | interna |

### `tem_na_festa.metodo_pagamento`

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `id` | BIGINT | 19 | sim | Gerado pelo banco | 1 | Identificador | PK | interna |
| `nome` | VARCHAR(50) | 50 | sim | Texto | PIX | Forma de pagamento | | interna |

### `tem_na_festa.pagamento`

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `id` | BIGINT | 19 | sim | Gerado pelo banco | 88 | Identificador | PK | interna |
| `valor` | DECIMAL(10,2) | 10,2 | sim | Maior que zero | 122.50 | Valor pago | | interna |
| `data_pagamento` | DATETIME | 19 | sim | Horário de São Paulo | 2026-10-28 10:20:00 | Quando foi pago | | interna |
| `tipo_pagamento` | VARCHAR(30) | 30 | sim | SINAL, QUITACAO ou INTEGRAL (`TipoPagamentoEnum` do backend; o padrão do script, `BIGINTEGRAL`, é um erro de digitação) | SINAL | Tipo do pagamento | | interna |
| `status_pagamento` | VARCHAR(30) | 30 | sim | PENDENTE, CONFIRMADO ou CANCELADO (`StatusPagamentoEnum`; padrão CONFIRMADO) | CONFIRMADO | Situação do pagamento | | interna |
| `metodo_pagamento_id` | BIGINT | 19 | sim | Método existente | 1 | Forma de pagamento | FK → metodo_pagamento.id | interna |
| `pedido_id` | BIGINT | 19 | sim | Pedido existente | 120 | Pedido | FK → pedido.id | interna |
| `usuario_id` | BIGINT | 19 | sim | Usuário existente | 2 | Quem registrou | FK → usuario.id | interna |

### `tem_na_festa.historico_status_pedido`

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `id` | BIGINT | 19 | sim | Gerado pelo banco | 301 | Identificador | PK | interna |
| `data_alteracao` | DATETIME | 19 | sim | Horário de São Paulo | 2026-10-29 08:00:00 | Quando mudou | | interna |
| `observacao` | TEXT | 65535 | não | Texto livre | Sinal recebido | Observação | | interna |
| `status_producao` | VARCHAR(50) | 50 | sim | Os mesmos valores de `pedido.status_producao`; padrão RASCUNHO | EM_PRODUCAO | Novo status | | interna |
| `pedido_id` | BIGINT | 19 | sim | Pedido existente | 120 | Pedido | FK → pedido.id | interna |
| `usuario_id` | BIGINT | 19 | sim | Usuário existente | 2 | Quem alterou | FK → usuario.id | interna |

### `tem_na_festa.produto`

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `id` | BIGINT | 19 | sim | Gerado pelo banco | 12 | Identificador; é o `produto_id` da base dos produtos | PK | interna |
| `nome` | VARCHAR(100) | 100 | sim | Texto; termo pesquisado no Trends | Bolo de pote | Nome do produto | | interna |
| `descricao` | TEXT | 65535 | não | Texto livre | Bolo de chocolate com brigadeiro | Descrição | | interna |
| `preco_venda` | DECIMAL(10,2) | 10,2 | sim | Maior ou igual a zero | 12.50 | Preço | | interna |
| `is_ativo` | BOOLEAN | 1 | não | Padrão verdadeiro; só ativos vão para a coleta | 1 | Produto ativo | | interna |
| `is_deletado` | BOOLEAN | 1 | sim | Padrão falso | 0 | Excluído | | interna |

### `tem_na_festa.item_pedido`

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `id` | BIGINT | 19 | sim | Gerado pelo banco | 540 | Identificador | PK | interna |
| `pedido_id` | BIGINT | 19 | sim | Pedido existente | 120 | Pedido | FK → pedido.id | interna |
| `produto_id` | BIGINT | 19 | sim | Produto existente e ativo na criação | 12 | Produto | FK → produto.id | interna |
| `quantidade` | BIGINT | 19 | sim | Maior que zero | 20 | Quantidade | | interna |
| `preco_unitario` | DECIMAL(10,2) | 10,2 | sim | Maior ou igual a zero | 12.50 | Preço na hora do pedido | | interna |
| `acrescimo` | DECIMAL(10,2) | 10,2 | sim | Padrão 0.00; maior ou igual a zero | 5.00 | Acréscimo cobrado no item (script do banco v1.0.1) | | interna |
| `observacao_item` | TEXT | 65535 | não | Texto livre | Sem lactose | Observação do item | | interna |

### `tem_na_festa.lembrete`

| Campo | Tipo | Tamanho | Obrigatório | Domínio e regra de validação | Exemplo real | Descrição | Chave | Sensibilidade |
|---|---|---|---|---|---|---|---|---|
| `id` | BIGINT | 19 | sim | Gerado pelo banco | 9 | Identificador | PK | interna |
| `descricao` | TEXT | 65535 | sim | Texto livre | Comprar formas de cupcake | Lembrete | | interna |
| `data_criacao` | DATE | 10 | sim | `YYYY-MM-DD` | 2026-10-28 | Criação | | interna |
| `data_limite` | DATE | 10 | sim | Igual ou depois de `data_criacao` | 2026-11-05 | Prazo | | interna |
| `usuario_id` | BIGINT | 19 | sim | Usuário existente | 2 | Dono do lembrete | FK → usuario.id | interna |

**Colunas criadas pelo backend fora do script.** O backend roda com `ddl-auto=update` (05, A4) e acrescenta colunas que o script da tag não tem: `pedido.versao`, `pagamento.chave_idempotencia` e `pagamento.assinatura_requisicao` (`pedido.desconto_pedido` e `item_pedido.acrescimo` passaram para o script na tag `v1.0.1`). Elas não entram na conferência automática, que segue o script; quando o script do `TEM-NA-FESTA-database` as incorporar numa tag nova, entram aqui junto com a mudança do `db_schema_ref`.
