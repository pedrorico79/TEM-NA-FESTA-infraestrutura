# Política de backup (regra 3-2-1)

Resumo: **RPO de 1 hora** (um backup a cada hora cheia, pelo cron do `app-1`) e **RTO de 1 hora** para a perda do ambiente inteiro (15 minutos quando só o banco se perde). Há quatro cópias em duas mídias, duas delas fora da região do ambiente, e cada transferência é conferida por `sha256sum`.

## Escopo

| Item | Onde fica | Arquivo no backup | Observação |
|---|---|---|---|
| Banco do backend | RDS, schema `tem_na_festa` | `db/tem_na_festa.sql.gz` | `mysqldump --single-transaction --routines --triggers` |
| Banco do microsserviço | RDS, schema `temnafesta_notificacao` | `db/temnafesta_notificacao.sql.gz` | idem |
| Configuração da aplicação | bucket de artefatos e o nó | `app/config.tar.gz` | `stack.env`, compose files, `tnf-node.env` e as imagens em execução |
| Contagem de linhas | gerada no dump | `contagens.tsv` | valida a restauração tabela por tabela |
| Cópia criptografada | gerada no backup | `*.gpg` | um `.gpg` para cada arquivo acima |
| Checksums | gerado no backup | `SHA256SUMS` | sha256 de todos os arquivos do conjunto |
| Logs do dia anterior | bucket bronze (Fluent Bit): `docker` (inclui o log de acesso do Nginx e os logs do backend), `auth` (SSH e sudo) e `systemd` | `logs/<dia>/logs_<dia>.tar.gz` | um pacote por dia completo, com `.gpg` e `SHA256SUMS` próprios, até 14 dias para trás |

Fora do escopo, de propósito: os segredos (ficam no SSM e no `secrets.env` do autor; a senha do banco nunca vai para um arquivo de backup), a fila do RabbitMQ (mensagens de vida curta) e o código (no GitHub, com tags).

## Onde ficam as cópias

| Cópia | Local | Mídia | Conteúdo | Retenção |
|---|---|---|---|---|
| 1, produção | RDS MySQL, `us-east-1` | banco gerenciado | os dados vivos | o snapshot final no `infra down` (05, B2) |
| 2, local | `/bckp/<carimbo>/` no `app-1`, `us-east-1` | disco EBS (bloco) | conjunto inteiro, em claro e `.gpg` | 24 horas |
| 3, fora do local | `s3://tnf-backup-<conta>-us-west-2/<env>/` | armazenamento de objeto, outra região | só `.gpg` e `SHA256SUMS` | `horario/` 2 dias, `diario/` 35 dias, `logs/` 180 dias, versões antigas 7 dias |
| 4, offline | `~/tnf-backups/<env>/` no computador do autor | disco local, fora da AWS | só `.gpg` e `SHA256SUMS` | sem expiração |

As cópias 1 a 3 cumprem a 3-2-1 (três cópias, duas mídias, uma fora do local). A cópia 4 fica isolada quando o computador está desligado e aproxima a política da 3-2-1-1-0; o "0 erros" vem da restauração de teste (`tnf-backup-restore`), que compara as contagens.

O bucket de backup não pertence a nenhum ambiente: o `infra down` não o apaga, e a cópia 2 morre junto com o `app-1`. Ele é criado pelo AWS CLI no `scripts/backup-setup.sh`, porque a SCP do laboratório impede o `aws_s3_bucket` do Terraform (08, H20).

Os logs têm a cópia 1 no bucket bronze (`us-east-1`), a 2 em `/bckp` e a 3 e a 4 iguais às do banco. A retenção de 180 dias segue os 6 meses que o Marco Civil da Internet (art. 15) pede para os registros de acesso a aplicações.

## RPO e cronjob

O sistema registra pedidos de uma confeitaria, lançados à mão pela equipe a partir das conversas de WhatsApp. Perder até uma hora de lançamentos é recuperável, porque as conversas continuam no WhatsApp; perder um dia, não. Daí o RPO de 1 hora. Cada execução leva alguns segundos e gera menos de 1 MB, então o custo de rodar de hora em hora é desprezível.

```cron
# /etc/cron.d/tnf-backup (node/cron/tnf-backup)
0 * * * * root /usr/local/sbin/tnf-backup >> /var/log/tnf-backup.log 2>&1
```

O cron é instalado pelo `node-bootstrap.sh` em todos os nós app, e o script só age no `app-1`. O primeiro conjunto de cada dia também vai para `diario/`, o que dispensa um segundo horário de cron (o laboratório raramente fica no ar às 2 h da manhã).

## RTO

| Cenário | O que é feito | RTO |
|---|---|---|
| Banco corrompido ou apagado, ambiente no ar | `tnf-backup-restore --destino producao` | 15 minutos |
| Ambiente perdido | `infra up <env>` (13 min medidos no dev em 05/11) e a restauração | 1 hora |

O tempo de restauração medido em teste está no relatório que o `tnf-backup-restore` grava em `/bckp/restauracoes/`.

## Integridade e criptografia

O `sha256sum` é conferido em três pontos: no destino, logo depois do envio ao S3 (o script baixa de volta e roda `sha256sum --check`), na cópia 4 (`scripts/backup-pull.sh`) e antes de cada restauração (um conjunto que não confere não é restaurado). O envio também usa `--checksum-algorithm SHA256`, e o S3 recusa uma parte que chegue diferente.

A cópia criptografada usa GPG com um par de chaves Curve25519 do backup. A chave pública fica em `s3://<bucket>/chaves/`, e os nós só cifram. A chave privada, protegida por senha, fica no SSM (`/tnf/backup/gpg_private_key`, SecureString) e no computador do autor (`~/.tnf-backup/tnf-backup-privada.asc`). A senha fica só com o autor, então quem compromete um nó não lê os backups.

## Responsáveis

O cron executa sozinho e grava em `/var/log/tnf-backup.log`. O autor (César) roda o `backup-setup.sh` uma vez, a restauração de teste ao menos uma vez por sprint e aprova qualquer restauração em produção.

## Comandos

```bash
scripts/backup-setup.sh                         # uma vez por conta do laboratório (WSL)
sudo tnf-backup --force                          # backup avulso (no app-1)
sudo tnf-backup-restore                          # teste: último conjunto do S3 em schemas restore_*
sudo tnf-backup-restore --origem local           # teste a partir da cópia 2
sudo tnf-backup-restore --destino producao       # restauração real (pare o backend antes)
scripts/backup-pull.sh prod                      # cópia 4 (WSL)
```
