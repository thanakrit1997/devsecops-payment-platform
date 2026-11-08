# payment-api — Senior DevSecOps exercise (solution)

The exercise (`docs/CANDIDATE-BRIEF.md`, `docs/EXERCISE.md`) asked to triage and fix an intentionally
defective platform repository. **All answers, decisions and evidence are in [`DECISIONS.md`](DECISIONS.md)**,
one section per module. Commit history follows the modules, starting from the untouched `baseline` commit.

| Module | Where |
|---|---|
| 1 Risk triage (P0 / P1 / P2) | `DECISIONS.md` → Module 1 |
| 2 Terraform / GKE | `terraform/`, `DECISIONS.md` → Module 2 |
| 3 CrashLoopBackOff | `gitops/base/payment-api/deployment.yaml`, `DECISIONS.md` → Module 3 |
| 4 CI/CD supply chain | `.gitlab-ci.yml`, `terraform/ci.tf`, `application/`, `CODEOWNERS`, `DECISIONS.md` → Module 4 |
| 5 Kustomize + Argo CD | `gitops/`, `argocd/`, `DECISIONS.md` → Module 5 |
| 6 MongoDB / Redis / Kafka | `DECISIONS.md` → Module 6 |
| 7 Incident commander | `DECISIONS.md` → Module 7 |
| Ansible (P2) | `ansible/`, `DECISIONS.md` → Ansible |
| Deployment evidence | `DECISIONS.md` → Deployment and verification |

Kubernetes customisation uses **Kustomize** only (no Helm).

## Test locally (no cloud needed)

Requirements: Go ≥ 1.23, `kubectl` (for `kubectl kustomize`), Terraform ≥ 1.6, Docker (optional).

```bash
make app-test            # go vet + unit tests
make validate            # terraform fmt/validate, render all overlays + argocd/, assert production requirements
make render-production   # rendered production manifests

docker build -t payment-api application
docker run -d --rm --name payment-api -p 8080:8080 -e APP_ENV=local payment-api
tests/smoke.sh http://localhost:8080 && docker stop payment-api
```

`scripts/validate.sh` fails if production loses any requirement (namespace `payment-production`, HPA floor 5,
500m / 512Mi requests, image pinned by digest) or regains `privileged`, `:latest`, `spec.replicas`, or one of the
baseline's credential literals (a known-string check, not a general secret scanner — CI runs secret detection).

## Deploy (GCP)

Sandbox values are in `terraform/envs/sandbox.tfvars` (unique `-tn` names, editor-only identity → `manage_iam = false`).

```bash
# 0. state bucket (once)
gcloud storage buckets create gs://candidate-7sol-test-tfstate-tn --location=asia-southeast1 \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://candidate-7sol-test-tfstate-tn --versioning

# 1. infrastructure (from the repository root)
terraform -chdir=terraform init -backend-config=envs/sandbox.gcs.tfbackend
terraform -chdir=terraform apply -var-file=envs/sandbox.tfvars -var 'master_authorized_networks={"operator"="<your-ip>/32"}'

# 2. image (CI does this on Cloud Build), then pin its digest in the overlays and push to Git
docker buildx build --platform linux/amd64 --push \
  -t asia-southeast1-docker.pkg.dev/candidate-7sol-test/payment-tn/payment-api:$(git rev-parse HEAD) application
(cd gitops/overlays/dev && kustomize edit set image payment-api=<image>@<digest>)   # kustomize CLI; same for staging, production
git commit -am "deploy: <sha> to dev, staging, production" && git push

# 3. per environment, before the first sync: namespace, then the Secret (out of Git)
kubectl create namespace payment-<env>        # Argo CD later applies the labels from Git
kubectl -n payment-<env> create secret generic payment-api-secrets \
  --from-literal=MONGODB_URL=... --from-literal=API_SHARED_SECRET=...

# 4. GitOps: register the cluster in Argo CD as "payment-gke", then
kubectl apply -k argocd
```

Access to the cluster API: from an authorized network, or from anywhere with a Google identity that holds
`container.clusters.connect` via the DNS endpoint:
`gcloud container clusters get-credentials payment-production-tn --region asia-southeast1 --dns-endpoint`.

Teardown steps are at the end of `DECISIONS.md`.
