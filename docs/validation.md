# Validation status

This page records actual evidence, not an implied support guarantee.

| Surface | Status |
|---|---|
| Official DAB image + Caddy + SRE custom-header pattern | Exercised in the originating private Azure SQL demo; not proof of every generalized template here |
| ACA Bicep and compiled ARM | Deployed successfully in an isolated Azure resource group, 2026-11-11 |
| Guided setup / verification | PowerShell parsing/generation, template alignment and protocol rejection fixtures passed; real endpoint verification passed |
| Azure SQL cross-session visibility | Verified against disposable Azure SQL Standard S2 using managed identity; other tiers/DMVs require customer DBA acceptance |
| SQL Server on VM | Generated contract only; no end-to-end VM deployment certified |
| Kubernetes / Docker Compose | Configuration generation only; no runtime certification yet |
| Deploy to Azure portal form | Schema/parameter alignment checks only; interactive portal completion not yet certified |
| Terraform ARM wrapper | Local initialization/validation and three mocked plan checks passed; no Terraform apply to Azure |
| Native Entra remote SRE connector | Not implemented or claimed |

See the release notes for changes. Always run the verifier and independent-session check on your database and approve all grants before connecting production.

## Isolated ACA / Azure SQL evidence

The deployed release used the committed ARM template, digest-pinned DAB/Caddy images, a VNet-integrated ACA environment, private DNS and an Azure SQL private endpoint. The SQL server used Entra-only authentication. The generated DBA script executed successfully and was rerun successfully.

Verification checked:

- Public HTTPS certificate validation and rejection of missing/wrong API keys.
- Exactly three tools/five entities, with successful live reads of every object.
- The expected managed-identity database user and denied owner/CONTROL/CREATE TABLE checks.
- An independent SQL session, a disposable blocking edge, the sleeping transaction owner, transaction ownership and granted/waiting locks.
- Denied effective permissions for business-table SELECT/INSERT and database CREATE PROCEDURE/ALTER.
- Successful reads after disabling SQL public networking and restarting the app, forcing fresh SQL connections.

Disposable SQL fixtures were removed, and the dedicated Azure test resources were deleted after validation. The DBA connection temporarily used exact observed client-IP firewall rules; no "allow Azure services" rule was used. Administrator tokens/credentials were never installed on the MCP host.

This did **not** create a new SRE Agent connector, exercise the portal form interactively, or run SQL Server/Kubernetes/Docker integrations. The previous demo exercised the SRE custom-header pattern; this release's new evidence is the ACA-to-SQL and remote MCP path. It is not a production availability, complete inherited-permission or all-tier certification.
