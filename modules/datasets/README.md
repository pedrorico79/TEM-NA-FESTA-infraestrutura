# `modules/datasets/`

Lambda `tnf-<env>-tendencias` (spec 10, seção 4): coleta as tendências dos produtos ativos do sistema pela API do backend atrás do ALB e grava no bronze. Só existe com `datasets_enabled = true`; o email e a senha do usuário de coleta ficam no SSM em `/tnf/<env>/datasets/`.
