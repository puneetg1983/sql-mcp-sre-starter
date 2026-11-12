# Deploy the SQL MCP host with Terraform

This is a Terraform wrapper around the same committed ARM template as **Deploy to Azure**. It deploys the MCP server, API-key gateway and managed identity on Azure Container Apps, without maintaining a second infrastructure implementation. Use the full repository checkout; `main.tf` loads `../azuredeploy.json`.

Requires Terraform 1.6+, Azure CLI authentication (`az login`) or an approved Terraform Azure credential, and an existing resource group. Follow the SQL and network prerequisites in the [main guide](../../README.md#1-deploy-to-azure-container-apps). This does not provision SQL, SQL grants or the network path.

1. Copy `terraform.tfvars.example` to `terraform.tfvars` in this directory and fill in your values. For private SQL, supply either `environment_id` or `infrastructure_subnet_id`. Match an existing environment's region.
2. Supply `TF_VAR_api_key` through your secret-management process. For `sql-login`, also supply `TF_VAR_sql_password` and set `sql_user` to an existing dedicated reader. Never use administrator credentials.
3. From this directory, run:

```powershell
terraform init
terraform plan -out=deploy.tfplan
terraform apply deploy.tfplan
terraform output
```

Save `endpoint` and `reader_name`, then follow **Step 2** of the main guide to authorize the database and verify the endpoint, and **Step 3** to connect SRE Agent.

**Secrets:** Terraform's `sensitive` flag hides values from normal console output; it does not encrypt state or saved plans. These files contain the API key and, in SQL-login mode, the SQL password. Use your organization's access-controlled, encrypted remote backend and protected CI secrets. Do not upload state, plans or real `.tfvars` files. No backend is configured for you; without one, Terraform stores state locally.

**Lifecycle:** Terraform manages an ARM deployment rather than each nested resource individually, so its plan does not show all nested changes or detect all resource drift. Review the ARM template too. Under the provider's default behavior, `terraform destroy` removes deployment-managed resources, including the MCP app and any environment this template created. Do not import an unrelated deployment or use this wrapper to take ownership of shared infrastructure. Existing SQL, an externally supplied environment and the resource group are not created by this wrapper.

**Validation:** Formatting, initialization, validation and mocked plan checks (Terraform 1.7+) are checked in CI. The underlying ARM template has ACA/Azure SQL live evidence; this Terraform wrapper has not been applied to Azure.
