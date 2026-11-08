# Candidate Decisions

Material decisions recorded during the exercise. Format per decision:
Observation → Decision → Reason → Risk / trade-off → Verification.

---

## Environment constraints discovered before any change

Read-only survey of GCP project `candidate-7sol-test`, run before touching anything:

```bash
gcloud projects get-iam-policy candidate-7sol-test        # who holds which role
gcloud services list --enabled                            # enabled APIs
gcloud container clusters list; gcloud artifacts repositories list
gcloud compute networks list; gcloud iam service-accounts list
gcloud logging read 'logName:"cloudaudit.googleapis.com%2Factivity"'   # who created / deleted what
curl -X POST https://cloudresourcemanager.googleapis.com/v1/projects/candidate-7sol-test:testIamPermissions \
  -d '{"permissions":["resourcemanager.projects.setIamPolicy","container.clusterRoleBindings.create", ...]}'
gcloud iam roles describe roles/editor                    # actual permissions in the role
gcloud resource-manager org-policies describe <constraint> --project=candidate-7sol-test --effective
```

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| E1 | Candidate identity has `roles/editor` only | `gcloud projects get-iam-policy` | — |
| E2 | No `*.setIamPolicy` anywhere (project, service account, Artifact Registry, bucket) | `testIamPermissions`; `roles/editor` contains zero `setIamPolicy` permissions | Terraform IAM bindings / Workload Identity bindings cannot be applied by the candidate (403) |
| E3 | No Kubernetes RBAC write (`container.{clusterRoles,clusterRoleBindings,roles,roleBindings}.create` absent) | `roles/editor` has only `get`/`list` on RBAC | Argo CD cannot be installed in-cluster (its install creates ClusterRoles/Bindings) |
| E4 | Can create GKE, Artifact Registry, buckets, Cloud Build builds, namespaces and all namespaced workload objects | `testIamPermissions` | Workloads can be deployed |
| E5 | Every candidate granted access to this project received `roles/editor` only | Admin Activity audit log (`SetIamPolicy`) | E2/E3 are intentional — design within them, do not seek escalation |
| E6 | Leftover resources from a previous candidate: VPC `payment-vpc`, subnet `payment-gke`, router/NAT `payment-router`, service accounts `payment-api`, `gke-payment-nodes` | `gcloud compute networks list`, audit log | Not ours, not in our state: do not modify, import or delete. Baseline `iam.tf` would collide (409) on `payment-api` |
| E7 | Another candidate was granted access on the same day | Audit log | Resource names must be unique to avoid collisions |
| E8 | `default` VPC allows SSH/RDP from `0.0.0.0/0` | `gcloud compute firewall-rules list` | Project-level risk outside repo scope; noted for the owner, not changed. Our cluster uses its own VPC |

---

## Module 1 — Risk triage

Severity: **P0** immediate security / availability risk · **P1** important production risk · **P2** hardening / maintainability.
Plan column: module where it is fixed, or why it is deferred.

### P0 — immediate

| ID | Risk | Location | Why P0 | Plan |
|---|---|---|---|---|
| P0-1 | Application service account holds `roles/owner` | `terraform/iam.tf:6-10` | Any workload compromise = full project takeover (IAM, data, billing) | M2: delete — the app calls no GCP API |
| P0-2 | Long-lived SA JSON key: created by Terraform, exported as output, stored in state, written to disk in CI | `terraform/iam.tf:12-19`, `.gitlab-ci.yml:7,15,26` | Combined with P0-1 this is an **owner key** living in state and CI variables; `sensitive = true` only hides it from CLI output | M2/M4: remove keys; CI uses OIDC → Workload Identity Federation |
| P0-3 | Plaintext credentials in Git and in logs (MongoDB root password, API shared secret) | `gitops/base/payment-api/deployment.yaml:28`, `configmap.yaml:7`, `tests/fixtures/pod-logs-previous.txt:2` | Anyone with repo or log read access has DB root. Treat as **compromised → rotate** | M5: remove from Git, reference a Secret supplied out-of-band; rotation is an owner action |
| P0-4 | Container runs `privileged: true` (and as root) | `deployment.yaml:49-50`, `application/Dockerfile:6-9` | Container escape → node → node SA credentials | M3/M5: drop privileged, non-root, read-only rootfs, drop ALL caps, seccomp |
| P0-5 | GKE control plane reachable from `0.0.0.0/0`, nodes have public IPs | `terraform/gke.tf:19-24` | Internet-exposed API server for a payment cluster | M2: private nodes + narrowed authorized networks |
| P0-6 | Production delivery path is broken and unsafe: overlay fails to render (patch targets `wrong-payment-api-name`); Argo CD prod app deploys **base** into `default` with auto-sync + prune from `HEAD`; CI also `kubectl apply`s prod on every push to `main` | `gitops/overlays/production/patch-deployment.yaml:4`, `argocd/production.yaml:10-18`, `.gitlab-ci.yml:20-27` | Production runs the wrong spec (2 CPU / 4Gi, `latest`, 2 replicas, `default` ns) and two writers fight over cluster state | M5 (overlay + Argo), M4 (CI out of prod) |
| P0-7 | Active outage per fixtures: readiness probe on `:8081` (app listens on `:8080`) → no pod ever Ready → Service has no endpoints; containers `OOMKilled`; replacement pods unschedulable | `deployment.yaml:33-38,45-48`, `tests/fixtures/*` | Service is fully down | M3 |

### P1 — important production risk

| ID | Risk | Location | Plan |
|---|---|---|---|
| P1-1 | Mutable image references (`latest`, `rc`, unqualified `payment-api:latest`); CI pushes to GitLab registry while overlays pull from Artifact Registry; nothing writes the built identity back to Git | `deployment.yaml:19-20`, overlays `kustomization.yaml:9`, `.gitlab-ci.yml:6,18` | M4/M5: build once, reference by digest per environment |
| P1-2 | Requests 2 CPU / 4Gi with no limits; no memory bound | `deployment.yaml:45-48` | M3 |
| P1-3 | Aggressive liveness (2s delay, 2s period), no startup probe | `deployment.yaml:39-44` | M3 |
| P1-4 | HPA `minReplicas: 2` silently overrides production's 5 replicas; `spec.replicas` + HPA + Argo self-heal fight | `hpa.yaml:10`, `patch-deployment.yaml:6` | M5 |
| P1-5 | PDB `minAvailable: 2` with 2 replicas allows zero voluntary disruptions → node drains / upgrades block | `pdb.yaml:6` | M5 |
| P1-6 | NetworkPolicy allows all ingress and egress; cluster has no enforcement enabled | `network-policy.yaml:12-15`, `gke.tf` | M2 (Dataplane V2) + M5 (real policy) |
| P1-7 | No Workload Identity; nodes use default SA with `cloud-platform` scope; pods can read node credentials from metadata | `gke.tf:11-17` | M2 |
| P1-8 | `deletion_protection = false`; local state only (no remote backend, locking, encryption, env separation) | `gke.tf:6`, `backend.tf.example` | M2 |
| P1-9 | Argo CD: `default` AppProject (no source/destination restriction), placeholder `repoURL`, tracks `HEAD`, no namespace bootstrap | `argocd/*.yaml` | M5 |
| P1-10 | CI has no tests, SAST, dependency / secret / image scanning, SBOM, signing, protected environment; `docker:latest` + privileged dind; registry password on CLI | `.gitlab-ci.yml` | M4 |

### P2 — hardening / maintainability

| ID | Risk | Location | Plan |
|---|---|---|---|
| P2-1 | Provider constraint `>= 5.0` (resolves to 8.x today), no lock file | `terraform/versions.tf:7` | M2 |
| P2-2 | Single default node pool, no system/workload separation, no autoscaling, no release channel / maintenance window | `gke.tf:8-17` | M2 |
| P2-3 | Base images not pinned by digest; full Debian runtime; `COPY . .` | `application/Dockerfile` | M4 |
| P2-4 | `APP_ENV=production` hard-coded in base (dev/staging report production); ConfigMap never consumed; `LOG_LEVEL: debug` in base | `deployment.yaml:25-26`, `configmap.yaml:6` | M5 |
| P2-5 | No Go tests; smoke scripts assert status only | `application/`, `tests/` | M4 |
| P2-6 | No graceful shutdown on SIGTERM | `application/src/main.go:35-36` | M3 (small, prevents dropped requests on rollout) |
| P2-7 | `validate.sh` silently skips when tools are missing; no `terraform validate` | `scripts/validate.sh` | M4 |
| P2-8 | Ansible uses `shell` for everything: not idempotent, restarts nginx every run | `ansible/playbook.yml` | Deferred unless time allows: no reachable host (inventory IP does not exist), lowest blast radius |
| P2-9 | Docs reference `gitlab/.gitlab-ci.yml`; file is at repo root | `docs/EXERCISE.md:74` | Noted only |

---

## Decision 1 — Fix order follows severity, not module order

### Observation
P0 items span Terraform, manifests and CI. P0-6 and P0-7 mean production is currently down *and* cannot be redeployed correctly.

### Decision
1. Restore a correct, renderable production spec (M3 + M5) — stops the outage class of risk.
2. Remove credential / privilege exposures (M2 IAM + keys, M5 secrets, M3 privileged).
3. Then supply chain (M4), then hardening (P2).

### Reason
Availability of a payment service and credential exposure are both P0, but credential exposure in a *baseline repo* is already past (rotation is required regardless); a broken delivery path blocks every other fix from reaching production.

### Risk / trade-off
Credentials stay valid until rotated by the owner; removing them from Git does not un-leak them.

### Verification
Behavioural findings were reproduced, not inferred: `kubectl kustomize gitops/overlays/production` fails with `no matches for Id Deployment.v1.apps/wrong-payment-api-name`; `go test ./...` reports no test files; `terraform providers` resolves `>= 5.0` to 8.10.0. Triage was cross-checked by an independent review pass that was not shown these conclusions. Each later module records its own verification.

---

## Decision 2 — Work within Editor-only sandbox permissions

### Observation
E2, E3, E5: no IAM writes, no RBAC writes, intentionally.

### Decision
- Do **not** request or engineer an escalation (no legacy ABAC, no Config Sync bootstrap of cluster-admin, no reuse of node credentials from pods, no SA keys).
- Remove IAM that is not needed (the app uses no GCP APIs → no application GSA).
- Keep least-privilege IAM that *is* needed (dedicated node SA) as code applied by the project owner; the sandbox uses the default compute SA, mitigated by Workload Identity (`GKE_METADATA`) so pods cannot reach node credentials.
- Run Argo CD **outside** the sandbox cluster (hub-spoke: local management cluster → GKE spoke).

### Reason
Separation of duties: a delivery identity should not be able to grant itself IAM. Hub-spoke Argo CD is a common production topology, not a workaround.

### Risk / trade-off
Sandbox node SA is broader than production design. Hub credentials in the sandbox are a short-lived user token; production would use a GSA with `roles/container.developer` via Workload Identity.

### Verification
Recorded with the deployment evidence (added at deploy time).
