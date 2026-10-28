# 05 – Segredos e dados

Estado: **fechado** (aprovado em 09/10/2026; consolidado com 06 e 07); ajustado em 10/10/2026 (A5 e Q8: sem segredo manual com a mensageria desligada, auditoria item 3; A1, A4, A6, A7, B5 e Q15: cliente MySQL nos nós app e acesso manual ao banco, auditoria item 5; A1 e Q16: regras dos valores gerados, auditoria item 6; B3: bucket bronze já existente é importado, auditoria item 7; B4, Q17 e Q18: origens dos logs e lista de unidades do systemd, auditoria item 9; B1, B2, Q6 e Q19 a Q21: id do ciclo, snapshots manuais, restauração de um snapshot escolhido e proteção do RDS contra substituição, auditoria item 12; B5 e Q19: `db_schema_*` só exigidas quando o banco nasce vazio, auditoria item 16; A6, A7 e Q22: containers não alcançam as credenciais da instância, IMDSv2 obrigatório e limite de saltos 1, auditoria item 17; A1, A6 e B1: chave SSH recuperável do state por `infra access`, auditoria item 18; A1, A6, B1, B4 e Q23: sessão do WhatsApp só no volume local, sem SSM nem S3, auditoria item 19) e em 20/10/2026 (B5 e Q7: o primeiro admin do sistema sai do script público e passa a ser criado à mão pelo `tnf-db-shell`, na E4b); e em 11/10/2026 (A4, B5, Q11 e Q24: usuário da aplicação sem `DROP`, falha no meio do script do schema com limpeza e nova tentativa, auditoria item 22; B5 e Q24: marcador lido antes das tabelas, queda do líder simulada e limitação aceita, varredura final de 11/10/2026). Única pendência: a configuração do microsserviço de mensageria (**PENDENTE**, ainda não enviada), que define as chaves de `messaging_secrets`, a forma de entrega ao serviço (A3) e como ele se autentica no WhatsApp (A8).
Depende de: 01 (RF-06, RF-07, RNF-03), 02 (arquitetura), 03 (variáveis), 04 (subida automática).

## Parte A – Segredos

### A1. Inventário
| Segredo | Origem | Quem usa |
|---|---|---|
| Senha do administrador do RDS (parâmetro SSM `db_admin_password`) | **gerado** (aleatório, por ambiente) | só a rotina `db-init` e o comando `tnf-db-shell` (A7), nos nós app. **Não vira segredo Docker** |
| Senha da aplicação no banco | **gerado** | backend |
| `JWT_SECRET` | **gerado** (aleatório, longo) | backend |
| Senha do RabbitMQ | **gerado** | RabbitMQ e microsserviço (o backend **não** usa o RabbitMQ: só envia eventos ao microsserviço) |
| `messaging_api_key` | **gerado** (aleatório, por ambiente); opcional, só tem efeito se o microsserviço validar a chave (06, seção 6.5) | backend e microsserviço |
| Tokens de entrada no Swarm | gerados pelo Swarm em tempo de execução; guardados em `swarm/join.json` no bucket de artefatos (04) | nós, na subida |
| Chave SSH privada | **gerada** pelo Terraform; fica no state (saída sensível, como os demais valores gerados, A2) e numa cópia local em `.keys/<env>.pem`, que o `infra access` recria a partir do state quando falta (02, A15; 08, seção 5.6) | você, para acessar o bastion, de qualquer das suas máquinas |
| Token(s) do WhatsApp e demais segredos do microsserviço | **manual** (`messaging_secrets`); **só exigidos com a mensageria ligada** (03, seção 3.4) | microsserviço |
| Sessão do WhatsApp (se o microsserviço a usa) | **criada pelo próprio microsserviço** no pareamento manual (06, seção 6.4.1); **não é gerada nem guardada pela infra**: fica só nos arquivos do volume local `messaging_session` do `app-1` | microsserviço |

- **Nomes de usuário não são segredos aleatórios (*Decidido* em 10/10/2026):** o usuário da aplicação no banco é fixo (`tnf_app`) e o do RabbitMQ também (`tnf_rabbit`). Ficam no `stack.env`/parâmetros como valores comuns; só as senhas são geradas. Isso evita nomes com caracteres inesperados e facilita o suporte.
- **Credenciais do Docker Hub:** os repositórios de imagens são públicos (07), então **os nós e o Terraform não têm credenciais do Docker Hub**. O token de escrita para publicar imagens existe apenas como *secret* dos repositórios de aplicação no GitHub (07, seção 4.3).
- Regra (RF-07): só o que vem de fora é digitado por você; o resto é gerado. Os gerados mudam a cada ambiente novo, o que é desejado. A sessão do WhatsApp é a única credencial que nasce de um ato manual no celular (pareamento) e não de um valor digitado ou gerado.

#### Regras dos valores gerados (*Decidido* em 10/10/2026)
| Valor | Tamanho | Alfabeto |
|---|---|---|
| `db_admin_password`, senha da aplicação no banco, senha do RabbitMQ | 32 caracteres | letras maiúsculas, minúsculas e dígitos |
| `messaging_api_key` | 48 caracteres | idem |
| `jwt_secret` | 64 caracteres | idem |
- **Sem símbolos, espaços nem quebras de linha** (`random_password` com `special = false`). Assim os valores passam sem escape por URL e JDBC, arquivo de opções do MySQL, shell, compose, arquivo de segredo Docker e leitores de arquivo como o `_FILE` do RabbitMQ e o `configtree` do Spring. Com 32 caracteres desse alfabeto (62 símbolos) a entropia é de cerca de 190 bits, muito acima do necessário; os limites do MySQL/RDS (senha do administrador até 41 caracteres, sem `/`, `'`, `"`, `@` nem espaço) ficam respeitados.
- **Sem quebra de linha final** ao gravar no SSM, ao criar o segredo Docker e ao ler dele (`printf '%s'`, nunca `echo`), porque leitores de arquivo tratam o `\n` final de formas diferentes. A conferência é indireta, por Q10 (login do backend) e Q16.
- **Gerados uma vez por vida do ambiente:** os tamanhos e o alfabeto são constantes do módulo `secrets` (não são variáveis do usuário). Reaplicar não muda nenhum valor (04, S2); trocar segredos exige recriar o ambiente (A3).

### A2. Geração e transporte até o líder do Swarm (*Decidido*)
O teste no laboratório mostrou que o SSM Parameter Store e o Secrets Manager funcionam. Decisão:
1. O Terraform gera os valores (`random_password`, com as regras de A1) e grava **cada segredo como parâmetro `SecureString`** do SSM Parameter Store, em `/tnf/<env>/secrets/<nome>`. Os manuais (`messaging_secrets`) entram pelo mesmo caminho, vindos do `secrets.env` (A5).
2. O líder do Swarm lê o caminho `/tnf/<env>/secrets/` com a permissão do `LabInstanceProfile` e cria os **segredos Docker** (04, seção 7, passo 5), exceto o `db_admin_password`.
3. Por serem criados pelo Terraform, os parâmetros são **removidos no destroy**, sem sobras. O bucket de artefatos, onde ficam `join.json` e `status/`, é apagado pelo `infra down` (08, H23).
- Por que SSM e não um arquivo no S3: o valor fica criptografado por chave KMS e é lido segredo a segredo, em vez de ficar em um objeto único legível por quem tiver acesso ao bucket.
- **O que continua no S3** (decisão D3 de 04): os tokens de entrada no Swarm (`join.json`) e os arquivos de status, porque são criados em tempo de execução pelos nós e, se ficassem no SSM, poderiam sobrar após um destroy direto e enganar a subida seguinte. O bucket de artefatos é apagado junto com o ambiente.
- Os valores gerados também ficam no **state do Terraform** (limitação do Terraform), inclusive a chave SSH privada. O bucket do state é criptografado, com bloqueio de acesso público e versionamento (B3); quem lê o state precisa de credenciais da conta.

### A3. Entrega aos containers (*Decidido*)
- Os segredos chegam como **segredos Docker**: o Docker os monta como **arquivos** em `/run/secrets/<nome>` dentro do container (não como variáveis de ambiente, que apareceriam em `docker inspect`). O mapeamento completo de nomes (SSM → segredo Docker → arquivo) está em 06, seção 5.
- **Backend (confirmado):** o `application.properties` usa placeholders do Spring (`${DB_URL}`, `${DB_USER}`, `${DB_PASSWORD}`, `${JWT_SECRET}`) e o código não lê o ambiente diretamente; o carregamento do `.env` na classe principal é só conveniência de desenvolvimento e é ignorado quando o arquivo não existe. Para ler os segredos montados como arquivos, o compose define a variável `SPRING_CONFIG_IMPORT=optional:configtree:/run/secrets/`. O Spring transforma cada arquivo em uma propriedade com o nome do arquivo, e os segredos usam os mesmos nomes do `.env` atual (`DB_PASSWORD`, `JWT_SECRET`) e, quando a integração existir, `MESSAGING_API_KEY`. Nenhuma alteração de código.
- **Microsserviço (PENDENTE):** a forma depende da configuração dele, que ainda não foi enviada. Plano B, sem alterar a imagem: o compose sobrescreve o comando de início para exportar os valores dos arquivos antes de iniciar o processo.
- **Configuração que não é segredo** vai em variáveis de ambiente do compose, a partir de `stack.env` (06, seção 4): `DB_URL` (endpoint do RDS), `DB_USER` (usuário da aplicação), `PORT` e `MESSAGING_URL`.
- Nomes dos segredos Docker: `tnf_<nome>`. A rotação dentro de um ambiente vivo está **fora do escopo**: para trocar segredos, recria-se o ambiente.

### A4. Usuário próprio da aplicação no banco (*Decidido*)
O backend não usa o administrador do RDS (02, seção 6). Uma rotina de inicialização, executada pelo líder na convergência (04, seção 7, passo 6) com o **cliente MySQL instalado nos nós app** (02, A12), conecta-se ao RDS com o administrador e, de forma idempotente:
- cria o usuário da aplicação (`tnf_app`) se não existir e **sempre redefine a senha** com a do ciclo atual (necessário quando o banco é restaurado de snapshot, que traz o usuário com a senha antiga);
- **revoga todos os privilégios** que o usuário tenha no schema e concede de novo a lista abaixo, para o resultado não depender do que o snapshot trouxe;
- concede privilégios **somente sobre o schema da aplicação** (`tem_na_festa.*`), sem acesso a outros schemas e sem a opção de repassar permissões (`GRANT OPTION`);
- inclui **permissões de estrutura** além das de dados: `SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, REFERENCES`. Motivo: o backend usa `spring.jpa.hibernate.ddl-auto=update` e precisa alterar o banco (criar tabelas e colunas novas ao iniciar). Esse papel era do usuário SQL administrador do script, que deixa de existir (B5).
- **Sem `DROP` (*Decidido* em 11/10/2026, auditoria item 22).** O `ddl-auto=update` do Hibernate só cria e altera: nunca apaga tabelas nem colunas. Remover chaves e índices exige `ALTER`, e não `DROP`. O `DROP` (que o MySQL também exige para `TRUNCATE`) só aumentaria o estrago possível de um bug ou de uma injeção de SQL. Se o backend, ou uma versão futura dele, passar a precisar do `DROP` (por exemplo, por usar `TRUNCATE`), a lista muda por uma nova decisão; o sintoma seria um erro "DROP command denied" nos logs do backend. Verificado por Q11 (os privilégios) e Q12 (o `ddl-auto=update` funciona sem ele).

### A5. Segredos manuais
- **Só existem com a mensageria ligada** (`service_replicas.messaging > 0`, 03 seção 3.4). Hoje o único segredo manual é `messaging_secrets`; enquanto a mensageria estiver desligada (até a E8), **não há segredo manual**, o `secrets.env` não é exigido e `infra up` não o procura.
- Com a mensageria ligada, ficam em um arquivo local **`secrets.env`** na raiz do repositório de infra, **fora do Git** (`.gitignore`) e com permissão `600` (dentro do sistema de arquivos do WSL, 08 seção 5.1). O script `infra` o carrega e o entrega ao Terraform como variáveis de ambiente `TF_VAR_*` sensíveis (que viram os parâmetros SSM de A2).
- Chave hoje (E8): `whapi_token`, o token da API da Whapi.
- Um comando `infra init-secrets` cria o arquivo perguntando os valores e confere o formato; `infra up` aborta antes do `apply` se, **com a mensageria ligada**, faltar algum valor obrigatório.
- O token do Docker Hub para publicar imagens **não** entra aqui: fica como *secret* dos repositórios de aplicação no GitHub (07).
- O `secrets.env` é o único segredo que **não** se recupera de outra máquina: ele fica só onde você o criou (ou é recriado por `infra init-secrets`). Só é necessário com a mensageria ligada.
- O **pareamento do WhatsApp não é um segredo manual no sentido deste item**: não passa pelo `secrets.env` nem pelo SSM (A8).

### A6. Regras para não vazar segredos (RNF-03, critério 7 de 01)
- Nenhum segredo no `user_data`, no repositório, nas saídas do Terraform (`sensitive = true`) ou em logs de scripts (`set +x`, nunca imprimir valores).
- Os compose files guardam **nomes** de segredos, nunca valores.
- Chave SSH privada em `.keys/`, fora do Git, permissão `600`, nunca em `/mnt/c`. A cópia local pode ser apagada à vontade: o `infra access` a recria a partir do state (08, seção 5.6). A chave não é copiada para nenhum outro lugar (nem SSM, nem S3 de artefatos, nem log).
- Os scripts não gravam segredos em arquivos fora de `/run/secrets` e de arquivos temporários removidos ao fim.
- **Senha do banco nunca na linha de comando** (apareceria em `ps` e no histórico): o cliente MySQL recebe a senha por um arquivo de opções temporário em `/run` (sistema de arquivos em memória), permissão `600`, criado imediatamente antes da conexão e removido ao fim, inclusive em caso de erro. Vale para o `db-init` e para o `tnf-db-shell` (A7).
- **Containers não alcançam as credenciais da instância (*Decidido* em 10/10/2026; 02, seção 4, A14).** As credenciais da LabRole, que leem todo o SSM, só são entregues a processos do host: as EC2 exigem IMDSv2 e têm limite de saltos 1, então um container não obtém o token do serviço de metadados. Os containers só recebem os segredos de que precisam, como arquivos em `/run/secrets` (A3). Por isso, nenhum serviço pode depender de credenciais da AWS dentro do container, e nenhuma stack usa `network_mode: host` nem modo privilegiado (limitações em 02, A14). Verificado por Q22.
- **Sessão do WhatsApp (*Decidido* em 10/10/2026; 06, seção 6.4.1).** Os arquivos da sessão equivalem a uma credencial da conta de WhatsApp: ficam **só no volume local** `messaging_session` do `app-1`, com a permissão que o próprio microsserviço aplica; nunca em SSM, S3 de artefatos, state, imagem ou logs, e **sem backup**. O QR code ou código de pareamento aparece nos logs do container e, por isso, no bronze (origem `docker`); é de vida curta e inútil depois do pareamento, e fica registrado como risco conhecido. Verificado por Q23.

### A7. Acesso manual ao banco (*Decidido* em 10/10/2026; 02, A12)
Para depurar ou corrigir dados, o caminho suportado é:
1. `infra ssh <env> app-1` (ou outro nó app) pelo bastion (08, seção 5).
2. No nó, `tnf-db-shell`: instalado em todos os nós app (04, seção 5), lê a senha do administrador do SSM (`db_admin_password`, com a permissão do `LabInstanceProfile`), monta o arquivo de opções temporário de A6 e abre o cliente MySQL no endpoint do RDS. A senha não é digitada nem aparece na tela.
- O bastion e os nós web não têm cliente nem acesso à porta 3306 do RDS (02, seção 5). Não há túnel SSH até o banco.
- O administrador do RDS tem poder total; o acesso fica restrito a quem tem a chave SSH do bastion e acesso ao nó app. **Um container do Swarm não consegue assumir a permissão da instância** (IMDSv2 obrigatório e limite de saltos 1, A6; 02, A14) e, portanto, não lê o parâmetro `db_admin_password`. Quem tem SSH no nó lê, por definição, e esse é o acesso previsto.

### A8. Autenticação do microsserviço no WhatsApp (*Decidido* em 10/10/2026, auditoria item 19; forma definida na E8)
**Na E8 (28/10/2026):** o microsserviço usa a API da Whapi com um token, o segredo manual `whapi_token` de `messaging_secrets` (A5), criado por `infra init-secrets` e entregue como o segredo Docker `tnf_whapi_token`. Não há sessão em disco nem pareamento.
A infra trata três formas possíveis, conforme a configuração do microsserviço (06, seção 6.4.1):
| Forma | Credencial | Tratamento |
|---|---|---|
| Biblioteca com sessão em disco | arquivos de sessão, criados no pareamento | volume local `messaging_session` no `app-1`; pareamento manual a cada ambiente novo; A6 |
| API oficial da Meta | token(s) | `messaging_secrets` (A5), entregues como segredos Docker (A3) |
| Sessão guardada pelo próprio microsserviço fora do disco | a definir | tratada como a anterior ou a seguinte, conforme a configuração |
- A sessão **não** é guardada no S3 para restaurar ambientes novos sem QR (alternativa descartada: 06, seção 6.4.1).
- Dev e prod devem usar números diferentes (recomendação de 06, seção 6.4.1); a escolha é do autor.

## Parte B – Dados

### B1. O que sobrevive a cada ciclo de destroy
| Dado | Onde fica | Sobrevive ao `infra down`? |
|---|---|---|
| State do Terraform | bucket de state (`bootstrap`) | **Sim** |
| Logs | bucket bronze (`bootstrap`) | **Sim** |
| Banco de dados | snapshots do RDS (finais e manuais) | **Sim** (últimos 3 finais e últimos 3 manuais) |
| Imagens | Docker Hub | **Sim** (fora da AWS) |
| Mensagens do RabbitMQ | volume local do nó | Não |
| Sessão do WhatsApp (se houver) | volume local `messaging_session` do `app-1` | Não: o pareamento é refeito a cada ambiente novo (06, seção 6.4.1) |
| Artefatos, tokens do Swarm | bucket de artefatos | Não |
| Segredos gerados | parâmetros SSM do ambiente | Não (removidos no destroy) |
| Chave SSH | cópia local em `.keys/` (em cada máquina que a recriou) e o original no state | A chave do ambiente vale só enquanto ele existir; cada ambiente novo gera uma nova, e as cópias locais antigas ficam inúteis (podem ser apagadas) |

### B2. Ciclo do banco (RF-06)

#### Id do ciclo e nomes dos snapshots (*Decidido* em 10/10/2026, auditoria item 12)
- **Id do ciclo:** um valor aleatório de 8 caracteres hexadecimais (`random_id` do Terraform, 4 bytes) criado no módulo `database` junto com o RDS. Fica no state, não muda entre `apply`s e **desaparece com o ambiente**; cada ambiente novo recebe um id novo. É por isso que o nome do snapshot final não colide entre ciclos. Um *timestamp* não serve: mudaria a cada `plan`.
- **Dois tipos de snapshot do ambiente**, distinguidos pelo nome (o prefixo inclui o ambiente, então dev e prod nunca se misturam):
  | Tipo | Nome | Quem cria | Exemplo |
  |---|---|---|---|
  | final | `<prefixo>-final-<id do ciclo>` | o RDS, ao ser removido (destroy) | `tem-na-festa-dev-final-a1b2c3d4` |
  | manual | `<prefixo>-manual-<AAAAMMDD-HHMMSS em UTC>` | `infra snapshot <env>` | `tem-na-festa-dev-manual-20261010-153012` |
- Os dois são snapshots "manuais" para a AWS (não automáticos); a diferença é só o nome, e é por ele que o `infra` os separa.

#### Descer (`infra down`) (04, seção 9)
- O RDS tem **snapshot final obrigatório** ao ser removido, com o nome acima. Se o snapshot falhar, o RDS não é removido e o destroy aborta.
- Depois do sucesso, o script faz a poda: mantém os **3 finais mais recentes** e os **3 manuais mais recentes** (ordenados pela data de criação), cada tipo contado à parte, no mesmo ambiente e região, e apaga os demais. Só toca snapshots com esses dois prefixos do próprio ambiente; nunca os de outro ambiente nem outros nomes.
- Backups automáticos do RDS: retenção de 1 dia (permite recuperar a sessão em andamento) e removidos junto com a instância.

#### Subir (`infra up`) (04, seção 3, passo 7)
- **Ambiente novo** (o RDS ainda não existe no state): o script procura o snapshot **final** mais recente do ambiente (nome com o prefixo `-final-`, estado disponível) e passa o ID como `db_snapshot_identifier`. **Snapshots manuais nunca são escolhidos sozinhos.** Para restaurar um específico, final ou manual: `infra up <env> --snapshot <id>`; o `infra` confere se o snapshot é do ambiente (prefixo `<prefixo>-final-` ou `<prefixo>-manual-`) e está disponível, senão recusa. `infra snapshots <env>` lista os snapshots do ambiente (nome, tipo, data, tamanho) para escolher.
- **Ambiente já no ar** (o RDS existe no state): o script **não** procura snapshot nem aceita `--snapshot` (recusa com mensagem). O banco em uso nunca é trocado por um `infra up`.
- **Proteção no Terraform:** o recurso do RDS usa `lifecycle { ignore_changes = [snapshot_identifier] }`. Sem isso, um snapshot mais novo (por exemplo, um manual tirado durante a sessão) mudaria o valor calculado e o Terraform **recriaria o RDS, destruindo o banco em uso**. Com a proteção, o valor só vale na criação, mesmo se alguém rodar `terraform apply` direto.
- Se não houver snapshot, o banco nasce vazio e a rotina de B5 cria a estrutura; é só nesse caso que as variáveis `db_schema_*` são exigidas (03, seção 3.8).
- Ao restaurar, a **senha do administrador é redefinida** com a do ciclo; a rotina de A4 redefine a do usuário da aplicação. O `db_name` não é usado na restauração (o schema vem no snapshot).
- Snapshots pertencem a uma região: mudar a `region` de um ambiente faz o script não encontrá-los e avisar.
- Criptografia do armazenamento: proposta `storage_encrypted = true` com a chave padrão da AWS (a opção existe no console do laboratório). Será confirmada na primeira criação real do RDS (09, E4b); se o laboratório bloquear, passa a `false`.
- Multi-AZ: **desligado por padrão** (decisão do projeto, para não correr risco de custo); o usuário pode ligar `db_multi_az` para testar.

#### Snapshot manual (`infra snapshot <env>`)
Tira um snapshot do RDS sem destruir nada (ponto de restauração antes de uma mudança arriscada). Exige o ambiente no ar, espera o snapshot ficar disponível e imprime o nome. Ele fica fora da restauração automática; para voltar a ele, usa-se `infra down` e `infra up <env> --snapshot <id>`. A poda dos manuais acontece no `infra down` (acima), não na criação.

### B3. Buckets persistentes (camada `bootstrap`)
| Bucket | Nome | Configuração |
|---|---|---|
| State | `tnf-tfstate-<id-da-conta>-<região>` | versionamento **ligado**, criptografia, bloqueio de acesso público, só TLS |
| Bronze | `bucket-bronze-<id-da-conta>-us-east-1` | criptografia, bloqueio de acesso público, só TLS; sem expiração de objetos por ora |

- **Os buckets são criados pelo `infra bootstrap` com o AWS CLI, fora do Terraform** (*Decidido* em 12/10/2026, na E2). O laboratório (SCP do AWS Academy) nega `s3:GetBucketObjectLockConfiguration`, que o recurso `aws_s3_bucket` do provedor AWS sempre lê e não tolera negado; por isso o Terraform do `bootstrap` gerencia **só a configuração** da tabela acima (versionamento, criptografia, bloqueio de acesso público e política de TLS), com `prevent_destroy`, e nunca o bucket em si.
- Nenhum dos dois é apagado por um `destroy` de ambiente, nem por um `destroy` do `bootstrap`: o Terraform não gerencia os buckets.
- Silver e gold ficam para a fase do datalake.
- **O bucket bronze pode já existir na conta** (por exemplo `bucket-bronze-827290239455-us-east-1`, criado antes deste Terraform numa conta anterior) (*Decidido* em 10/10/2026; ajustado em 12/10/2026). O `infra bootstrap` o **adota**: não o cria de novo e aplica a configuração da tabela acima. Regras:
  - Os objetos antigos **não são apagados nem movidos**. Os logs novos usam o layout de B4, sob `logs/env=<env>/`, e convivem com o conteúdo antigo.
  - O `plan` do `bootstrap` mostra o que o Terraform alteraria no bucket existente (criptografia, bloqueio de acesso público, política de TLS). Qualquer diferença inesperada, por exemplo política de bucket, regra de ciclo de vida ou notificação que o Terraform removeria, é mostrada e **exige a sua confirmação** antes do `apply`.
  - Se o bucket não existir (outra conta, outra região), o `infra bootstrap` o cria com o AWS CLI, com as etiquetas `Project`, `Env = shared` e `ManagedBy`. O mesmo vale para o bucket do state.
  - Verificado por G16 (08).

### B4. Layout dos logs no bronze (preparado para o Glue/Athena futuros)
`logs/env=<env>/source=<docker|auth|systemd>/year=AAAA/month=MM/day=DD/<hostname>_<hhmmss>_<uuid>.json`
- Formato JSON, uma entrada por linha, como no seu desenho atual.
- Os campos `env`, `source` e a data viram partições, o que facilita o crawler do Glue e as consultas do Athena depois. A data das partições é em **UTC**.
- Cada origem tem a sua tag e a sua saída (02, seção 7.1), o que corrige o problema encontrado no desenho original (o `match` não casava com nenhuma tag).
- **O que cada origem contém** (configuração completa em 02, seção 7.1):
  - `source=docker`: stdout e stderr dos containers dos nós web e app; o campo `attrs` traz o nome do serviço e da stack. Se o microsserviço de WhatsApp imprimir o QR code ou o código de pareamento, eles chegam aqui (A6).
  - `source=auth`: `auth.log` de **todas** as instâncias, inclusive o bastion (acessos SSH).
  - `source=systemd`: apenas as unidades `docker`, `ssh`, `fluent-bit`, `cloud-init`, `cloud-config`, `cloud-final` e `tnf-converge`. Isso inclui a saída do `node-bootstrap.sh` e da convergência.
- Todo registro tem os campos `env`, `host` e `role` (`web`, `app` ou `bastion`).
- Como nunca se imprimem segredos nos scripts (A6), o bronze não os recebe (Q1); os logs da própria aplicação são responsabilidade dela.

### B5. Estrutura inicial do banco (tabelas e dados iniciais) (*Decidido*)
**Script SQL:** fica em um **repositório separado e público** do GitHub (`TEM-NA-FESTA-database`). Depois da mudança decidida pelo autor, ele **cria só as tabelas**. O primeiro usuário administrador do sistema **não** vai no script, para que nem o hash da senha fique público: ele é criado à mão, uma vez por banco novo, pelo `tnf-db-shell` (A7), com o procedimento do README (*Decidido* em 20/10/2026, na E4b). Depois disso, ele vem nos snapshots. A criação do usuário SQL administrador foi **removida do script**: ela servia ao desenvolvimento e a permitir que o backend alterasse o banco, e esse papel passa a ser do usuário da aplicação com permissões de estrutura (A4). Para operação manual, o administrador do RDS continua disponível a quem acessar um nó app pelo bastion (A7).

A rotina de inicialização do banco (a mesma de A4, executada pelo líder, 04 seção 7 passo 6) faz, nesta ordem e de forma idempotente:
1. Conecta com o administrador do RDS (cliente MySQL do nó líder; se o RDS ainda não aceitar conexão, repete por alguns minutos antes de falhar, 04, seção 10).
2. **Se o schema da aplicação não tem tabelas** (banco vazio, sem snapshot), baixa o script e o aplica, como descrito em "Falha no meio do script" abaixo.
3. **Só com o schema completo**, cria ou atualiza o usuário da aplicação e seus privilégios (A4).

Com banco restaurado de snapshot **que tem tabelas**, o passo 2 não faz nada (as tabelas e, se já foi criado, o admin do sistema vêm no snapshot).

**Como o script é obtido:**
- Como o repositório é público, a rotina baixa o arquivo pela URL "raw" do GitHub **sem token**, a partir dos nós privados via NAT, com 3 tentativas e espera crescente.
- A versão é **fixa por variável** (tag ou commit), nunca "a branch mais recente", para que o mesmo ambiente suba sempre com o mesmo schema. Variáveis em 03: `db_schema_repo_url`, `db_schema_ref` e `db_schema_path` (sem valor padrão; ficam em branco nos `terraform.tfvars` até existirem e são **exigidas só quando o banco nasce vazio**, isto é, sem snapshot; com snapshot podem ficar em branco, 03 seção 3.8; `db_schema_ref` recusa nomes de branch, T15). O `db_schema_ref` deve apontar para uma versão **posterior à remoção** do usuário SQL do script. O líder as recebe pelo `stack.env` (`DB_SCHEMA_REPO_URL`, `DB_SCHEMA_REF` e `DB_SCHEMA_PATH`; 06, seção 4).
- O script só é executado se não houver tabelas; mesmo assim, ele deve ser seguro para um banco vazio.

#### Falha no meio do script (*Decidido* em 11/10/2026, auditoria item 22)
O MySQL não desfaz tabelas criadas quando um script falha na metade. Sem cuidado, a tentativa seguinte veria tabelas, pularia o script e daria o ambiente por pronto com o banco incompleto (e o `infra down` tiraria o snapshot final desse banco, que a subida seguinte restauraria). Por isso:
- **Antes** de aplicar o script, o `db-init` confirma que o schema está vazio e grava `schema: started` em `status/db-init.json` (04, seção 7, passo 6); ao terminar sem erro, grava `schema: applied`.
- **Em toda execução, o marcador é lido antes de olhar as tabelas:** `schema: started` significa que a tentativa anterior foi interrompida, e o schema é limpo e o script reaplicado, mesmo que haja tabelas.
- **Se o script falhar**, ou o líder cair no meio, o `db-init` **remove todos os objetos criados no schema** (tabelas, visões, rotinas, gatilhos e eventos), deixando-o vazio como estava. É seguro justamente porque o schema estava vazio quando a tentativa começou; num schema com dados, essa limpeza nunca acontece.
- A falha vira `degraded`, com as últimas linhas do erro, e o `infra up` termina com código `3` (04, seção 8). **Não há repetição automática a cada minuto**: uma nova tentativa só ocorre quando o hash do manifesto mudar, isto é, depois de uma mudança aplicada.
- **Correção, sem recriar o ambiente:** publicar a versão corrigida do script no repositório do schema, apontar `db_schema_ref` para a tag nova em `envs/<env>/terraform.tfvars` e rodar `infra up`. Vale também para um `db_schema_ref` inexistente (Q13).
- Se o ambiente for destruído nessa situação (`failed`), o snapshot final é de um banco **vazio**. Na subida seguinte, se `db_schema_*` estiverem em branco, o `db-init` termina em `degraded` pedindo para preenchê-las e rodar `infra up` (04, seção 10).
- **Limitação aceita (*Decidido* na varredura final de 11/10/2026, opção B):** o marcador mora no bucket de artefatos e some com o ambiente. Se o líder cair no meio do script e o ambiente for destruído antes da convergência seguinte, o snapshot final guarda o schema pela metade e a subida seguinte o aceita como completo. É uma janela de segundos, uma vez por banco novo; o sintoma (por exemplo, o primeiro admin do sistema ausente) e a correção manual estão em 04, seção 7, passo 6.

**Usuário administrador do sistema (primeiro login) (*Decidido* em 20/10/2026, na E4b):** não vem do script, que é público. Num banco novo (sem snapshot), depois de o `db-init` aplicar o script, você cria o admin pelo `tnf-db-shell`, com a senha em hash BCrypt gerado na sua máquina (procedimento no README). É um passo manual, uma vez por banco novo; os snapshots o preservam nos ciclos seguintes. Como em 04, seção 7, passo 6, o sintoma de ter esquecido o passo é o login do admin falhar.

**Mudanças futuras no schema:** com `ddl-auto=update`, tabelas e colunas novas são criadas pelo próprio backend ao iniciar, então a maior parte das mudanças chega sozinha, inclusive em banco restaurado de snapshot. Alterações que o Hibernate não faz (renomear, remover, mudar tipo ou dados) continuam manuais, feitas com o `tnf-db-shell` (A7), que usa o administrador do RDS (o usuário da aplicação não tem `DROP`, A4). Ferramenta de migração está fora do escopo.

- **Banco do microsserviço (*Decidido* pelo autor em 28/10/2026, na E8):** um segundo schema, `messaging_db_name` (padrão `temnafesta_notificacao`), no mesmo RDS. O `db-init` roda um segundo perfil, com marcador próprio (`status/db-init-messaging.json`), as mesmas regras de B5 e o script do repositório do microsserviço (`messaging_db_schema_*`, fixado por tag). O usuário `tnf_notificacao` tem só `SELECT, INSERT, UPDATE, DELETE` nesse schema (o microsserviço usa `ddl-auto=none`) e a senha gerada `messaging_db_password`. O snapshot do RDS guarda os dois schemas.

## Critérios de aceite
| # | Cenário | Esperado |
|---|---|---|
| Q1 | Subir um ambiente e procurar os valores gerados no `user_data` das instâncias, nos objetos do S3 (incluindo o `join.json`, que só deve ter tokens do Swarm), na saída do Terraform e nos logs no bronze | nenhum valor de segredo encontrado fora dos parâmetros SSM |
| Q2 | `docker inspect` dos serviços | nenhum segredo em variáveis de ambiente |
| Q3 | Gravar uma linha de teste, `infra down`, `infra up` | linha de teste presente |
| Q4 | Após o restore, conectar com a senha nova do administrador | funciona; a senha antiga é rejeitada |
| Q5 | Rodar `terraform destroy` direto, sem o script | snapshot final criado mesmo assim, com o nome `<prefixo>-final-<id do ciclo>`; parâmetros SSM removidos |
| Q6 | Fazer 4 ciclos `down` | restam 3 snapshots finais do ambiente; os de outro ambiente e os manuais ficam intactos |
| Q7 | Primeira subida sem snapshot | banco criado com as tabelas pelo script SQL na versão fixada e aplicação iniciada; o primeiro admin do sistema, criado pelo procedimento do README com o `tnf-db-shell`, aparece em `usuario` e sobrevive ao ciclo `infra down` e `infra up` |
| Q8 | Com a mensageria **ligada**, `infra up` sem `secrets.env` ou com campo obrigatório vazio. Com a mensageria **desligada**, `infra up` sem `secrets.env` | com ela ligada: aborta antes do `apply` com mensagem clara; com ela desligada: segue normalmente, sem exigir o arquivo |
| Q9 | Inspecionar os buckets de state e bronze | acesso público bloqueado, criptografia ligada; state com versionamento |
| Q10 | Após `infra up`, o backend inicia lendo `DB_PASSWORD` e `JWT_SECRET` de `/run/secrets` | login na aplicação funciona |
| Q11 | Após a primeira subida, listar os usuários do banco (`mysql.user`) e rodar `SHOW GRANTS FOR 'tnf_app'` | só o administrador do RDS, o usuário da aplicação e os usuários internos do RDS; nenhum usuário vindo do script. Os privilégios do `tnf_app` são exatamente `SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, REFERENCES` em `tem_na_festa.*`: sem `DROP`, sem `GRANT OPTION` e sem nada fora desse schema. Em banco restaurado de snapshot, o resultado é o mesmo |
| Q12 | Subir uma versão do backend com uma coluna nova em uma entidade, em banco restaurado de snapshot | a coluna é criada no startup, com o usuário da aplicação **sem `DROP`**; backend saudável |
| Q13 | Subir com `db_schema_ref` inexistente | a convergência falha com mensagem clara apontando o download do script (e o schema fica vazio); corrigindo o `db_schema_ref` e rodando `infra up`, o ambiente se corrige sem ser recriado |
| Q14 | Procurar credenciais do Docker Hub nos nós, no Terraform e nos parâmetros SSM | nenhuma |
| Q15 | Com o ambiente no ar: `infra ssh <env> app-1` e `tnf-db-shell`; depois, tentar o mesmo cliente a partir do bastion e de um nó web, e olhar `ps` durante a sessão | no nó app a sessão abre sem pedir a senha e a senha não aparece em `ps`; no bastion e nos nós web não existe o cliente e a porta 3306 do RDS não é alcançável |
| Q16 | Com o ambiente no ar, ler os parâmetros `/tnf/<env>/secrets/` com o AWS CLI (com descriptografia) e conferir cada valor gerado; conferir também o conteúdo dos arquivos em `/run/secrets` de um container | tamanhos 32/48/64 conforme A1, só letras e dígitos, nenhum espaço nem quebra de linha (nem final); repetir `infra up` não altera nenhum valor |
| Q17 | Com o ambiente no ar há alguns minutos (sem containers de aplicação ainda, ou com eles): fazer um `infra ssh` ao bastion e listar `logs/env=<env>/` no bronze | existem `source=auth` (com o login SSH no bastion e `/var/log/auth.log` presente em todas as instâncias) e `source=systemd`; o `systemd` só tem as unidades da lista de 02, seção 7.1 (nenhuma outra, como `systemd-resolved`), incluindo mensagens do `cloud-final` do boot; as chaves seguem o layout de B4 e as partições são em UTC; cada registro tem `env`, `host` e `role` |
| Q18 | Com os containers de aplicação no ar: gerar tráfego no ALB e reiniciar o serviço `fluent-bit` em um nó | `source=docker` aparece com o nome do serviço em `attrs` (`backend-som`, `frontend`, RabbitMQ), só dos nós web e app; o reinício do Fluent Bit não duplica linhas já enviadas |
| Q19 | Com o ambiente no ar: gravar uma linha de teste e rodar `infra snapshot dev`; depois `infra down dev` e `infra up dev` sem opções; depois, repetir o ciclo com `infra down dev` e `infra up dev --snapshot <nome do manual>`, **desta vez com `db_schema_repo_url`, `db_schema_ref` e `db_schema_path` em branco no `terraform.tfvars`**; por fim, `infra snapshots dev` | o nome do manual é `<prefixo>-manual-<AAAAMMDD-HHMMSS>` e o do final é `<prefixo>-final-<8 hex>`; o `up` sem opções restaura o **final** (o manual não é usado); com `--snapshot` restaura o manual **mesmo com as variáveis do schema em branco** (não são exigidas quando há snapshot), e a linha de teste gravada antes dele está lá; a listagem mostra os dois tipos; `--snapshot` com nome de outro ambiente ou inexistente é recusado |
| Q20 | Criar 4 snapshots manuais e fazer 4 ciclos `down` no mesmo ambiente | depois do último `down` restam 3 finais e 3 manuais, os mais recentes de cada tipo; snapshots de outro ambiente e de outros nomes ficam intactos |
| Q21 | Com o ambiente no ar, criar um snapshot manual (mais novo que qualquer final) e rodar `infra up` de novo; repetir com `infra up --snapshot <id>` e com `terraform apply` direto passando `db_snapshot_identifier` diferente | o `plan` não mostra mudança no RDS e o banco continua o mesmo (a linha gravada depois do snapshot continua lá); `--snapshot` com o ambiente no ar é recusado com mensagem; o `apply` direto também não recria o RDS |
| Q22 | Com o ambiente no ar, **(a)** consultar as opções de metadados de todas as instâncias do ambiente (`aws ec2 describe-instances`, web, app e bastion); **(b)** em um nó (por `infra ssh`), pedir os metadados com `curl` sem token e depois com token (`PUT` e `GET`); **(c)** de dentro de um container de aplicação em um nó web e em um nó app (`docker exec`, com o `wget` ou `curl` de C17), tentar obter o token e, sem token, os metadados; **(d)** conferir que o que roda no host segue funcionando | **(a)** `HttpTokens = required`, `HttpPutResponseHopLimit = 1` e `HttpEndpoint = enabled` em todas; **(b)** sem token a resposta é `401`; com token, o host recebe os metadados e o nome do perfil `LabInstanceProfile`; **(c)** o pedido do token não obtém resposta (tempo esgotado) e sem token dá `401` (ou também não responde): nenhuma credencial é obtida; **(d)** o `aws sts get-caller-identity` no host funciona, os objetos novos aparecem no bronze (Q17) e o `tnf-db-shell` abre a sessão (Q15). As partes (a), (b) e (d) fecham na E4a e na E4b; a (c) na E6, quando há containers |
| Q23 | **Só se o microsserviço guarda a sessão do WhatsApp** (E8): com o WhatsApp pareado, procurar o conteúdo dos arquivos da sessão (lido do volume `messaging_session`) nos parâmetros SSM, nos objetos do bucket de artefatos, na saída do Terraform e no state, e nos logs do bronze | nenhum conteúdo da sessão fora do volume local; no bronze pode aparecer apenas o QR code ou código de pareamento, que já é inútil depois do pareamento (A6). Com a API oficial (token), vale a parte de Q1 para os tokens |
| Q24 | Subir um ambiente **sem snapshot** com `db_schema_ref` apontando para uma tag descartável cujo script cria uma tabela e depois falha (por exemplo, com um erro de sintaxe na segunda instrução). Esperar 5 min. **Simular a queda do líder no meio de uma tentativa** (o script real roda em segundos, então não se cronometra um `kill -9`): pelo `tnf-db-shell`, criar uma tabela qualquer no schema (`tnf_queda`) e trocar, em `status/db-init.json`, `schema: failed` por `schema: started`. Depois, apontar `db_schema_ref` para uma tag correta e rodar `infra up` | **(a)** o `db-init` termina em `degraded` com as últimas linhas do erro, o `infra up` termina com código `3` e `SHOW TABLES` no schema volta **vazio**; **(b)** `status/db-init.json` mostra `schema: failed` e uma única tentativa nos 5 min (sem laço); **(c)** depois do `infra up` com a tag correta, em até 3 min o `db-init` lê `schema: started` **antes** de olhar as tabelas, remove a `tnf_queda`, aplica o script do começo (`schema: applied`), cria o usuário da aplicação, `converge.json` = `ready` e o primeiro admin do sistema existe, **sem recriar o ambiente**; **(d)** se o ambiente for destruído enquanto está em `degraded`, o snapshot final é de um banco sem tabelas e a subida seguinte, com `db_schema_*` em branco, termina em `degraded` com a mensagem de 04, seção 10 |

## Pendências
- **Configuração do microsserviço de mensageria (PENDENTE, ainda não enviada):** define as chaves de `messaging_secrets`, a entrega de segredos a ele e as variáveis do compose; se ele valida a `messaging_api_key`; **como se autentica no WhatsApp** (A8) e em que caminho grava a sessão. Só bloqueia a E8.
- Atualizar o script no repositório do schema (remover o usuário SQL) e criar a tag para `db_schema_ref` antes da primeira subida real que nasça com banco vazio; é uma tarefa do repositório do schema, não da infra. Para o Q24 é preciso uma segunda tag, descartável, com um script que falha de propósito.
- Confirmar com o Q10 (E6) e o Q12 (E7), que são as etapas em que o backend já está rodando, que ele não usa `TRUNCATE` nem outro comando que exija `DROP` (A4): os logs do backend não devem mostrar "DROP command denied". Na E4b ainda não há backend; lá só se confere a lista de privilégios (Q11).
