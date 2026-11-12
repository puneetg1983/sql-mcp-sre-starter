terraform {
  required_version = ">= 1.6, < 2.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  type        = string
  description = "Subscription containing the existing deployment resource group."
}

variable "resource_group_name" {
  type        = string
  description = "Existing resource group. Use a dedicated group for this starter."
}

variable "location" {
  type        = string
  description = "Azure region; must match an existing Container Apps environment."
}

variable "name" {
  type    = string
  default = "sql-mcp"
}

variable "sql_server" {
  type        = string
  description = "SQL TLS hostname, not a URL, IP address or connection string."
}

variable "sql_database" {
  type = string
}

variable "sql_port" {
  type    = number
  default = 1433
}

variable "sql_authentication" {
  type    = string
  default = "managed-identity"

  validation {
    condition     = contains(["managed-identity", "sql-login"], var.sql_authentication)
    error_message = "Choose managed-identity or sql-login."
  }
}

variable "sql_user" {
  type        = string
  default     = ""
  description = "SQL-login mode only: existing dedicated reader login."
}

variable "sql_password" {
  type        = string
  sensitive   = true
  default     = ""
  description = "SQL-login mode only: supply through TF_VAR_sql_password or a secret store."
}

variable "environment_id" {
  type        = string
  default     = ""
  description = "Existing SQL-connected Container Apps environment resource ID, or empty."
}

variable "infrastructure_subnet_id" {
  type        = string
  default     = ""
  description = "New environment only: approved dedicated, delegated subnet resource ID."
}

variable "api_key" {
  type        = string
  sensitive   = true
  description = "32-128 random letters, digits, underscores or hyphens; keep in a secret store."

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{32,128}$", var.api_key))
    error_message = "Use 32-128 letters, digits, underscores or hyphens."
  }
}

resource "azurerm_resource_group_template_deployment" "mcp" {
  name                = "${var.name}-starter"
  resource_group_name = var.resource_group_name
  deployment_mode     = "Incremental"
  template_content    = file("${path.module}/../azuredeploy.json")
  parameters_content = jsonencode({
    location               = { value = var.location }
    name                   = { value = var.name }
    sqlServer              = { value = var.sql_server }
    sqlDatabase            = { value = var.sql_database }
    sqlPort                = { value = var.sql_port }
    sqlAuthentication      = { value = var.sql_authentication }
    sqlUser                = { value = var.sql_user }
    sqlPassword            = { value = var.sql_password }
    environmentId          = { value = var.environment_id }
    infrastructureSubnetId = { value = var.infrastructure_subnet_id }
    apiKey                 = { value = var.api_key }
  })

  lifecycle {
    precondition {
      condition     = var.environment_id == "" || var.infrastructure_subnet_id == ""
      error_message = "Supply an existing environment ID or a new environment subnet ID, not both."
    }
    precondition {
      condition     = var.sql_authentication != "sql-login" || (var.sql_user != "" && var.sql_password != "")
      error_message = "SQL-login authentication requires a dedicated reader login and password."
    }
  }
}

output "endpoint" {
  value = jsondecode(azurerm_resource_group_template_deployment.mcp.output_content).endpoint.value
}

output "reader_name" {
  value = jsondecode(azurerm_resource_group_template_deployment.mcp.output_content).readerName.value
}
