variable "yc_token" {
  description = "Yandex.Cloud OAuth token"
  sensitive   = true
}

variable "yc_cloud_id" {
  description = "Yandex.Cloud ID"
}

variable "yc_folder_id" {
  description = "Yandex.Cloud folder ID"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  default     = "~/.ssh/id_rsa.pub"
}

variable "db_password" {
  description = "Password for PostgreSQL database"
  sensitive   = true
}
