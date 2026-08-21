# Exercise Modules

## Module 1 — Repository discovery and prioritization

Spend the first 15 minutes reviewing the repository.

Produce a short prioritized list in `DECISIONS.md`:

- P0 — immediate security / availability risk
- P1 — important production risk
- P2 — hardening / maintainability

Do not attempt to fix everything immediately.

---

## Module 2 — Terraform / GCP / GKE

Review the Terraform in `terraform/`.

Improve the highest-risk production issues you can identify. Focus on:

- IAM and credential model
- cluster exposure
- workload identity
- node / workload separation
- upgrade / maintenance posture
- deletion safeguards
- state management
- reproducibility

Verification examples:

```bash
terraform fmt -check
terraform validate
terraform plan
```

Explain anything you intentionally leave unfixed.

---

## Module 3 — Kubernetes production debugging

A rollout is failing.

Initial observation:

```text
payment-api-7f78bc7fd5-j7x9k   0/1   CrashLoopBackOff
payment-api-7f78bc7fd5-m8q2x   0/1   CrashLoopBackOff
```

Use the manifests under `gitops/base/payment-api/` and the supplied fixtures under `tests/fixtures/`.

Treat the fixtures as representative output from a production cluster.

Show your troubleshooting path and make the minimum safe changes required.

Useful evidence may include:

- pod events
- current and previous logs
- readiness / liveness behavior
- endpoints
- resource requests
- environment configuration

---

## Module 4 — GitLab CI/CD + DevSecOps

Review `gitlab/.gitlab-ci.yml`.

Refactor it toward a production-grade software supply chain.

Consider:

- testing
- SAST
- dependency scanning
- secret scanning
- image build
- immutable image identity
- SBOM
- image scanning
- signing / provenance
- GCP authentication
- promotion
- protected production deployment

Do not make GitLab CI directly own production cluster state.

---

## Module 5 — Kustomize + Argo CD GitOps

The base and environment overlays are under `gitops/`.

Production requirements:

- replicas: 5
- CPU request: 500m
- memory request: 512Mi
- production namespace: `payment-production`
- production image must be immutable
- production configuration must not be implemented by editing the base directly

Review the Argo CD applications under `argocd/`.

Correct the GitOps model and verify rendered output.

Examples:

```bash
kustomize build gitops/overlays/dev
kustomize build gitops/overlays/staging
kustomize build gitops/overlays/production
```

---

## Module 6 — Data services

Read `configs/DATA-SCENARIOS.md` and explain your investigation and mitigation approach.

You do not need to install MongoDB, Redis, or Kafka.

---

## Module 7 — Incident commander

Read `configs/INCIDENT.md` only when instructed by the interviewer.

Act as incident commander. Explain priorities, role assignment, mitigation, rollback / roll-forward criteria, verification, communication, and follow-up actions.

---

## Final 10 minutes

Summarize:

- top three risks found
- changes made
- changes not made and why
- how you verified work
- what you would do next before production
