mock_provider "azurerm" {}

variables {
  subscription_id     = "00000000-0000-0000-0000-000000000000"
  resource_group_name = "rg-sql-mcp-test"
  location            = "eastus"
  sql_server          = "orders-sql.database.windows.net"
  sql_database        = "Orders"
  api_key             = "test-only-placeholder-not-a-real-key"
}

run "same_arm_contract" {
  command = plan

  assert {
    condition = (
      toset(keys(jsondecode(azurerm_resource_group_template_deployment.mcp.parameters_content))) ==
      toset(keys(jsondecode(azurerm_resource_group_template_deployment.mcp.template_content).parameters))
    )
    error_message = "Terraform must supply exactly the ARM template parameters."
  }

  assert {
    condition = (
      jsondecode(azurerm_resource_group_template_deployment.mcp.parameters_content).sqlServer.value == var.sql_server &&
      jsondecode(azurerm_resource_group_template_deployment.mcp.parameters_content).sqlDatabase.value == var.sql_database &&
      jsondecode(azurerm_resource_group_template_deployment.mcp.parameters_content).apiKey.value == var.api_key
    )
    error_message = "Terraform must pass the selected SQL target and API key to ARM."
  }
}

run "reject_conflicting_network_choices" {
  command = plan

  variables {
    environment_id           = "/subscriptions/test/resourceGroups/test/providers/Microsoft.App/managedEnvironments/existing"
    infrastructure_subnet_id = "/subscriptions/test/resourceGroups/test/providers/Microsoft.Network/virtualNetworks/test/subnets/test"
  }

  expect_failures = [azurerm_resource_group_template_deployment.mcp]
}

run "reject_missing_sql_credentials" {
  command = plan

  variables {
    sql_authentication = "sql-login"
  }

  expect_failures = [azurerm_resource_group_template_deployment.mcp]
}
