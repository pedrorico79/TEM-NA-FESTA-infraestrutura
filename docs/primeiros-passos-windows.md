# Primeiros passos no Windows

Este guia prepara uma máquina Windows para usar o repositório de infraestrutura do Tem Na Festa (08, seção 5.1). Siga os passos **na ordem**.

> **O `infra` não deve ser executado no PowerShell nem no Prompt de Comando.** Ele é um script bash e roda **dentro do WSL** (Ubuntu). O PowerShell só é usado no passo 1, para instalar o WSL.

## 1. Instalar o WSL 2 com Ubuntu

No **PowerShell como administrador**:

```powershell
wsl --install -d Ubuntu
```

Reinicie o computador se for pedido. Na primeira abertura do Ubuntu, crie o seu usuário e senha do Linux. Confira que a versão é a 2:

```powershell
wsl -l -v
```

A coluna `VERSION` do Ubuntu deve mostrar `2`. Daqui em diante, **todos os comandos são digitados no terminal do Ubuntu** (menu Iniciar → Ubuntu).

## 2. Instalar as ferramentas

### 2.1 Pacotes do Ubuntu

```bash
sudo apt update
sudo apt install -y git make jq curl unzip shellcheck bats yamllint gnupg lsb-release
```

### 2.2 Terraform (1.11 ou superior)

Pelo repositório oficial da HashiCorp:

```bash
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
```

### 2.3 AWS CLI v2

```bash
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
sudo ./aws/install
cd ~
```

### 2.4 TFLint

Pelo instalador oficial do projeto:

```bash
curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
```

### 2.5 GitHub CLI (opcional)

O `gh` não é necessário para o `infra`; é só uma conveniência para abrir PRs pelo terminal. Instruções em <https://github.com/cli/cli/blob/trunk/docs/install_linux.md>.

### 2.6 Conferir

```bash
terraform version
aws --version
jq --version
curl --version | head -1
make --version | head -1
shellcheck --version | head -2
tflint --version
bats --version
yamllint --version
```

## 3. Clonar o repositório dentro do WSL

Clone **no sistema de arquivos do Linux** (por exemplo, `~/projetos/`), **nunca** em `/mnt/c/...`. Em `/mnt/c` as permissões `600` do `secrets.env` e da chave SSH não funcionam (o SSH recusa a chave) e o Terraform fica muito mais lento.

```bash
mkdir -p ~/projetos
cd ~/projetos
git clone https://github.com/pedrorico79/TEM-NA-FESTA-infraestrutura.git
cd TEM-NA-FESTA-infraestrutura
```

Os finais de linha já ficam corretos (`LF`) por causa do `.gitattributes` do repositório. Para editar no VS Code do Windows, abra a pasta pelo WSL (extensão *WSL*, comando `code .` dentro do Ubuntu), para que os arquivos continuem no sistema de arquivos do Linux.

## 4. Configurar as credenciais do laboratório dentro do WSL

As credenciais configuradas no Windows **não valem** dentro do WSL. A cada sessão do AWS Academy Learner Lab:

1. No Learner Lab, clique em **Start Lab** e espere o indicador ficar verde.
2. Clique em **AWS Details** e, em *AWS CLI*, clique em **Show**.
3. No Ubuntu, abra o arquivo de credenciais:

   ```bash
   mkdir -p ~/.aws
   nano ~/.aws/credentials
   ```

4. Substitua todo o conteúdo pelo bloco copiado do Learner Lab (seção `[default]` com `aws_access_key_id`, `aws_secret_access_key` e `aws_session_token`), salve (`Ctrl+O`, `Enter`) e saia (`Ctrl+X`).
5. Configure a região, uma vez só:

   ```bash
   aws configure set region us-east-1
   ```

6. Confira:

   ```bash
   aws sts get-caller-identity
   ```

As credenciais vencem com a sessão do laboratório (cerca de 4 horas). Ao começar uma nova sessão, repita os passos 1 a 4. Nunca copie as credenciais para dentro do repositório.

## 5. Rodar o `infra doctor`

Na pasta do repositório, dentro do Ubuntu:

```bash
./infra doctor
```

Ele confere as ferramentas e versões, as credenciais do laboratório e a região, e avisa se o repositório estiver em `/mnt/c`. Para cada item que faltar, mostra o que fazer. Corrija e rode de novo até não haver pendências.

## Problemas comuns

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `^M: command not found` ou `bad interpreter` | arquivo com finais de linha `CRLF` | clone de novo dentro do WSL (passo 3); não copie arquivos do Windows para o repositório |
| `infra` não é reconhecido no PowerShell | o `infra` é bash | abra o terminal do Ubuntu e rode `./infra` na pasta do repositório |
| `ExpiredToken` ou `InvalidClientTokenId` | sessão do laboratório vencida | repita o passo 4 com as credenciais novas |
| `infra doctor` avisa sobre `/mnt/c` | repositório clonado no disco do Windows | clone de novo em `~/projetos` (passo 3) |
