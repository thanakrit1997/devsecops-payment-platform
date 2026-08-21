.PHONY: app-test app-build render-dev render-staging render-production terraform-fmt validate

app-test:
	cd application && go test ./...

app-build:
	cd application && go build ./...

render-dev:
	kustomize build gitops/overlays/dev

render-staging:
	kustomize build gitops/overlays/staging

render-production:
	kustomize build gitops/overlays/production

terraform-fmt:
	terraform -chdir=terraform fmt -check

validate:
	./scripts/validate.sh
