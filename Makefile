.PHONY: app-test app-build render-dev render-staging render-production terraform-fmt validate

app-test:
	cd application && go vet ./... && go test -count=1 ./...

app-build:
	cd application && go build ./...

render-dev:
	kubectl kustomize gitops/overlays/dev

render-staging:
	kubectl kustomize gitops/overlays/staging

render-production:
	kubectl kustomize gitops/overlays/production

terraform-fmt:
	terraform -chdir=terraform fmt -check

validate:
	./scripts/validate.sh
