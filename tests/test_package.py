import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]
KEY = "a" * 64


def pwsh(script, *args, root=ROOT):
    return subprocess.run(
        ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(root / "scripts" / script), *args],
        text=True, capture_output=True, timeout=90,
    )


class PackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        for directory in ("scripts", "config", "sql"):
            shutil.copytree(ROOT / directory, cls.root / directory)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_powershell_parses(self):
        command = (
            "$all=@(); Get-ChildItem '" + str(ROOT / "scripts") + "' -Filter *.ps1 | "
            "ForEach-Object {$t=$null;$e=$null;"
            "[System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e)|Out-Null;"
            "$all+=$e}; if($all.Count){$all|Out-String|Write-Error;exit 1}"
        )
        result = subprocess.run(["pwsh", "-NoProfile", "-Command", command], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_generated_sql_escapes_literals_and_does_not_execute(self):
        result = pwsh("New-DatabaseSetup.ps1", "-Database", "Odd'Database", "-ReaderName", "Reader'Name", root=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        sql = (self.root / ".local" / "setup.sql").read_text()
        self.assertIn("N'Odd''Database'", sql)
        self.assertIn("N'Reader''Name'", sql)
        self.assertNotIn("__DATABASE__", sql)
        self.assertIn("IF SCHEMA_ID(N'sre_sql') IS NOT NULL", sql)
        self.assertNotRegex(sql, r"(?i)\b(?:DROP\s+DATABASE|TRUSTWORTHY|GRANT\s+CONTROL)\b")

    def test_contract_and_compiled_secret_mounts(self):
        config = json.loads((ROOT / "config" / "dab-config.json").read_text())
        self.assertLessEqual(len(json.dumps(config, separators=(",", ":")).encode()), 4096)
        entities = config["entities"]
        self.assertEqual(set(entities), {"ConnectionInfo", "Requests", "Sessions", "Transactions", "ReadLocks"})
        for name, entity in entities.items():
            self.assertFalse(entity["cache"]["enabled"])
            self.assertEqual(entity["permissions"][0]["actions"], ["execute"] if name == "ReadLocks" else ["read"])
        images = json.loads((ROOT / "config" / "images.json").read_text())
        self.assertTrue(all(re.search(r"@sha256:[a-f0-9]{64}$", value) for value in images.values()))
        arm = json.loads((ROOT / "infra" / "azuredeploy.json").read_text())
        app = next(r for r in arm["resources"] if r["type"] == "Microsoft.App/containerApps")
        template = app["properties"]["template"]
        self.assertEqual(template["scale"], {"minReplicas": 1, "maxReplicas": 1})
        self.assertEqual(len(template["volumes"]), 2)
        for container in template["containers"]:
            self.assertNotIn("volumes", container)
        self.assertEqual(arm["parameters"]["apiKey"]["type"].lower(), "securestring")
        self.assertEqual(arm["parameters"]["sqlPassword"]["type"].lower(), "securestring")
        self.assertNotIn("apiKey", arm["outputs"])
        ui = json.loads((ROOT / "infra" / "createUiDefinition.json").read_text())
        self.assertEqual(set(ui["parameters"]["outputs"]), set(arm["parameters"]))
        caddy = (ROOT / "config" / "Caddyfile").read_text()
        self.assertIn("header X-API-Key {$MCP_API_KEY}", caddy)
        self.assertIn("header_up -X-MS-*", caddy)
        self.assertIn('respond "Unauthorized" 401', caddy)

    def test_kubernetes_is_gateway_only_and_secret_not_in_stdout(self):
        with tempfile.TemporaryDirectory() as directory:
            connection = Path(directory) / "connection.txt"
            connection.write_text("Server=tcp:sql.example.test,1433;Database=Orders;User ID=reader;Password=secret$quoted;Encrypt=True;TrustServerCertificate=False;")
            result = pwsh(
                "New-Kubernetes.ps1", "-Hostname", "sql.example.test", "-TlsSecretName", "sql-tls",
                "-ConnectionStringFile", str(connection),
                root=self.root,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        resources = json.loads((self.root / ".local" / "kubernetes.json").read_text())["items"]
        deployment = next(x for x in resources if x["kind"] == "Deployment")
        pod = deployment["spec"]["template"]["spec"]
        dab, gateway = pod["containers"]
        self.assertEqual(next(x["value"] for x in dab["env"] if x["name"] == "ASPNETCORE_URLS"), "http://127.0.0.1:5000")
        self.assertNotIn("ports", dab)
        service = next(x for x in resources if x["kind"] == "Service")
        self.assertEqual(service["spec"]["type"], "ClusterIP")
        self.assertEqual(service["spec"]["ports"][0]["targetPort"], 8080)
        self.assertNotIn("secret$quoted", result.stdout + result.stderr)

    def test_bad_tls_connection_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            connection = Path(directory) / "connection.txt"
            connection.write_text("Server=sql;Database=Orders;Encrypt=True;TrustServerCertificate=True;")
            result = pwsh(
                "New-Kubernetes.ps1", "-Hostname", "sql.example.test", "-TlsSecretName", "sql-tls",
                "-ConnectionStringFile", str(connection),
                root=self.root,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TrustServerCertificate=False", result.stderr)


class ProtocolTests(unittest.TestCase):
    def run_fixture(self, mode):
        from datetime import datetime, timedelta, timezone

        calls = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if mode == "redirect":
                    self.send_response(302)
                    self.send_header("Location", "https://example.invalid/do-not-send-key")
                    self.end_headers()
                    return
                if self.headers.get("X-API-Key") != KEY and mode != "open":
                    self.send_response(401)
                    self.end_headers()
                    return
                method = body["method"]
                calls.append(method)
                if method == "notifications/initialized":
                    self.send_response(202)
                    self.end_headers()
                    return
                if method == "initialize":
                    result = {"protocolVersion": "2025-03-26", "serverInfo": {"name": "fixture"}}
                elif method == "tools/list":
                    names = ["describe_entities", "execute_entity", "read_records"]
                    if mode == "write-tool":
                        names.append("execute_sql")
                    result = {"tools": [{"name": n} for n in names]}
                else:
                    name = body["params"]["name"]
                    arguments = body["params"]["arguments"]
                    if name == "describe_entities":
                        data = {"entities": [{"name": n} for n in ("ConnectionInfo", "ReadLocks", "Requests", "Sessions", "Transactions")]}
                    elif name == "execute_entity":
                        data = {"status": "success", "value": {"value": []}}
                    else:
                        if arguments["entity"] == "ConnectionInfo":
                            observed = datetime.now(timezone.utc)
                            if mode == "stale":
                                observed -= timedelta(minutes=10)
                            elif mode == "sql-timestamp":
                                observed = observed.replace(tzinfo=None)
                            rows = [{
                                "DatabaseName": "Orders" if mode != "wrong-db" else "Other",
                                "DatabaseUser": "reader", "SessionId": 10,
                                "IsDbOwner": 1 if mode == "owner" else 0,
                                "CanControlDatabase": 0, "CanCreateTable": 0,
                                "ObservedAtUtc": observed.isoformat(),
                            }]
                        else:
                            rows = [{"SessionId": 123}] if arguments["entity"] == "Sessions" and mode != "invisible" else []
                        data = {"status": "success", "result": {"value": rows}}
                    result = {"content": [{"type": "text", "text": json.dumps(data)}]}
                reply = json.dumps({"jsonrpc": "2.0", "id": body["id"], "result": result}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Mcp-Session-Id", "fixture-session")
                self.end_headers()
                self.wfile.write(reply)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                keyfile = Path(directory) / "key.txt"
                keyfile.write_text(KEY)
                result = pwsh(
                    "Test-Mcp.ps1", "-Endpoint", f"http://127.0.0.1:{server.server_port}/mcp",
                    "-Database", "Orders", "-ReaderName", "reader", "-ApiKeyFile", str(keyfile),
                    "-AllowLoopbackHttp", "-WitnessSessionId", "123",
                )
                self.assertNotIn(KEY, result.stdout + result.stderr)
                return result
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_successful_live_contract_read(self):
        for mode in ("ok", "sql-timestamp"):
            with self.subTest(mode=mode):
                result = self.run_fixture(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("READY TO CONNECT", result.stdout)
                self.assertIn("independently identified", result.stdout)

    def test_unsafe_or_incorrect_endpoints_never_report_success(self):
        for mode in ("open", "redirect", "write-tool", "wrong-db", "owner", "invisible", "stale"):
            with self.subTest(mode=mode):
                result = self.run_fixture(mode)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("READY TO CONNECT", result.stdout)


if __name__ == "__main__":
    unittest.main()
