# State remoto no bucket de state (02, seção 2; 08, seção 4.1). O bucket e a
# região chegam pelo infra com -backend-config (E2).
terraform {
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    use_lockfile = true
  }
}
