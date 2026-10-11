# Confere os valores de envs/<env>/terraform.tfvars contra o contrato (03),
# com o provedor AWS simulado (C10). O make roda este teste uma vez por
# ambiente, com -var-file apontando para o terraform.tfvars e, por -var, um
# marcador nas quatro variáveis sem padrão, que ficam em branco até a E4a
# (03, seção 3.8). Não há variáveis neste arquivo: tudo vem do make.

mock_provider "aws" {
  source = "../mocks"
}

run "tfvars_do_ambiente_respeita_o_contrato" {
  command = plan

  module {
    source = "../../../modules/environment"
  }
}
