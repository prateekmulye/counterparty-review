#!/usr/bin/env python3
"""Native Linux runtime gate: the 12 disposable database/TLS/ownership checks.

Requires Docker, openssl and already-local Linux amd64 app/PostgreSQL 17 images.
Never pulls, builds, uses real credentials, requests inference or uses an existing
database. Internal Docker networking blocks external services. Only fixed status
fields and numeric metrics enter the receipt; no logs, secrets, cookies or bodies.
"""
import argparse
import base64
import hashlib
import html.parser
import json
import os
from pathlib import Path
import platform
import secrets
import subprocess
import tempfile
import time
import urllib.parse
import uuid

HOST = "counterparty.prateekmulye.dev"
LABEL = "dev.prateekmulye.counterparty-runtime-qa"
CHECKS = {
    "disposable_database_ready", "matching_ca_and_hostname_verified_tls",
    "wrong_ca_rejected", "wrong_hostname_rejected", "positive_tls_control_after_rejections",
    "release_migrations", "migration_rerun_is_idempotent", "application_reads_migrated_tls_database",
    "http_owner_isolation_and_hashed_storage", "records_and_ownership_survive_application_restart",
    "application_connections_use_tls", "no_model_jobs_requested",
}


def docker(*args, timeout=25, stdin=None):
    result = subprocess.run(["docker", *args], input=stdin, text=True,
                            capture_output=True, timeout=timeout, check=False)
    if result.returncode:
        # Docker errors may contain credentials. Never emit stderr or arguments.
        raise RuntimeError("docker_command_failed")
    return result.stdout.strip()


def need(condition):
    if not condition:
        raise AssertionError("observable_contract_failed")


def error_category(error):
    for kind, category in ((subprocess.TimeoutExpired, "command_timeout"),
                           (AssertionError, "contract_failed"), (OSError, "os_error"),
                           (ValueError, "invalid_response"), (RuntimeError, "runtime_failure")):
        if isinstance(error, kind):
            return category
    return "unexpected_error"


class Client:
    def __init__(self, port, host):
        self.port, self.host, self.headers = port, host, {}


class HiddenInputs(html.parser.HTMLParser):
    def __init__(self, raw):
        super().__init__()
        self.fields = {}
        self.feed(raw.decode())

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "input" and attrs.get("type") == "hidden":
            self.fields[attrs["name"]] = attrs.get("value", "")


class ContainerClient(Client):
    """Probe from an isolated helper without consuming the app's CPU allowance."""

    def __init__(self, helper, target):
        super().__init__(8080, HOST)
        self.helper, self.target = helper, target

    def request(self, method, path, body=None, timeout=25):
        headers = {"Host": self.host, "Connection": "close", **self.headers}
        if body is not None and not isinstance(body, bytes):
            body = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        payload = json.dumps({"target": self.target, "method": method, "path": path, "headers": headers,
                              "timeout": min(8, timeout),
                              "body": None if body is None else base64.b64encode(body).decode()})
        # Cookie/body data travels only through captured stdin/stdout, never argv,
        # the receipt, or app logs. The app's 8080 proxy still handles every request.
        code = """import base64,http.client,json,sys
request=json.load(sys.stdin)
connection=http.client.HTTPConnection(request['target'],8080,timeout=request['timeout'])
try:
    body=None if request['body'] is None else base64.b64decode(request['body'])
    connection.request(request['method'],request['path'],body,request['headers'])
    response=connection.getresponse()
    raw=response.read(1_048_577)
    if len(raw)>1_048_576: raise ValueError('response_size')
    print(json.dumps([response.status,{k.lower():v for k,v in response.getheaders()},base64.b64encode(raw).decode()]))
finally:
    connection.close()
"""
        status, response_headers, raw = json.loads(
            docker("exec", "-i", self.helper, "python", "-B", "-c", code, stdin=payload, timeout=timeout))
        return status, response_headers, base64.b64decode(raw)


def bootstrap(client):
    status, headers, raw = client.request("GET", "/")
    need(status == 200)
    cookie = headers.get("set-cookie", "")
    need(cookie.startswith("__Host-counterparty=") and "secure" in cookie.lower())
    client.headers.update({"Cookie": cookie.split(";", 1)[0],
                           "Origin": "https://" + HOST,
                           "Content-Type": "application/x-www-form-urlencoded"})
    fields = HiddenInputs(raw).fields
    need(bool(fields.get("_csrf_token")) and bool(fields.get("idempotency_key")))
    return fields


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--postgres-image", required=True)
    parser.add_argument("--app-image", default="portfolio-counterparty:review")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    owner = "cp-db-qa-" + uuid.uuid4().hex[:12]
    network, database, app = owner, owner + "-db", owner + "-app"
    helper = owner + "-client"
    planned = [database, app, helper]
    report = {"scope": "Disposable local containers with synthetic company records",
              "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "utc_started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "native_linux_amd64": False, "checks": [],
              "http_client": "Separate helper on the internal network; app proxy port 8080",
              "not_covered": ["Public provider database/TLS", "Hosted model inference",
                              "Sustained capacity", "Backup restoration", "Retention expiry"]}

    def check(name, action):
        started = time.monotonic()
        try:
            detail = action()
            report["checks"].append({"name": name, "passed": True, "detail": detail,
                                     "elapsed_seconds": round(time.monotonic() - started, 3)})
            return detail
        except Exception as error:
            report["checks"].append({"name": name, "passed": False,
                                     "error_category": error_category(error),
                                     "elapsed_seconds": round(time.monotonic() - started, 3)})
            raise RuntimeError(name) from None

    def owned(kind, name):
        try:
            value = json.loads(docker(kind, "inspect", name, timeout=3))[0]
            labels = value.get("Labels", {}) if kind == "network" else value.get("Config", {}).get("Labels", {})
            return value["Id"] if (labels or {}).get(LABEL) == owner else None
        except Exception:
            return False

    def diagnostics():
        observations = {}
        for role, name in (("app", app), ("helper", helper), ("database", database)):
            observed = observations[role] = {}
            try:
                item = json.loads(docker("container", "inspect", name, timeout=3))[0]
                need(item["Config"]["Labels"].get(LABEL) == owner)
                state = item["State"]
                observed.update(running=state["Running"], oom_killed=state["OOMKilled"],
                                exit_code=state["ExitCode"], restart_count=item["RestartCount"])
                health = state.get("Health", {}).get("Status")
                observed["health"] = health if health in ("starting", "healthy", "unhealthy") else "unavailable"
                if role == "app":
                    limits = item["HostConfig"]
                    observed["limits"] = {key: limits[key] for key in ("Memory", "MemorySwap", "NanoCpus", "PidsLimit")}
                    if state["Running"]:
                        lines = docker("exec", item["Id"], "cat", "/sys/fs/cgroup/memory.current",
                                       "/sys/fs/cgroup/memory.peak", "/sys/fs/cgroup/memory.events",
                                       timeout=3).splitlines()
                        need(len(lines) >= 2)
                        events = dict(line.split() for line in lines[2:])
                        observed["metrics"] = {
                            "memory_current_bytes": int(lines[0]), "memory_peak_bytes": int(lines[1]),
                            "memory_events": {key: int(events[key]) for key in
                                              ("low", "high", "max", "oom", "oom_kill", "oom_group_kill")
                                              if key in events}}
            except Exception as error:
                observed["diagnostics_error"] = error_category(error)
        return observations

    old_umask = os.umask(0o077)
    try:
        need(platform.system() == "Linux" and platform.machine() == "x86_64")
        need(docker("info", "--format", "{{.OSType}}/{{.Architecture}}") in
             ("linux/x86_64", "linux/amd64"))
        report["native_linux_amd64"] = True
        with tempfile.TemporaryDirectory(prefix=owner + "-") as folder:
            folder = Path(folder)
            tls = folder / "db-tls"
            tls.mkdir(mode=0o700)
            # Resolve local IDs first. Docker must never fetch an unknown image.
            images = {}
            for key, image in (("app", args.app_image), ("postgres", args.postgres_image)):
                inspected = json.loads(docker("image", "inspect", image))[0]
                need(inspected["Architecture"] == "amd64" and inspected["Os"] == "linux")
                images[key] = inspected["Id"]
            report["images"] = images

            def openssl(*command):
                result = subprocess.run(["openssl", *command], cwd=tls,
                                        capture_output=True, timeout=20)
                need(result.returncode == 0)

            for ca in ("ca", "wrong-ca"):
                openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                        "-subj", "/CN=" + ca, "-keyout", ca + ".key", "-out", ca + ".crt")
            openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=qa-db",
                    "-keyout", "server.key", "-out", "server.csr")
            (tls / "server.ext").write_text("subjectAltName=DNS:qa-db\nextendedKeyUsage=serverAuth\n")
            openssl("x509", "-req", "-in", "server.csr", "-CA", "ca.crt", "-CAkey", "ca.key",
                    "-CAcreateserial", "-out", "server.crt", "-days", "2", "-extfile", "server.ext")
            (tls / "pg_hba.conf").write_text(
                "local all all trust\nhostssl all all 0.0.0.0/0 scram-sha-256\n"
                "hostssl all all ::/0 scram-sha-256\nhostnossl all all 0.0.0.0/0 reject\n"
                "hostnossl all all ::/0 reject\n")
            # Only public certificates are readable by the nonroot app container.
            # Their host parent directory and every private key/env file remain 0700/0600.
            for ca in ("ca.crt", "wrong-ca.crt"):
                (tls / ca).chmod(0o644)
            password = secrets.token_hex(24)
            (folder / "pg.env").write_text(
                "POSTGRES_USER=qa_admin\nPOSTGRES_PASSWORD=" + secrets.token_hex(24) +
                "\nPOSTGRES_DB=qa_counterparty\nPGDATA=/var/lib/postgresql/data/qa\n")
            common = {"PUBLIC_ORIGIN": "https://" + HOST, "AI_PROVIDER": "workers-ai",
                      "AI_GATEWAY_URL": "https://ai.prateekmulye.dev/v1/infer",
                      "AI_GATEWAY_SECRET": secrets.token_urlsafe(32),
                      "SECRET_KEY_BASE": secrets.token_urlsafe(64), "DATABASE_CA_FILE": "/qa-ca.pem"}
            for variant, hostname in (("good", "qa-db"), ("wrong-ca", "qa-db"), ("wrong-host", "qa-db-wrong")):
                env = dict(common, DATABASE_URL=f"postgresql://qa_app:{password}@{hostname}:5432/qa_counterparty")
                (folder / (variant + ".env")).write_text("".join(f"{k}={v}\n" for k, v in env.items()))
            docker("network", "create", "--internal", "--label", LABEL + "=" + owner, network)
            start_db = ("mkdir -p /tmp/qa-tls; cp /qa/server.crt /qa/server.key /qa/pg_hba.conf /tmp/qa-tls/; "
                        "chown -R postgres:postgres /tmp/qa-tls; chmod 700 /tmp/qa-tls; "
                        "chmod 600 /tmp/qa-tls/server.key; exec docker-entrypoint.sh postgres "
                        "-c ssl=on -c ssl_cert_file=/tmp/qa-tls/server.crt "
                        "-c ssl_key_file=/tmp/qa-tls/server.key -c hba_file=/tmp/qa-tls/pg_hba.conf "
                        "-c log_statement=none -c log_min_messages=fatal")
            docker("run", "-d", "--pull=never", "--platform=linux/amd64", "--name", database,
                   "--label", LABEL + "=" + owner, "--network", network, "--network-alias", "qa-db",
                   "--network-alias", "qa-db-wrong", "--memory=256m", "--memory-swap=256m",
                   "--tmpfs", "/var/lib/postgresql/data:rw,nosuid,size=128m",
                   "--env-file", str(folder / "pg.env"), "--mount", f"type=bind,src={tls},dst=/qa,readonly",
                   "--entrypoint", "sh", images["postgres"], "-ec", start_db)

            def sql(query, timeout=25):
                return docker("exec", "-i", database, "psql", "-XAt", "-v", "ON_ERROR_STOP=1",
                              "-U", "qa_admin", "-d", "qa_counterparty", stdin=query, timeout=timeout)

            def db_ready():
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    try:
                        need(sql("SELECT 1;", timeout=min(25, deadline - time.monotonic())) == "1")
                        need(time.monotonic() < deadline)
                        return {"ready": True}
                    except Exception:
                        time.sleep(min(0.2, max(0, deadline - time.monotonic())))
                raise RuntimeError("database_start_deadline")

            check("disposable_database_ready", db_ready)
            need(170000 <= int(sql("SHOW server_version_num;")) < 180000)
            sql("CREATE ROLE qa_app LOGIN PASSWORD '" + password + "';\n"
                "ALTER DATABASE qa_counterparty OWNER TO qa_app;\n"
                "GRANT USAGE, CREATE ON SCHEMA public TO qa_app;\n")

            def release(variant, expression, success=True, tls_reason=None):
                name = owner + "-" + variant + "-" + str(len(planned))
                planned.append(name)
                ca = "wrong-ca.crt" if variant == "wrong-ca" else "ca.crt"
                command = ["docker", "run", "--rm", "--pull=never", "--platform=linux/amd64",
                           "--name", name, "--label", LABEL + "=" + owner, "--network", network,
                           "--memory=256m", "--memory-swap=256m", "--pids-limit=128",
                           "--env-file", str(folder / (variant + ".env")), "--mount",
                           f"type=bind,src={tls / ca},dst=/qa-ca.pem,readonly",
                           "--entrypoint", "/app/bin/counterparty_review", images["app"], "eval", expression]
                result = subprocess.run(command, capture_output=True, text=True, timeout=45)
                captured = (result.stdout + result.stderr).lower()
                need((result.returncode == 0) == success)
                if success:
                    need("qa_ok" in captured)
                else:
                    need(any(reason in captured for reason in tls_reason))
                return {"exit_success": result.returncode == 0,
                        "tls_rejection_confirmed": not success}

            probe = ("Application.ensure_all_started(:ssl); Application.ensure_all_started(:postgrex); "
                     "Application.ensure_all_started(:ecto_sql); Application.load(:counterparty_review); "
                     "{:ok, _} = CounterpartyReview.Repo.start_link(connect_timeout: 2_000); "
                     "%{rows: [[true]]} = CounterpartyReview.Repo.query!("
                     "\"SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()\", [], timeout: 5_000); "
                     "IO.puts(\"QA_OK\")")
            check("matching_ca_and_hostname_verified_tls", lambda: release("good", probe))
            check("wrong_ca_rejected", lambda: release("wrong-ca", probe, False, ["unknown ca", "unknown_ca"]))
            check("wrong_hostname_rejected", lambda: release("wrong-host", probe, False,
                                                              ["hostname_check_failed", "hostname mismatch"]))
            check("positive_tls_control_after_rejections", lambda: release("good", probe))
            migrate = "CounterpartyReview.Release.migrate(); IO.puts(\"QA_OK\")"
            check("release_migrations", lambda: release("good", migrate))
            versions = sql("SELECT version FROM schema_migrations ORDER BY version;")
            need(versions.splitlines() == [str(20260917000000 + i * 100) for i in range(4)])
            check("migration_rerun_is_idempotent", lambda: release("good", migrate))
            need(sql("SELECT version FROM schema_migrations ORDER BY version;") == versions)

            docker("run", "-d", "--pull=never", "--platform=linux/amd64", "--name", app,
                   "--label", LABEL + "=" + owner, "--network", network, "--network-alias", "qa-app",
                   "--memory=256m",
                   "--memory-swap=256m", "--cpus=0.1", "--pids-limit=128", "--security-opt=no-new-privileges",
                   "--env-file", str(folder / "good.env"), "--mount",
                   f"type=bind,src={tls / 'ca.crt'},dst=/qa-ca.pem,readonly", images["app"])
            # No credentials or mounts. This helper never runs the application or
            # its inherited healthcheck; its CPU is outside the tested app cgroup.
            helper_id = docker("run", "-d", "--pull=never", "--platform=linux/amd64", "--name", helper,
                               "--label", LABEL + "=" + owner, "--network", network,
                               "--memory=64m", "--memory-swap=64m", "--pids-limit=32",
                               "--security-opt=no-new-privileges", "--read-only", "--no-healthcheck",
                               "--entrypoint", "python", images["app"], "-B", "-c",
                               "import signal; signal.pause()")
            a, b = ContainerClient(helper_id, "qa-app"), ContainerClient(helper_id, "qa-app")

            def ready():
                started = time.monotonic()
                deadline = time.monotonic() + 60
                observation = {"last_http_status": None, "last_error_category": None, "probe_count": 0}
                report.setdefault("readiness_observations", []).append(observation)
                while time.monotonic() < deadline:
                    try:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            break
                        observation["probe_count"] += 1
                        observation["last_http_status"] = a.request("GET", "/", timeout=min(25, remaining))[0]
                        observation["last_error_category"] = None
                        need(observation["last_http_status"] == 200)  # Health alone does not query the database.
                        need(time.monotonic() < deadline)
                        observation["elapsed_seconds"] = round(time.monotonic() - started, 3)
                        return {"http_status": 200}
                    except Exception as error:
                        observation["last_error_category"] = error_category(error)
                        time.sleep(min(0.3, max(0, deadline - time.monotonic())))
                observation["elapsed_seconds"] = round(time.monotonic() - started, 3)
                raise RuntimeError("application_start_deadline")

            check("application_reads_migrated_tls_database", ready)
            form_a, form_b = bootstrap(a), bootstrap(b)
            need(a.headers["Cookie"] != b.headers["Cookie"])
            shared_key = str(uuid.uuid4())

            def create(client, form):
                body = urllib.parse.urlencode(dict(form, idempotency_key=shared_key,
                                                   name="Synthetic Database QA GmbH", country="DE", lei="")).encode()
                status, headers, _ = client.request("POST", "/reviews", body)
                need(status == 302)
                path = headers.get("location", "")
                need(path.startswith("/reviews/") and str(uuid.UUID(path.rsplit("/", 1)[1])) == path.rsplit("/", 1)[1])
                return path

            paths = []
            def create_and_scope():
                paths.extend([create(a, form_a), create(b, form_b)])
                need(paths[0] != paths[1])
                for client, own, foreign, form in ((a, paths[0], paths[1], form_a), (b, paths[1], paths[0], form_b)):
                    need(client.request("GET", own)[0] == 200)
                    need(client.request("GET", foreign)[0] == 404)
                    need(client.request("GET", foreign + "/export")[0] == 404)
                    for action in ("delete", "replay"):
                        need(client.request("POST", foreign + "/" + action,
                                            urllib.parse.urlencode(form).encode())[0] == 404)
                    _, _, page = client.request("GET", "/")
                    need(own.encode() in page and foreign.encode() not in page)
                need(sql("SELECT count(*) = 2 AND count(DISTINCT owner_hash) = 2 "
                         "AND bool_and(owner_hash ~ '^[0-9a-f]{64}$') FROM review_runs;") == "t")
                return {"visitor_count": 2, "distinct_records": 2, "foreign_reads_and_mutations": 404,
                        "same_idempotency_key_is_owner_scoped": True}

            check("http_owner_isolation_and_hashed_storage", create_and_scope)
            def restart_persistence():
                docker("restart", "--time", "7", app, timeout=20)
                ready()
                for client, own, foreign in ((a, paths[0], paths[1]), (b, paths[1], paths[0])):
                    status, _, raw = client.request("GET", own)
                    need(status == 200 and b"Synthetic Database QA GmbH" in raw)
                    need(client.request("GET", foreign)[0] == 404)
                need(sql("SELECT count(*) FROM review_runs;") == "2")
                return {"preserved_records": 2, "original_cookies_still_scoped": True}

            check("records_and_ownership_survive_application_restart", restart_persistence)
            need(sql("SELECT bool_and(s.ssl) FROM pg_stat_ssl s JOIN pg_stat_activity a USING (pid) "
                     "WHERE a.usename = 'qa_app' AND a.datname = 'qa_counterparty';") == "t")
            check("application_connections_use_tls", lambda: {"verified": True})
            need(sql("SELECT count(*) FROM oban_jobs WHERE args->>'operation' = 'analyze';") == "0")
            check("no_model_jobs_requested", lambda: {"analyze_jobs": 0, "external_network": "disabled"})
    except Exception as error:
        report["fatal_error_category"] = error_category(error)
    finally:
        # Snapshot before destroying evidence, including failed startup. Never read logs.
        report["resources"] = diagnostics()
        for name in reversed(planned):
            container_id = owned("container", name)
            if container_id:
                try:
                    docker("rm", "-f", container_id, timeout=15)
                except Exception:
                    report["cleanup_failed"] = True
        network_id = owned("network", network)
        if network_id:
            try:
                docker("network", "rm", network_id)
            except Exception:
                report["cleanup_failed"] = True
        try:
            need(not docker("container", "ls", "-aq", "--filter", "label=" + LABEL + "=" + owner))
            need(not docker("network", "ls", "-q", "--filter", "label=" + LABEL + "=" + owner))
            report["owned_resources_removed"] = True
        except Exception:
            report["cleanup_failed"] = True
        os.umask(old_umask)
        app_resources = report["resources"]["app"]
        limits = app_resources.get("limits", {})
        metrics = app_resources.get("metrics", {})
        events = metrics.get("memory_events", {})
        report["resource_envelope_verified"] = (
            app_resources.get("running") is True and app_resources.get("oom_killed") is False
            and limits.get("Memory") == limits.get("MemorySwap") == 256 * 1024 * 1024
            and limits.get("NanoCpus") == 100_000_000
            and 0 < metrics.get("memory_peak_bytes", 0) <= 256 * 1024 * 1024
            and events.get("oom") == events.get("oom_kill") == 0)
        report["passed"] = (len(report["checks"]) == len(CHECKS)
                            and {row["name"] for row in report["checks"]} == CHECKS
                            and all(row["passed"] for row in report["checks"])
                            and "fatal_error_category" not in report
                            and report["resource_envelope_verified"]
                            and report.get("owned_resources_removed") is True
                            and not report.get("cleanup_failed"))
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"passed": report["passed"], "checks": len(report["checks"]), "receipt": str(args.output)}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
