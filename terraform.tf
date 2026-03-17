# =============================================================================
# Terraform 基盤設定
# =============================================================================

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    alz = {
      source  = "azure/alz"
      version = "~> 0.20"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # テストデプロイ時はコメントアウトしてローカル state を使用
  # 本番ではコメントを外して backend を有効化してください
  # backend "azurerm" {}
}

# =============================================================================
# Data Sources
# =============================================================================

data "azurerm_client_config" "current" {}

# =============================================================================
# Providers
# =============================================================================

# デフォルト — テナントレベルリソース（管理グループ、ポリシー）に使用
provider "azurerm" {
  resource_provider_registrations = "none"
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Management サブスクリプション — Log Analytics, Sentinel, UAMI, DCR
provider "azurerm" {
  alias                          = "management"
  resource_provider_registrations = "none"
  subscription_id                = var.subscription_ids["management"]
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Connectivity サブスクリプション — Hub VNet, DNS, ネットワーク関連
provider "azurerm" {
  alias                          = "connectivity"
  resource_provider_registrations = "none"
  subscription_id                = var.subscription_ids["connectivity"]
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
