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

  # リモート state backend（Azure Storage）
  backend "azurerm" {
    use_oidc = true
  }
}

# =============================================================================
# Data Sources
# =============================================================================

data "azurerm_client_config" "current" {}

# =============================================================================
# Providers
# =============================================================================

# デフォルト — テナントレベルリソース（管理グループ、ポリシー、サブスクリプション作成）に使用
provider "azurerm" {
  resource_provider_registrations = "none"
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    subscription {
      prevent_cancellation_on_destroy = true
    }
  }
}

# Management サブスクリプション — Log Analytics, Sentinel, UAMI, DCR
provider "azurerm" {
  alias                           = "management"
  resource_provider_registrations = "none"
  subscription_id                 = var.subscription_ids["management"]
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Connectivity サブスクリプション — Hub VNet, DNS, ネットワーク関連
provider "azurerm" {
  alias                           = "connectivity"
  resource_provider_registrations = "none"
  subscription_id                 = var.subscription_ids["connectivity"]
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
