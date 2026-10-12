output "bucket_name" {
  description = "Bucket de artefatos do ambiente."
  value       = var.bucket_name
}

output "manifest_hash" {
  description = "Hash do conjunto de compose files e stack.env aplicado."
  value       = local.manifest_hash
}

output "node_objects" {
  description = "Objetos de node/ já enviados; as instâncias dependem deles."
  value       = [for o in aws_s3_object.node : o.key]
}
