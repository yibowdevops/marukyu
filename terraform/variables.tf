variable "aws_profile" {
  default = "marukyu"
}

variable "region" {
  default = "ap-southeast-1"
}

variable "instance_type" {
  default = "t2.micro"
}

variable "poll_interval" {
  default     = 60
  description = "Poll interval in seconds"
}

variable "telegram_bot_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Telegram bot token for stock change notifications. Must be set together with telegram_chat_id."
}

variable "telegram_chat_id" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Telegram chat ID for stock change notifications. Must be set together with telegram_bot_token."
}

variable "telegram_alarm_email" {
  type        = string
  default     = ""
  description = "Email to subscribe to scheduler error alarms. Empty disables the SNS topic."
}
