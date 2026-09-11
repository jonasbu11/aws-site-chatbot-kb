variable "name" {
  type = string
}

variable "embedding_model_id" {
  type = string
}

variable "embedding_dimensions" {
  type = number
}

variable "chunk_max_tokens" {
  type = number
}

variable "chunk_overlap_percentage" {
  type = number
}
