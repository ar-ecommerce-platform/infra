# infra

Operational glue for the `ar-ecommerce-platform`.

```
infra/
├── compose/
│   ├── docker-compose.yml   # the full local stack (10 services, one network)
│   ├── .env.example         # committed contract for the environment variables
│   └── .env                 # your real local values (gitignored)
├── scripts/
│   ├── demo-flow.ps1 / .sh  # end-to-end demo through the gateway
│   └── run-local.ps1        # build + run everything without Docker
└── RUNBOOK.md               # ports, how to run, security, troubleshooting, next steps
```

Quick start:

```bash
cp infra/compose/.env.example infra/compose/.env   # edit JWT_SECRET
docker compose -f infra/compose/docker-compose.yml up -d --build
pwsh infra/scripts/demo-flow.ps1
```

See **[RUNBOOK.md](RUNBOOK.md)** for everything else.

### Not built yet (see RUNBOOK "Deferred")

Kubernetes/Helm manifests, Terraform (VPC/RDS/AKS·EKS), Key Vault / Secrets Manager wiring,
observability stack. The compose stack above is the current, working local environment.
