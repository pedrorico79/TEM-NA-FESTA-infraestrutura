variable "env" {
  description = "Ambiente (dev ou prod), usado no caminho /tnf/<env>/secrets/."
  type        = string
}

variable "messaging_secrets" {
  description = "Segredos manuais do microsserviço, vindos do secrets.env (05, A5). Vazio com a mensageria desligada."
  type        = map(string)
  default     = {}
  sensitive   = true
}
