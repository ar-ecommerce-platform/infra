# Platform Runbook

Local, offline operation of the `ar-ecommerce-platform` stack.

## Services & ports

| Service | Port | Notes |
|---|---|---|
| discovery-server | 8761 | Eureka registry; UI at http://localhost:8761 |
| config-server | 8888 | Spring Cloud Config, **native** backend over a mounted `config-repo` |
| api-gateway | **8080** | the only entry point clients use; routes `/api/**`, enforces JWT, CORS |
| auth-service | 8081 | register / login / validate; issues HS256 JWT |
| order-service | 8082 | orchestrates product + inventory + payment + notification |
| product-service | 8083 | seeded catalog (ids 1..5) |
| inventory-service | 8084 | stock; product 5 seeded low (qty 3) for the out-of-stock demo |
| payment-service | 8085 | approves everything at/below `PAYMENT_AUTO_DECLINE_ABOVE_CENTS` (default 500000) |
| notification-service | 8086 | in-memory; logs + stores notifications |
| user-service | 8087 | user profiles (H2) |

By default the six data services run on in-memory **H2** — fast, and **data resets on every
restart**. The PostgreSQL overlay (below) makes data persist.

## Run it (Docker — supported path)

```bash
cp infra/compose/.env.example infra/compose/.env   # then edit JWT_SECRET
docker compose -f infra/compose/docker-compose.yml up -d --build
docker compose -f infra/compose/docker-compose.yml ps      # wait for healthy
pwsh infra/scripts/demo-flow.ps1
docker compose -f infra/compose/docker-compose.yml down
```

First build pulls base images + all Gradle dependencies; expect several minutes.

## Run it against PostgreSQL (`prod` profile)

Add the overlay. It starts one `postgres:16` container (a database per service),
sets `SPRING_PROFILES_ACTIVE=prod`, and each service runs **Flyway** migrations then
`ddl-auto: validate`.

```bash
docker compose -f infra/compose/docker-compose.yml -f infra/compose/docker-compose.postgres.yml up -d --build
```

- Data now survives `docker compose ... restart <service>`.
- `docker compose ... down -v` drops the `pgdata` volume (full reset).
- Inspect: `docker exec -it postgres psql -U ecom -d orderdb` → `\dt`, `select * from orders;`
- Migrations live in each service at `src/main/resources/db/migration/V*.sql`; the H2 dev
  profile keeps `ddl-auto: update` and has Flyway disabled.

## Run it (no Docker)

```powershell
pwsh infra/scripts/run-local.ps1            # build + launch all 10
pwsh infra/scripts/run-local.ps1 -Stop      # stop them
```

Needs `JAVA_HOME` pointing at a JDK 21 (the repo has Corretto 21 under `~/.jdks`).

## API docs (Swagger)

Each service serves its own Swagger UI at `http://localhost:<port>/swagger-ui.html`
(OpenAPI JSON at `/v3/api-docs`) — e.g. product-service at http://localhost:8083/swagger-ui.html.

## The demo flow

`infra/scripts/demo-flow.ps1` drives everything through `http://localhost:8080`:

1. `POST /api/auth/register` → 201
2. `POST /api/auth/login` → `{ token, tokenType, expiresInMs }`
3. `GET /api/products` (Bearer token) → 5 products
4. `GET /api/inventory/{id}`
5. `POST /api/orders` `{ userId, items:[{productId,quantity}] }` → `status: CONFIRMED`, `totalCents`, `paymentId`
6. `GET /api/payments/{paymentId}` → `APPROVED`
7. `GET /api/notifications?userId=…` → the `ORDER_CONFIRMED` entry
8. `GET /api/orders?userId=…`

Failure paths it also checks: no token → 401; over-stock (product 5, huge qty) → 409 `REJECTED_STOCK`; total above the ceiling → 402 `PAYMENT_FAILED`.

For manual poking, `infra/http/platform.http` runs the same flow from IntelliJ's HTTP client
(or the VS Code REST Client), capturing the token and ids between requests.

## Testing

| Layer | Where | Runs in |
|---|---|---|
| Unit (JUnit 5 + Mockito + AssertJ) | each service `src/test` | `./gradlew test` |
| Controller slice (`@WebMvcTest` + MockMvc) | each service | `./gradlew test` |
| Repository slice (`@DataJpaTest`) | auth, user, product, order | `./gradlew test` |
| Integration — real Postgres (`@SpringBootTest` + Testcontainers `@ServiceConnection`) | `order-service` | `./gradlew test` (needs Docker) |
| End-to-end API (REST Assured, through the gateway) | `e2e-tests/` | `./gradlew test` — self-skips when the stack is down |
| Coverage | JaCoCo report per service | `build/reports/jacoco/` |

The `order-service` integration test is what proved the placement flow persists a
`REJECTED_STOCK` / `PAYMENT_FAILED` order as an audit record even though the call ends in an
exception — the writes are short independent transactions (`OrderTransactions`), not one
transaction spanning the external HTTP calls.

## Security & secrets

- **No secret is committed.** `infra/compose/.env` is gitignored; `infra/compose/.env.example` is the committed contract.
- Values reach the apps only as environment variables; `application.yml` files contain `${VAR}` references with obviously-non-production dev fallbacks.
- **Local dev:** gitignored `.env`. **CI:** GitHub Environment secrets + OIDC federation to the cloud (no stored cloud creds). **Prod:** Azure Key Vault / AWS Secrets Manager read via managed identity / IAM role. Same variable names at every layer; only the source changes.
- `gitleaks` in pre-commit + CI is the guardrail (to be wired in the CI phase).
- The `NVD_API_KEY` in the per-repo `.env` files was never pushed (gitignored) but has been seen by tooling — reissue it at nvd.nist.gov; it is a free, read-only, low-value key.
- Treat any secret an AI coding tool has read as disclosed: disposable for dev keys, rotate for anything production.

## "Sign in with Microsoft 365" (optional)

The gateway accepts a token from **either** issuer: the local `auth-service` (always) and
Microsoft Entra ID (only when `ENTRA_ISSUER_URI` is set — leave it blank and the demo runs with
zero Azure dependency).

To enable it:

1. Azure Portal → **App registrations** → new registration `ar-ecommerce-platform`.
2. **Expose an API** → Application ID URI `api://<client-id>` → add scope `access_as_user`.
3. Put these in `infra/compose/.env`:
   ```
   ENTRA_ISSUER_URI=https://login.microsoftonline.com/<tenant-id>/v2.0
   ENTRA_CLIENT_ID=<client-id>
   ```
4. Restart the gateway. Get a token with
   `az account get-access-token --resource api://<client-id>` and call `/api/orders` with it.

Redirect URIs (web `http://localhost:5173`, mobile custom scheme) are a client concern and come
with the frontend / mobile apps.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `port is already allocated` | another process on 8080–8888/8761; stop it or change the host port mapping in `docker-compose.yml` |
| Gradle can't find JDK 21 | `export JAVA_HOME=~/.jdks/corretto-21.0.7` (or let `org.gradle.java.installations.auto-download=true` fetch it) |
| a service stays `unhealthy` | `docker compose ... logs <service>`; usually still starting — `start_period` is 60s |
| `config-server` unhealthy | check the `../../config-repo` bind mount resolved; `curl localhost:8888/auth-service/default` |
| gateway 503 on `/api/...` | the target service hasn't registered in Eureka yet — check http://localhost:8761 |
| rebuild one service | `docker compose ... up -d --build <service>` |

## Deferred — the next lessons

- ~~Postgres + prod profiles~~ — **done**: `docker-compose.postgres.yml` overlay, per-service Flyway migrations, `ddl-auto: validate`. Next here: connection pooling tuning, one Postgres *role* per service, and a managed instance in cloud.
- **Event-driven notifications** — order-service publishes `OrderConfirmed` to RabbitMQ/Kafka; notification-service consumes it (choreography vs the current synchronous orchestration).
- **Resilience** — Resilience4j retries, timeouts, circuit breakers around the order-service client calls; compensation when a partial stock reservation must be rolled back.
- **RS256 + JWKS** — auth-service signs with a private key and exposes `/oauth2/jwks`; the gateway validates local and Entra tokens the same way. Currently HS256 shared-secret for the local path.
- **Gateway → downstream identity** — forward `X-User-Id` / `X-User-Roles`; per-service resource-server validation.
- **`common` library** — share the JWT helper instead of re-implementing it in auth-service.
- **CI** — workflows are written (`.github/workflows/ci.yml` per repo: build + test + gitleaks, image to GHCR on `main`/`develop`; weekly `security-scan.yml` = OWASP Dependency-Check; nightly `e2e.yml` in `e2e-tests` runs the suite against GHCR images). Left to do: push and confirm green; add SonarCloud + Snyk once accounts exist; JaCoCo 80% gate as a ratchet; consolidate `gradle/quality.gradle` into a `build-conventions` composite build. For the private-repo `e2e.yml`, set a `CI_PAT` secret (or make `infra` public) for the cross-repo checkout.
- **Dependency locking** — regenerate `gradle.lockfile`s with `--write-locks` once dependencies settle.
- **More testing** — Testcontainers integration tests on the other JPA services; consumer-driven contract tests (Spring Cloud Contract / Pact) between order-service and its collaborators; mutation testing (PITest); load tests (k6 / Gatling).
- **Cloud** — Terraform (VPC/RDS/AKS or EKS), Helm charts, Key Vault / Secrets Manager, OIDC federation from GitHub Actions.
- **Observability** — ELK / Prometheus + Grafana, distributed tracing.
- **Clients** — web frontend (MSAL.js) and iOS/Android apps (MSAL); the API is already shaped for them (single gateway, `/api/**` JSON, JWT bearer, CORS).
