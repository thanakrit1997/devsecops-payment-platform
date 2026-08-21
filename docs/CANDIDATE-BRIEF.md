# Candidate Brief — Senior DevSecOps Live Exercise

You are taking ownership of a production-bound service called `payment-api`.

The platform uses:

- GCP and GKE
- Terraform
- Ansible
- GitLab CI/CD
- Kustomize
- Argo CD
- MongoDB
- Redis
- Kafka

The repository contains intentionally imperfect configuration. You are not expected to fix everything.

## Your objectives

1. Identify the highest-risk issues first.
2. Improve the infrastructure and delivery configuration.
3. Troubleshoot the supplied Kubernetes failure.
4. Refactor the CI/CD flow toward secure GitOps.
5. Correct the Kustomize / Argo CD deployment model.
6. Analyze MongoDB, Redis, and Kafka production symptoms.
7. Lead a short incident-response scenario.
8. Record key decisions in `DECISIONS.md`.

## Working method

Use this loop whenever practical:

```text
Observe -> Hypothesis -> Evidence -> Smallest safe change -> Verify
```

You may use official documentation and normal web search.

## Important

Production deployment state should be Git-driven. Kustomize is the required customization mechanism. Do not introduce Helm.
