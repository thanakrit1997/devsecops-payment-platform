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
| P2-6 | No graceful shutdown on SIGTERM | `application/src/main.go:35-36` | M4 (with the application tests; prevents dropped requests on rollout) |
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

---

## Module 3 — Kubernetes production debugging (CrashLoopBackOff)

### Observation — evidence chain from `tests/fixtures/`

| Signal | Source | What it means |
|---|---|---|
| `Last State: Terminated`, `Reason: OOMKilled`, `Exit Code: 137`, `Restart Count: 8` | `pod-describe.txt:8-12` | Process killed for memory (137 = 128 + SIGKILL). CrashLoopBackOff is only the kubelet's back-off after repeated kills |
| Last log line `allocating startup cache`, 5 s after start, then termination | `pod-logs-previous.txt:4-5` | Memory spike during startup |
| `Readiness probe failed: dial tcp 10.20.1.13:8081: connect: connection refused` | `pod-describe.txt:17`, `events.txt:2` | Nothing listens on 8081; the app logs `listening on :8080` |
| `FailedScheduling 0/2 nodes are available: 2 Insufficient cpu, 2 Insufficient memory` | `events.txt:4` | Requests of 2 CPU / 4Gi do not fit next to existing requests |
| Nodes at 83-88 % CPU, 88-91 % memory | `nodes.txt` | Little headroom; supports both the scheduling failure and node-level memory pressure |

### Hypothesis — three independent faults, not one

1. **Restarts**: container is OOM-killed while allocating its startup cache.
2. **No traffic, even if (1) is fixed**: readiness probes port 8081 → pod never Ready → Service has no endpoints. Readiness failure does not restart a pod; it removes it from load balancing.
3. **No self-recovery**: oversized requests → replacement / surge pods cannot be scheduled.

**OOM mechanism is not proven by the fixtures.** The manifest sets no memory limit and `describe` shows requests only. Either a namespace `LimitRange` injected a default limit, or the kernel killed the process under node memory pressure (no limit + node at ~90 %). Evidence that distinguishes them:

```bash
kubectl -n payment-production get limitrange,resourcequota
kubectl -n payment-production get pod <pod> -o jsonpath='{.spec.containers[*].resources}'
kubectl describe node <node> | grep -E 'MemoryPressure|SystemOOM' ; kubectl get events -A --field-selector reason=SystemOOM
kubectl top pod -n payment-production --containers   # + Cloud Monitoring container memory during startup
```

Note: the fixture logs show MongoDB / cache code that does not exist in `application/src/main.go`. The running image is not what Git contains — a direct consequence of mutable `latest` tags (P1-1).

### Full troubleshooting path (live cluster)

```bash
kubectl -n payment-production get deploy,rs,pods -o wide            # which ReplicaSet, how many Ready
kubectl -n payment-production describe pod <pod>                     # Last State, probes, requests/limits, events
kubectl -n payment-production logs <pod> --previous                  # log of the killed container
kubectl -n payment-production get events --sort-by=.lastTimestamp    # probe failures, FailedScheduling
kubectl -n payment-production get endpointslices -l kubernetes.io/service-name=payment-api   # empty => readiness
kubectl top nodes ; kubectl describe nodes | grep -A8 'Allocated resources'                  # requests vs allocatable
kubectl -n payment-production rollout history deploy/payment-api
```

Immediate mitigation in a live incident: roll back by **reverting the Git commit** (Argo CD self-heal would undo a manual `kubectl rollout undo`).

### Decision — minimum safe changes (`gitops/base/payment-api/deployment.yaml`)

| Change | Fault addressed |
|---|---|
| Readiness probe → named port `http` (8080); all probes use the named port | 2 |
| `startupProbe` on `/health` (60 s budget); liveness relaxed to 10 s period | Protects slow startup from liveness kills. **Not** an OOM fix |
| Requests right-sized: base 100m / 128Mi; production 500m / 512Mi via overlay | 3 |
| Memory **limit = request** | OOM becomes a deterministic per-container event instead of a node-level kill of whichever process the kernel picks; scheduler accounting matches real usage |
| Rolling update `maxSurge: 1`, `maxUnavailable: 0` | A rollout never removes a serving pod before its replacement is Ready; a stuck rollout keeps old pods serving |
| `privileged: true` removed, non-root, read-only root FS, drop ALL capabilities, seccomp `RuntimeDefault` | P0-4 (security, not the crash) |

### Risk / trade-off

The startup cache code is not in this repository, so its real peak is unknown. A 512Mi limit will still OOM if the cache needs more. Required follow-up: measure peak container memory at startup and either size request = limit above it, or bound the cache in code. CPU limit deliberately not set (avoids CFS throttling on a latency-sensitive API; requests still drive scheduling and HPA).

### Verification

- Offline: all overlays render; `scripts/validate.sh` asserts production requirements and fails on reintroduced `privileged`, mutable tags, or a lowered HPA floor (negative tests run).
- Live: rollout status, Ready endpoints, restart count and probe events — recorded with the deployment evidence.

---

## Module 5 — Kustomize + Argo CD GitOps

### Observation

| Problem | Location |
|---|---|
| Production patch targets `wrong-payment-api-name` → overlay does not render | `gitops/overlays/production/patch-deployment.yaml:4` |
| Production overlay namespace `default` | `gitops/overlays/production/kustomization.yaml:3` |
| Argo CD production app deploys **base**, into `default`, from `HEAD` | `argocd/production.yaml:10-14` |
| Mutable images everywhere (`latest`, `rc`) | overlays |
| `APP_ENV=production` hard-coded in base (dev / staging claim to be production); ConfigMap never consumed | base |
| HPA `minReplicas: 2` overrides production 5 replicas | `hpa.yaml:10` |
| `default` AppProject: any repo, any destination, any kind | `argocd/*.yaml` |

### Decision

- **Production config lives only in the overlay** (requirement: base not edited for production): namespace `payment-production`, requests 500m / 512Mi (+ 512Mi limit) via `patch-deployment.yaml` (target fixed), HPA floor 5 via a JSON patch, image by **digest**.
- **Replicas = 5 is implemented as HPA `minReplicas: 5`**, and `spec.replicas` is removed from the Deployment. Keeping both makes the HPA and Argo CD self-heal fight. Ambiguity noted: if "exactly 5" is intended, remove the HPA in the production overlay instead.
- **Base is environment-neutral**: no namespace, no registry, no environment name. `APP_ENV` / `LOG_LEVEL` set per overlay through `configMapGenerator` (`behavior: merge`); the generated name hash rolls pods on config change.
- **Every overlay pins a digest.** dev / staging digests are written by CI after a `main` build; production changes only through a reviewed merge request that copies a digest already verified in staging.
- **Namespaces are in Git** (`pod-security.kubernetes.io/enforce: restricted`, annotated `Prune=false` so a Git mistake cannot delete a namespace together with its out-of-band Secret).
- **Argo CD**: dedicated `payment` AppProject restricting source repo, destinations (three namespaces on cluster `payment-gke`) and the resource kinds the overlays render. Applications point at overlays, track `main`, auto-sync with prune + self-heal, plus:
  - `ignoreDifferences` on Deployment `/spec/replicas` with `RespectIgnoreDifferences=true` — removing `spec.replicas` from Git would otherwise make the first client-side apply reset the running Deployment to **1** replica (field present in last-applied config, absent in desired) before the HPA reacts;
  - `PruneLast=true` — the previous hash-suffixed ConfigMap is pruned only after the new pods are healthy, so a failed rollout can still restart old pods.

  Both were found by the independent review pass. `scripts/validate.sh` renders `argocd/` too.
- PDB `maxUnavailable: 1` (works at any replica count; `minAvailable: 2` at 2 replicas blocked every drain). NetworkPolicy becomes default-deny with explicit allows: ingress TCP 8080 from the same namespace, egress DNS to kube-dns and the three data-service ports.

### Reason

Folder-per-environment on one branch keeps one source of truth and makes promotion a one-line, reviewable diff (the digest). Rejected: branch-per-environment (drift, cherry-picks, merge conflicts); an image-updater writing directly to production (bypasses review).

### Risk / trade-off

Production auto-sync means a merged change deploys immediately. Accepted because the gate is the merge (protected branch, CODEOWNERS on `gitops/overlays/production/`), the digest was already verified in staging, and rollout is `maxUnavailable: 0` behind readiness. Placeholder digests (`sha256:000…`) remain until the first build writes real ones. NetworkPolicy egress to data-service ports is not restricted by destination because their location is not defined in this repository.

### Verification

`scripts/validate.sh`: renders all overlays and `argocd/`, asserts production requirements, fails on `privileged`, `:latest`, Deployment `replicas`, or credential literals (negative tests run: HPA floor 4, privileged re-added, tag instead of digest — all rejected). Server-side dry-run and live sync are recorded with the deployment evidence.

---

## Module 2 — Terraform / GCP / GKE

### Observation

| Focus area | Baseline | Location |
|---|---|---|
| IAM / credentials | App SA with `roles/owner`; JSON key created, exported as output, stored in state | `iam.tf` |
| Cluster exposure | Authorized networks `0.0.0.0/0`; no private nodes (public node IPs) | `gke.tf:19-24` |
| Workload identity | Not enabled; pods can read node credentials from the metadata server | `gke.tf` |
| Node / workload separation | Single default pool, default SA, `cloud-platform` scope | `gke.tf:8-17` |
| Upgrade / maintenance | No release channel, no maintenance window | `gke.tf` |
| Deletion safeguards | `deletion_protection = false` | `gke.tf:6` |
| State | Local state; backend only an example | `backend.tf.example` |
| Reproducibility | Provider `>= 5.0` (8.10.0 today, any future major tomorrow), no lock file; runs on the `default` VPC; deprecated `remove_default_node_pool` | `versions.tf`, `variables.tf` |

### Decision

| Area | Change | Reason |
|---|---|---|
| IAM | **Delete** the application SA, its `roles/owner` binding, the key and the key output | The app calls no Google API. Least privilege for a workload with no need is *no identity*, not a smaller role |
| IAM | Dedicated node SA with `roles/container.defaultNodeServiceAccount` + `artifactregistry.reader` on the one repository, behind `manage_iam` | Nodes need logs / metrics / image pull only. `manage_iam = false` + `node_service_account` for identities that cannot write IAM; a precondition stops a silent fallback to the default SA |
| Exposure | Private nodes; public IP endpoint restricted to `master_authorized_networks` (required variable, `0.0.0.0/0` rejected by validation); `gcp_public_cidrs_access_enabled = false`; IAM-authorised DNS endpoint | No public node IPs. API reachable only from listed CIDRs, or with a Google identity that holds `container.clusters.connect` — reviewers do not need an IP allow-list entry |
| Workload identity | `workload_pool` on the cluster, `GKE_METADATA` on every pool | Pods get their own (currently none) identity and cannot reach node credentials — this also contains the sandbox's broader node SA |
| Separation | No default pool. `system` pool (1/zone) for GKE components; dedicated `payment` pool (autoscaling 1-3/zone) tainted `dedicated=payment:NoSchedule` — the Deployment carries the matching toleration + `nodeSelector: pool=payment`; Shielded VM secure boot | System components and application pods cannot starve each other; separate upgrade / scaling characteristics. Tainting the workload pool (not the system pool) cannot leave a system component without a schedulable node |
| Upgrades | `REGULAR` release channel; maintenance window Sat/Sun 00:00-06:00 Asia/Bangkok (`BYDAY=FR,SA` at 17:00 UTC — RRULE days are UTC); node surge upgrade `max_surge 1 / max_unavailable 0`; auto-repair / auto-upgrade | Supported, patched versions with predictable timing; 12 h/week satisfies GKE's ≥ 48 h per 32 days; node upgrades never remove capacity first (works with the PDB from Module 5) |
| Deletion | `deletion_protection = true` **and** `lifecycle { prevent_destroy = true }` | `deletion_protection` is enforced only when the cluster itself is deleted — after `destroy` has already removed the node pools. `prevent_destroy` rejects the whole plan first |
| State | `backend "gcs" {}` with per-environment config (`envs/<env>.gcs.tfbackend`) | GCS backend locks natively; bucket: versioning, uniform access, public-access prevention; encryption at rest by default (CMEK optional). One prefix (or bucket) per environment limits blast radius |
| Reproducibility | Provider `~> 8.10` + committed `.terraform.lock.hcl` (linux_amd64 + darwin_arm64); own VPC / subnet / secondary ranges in code; per-environment `envs/<env>.tfvars`; `name_suffix` for shared projects | Same plan on every machine; nothing depends on hand-made or pre-existing network resources |
| NetworkPolicy enforcement | `datapath_provider = "ADVANCED_DATAPATH"` (Dataplane V2) | Module 5 NetworkPolicies are enforced, not decorative |
| Registry | Artifact Registry repository with `immutable_tags = true` | A pushed tag can never be re-pointed; deployments still pin digests |

### Intentionally not done

- **Cloud NAT** — private nodes reach Artifact Registry / Google APIs via Private Google Access; no workload needs internet egress yet. Add with the first workload that does.
- **Binary Authorization** — enforcement needs attestors and signing in CI (Module 4); enabling it before signing exists would block every deploy.
- **CMEK for etcd / state bucket** — default Google-managed encryption accepted for this scope.
- **CI Workload Identity Federation pool** — belongs with Module 4; it also needs IAM writes.

### Risk / trade-off

The sandbox applies with `manage_iam = false`, so nodes run as the default compute SA (`roles/editor`). Mitigated by `GKE_METADATA` (pods cannot obtain the node token), private nodes and Shielded VMs; the dedicated node SA is ready in code for an identity with IAM rights. Regional cluster = 3 zones × 2 pools: higher cost than zonal, chosen for control-plane and zonal-failure availability of a payment service.

### Verification

- `terraform fmt -check`, `terraform validate` — clean, no deprecation warnings.
- `terraform plan` against the real project (read-only, local backend copy, short-lived token): 6 resources to create with `envs/sandbox.tfvars`; 9 (adds node SA + two bindings) with `manage_iam = true`.
- Negative checks: `master_authorized_networks = {any = "0.0.0.0/0"}` → `Invalid value for variable`; `manage_iam = false` without `node_service_account` → `Resource precondition failed`.
- Independent review pass found three issues, all fixed: `deletion_protection` alone lets `destroy` delete node pools first; maintenance `BYDAY` was shifted a day by UTC evaluation; the workload pool was untainted.
- Apply results are recorded with the deployment evidence.

---

## Module 4 — GitLab CI/CD + DevSecOps

### Observation

| Problem | Location |
|---|---|
| Long-lived SA JSON key echoed to `/tmp` in two jobs (one unused) | `.gitlab-ci.yml:7,15,26` |
| CI `kubectl apply`s production on every push to `main` — a second writer next to Argo CD (and it could not even authenticate: no cluster credentials step) | `.gitlab-ci.yml:20-27` |
| Mutable `:latest` image pushed to the GitLab registry, while overlays pull Artifact Registry | `.gitlab-ci.yml:6,17-18` |
| No tests, SAST, dependency / secret / image scanning, SBOM, signing | — |
| `docker:latest` + privileged `docker:dind`; registry password on the command line; `bitnami/kubectl:latest` | `.gitlab-ci.yml:11-16,22` |
| Runtime image: full Debian, root user, unpinned bases | `application/Dockerfile` |
| No Go tests; no graceful shutdown | `application/src/main.go` |

### Decision — pipeline (`.gitlab-ci.yml`)

| Requirement | Implementation |
|---|---|
| Testing | `unit-test`: gofmt, `go vet`, `go test` (new `src/main_test.go`) |
| SAST | GitLab `Jobs/SAST` template (Semgrep), enabled in MR pipelines (`AST_ENABLE_MR_PIPELINES`) |
| Dependency scanning | `govulncheck` — module + stdlib CVEs reachable from the code |
| Secret scanning | GitLab `Jobs/Secret-Detection` template (gitleaks) |
| Security gate | `security-gate` (stage `gate`, before any build): fails on any High / Critical finding in the SAST or secret-detection report, and fails closed if a report is missing — the templates alone only report |
| IaC / config scanning | `trivy config` on the repository (Dockerfile, manifests, Terraform; HIGH/CRITICAL fail) |
| Manifest + Terraform checks | `scripts/validate.sh manifests` (production requirements) and `terraform fmt/validate` |
| Image build | Cloud Build (`gcloud builds submit`) — no privileged runner / dind; runs as a dedicated build SA that can only push to the one repository and write logs |
| Immutable identity | Tag = commit SHA (repository has immutable tags); every later step uses `IMAGE@sha256:…` passed via dotenv artifact |
| Image scanning | `trivy image --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed` on the digest |
| SBOM | CycloneDX from Trivy, attached as a signed attestation |
| Signing / provenance | `cosign sign` + `cosign attest` keyless (Sigstore; identity = this GitLab pipeline). Cosign binary pinned by version + SHA-256, registry login with the job's short-lived token. Cloud Build records SLSA build provenance for the image |
| GCP authentication | Workload Identity Federation: per-job OIDC `id_token` → STS → short-lived token for `gitlab-ci` SA. Provider accepts only this project's **protected** refs (`terraform/ci.tf`). No key anywhere |
| Promotion | `deploy-dev-staging` commits the digest to the dev + staging overlays; `promote-production` (manual) opens a merge request changing only the production digest |
| Protected production | `promote-production` runs in protected environment `production`; production overlay **and the base it renders from** owned by `@payment/release-approvers`, `CODEOWNERS` itself owned by platform (code-owner approval on protected `main`); Argo CD syncs after merge |
| CI does not own cluster state | CI identity has no Kubernetes permission at all; the only path to a cluster is a Git commit |

Image hardening (`application/Dockerfile`): multi-stage, static `CGO_ENABLED=0` build with `-trimpath`; runtime `distroless/static-debian13:nonroot` (no shell, no package manager, uid 65532); both bases pinned by digest; explicit `COPY` instead of `COPY . .`. Builder moved to Go 1.26 (Go 1.23 is out of support; `go.mod` minimum unchanged). CI tool images are pinned by digest.

Application: graceful shutdown on SIGTERM (`Server.Shutdown`, 20 s < 30 s grace period); handlers extracted into `newMux()` for testing.

### Reason

Every artifact is built once and identified by digest; scanners, signature, SBOM and every environment refer to the same bytes. Promotion is a reviewable Git diff, so the audit trail of "what runs in production, approved by whom" is the Git history.

### Risk / trade-off

- **Not executed**: the repository is delivered on GitHub, so this pipeline has not run on GitLab. Verified: YAML parses and every `script` entry is a string (a `deploy: …` commit message had silently become a YAML mapping — GitLab would reject the file); each job's commands were run locally where tools are available (`go vet/test`, `validate.sh`, `terraform validate`); the build path is exercised with Cloud Build during deployment.
- `security-gate` evaluates the analyzers' own report format; GitLab Ultimate security policies would be the managed alternative.
- `GITOPS_PUSH_TOKEN` is a long-lived project access token (write_repository only, masked, protected, with expiry). A GitLab-native short-lived alternative would remove it.
- Signatures are produced but not yet **enforced** at admission (Binary Authorization / policy controller) — see Module 2.
- WIF, CI and build SAs need IAM writes: in `terraform/ci.tf` behind `manage_iam` (not applicable with the sandbox's editor-only identity).

### Verification

- `go vet ./...`, `go test ./...` pass; the test fails when `/ready` output is changed (mutation check).
- SIGTERM → `shutting down` logged, process exits 0.
- `tests/smoke.sh` passes against the local binary and fails against a closed port.
- `scripts/validate.sh` (both sections) passes; `terraform validate` passes with `ci.tf`; `terraform plan` with `manage_iam = true` creates the WIF pool / provider, CI and build SAs, build bucket and their bindings (24 resources), and still 6 with the sandbox settings.
- An independent review pass of this module found nine pipeline / IAM defects that static checks did not catch (YAML mapping in `script`, check jobs absent from MR pipelines, single-target `trivy config`, missing `serviceusage` / bucket-metadata / build-log permissions, shell-less cosign image and its registry auth, unowned `gitops/base/` and `CODEOWNERS`, non-blocking SAST). All fixed.

---

## Module 6 — Data services (`configs/DATA-SCENARIOS.md`)

Approach for all three: correlate the start time with changes (deploys, config, traffic, batch jobs) before tuning anything; mitigate first, root-cause second.

### MongoDB — latency 20 ms → 900 ms; app CPU 30 %, Mongo CPU 42 %, disk I/O 95 %, connections 78 %

**1. First hypotheses** (CPU is low, disk is saturated → operations are *waiting*, not computing)
1. A query / index regression (new query shape, dropped or unused index) doing collection scans → many documents read from disk.
2. Working set no longer fits the WiredTiger cache → cache misses become disk reads for *every* query.
3. Storage limit reached: provisioned IOPS / throughput of the volume (cloud disk throttling) or a noisy co-tenant.
4. Write-side I/O: bulk writes, index build, TTL deletions, checkpoint / journal pressure, a backup or snapshot.
Connections at 78 % are most likely a *consequence*: slow operations hold connections longer and pools grow.

**2. Evidence**
```
db.currentOp({secs_running: {$gt: 1}})                      # what is running now, planSummary, waiting on what
db.setProfilingLevel(1, {slowms: 100}); db.system.profile   # slow ops: planSummary COLLSCAN, docsExamined vs nreturned, keysExamined
db.coll.find(<top query>).explain("executionStats")
db.serverStatus().wiredTiger.cache   # bytes in cache vs max, pages read into cache/s, app-thread eviction
db.serverStatus().opLatencies, .globalLock.currentQueue, .connections
mongotop / mongostat                 # which collection, reads vs writes
iostat -x (await, %util, r/s vs w/s) + volume IOPS/throughput vs provisioned limit
rs.status()                          # replication lag (majority write waits)
```
plus the deploy / batch-job timeline.

**3. Query/index vs storage**

| Signal | Query / index problem | Storage problem |
|---|---|---|
| Profiler | `COLLSCAN` or `docsExamined / nreturned` ≫ 1, concentrated in a few query shapes / collections | Plans are `IXSCAN` with low examined ratio, yet slow |
| Simple `_id` lookup | Fast | Also slow — everything is slow |
| Disk pattern | Read I/O follows those queries; stops when they are killed | Await high for all I/O; volume at its IOPS / throughput cap; cache-miss rate high across the workload |
| Timeline | Starts with a deploy / new feature | Starts with data growth, a backup, a volume change, a noisy neighbour |

**4. Immediate mitigation**
- Roll back / feature-flag off the change that introduced the query (fastest, safest).
- Kill clearly runaway operations (`db.killOp`) — selectively.
- Shed or pause non-critical load: reports, analytics, batch jobs, backups running on the primary.
- Raise volume performance (larger / faster disk: on GCP, PD size and type drive IOPS; online change).
- Add the missing index only with care: an index build adds I/O to a saturated disk — build at low traffic.
- Keep connection pools bounded with timeouts so the app fails fast instead of piling up.

**5. Longer term**
Slow-query and `COLLSCAN` alerting; index review as part of code review (explain plans for new queries); load test with production-like data volume before release; capacity plan so the working set fits RAM and disk has headroom; isolate analytics on a dedicated (hidden) secondary; SLO on p99 latency.

### Redis — used 15 GB / maxmemory 16 GB, 2.3 M evicted keys, hit rate falling

**What is likely happening**: Redis lives at `maxmemory` and evicts continuously; it is evicting keys that are still needed, so reads miss, fall through to the database (consistent with the MongoDB pressure) and refill the cache — churn. Evictions > 0 means the policy is not `noeviction` (that would surface as write errors instead).

| Area | Investigation | What it tells |
|---|---|---|
| TTL behaviour | `INFO keyspace` (keys vs `expires`, `avg_ttl`); sample with `SCAN` + `TTL`; `expired_keys` rate | Keys written **without TTL** accumulate forever (often a recent code change) |
| Eviction policy | `CONFIG GET maxmemory-policy` | With `volatile-*` and many non-TTL keys, only TTL keys are evictable — the hot cache entries get evicted while stale permanent keys stay. Pure cache → `allkeys-lfu` / `allkeys-lru` |
| Hot keys | `redis-cli --hotkeys` (LFU policy), client metrics, short `MONITOR` sample | Single keys / shards saturating CPU or network |
| Big keys | `redis-cli --bigkeys` / `--memkeys`, `MEMORY USAGE`, `MEMORY STATS`, `mem_fragmentation_ratio` | A few huge hashes / lists / sets consume the memory; fragmentation wastes RSS |
| Cache stampede | Miss bursts aligned with expiry / eviction of popular keys; DB QPS spikes | Many clients recompute the same key at once → DB overload. Fix: single-flight / lock per key, TTL jitter, stale-while-revalidate, early refresh |
| Persistence / replication | `INFO persistence` (`rdb_bgsave_in_progress`, `latest_fork_usec`, AOF rewrite), `INFO replication`, `client-output-buffer-limit` | RDB / AOF-rewrite fork uses copy-on-write: at 15/16 GB a write-heavy fork can push RSS over the host and get OOM-killed; replica full resync needs an RDB plus replication buffer. `maxmemory` must leave headroom (≈ 25-30 %) when persistence or replicas are on. Evictions on the primary propagate as `DEL`s to replicas |

Mitigation: add memory or shards; set TTL on everything cached (and fix the code path that stopped doing so); `allkeys-lfu` for a pure cache; split big keys; protect the database from stampedes; do not mix non-evictable data (sessions, queues, locks) with cache in an instance that evicts. Long term: per-namespace memory budget, alerts on evictions and hit rate, TTL required in code review.

### Kafka — `payment-events` lag: p0 10, p1 15, **p2 892 331**, p3 13

**1. First suspicion**: a problem specific to partition 2, not general under-capacity (the other three are near zero with the same consumers). Either its consumer is **stuck** (offset not moving — poison message in a retry loop, hung call, an open transaction blocking the last stable offset) or the partition is **hot** (a skewed key sends far more traffic there than one consumer can process).

**2. Evidence**
```
kafka-consumer-groups --describe --group <g>     # per partition: CURRENT-OFFSET, LOG-END-OFFSET, LAG, CONSUMER-ID, HOST
```
- Repeat over time: is p2's committed offset moving at all (stuck vs slow)? Is its log-end offset growing faster than the others (produce skew)?
- Is p2 assigned at all (`CONSUMER-ID` = `-`)? Rebalance churn (`max.poll.interval.ms` exceeded) in consumer logs?
- Consumer logs / metrics for the instance owning p2: errors, retries, deserialisation failures, GC, restarts.
- Read the message at the stuck offset (`kafka-console-consumer --partition 2 --offset <n> --max-messages 1`).
- Broker side: leader of p2, ISR / under-replicated partitions, that broker's disk and request latency.
- Key distribution of recent messages on p2 (one merchant / account dominating?).

**3. Would 4 → 20 consumers help? No.** In a consumer group each partition is consumed by at most one member. With 4 partitions, at most 4 consumers do work; 16 would idle. The backlog sits in partition 2 and only its single assigned consumer can drain it. Adding partitions would not move the existing backlog, does not split a single hot key, and changes key → partition mapping (breaking per-key ordering, which matters for payment events). More consumers help only when *all* partitions lag and there are at least as many partitions as consumers.

**4. What makes one partition different**
- Hot / skewed partition key (or a custom partitioner bug).
- Poison message: a record that always fails → the consumer retries forever and never commits.
- The consumer instance owning p2 is unhealthy (slow node, CPU limits, GC pauses, OOM restarts → rebalances).
- Downstream dependency slow only for keys on p2 (e.g. one merchant's database shard).
- `read_committed` consumers blocked by a hanging producer transaction on p2 (last stable offset does not advance).
- p2's leader on a degraded broker (disk, network, ISR shrink); unusually large messages on p2.

Mitigation: poison message → route to a dead-letter topic after N attempts and record the skipped offset (payments: idempotent consumer + replay from the DLT after a fix); stuck / unhealthy consumer → restart or replace that instance; hot key → revisit the key (finer-grained key while preserving the ordering scope that is actually required). Long term: per-partition lag alerts (not only total lag), DLT pattern, idempotent consumers, key-distribution monitoring.

---

## Module 7 — Incident commander (`configs/INCIDENT.md`)

Prepared in writing because this exercise is delivered as a take-home.

```text
15:10 payment-api v2.8.3 deployed      15:25 MongoDB latency rises sharply
15:15 Kafka consumer lag rising         15:28 pod restarts increase
15:20 Redis memory 92 %                 15:30 customer payment failures 37 %
```

### First 5 minutes (15:30-15:35)

1. **Declare SEV-1**: 37 % of customer payments failing (baseline 0.1 %). Open the incident channel / bridge and a timeline document.
2. **Assign roles** — the IC coordinates and decides, and does not debug:

   | Role | Owns |
   |---|---|
   | Incident commander | Priorities, decisions, rollback call, severity |
   | Operations lead | Executes the mitigation (rollback), owns the cluster / Argo CD |
   | SMEs: data (MongoDB, Redis), streaming (Kafka), payment-api owner | Diagnosis in their area, report to ops lead |
   | Communications lead | Status page, customer support, merchants / partners, executives |
   | Scribe | Timeline: every observation, decision, action with timestamp |

3. **Change freeze** for production: no merges to `main` except the incident change; pause non-critical batch / report jobs hitting MongoDB.
4. **Impact assessment** (parallel, not blocking the decision): failure rate by endpoint / payment method / merchant; are failures clean declines or *ambiguous* (timeout after authorisation → possible double charge)? Money-at-risk and reconciliation scope start here.

### Hypothesis and decision

The only change is v2.8.3 at 15:10, and the cascade starts five minutes later in a plausible order: new behaviour fills Redis (e.g. keys without TTL / a new key pattern) → evictions and misses → load shifts to MongoDB → latency → consumers slow down → Kafka lag → timeouts, liveness failures / OOM → restarts → customer failures. Treat **v2.8.3 as the cause until disproved**.

**Decision: roll back v2.8.3 now** — mitigate first, root-cause later.

| Roll back when | Roll forward only when |
|---|---|
| Incident correlates with the deploy (it does) | Rollback is impossible or more dangerous |
| Previous version is known good | The fix is small, understood, tested, and faster than rollback |
| No irreversible change in v2.8.3: check for a non-backward-compatible DB migration or Kafka message-format change first (2 minutes) | A forward-only migration already ran |

Time-box: if this check is not conclusive within ~10 minutes of declaring, roll back anyway.

**How (GitOps)**: revert the production promotion commit (digest back to v2.8.2) and merge with the incident approver → Argo CD syncs. Break-glass if Git / CI is the bottleneck: disable auto-sync on `payment-api-production`, `argocd app rollback` to the previous revision, then make Git match and re-enable auto-sync — never leave Git and the cluster diverged.

### Parallel mitigations (do not make things worse)

- **Redis**: add memory / headroom if possible; **do not `FLUSHALL`** — an empty cache stampedes MongoDB.
- **MongoDB**: shed non-critical reads (reports, analytics), pause batch jobs and backups on the primary.
- **Kafka**: do not scale consumers beyond the partition count; after rollback the backlog drains — confirm consumers are idempotent so replays do not double-process payments.
- **Restarts**: check OOM vs liveness. Restarts under load shrink capacity further; a temporary liveness relaxation is acceptable, a memory-limit increase only with evidence.

### Evidence collection (snapshot before it disappears)

`git diff v2.8.2..v2.8.3` (code + config), Argo CD history; `kubectl get events`, `describe` / `logs --previous` of restarted pods; Redis `INFO memory / stats / keyspace`, `--bigkeys` sample; MongoDB `currentOp`, profiler, `serverStatus`; `kafka-consumer-groups --describe` per partition; dashboards (error rate, latency, saturation) exported with timestamps; error breakdown by endpoint and status code; sample traces.

### Communication

- **Internal**: incident channel update every 15 minutes — impact, what we know, current action, next update time. Short executive summary on severity changes.
- **External**: status page within ~15 minutes of declaring ("Some card payments are failing; we are mitigating; next update 16:00"), customer-support macro, notify payment partners / large merchants if their volume is affected. Facts only, no speculation, always a next-update time.

### Verification of recovery (before standing down)

- Error rate back to ~0.1 % and p99 latency at baseline, sustained for 30 minutes.
- Pod restarts stop; Kafka lag drains to normal **on every partition**; Redis memory / evictions stable and hit rate recovering; MongoDB latency normal.
- Synthetic end-to-end payment succeeds.
- **Reconciliation**: list payments in 15:10-recovery with ambiguous outcomes; resolve each (complete, reverse, or notify) and check for duplicates.
- Then downgrade severity, lift the freeze gradually, final status-page update.

### Post-incident

Blameless post-mortem within 3 working days: timeline, root cause and contributing factors (why did testing not catch it, why did detection take 20 minutes), what went well. Action items with owners and dates; reconciliation report.

### SDLC controls that reduce recurrence

| Control | Effect on this incident |
|---|---|
| Canary / progressive delivery with automated analysis (e.g. Argo Rollouts: error rate, latency, Redis memory) and auto-rollback | 5 % canary would have limited impact and rolled back in minutes |
| Feature flags: deploy ≠ release | Turn the new behaviour off without a rollback |
| Performance test in staging with production-like data and cache size | Cache growth / new query shape found before production |
| Review checklists enforced in CI: TTL on every cache write, explain plan for new queries, backward-compatible (expand / contract) migrations, Kafka schema compatibility | Rollback always possible; known failure modes caught in review |
| SLO burn-rate alerting; per-partition lag, Redis eviction, Mongo slow-query alerts | Detection in minutes, not at 37 % failures |
| Payment-service change windows and rehearsed rollback runbook | Faster, calmer decision |
