#!/bin/bash
# =============================================================================
# setup-infra-cesarmiguel.sh
# Script completo de provisionamento de infraestrutura AWS
# Faculdade — Diagrama: VPC + Subnets + IGW + NAT + EC2 NGINX + EC2 Privada
# =============================================================================
set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURAÇÕES — ajuste conforme necessário
# ─────────────────────────────────────────────────────────────────────────────
AWS_REGION="us-east-1"
AMI_ID="ami-0ec10929233384c7f"   # Ubuntu Server 24.04 LTS (us-east-1)
INSTANCE_TYPE="t3.micro"
KEY_NAME="preset-cesarmiguel-key"

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn() { echo -e "${YELLOW}[WAIT]${NC} $1"; }

echo ""
echo "=============================================="
echo "  Provisionamento de Infraestrutura AWS"
echo "  Projeto: preset-cesarmiguel"
echo "=============================================="
echo ""

# =============================================================================
# PARTE 1 — REDE: VPC, Subnets, IGW, NAT Gateway, Route Tables
# =============================================================================
echo -e "${CYAN}>>> PARTE 1 — Rede${NC}"
echo ""

# ─── 1. VPC ──────────────────────────────────────────────────────────────────
log "Criando VPC 10.0.0.0/23..."
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block '10.0.0.0/23' \
  --instance-tenancy 'default' \
  --region "$AWS_REGION" \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=preset-cesarmiguel-vpc}]' \
  --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
ok "VPC criada: $VPC_ID"

# ─── 2. SUBNETS ──────────────────────────────────────────────────────────────
log "Criando subnet pública (10.0.0.0/24)..."
SUBNET_PUBLIC_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block '10.0.0.0/24' \
  --availability-zone "${AWS_REGION}a" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=preset-cesarmiguel-subnet-public1-us-east-1a}]' \
  --query 'Subnet.SubnetId' --output text)

aws ec2 modify-subnet-attribute \
  --subnet-id "$SUBNET_PUBLIC_ID" \
  --map-public-ip-on-launch
ok "Subnet pública criada: $SUBNET_PUBLIC_ID"

log "Criando subnet privada (10.0.1.0/24)..."
SUBNET_PRIVATE_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block '10.0.1.0/24' \
  --availability-zone "${AWS_REGION}a" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=preset-cesarmiguel-subnet-private1-us-east-1a}]' \
  --query 'Subnet.SubnetId' --output text)
ok "Subnet privada criada: $SUBNET_PRIVATE_ID"

# ─── 3. INTERNET GATEWAY ─────────────────────────────────────────────────────
log "Criando e anexando Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=preset-cesarmiguel-igw}]' \
  --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID"
ok "Internet Gateway criado e anexado: $IGW_ID"

# ─── 4. ELASTIC IP + NAT GATEWAY ─────────────────────────────────────────────
log "Alocando Elastic IP..."
EIP_ALLOC_ID=$(aws ec2 allocate-address \
  --domain 'vpc' \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=preset-cesarmiguel-eip-us-east-1a}]' \
  --query 'AllocationId' --output text)
ok "Elastic IP alocado: $EIP_ALLOC_ID"

log "Criando NAT Gateway na subnet pública..."
NAT_GW_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$SUBNET_PUBLIC_ID" \
  --allocation-id "$EIP_ALLOC_ID" \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=preset-cesarmiguel-nat-public1-us-east-1a}]' \
  --query 'NatGateway.NatGatewayId' --output text)

warn "Aguardando NAT Gateway ficar disponível (pode levar ~1 min)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
ok "NAT Gateway disponível: $NAT_GW_ID"

# ─── 5. ROUTE TABLE PÚBLICA ──────────────────────────────────────────────────
log "Criando route table pública..."
RTB_PUBLIC_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=preset-cesarmiguel-rtb-public}]' \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route \
  --route-table-id "$RTB_PUBLIC_ID" \
  --destination-cidr-block '0.0.0.0/0' \
  --gateway-id "$IGW_ID"

aws ec2 associate-route-table \
  --route-table-id "$RTB_PUBLIC_ID" \
  --subnet-id "$SUBNET_PUBLIC_ID"
ok "Route table pública criada: $RTB_PUBLIC_ID"

# ─── 6. ROUTE TABLE PRIVADA ──────────────────────────────────────────────────
log "Criando route table privada..."
RTB_PRIVATE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=preset-cesarmiguel-rtb-private1-us-east-1a}]' \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route \
  --route-table-id "$RTB_PRIVATE_ID" \
  --destination-cidr-block '0.0.0.0/0' \
  --nat-gateway-id "$NAT_GW_ID"

aws ec2 associate-route-table \
  --route-table-id "$RTB_PRIVATE_ID" \
  --subnet-id "$SUBNET_PRIVATE_ID"
ok "Route table privada criada: $RTB_PRIVATE_ID"

# =============================================================================
# PARTE 2 — NACLs: Pública e Privada
# =============================================================================
echo ""
echo -e "${CYAN}>>> PARTE 2 — NACLs${NC}"
echo ""

# ─── 7. NACL PÚBLICA ─────────────────────────────────────────────────────────
log "Criando NACL pública..."
NACL_PUBLIC_ID=$(aws ec2 create-network-acl \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=network-acl,Tags=[{Key=Name,Value=preset-cesarmiguel-nacl-public}]' \
  --query 'NetworkAcl.NetworkAclId' --output text)

# Entradas
aws ec2 create-network-acl-entry --network-acl-id "$NACL_PUBLIC_ID" \
  --ingress --rule-number 100 --protocol tcp --rule-action allow \
  --cidr-block '0.0.0.0/0' --port-range From=22,To=22

aws ec2 create-network-acl-entry --network-acl-id "$NACL_PUBLIC_ID" \
  --ingress --rule-number 200 --protocol tcp --rule-action allow \
  --cidr-block '0.0.0.0/0' --port-range From=80,To=80

aws ec2 create-network-acl-entry --network-acl-id "$NACL_PUBLIC_ID" \
  --ingress --rule-number 300 --protocol tcp --rule-action allow \
  --cidr-block '0.0.0.0/0' --port-range From=443,To=443

aws ec2 create-network-acl-entry --network-acl-id "$NACL_PUBLIC_ID" \
  --ingress --rule-number 400 --protocol tcp --rule-action allow \
  --cidr-block '0.0.0.0/0' --port-range From=32000,To=65535

# Saída
aws ec2 create-network-acl-entry --network-acl-id "$NACL_PUBLIC_ID" \
  --egress --rule-number 100 --protocol all --rule-action allow \
  --cidr-block '0.0.0.0/0'

# Associar à subnet pública
NACL_PUBLIC_ASSOC_ID=$(aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$SUBNET_PUBLIC_ID" \
  --query 'NetworkAcls[0].Associations[?SubnetId==`'"$SUBNET_PUBLIC_ID"'`].NetworkAclAssociationId' \
  --output text)

aws ec2 replace-network-acl-association \
  --association-id "$NACL_PUBLIC_ASSOC_ID" \
  --network-acl-id "$NACL_PUBLIC_ID"

ok "NACL pública criada e associada: $NACL_PUBLIC_ID"

# ─── 8. NACL PRIVADA ─────────────────────────────────────────────────────────
log "Criando NACL privada..."
NACL_PRIVATE_ID=$(aws ec2 create-network-acl \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=network-acl,Tags=[{Key=Name,Value=preset-cesarmiguel-nacl-private}]' \
  --query 'NetworkAcl.NetworkAclId' --output text)

# Entradas (SSH, HTTP, HTTPS somente da subnet pública)
aws ec2 create-network-acl-entry --network-acl-id "$NACL_PRIVATE_ID" \
  --ingress --rule-number 100 --protocol tcp --rule-action allow \
  --cidr-block '10.0.0.0/24' --port-range From=22,To=22

aws ec2 create-network-acl-entry --network-acl-id "$NACL_PRIVATE_ID" \
  --ingress --rule-number 200 --protocol tcp --rule-action allow \
  --cidr-block '10.0.0.0/24' --port-range From=80,To=80

aws ec2 create-network-acl-entry --network-acl-id "$NACL_PRIVATE_ID" \
  --ingress --rule-number 300 --protocol tcp --rule-action allow \
  --cidr-block '10.0.0.0/24' --port-range From=443,To=443

aws ec2 create-network-acl-entry --network-acl-id "$NACL_PRIVATE_ID" \
  --ingress --rule-number 400 --protocol tcp --rule-action allow \
  --cidr-block '0.0.0.0/0' --port-range From=32000,To=65535

# Saída
aws ec2 create-network-acl-entry --network-acl-id "$NACL_PRIVATE_ID" \
  --egress --rule-number 100 --protocol all --rule-action allow \
  --cidr-block '0.0.0.0/0'

# Associar à subnet privada
NACL_PRIVATE_ASSOC_ID=$(aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=$SUBNET_PRIVATE_ID" \
  --query 'NetworkAcls[0].Associations[?SubnetId==`'"$SUBNET_PRIVATE_ID"'`].NetworkAclAssociationId' \
  --output text)

aws ec2 replace-network-acl-association \
  --association-id "$NACL_PRIVATE_ASSOC_ID" \
  --network-acl-id "$NACL_PRIVATE_ID"

ok "NACL privada criada e associada: $NACL_PRIVATE_ID"

# =============================================================================
# PARTE 3 — COMPUTE: Key Pair, Security Groups, EC2 pública (NGINX), EC2 privada
# =============================================================================
echo ""
echo -e "${CYAN}>>> PARTE 3 — Compute${NC}"
echo ""

# ─── 9. KEY PAIR ─────────────────────────────────────────────────────────────
log "Criando key pair..."
aws ec2 create-key-pair \
  --key-name "$KEY_NAME" \
  --query 'KeyMaterial' \
  --output text > "${KEY_NAME}.pem"

chmod 400 "${KEY_NAME}.pem"
ok "Key pair salvo em: ${KEY_NAME}.pem"

# ─── 10. SECURITY GROUP PÚBLICO ──────────────────────────────────────────────
log "Criando Security Group público (NGINX)..."
SG_PUBLIC_ID=$(aws ec2 create-security-group \
  --group-name "preset-cesarmiguel-sg-public" \
  --description "SG para instancia publica com NGINX" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=preset-cesarmiguel-sg-public}]" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_PUBLIC_ID" \
  --protocol tcp --port 22 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_PUBLIC_ID" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_PUBLIC_ID" \
  --protocol tcp --port 8080 --cidr 0.0.0.0/0

ok "SG público criado: $SG_PUBLIC_ID"

# ─── 11. SECURITY GROUP PRIVADO ──────────────────────────────────────────────
log "Criando Security Group privado..."
SG_PRIVATE_ID=$(aws ec2 create-security-group \
  --group-name "preset-cesarmiguel-sg-private" \
  --description "SG para instancia privada" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=preset-cesarmiguel-sg-private}]" \
  --query 'GroupId' --output text)

# SSH somente via EC2 pública (padrão bastion)
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_PRIVATE_ID" \
  --protocol tcp --port 22 \
  --source-group "$SG_PUBLIC_ID"

# Porta de app interna — ajuste conforme sua aplicação
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_PRIVATE_ID" \
  --protocol tcp --port 8080 \
  --source-group "$SG_PUBLIC_ID"

ok "SG privado criado: $SG_PRIVATE_ID"

# ─── 12. EC2 PÚBLICA — NGINX ─────────────────────────────────────────────────
log "Criando EC2 pública com NGINX (user-data)..."
EC2_PUBLIC_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --subnet-id "$SUBNET_PUBLIC_ID" \
  --security-group-ids "$SG_PUBLIC_ID" \
  --associate-public-ip-address \
  --user-data '#!/bin/bash
dnf update -y
dnf install -y nginx
systemctl enable nginx
systemctl start nginx' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=preset-cesarmiguel-ec2-public-nginx}]" \
  --query 'Instances[0].InstanceId' --output text)

warn "Aguardando EC2 pública ficar running..."
aws ec2 wait instance-running --instance-ids "$EC2_PUBLIC_ID"

EC2_PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$EC2_PUBLIC_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
ok "EC2 pública disponível: $EC2_PUBLIC_ID  →  $EC2_PUBLIC_IP"

# ─── 13. EC2 PRIVADA ─────────────────────────────────────────────────────────
log "Criando EC2 privada..."
EC2_PRIVATE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --subnet-id "$SUBNET_PRIVATE_ID" \
  --security-group-ids "$SG_PRIVATE_ID" \
  --no-associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=preset-cesarmiguel-ec2-private}]" \
  --query 'Instances[0].InstanceId' --output text)

warn "Aguardando EC2 privada ficar running..."
aws ec2 wait instance-running --instance-ids "$EC2_PRIVATE_ID"

EC2_PRIVATE_IP=$(aws ec2 describe-instances \
  --instance-ids "$EC2_PRIVATE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
ok "EC2 privada disponível: $EC2_PRIVATE_ID  →  $EC2_PRIVATE_IP"

# =============================================================================
# RESUMO FINAL
# =============================================================================
echo ""
echo "=============================================="
echo -e "${GREEN}  ✅ Infraestrutura provisionada com sucesso!${NC}"
echo "=============================================="
echo ""
echo "  REDE"
echo "  ├─ VPC:              $VPC_ID  (10.0.0.0/23)"
echo "  ├─ Subnet pública:   $SUBNET_PUBLIC_ID  (10.0.0.0/24)"
echo "  ├─ Subnet privada:   $SUBNET_PRIVATE_ID  (10.0.1.0/24)"
echo "  ├─ Internet Gateway: $IGW_ID"
echo "  ├─ NAT Gateway:      $NAT_GW_ID"
echo "  ├─ RTB pública:      $RTB_PUBLIC_ID"
echo "  └─ RTB privada:      $RTB_PRIVATE_ID"
echo ""
echo "  NACLs"
echo "  ├─ NACL pública:     $NACL_PUBLIC_ID"
echo "  └─ NACL privada:     $NACL_PRIVATE_ID"
echo ""
echo "  COMPUTE"
echo "  ├─ Key pair:         ${KEY_NAME}.pem"
echo "  ├─ SG público:       $SG_PUBLIC_ID  (portas 22, 80, 8080)"
echo "  ├─ SG privado:       $SG_PRIVATE_ID"
echo "  ├─ EC2 pública:      $EC2_PUBLIC_ID  →  http://$EC2_PUBLIC_IP"
echo "  └─ EC2 privada:      $EC2_PRIVATE_ID  →  $EC2_PRIVATE_IP (privado)"
echo ""
echo "  ACESSO SSH"
echo "  ┌─ EC2 pública:"
echo "  │    ssh -i ${KEY_NAME}.pem ec2-user@$EC2_PUBLIC_IP"
echo "  └─ EC2 privada (via bastion):"
echo "       ssh -i ${KEY_NAME}.pem -J ec2-user@$EC2_PUBLIC_IP ec2-user@$EC2_PRIVATE_IP"
echo ""
