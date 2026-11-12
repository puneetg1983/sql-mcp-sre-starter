# Connect Azure SRE Agent

First run `Test-Mcp.ps1`. Keep the API key in your approved password manager; do not paste it into chat or incident reports.

1. Open https://sre.azure.com and select your agent.
2. Go to **Build + setup > Extensions > Connectors** and add an **MCP server**.
3. Select **Streamable-HTTP** and paste the full `https://<host>/mcp` endpoint.
4. Configure custom header **X-API-Key** with the saved key. If authentication and headers are separate, choose **No authentication** and add the header. The gateway still authenticates every MCP request.
5. Connect; select only `describe_entities`, `read_records`, and `execute_entity`; save.
6. In a new chat, ask the agent to read ConnectionInfo and report the current database, actual database user and selected privilege checks. Then ask about current requests, sessions, transactions and locks.

Tools can be used directly in the main agent conversation; a custom agent is not required.

`execute_entity` is enabled only because the **sole configured procedure** is the read-only ReadLocks. Do not add arbitrary SQL, business procedures or modification tools.

## Expected first answer

The intended database and dedicated reader, a current ObservedAtUtc, and zero for IsDbOwner, CanControlDatabase and CanCreateTable. Unknown/null is not denied. The agent should acknowledge empty or insufficient evidence instead of inventing a blocker.

Do not use the SQL hostname, connection string, a Key Vault URI, or the container root URL as the MCP endpoint. An API key is not a SQL password. The SRE Agent identity's Azure Reader role does not grant this connection SQL rights.

## Authentication alternatives

The baseline uses a shared API key over HTTPS because this pattern has been exercised with SRE Agent. Authorization applies to everyone who can use that connector; it is not per-user SQL impersonation.

Microsoft's documentation describes remote OAuth for **spec-compliant OAuth servers**, including dynamic registration and PKCE. DAB JWT validation alone is not that OAuth authorization flow. Managed identity in the current SRE connector documentation is described for stdio, not a universal remote DAB token-acquisition path. Do not remove the gateway merely because SQL uses managed identity.

[Official SRE Agent MCP setup](https://learn.microsoft.com/azure/sre-agent/mcp-connector) | [Authentication and transports](https://learn.microsoft.com/azure/sre-agent/mcp-connectors)

## Troubleshoot the layer that failed

| Symptom | Check |
|---|---|
| Timeout or invalid certificate | SRE-to-MCP network path, DNS, ingress and HTTPS certificate |
| HTTP 401 | Exact key, header forwarding and gateway reload after rotation |
| HTTP 502/503 | DAB startup, SQL grants, host-to-SQL DNS/routing/TLS and identity |
| SQL login failure | Runtime principal, managed identity assignment or dedicated login |
| Tools missing | Connector tool selection and the deployed DAB configuration |
| Only own session visible | DMV/tier permissions; perform the independent session check |

Do not disable TLS checks, open SQL to the internet, or use a DBA principal to silence errors.
