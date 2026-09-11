output "knowledge_base_id" {
  value = aws_bedrockagent_knowledge_base.this.id
}

output "knowledge_base_arn" {
  value = aws_bedrockagent_knowledge_base.this.arn
}

output "data_source_id" {
  value = aws_bedrockagent_data_source.docs.data_source_id
}

output "docs_bucket" {
  value = aws_s3_bucket.docs.bucket
}

output "docs_bucket_arn" {
  value = aws_s3_bucket.docs.arn
}

output "vector_index_arn" {
  value = aws_s3vectors_index.this.index_arn
}
