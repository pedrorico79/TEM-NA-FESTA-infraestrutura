# `stacks/rabbitmq/`

Reservada para arquivos de configuração do RabbitMQ (06, seção 2). Hoje está vazia de propósito: a stack `tnf-rabbitmq` (`stacks/rabbitmq.yml`) usa a configuração padrão da imagem, com usuário e senha vindos dos segredos do Swarm.

Não há `rabbitmq.conf` nem `definitions.json`. O `definitions.json` foi descartado na E8: a fila `queue_pedido` e a troca ligada a ela são declaradas pelo próprio microsserviço de notificações. Um `definitions.json` carregado no boot também faria o RabbitMQ não criar o usuário padrão (06, seção 6.2).
