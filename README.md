# Counterparty Review

Resolve a company-name discrepancy against public GLEIF records. Inspect identifiers, jurisdiction and entity status, request an evidence-bound AI proposal if useful, then make and export a human decision.

This independent project supports selected incorporated legal forms in Germany, Austria, the Netherlands and Ireland. It does not certify identity or perform credit, sanctions or KYC clearance. Public hosting verification is still in progress.

## Run locally

Prerequisites: Elixir 1.18, Erlang/OTP, Python 3 and a running PostgreSQL server with a Unix socket. Development has been exercised with PostgreSQL 17. The database role must be able to create the development database.

From this directory, set the values for your local PostgreSQL instance. This example assumes socket directory `/tmp`, port `5432` and a database role matching your operating-system username:

```sh
export DB_SOCKET_DIR=/tmp
export DB_PORT=5432
export DB_USER="$(id -un)"
export DB_NAME=counterparty_review_dev
mix deps.get
mix ecto.setup
mix phx.server
```

Open **http://127.0.0.1:54185**. Use that address rather than `localhost`; the HTTP boundary checks the exact origin. Set `PORT` before starting to use a different unprivileged local port. The health endpoint returns `ok` without creating a session:

```sh
curl --fail http://127.0.0.1:54185/health
```

Enter a public corporate legal name and its jurisdiction, optionally with an LEI. **Find company records** starts a GLEIF lookup, not an AI call. Inspect the returned facts, request AI assistance if needed, then accept a selectable record, reject it or leave the review unresolved. Export the review before its retention period ends.

Local AI is optional. Registry lookup and human review remain available without a model.

## Architecture and decision boundary

```text
Phoenix forms → owner-scoped Ecto transaction → PostgreSQL + Oban
                                                    ↓
                                         bounded GLEIF lookup
                                                    ↓
                              saved evidence → optional Python agent
                                                    ↓
                                      validation → human decision
```

- **Phoenix, Bandit and Ecto** serve server-rendered forms, enforce owner scope, CSRF, revisions and evidence hashes, and commit decisions transactionally. No browser JavaScript is required.
- **Oban** runs retrieval and analysis as bounded jobs. Leases, idempotent submission keys and source-attempt limits guard retries and duplicate effects.
- **GLEIF** is the fixed external source. The application retains a normalized evidence snapshot, retrieval time and content hashes. A lookup displays at most five supported candidates and reports truncation; it is not an exhaustive company search.
- **Python agent** has at most two evidence-tool steps and three model calls per analysis. Its tools inspect supplied candidates and retrieve supplied policy text; they cannot browse arbitrary URLs or execute model-written code.
- **Validation** checks references, exact rendered claims, identity conflicts and ambiguity in Python and again in Elixir. A model proposal never accepts a record. The user must decide against the current evidence revision.

Name matching requires the complete normalized legal name. Without an explicit LEI, a terminal `AG` and `Aktiengesellschaft` are treated as equivalent; other aliases and partial names are unsupported. A matching registration ID cannot override an unsupported name, and unresolved ambiguity blocks a proposal. Inspect the source evidence and review the record manually before deciding.

Replay creates another review using the saved evidence snapshot. It does not refresh GLEIF data. JSON exports contain the evidence, model outcome when requested, event history and human decision.

## AI and hosted configuration

Default `AI_PROVIDER=local` expects Ollama at `127.0.0.1:11439` with `qwen3.5:9b`, digest `6488c96fa5faab64bb65cbd30d4289e20e6130ef535a93ef9a49f42eda893ea7`. The agent rejects a different model identity. No model is downloaded automatically and no remote fallback is attempted.

The supplied production release requires:

| Variable | Requirement |
|---|---|
| `PUBLIC_ORIGIN` | Exactly `https://counterparty.prateekmulye.dev` |
| `SECRET_KEY_BASE` | Stable operator-managed secret, at least 64 bytes |
| `DATABASE_URL` | PostgreSQL URL naming host and database, without query options |
| `DATABASE_CA_FILE` | Optional provider CA bundle; otherwise system trust roots are used |
| `AI_PROVIDER` | `workers-ai` |
| `AI_GATEWAY_URL` | Exactly `https://ai.prateekmulye.dev/v1/infer` |
| `AI_GATEWAY_SECRET` | Operator-provisioned Counterparty credential |

Database TLS verifies both certificate and hostname. The Python child inherits only the three AI settings. The private gateway fixes inference to `@cf/qwen/qwen3-30b-a3b-fp8`; visitors need no keys. Each agent step consumes a separate invocation from the shared daily quota. Model or quota failure leaves manual evidence review available.

The container exposes HAProxy on port 8080, forwarding to Bandit on `127.0.0.1:8081`. Run migrations before serving a new release:

```sh
/app/bin/counterparty_review eval 'CounterpartyReview.Release.migrate()'
```

That command runs inside a configured release container. It is not a development setup command.

## Data and operating limits

Submit public corporate records only. Do not enter personal, account, customer or confidential employer data. The lookup sends the company name or supplied LEI to GLEIF. Hosted AI is invoked only on request and sends the saved public evidence to Cloudflare Workers AI.

A signed browser cookie scopes reviews to their owner. Clearing it removes access; there is no account recovery. Review data becomes unavailable after 24 hours. Cleanup deletes expired active database rows on startup and through the running maintenance worker. Users can delete earlier. This does not erase exports or guarantee removal from provider backups or disk remnants.

The source caps retained reviews at 128 overall and 16 per browser owner, with at most 20 active reviews and one review job executing at a time. A run allows three analysis requests. These are admission limits, not throughput or availability promises. The application logs fixed error/status information rather than record bodies, prompts or raw exception text.

GLEIF data uses [CC0 terms](https://www.gleif.org/en/meta/lei-data-terms-of-use). Source availability and completeness can vary. A missing result does not establish that a company does not exist; LEI registration status is distinct from entity status.

## Checks and recovery

Use a separate test database. The configuration refuses any test database name other than `counterparty_review_test`:

```sh
DB_NAME=counterparty_review_test MIX_ENV=test mix ecto.setup
DB_NAME=counterparty_review_test MIX_ENV=test mix test
python3 -B -m unittest discover -s agent -p test_agent.py -v
```

Tests cover ownership, lifecycle transactions, stale decisions, retention bounds, evidence validation and AI error contracts. Model doubles do not establish live-model accuracy.

If PostgreSQL cannot connect, check the socket directory, port and role before rerunning setup. If no selectable candidate appears, inspect the recorded conflict or coverage limit rather than treating absence as proof. If AI is unavailable or abstains, inspect the source facts and make the decision manually.
