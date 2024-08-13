variable "project_id" {
  type        = string
  description = "デプロイ先のプロジェクトID"
}

variable "region" {
  type        = string
  default     = "asia-northeast1"
  description = "デプロイ先のリージョン"
}

variable "zone" {
  type        = string
  default     = "asia-northeast1-a"
  description = "compute engineのzone"
}

variable "your_account" {
  type        = string
  description = "踏み台サーバーに接続するのユーザー"
}
