# Política de backup (regra 3-2-1)

Resumo: um backup por dia, **às 03:00 de Brasília (RPO de 24 horas)**, feito pelo cron do `app-1`, com **RTO de 1 hora** para a perda do ambiente inteiro (15 minutos quando só o banco se perde). Banco, configuração e logs vão juntos num único conjunto diário, criptografado e conferido por `sha256sum`.

## As três cópias

| Cópia | Onde | Mídia | Conteúdo | Retenção |
|---|---|---|---|---|
| 1, produção | RDS MySQL e bucket bronze dos logs, `us-east-1` | banco gerenciado e objeto | os dados vivos e os logs que o Fluent Bit envia | snapshot final no `infra down` (05, B2) |
| 2, S3 | `s3://tnf-backup-<conta>-us-west-2/<env>/diario/<carimbo>/` | armazenamento de objeto, outra região | só `.gpg` e `SHA256SUMS` | 180 dias; versões antigas 7 dias |
| 3, local offline | `~/tnf-backups/<env>/diario/` no computador do autor | disco local, fora da AWS | só `.gpg` e `SHA256SUMS` | sem expiração |

Três cópias, duas mídias (a AWS e o disco do computador) e uma fora do local (duas, na verdade: outra região e fora da AWS). A cópia 3 fica isolada quando o computador está desligado e aproxima a política da 3-2-1-1-0; o "0 erros" vem da restauração de teste.

O `/bckp` do `app-1` não é uma cópia: é a área de trânsito onde o conjunto é montado antes do envio, apagada assim que o S3 confere.

O bucket de backup não pertence a nenhum ambiente: o `infra down` não o apaga. Ele é criado pelo AWS CLI no `scripts/backup-setup.sh`, porque a SCP do laboratório impede o `aws_s3_bucket` do Terraform (08, H20).

## O que vai no conjunto diário

| Arquivo | Origem | Conteúdo |
|---|---|---|
| `db/tem_na_festa.sql.gz` | RDS | dump do schema do backend (`mysqldump --single-transaction --routines --triggers`) |
| `db/temnafesta_notificacao.sql.gz` | RDS | dump do schema do microsserviço |
| `app/config.tar.gz` | bucket de artefatos e o nó | `stack.env`, compose files, `tnf-node.env` e as imagens em execução |
| `logs/logs.tar.gz` | bucket bronze | logs `docker` (inclui o acesso do Nginx e os logs do backend), `auth` (SSH e sudo) e `systemd` dos dias completos desde o backup anterior, até 14 dias |
| `contagens.tsv` | RDS | linhas por tabela no momento do dump, para validar a restauração |
| `*.gpg` | o próprio backup | cópia criptografada de cada arquivo acima |
| `SHA256SUMS` | o próprio backup | sha256 de todos os arquivos |

Fora do escopo, de propósito: os segredos (ficam no SSM e no `secrets.env` do autor), a fila do RabbitMQ (mensagens de vida curta) e o código (no GitHub, com tags).

## RPO e cronjob

O backup roda às 03:00 de Brasília, quando a confeitaria está fechada. No pior caso se perdem os lançamentos desde a madrugada anterior, que a equipe consegue refazer pelas conversas de WhatsApp, por onde os pedidos chegam.

```cron
# /etc/cron.d/tnf-backup (node/cron/tnf-backup). Os nós rodam em UTC: 06:00 UTC = 03:00 em Brasília.
0 6 * * * root /usr/local/sbin/tnf-backup >> /var/log/tnf-backup.log 2>&1
30 * * * * root /usr/local/sbin/tnf-backup --se-atrasado >> /var/log/tnf-backup.log 2>&1
```

A segunda linha existe por causa do laboratório, que raramente está no ar às 3 h: a cada hora o script só lista o S3 e, se o último conjunto tiver mais de 24 horas, faz o backup naquele momento. O cron é instalado pelo `node-bootstrap.sh` em todos os nós app, e o script só age no `app-1`.

## RTO

| Cenário | O que é feito | RTO |
|---|---|---|
| Banco corrompido ou apagado, ambiente no ar | `tnf-backup-restore --destino producao` | 15 minutos |
| Ambiente perdido | `infra up <env>` (13 min medidos no dev em 05/11) e a restauração | 1 hora |

O tempo de restauração medido em teste fica no relatório que o `tnf-backup-restore` grava em `/bckp/restauracoes/`.

## Integridade e criptografia

O `sha256sum` é conferido em três pontos: no S3, logo depois do envio (o script baixa de volta e roda `sha256sum --check`), na cópia offline (`scripts/backup-pull.sh`) e antes de cada restauração. O envio também usa `--checksum-algorithm SHA256`.

A criptografia usa GPG com um par de chaves Curve25519 do backup. A chave pública fica em `s3://<bucket>/chaves/`, e os nós só cifram. A chave privada, protegida por senha, fica no SSM (`/tnf/backup/gpg_private_key`) e em `~/.tnf-backup/` no computador do autor. A senha fica só com o autor.

## Comandos

```bash
scripts/backup-setup.sh                         # uma vez por conta do laboratório (WSL)
sudo tnf-backup --force                          # backup avulso (no app-1)
sudo tnf-backup-restore                          # teste: último conjunto do S3 em schemas restore_*
sudo tnf-backup-restore --destino producao       # restauração real (pare o backend antes)
scripts/backup-pull.sh prod                      # cópia 3, offline (WSL)
```
