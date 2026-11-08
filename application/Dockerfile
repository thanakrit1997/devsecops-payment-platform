# Base images pinned by digest (multi-arch index); bump via MR.
FROM golang:1.26@sha256:cfa27959837144bf4649802ba38e59daffd0dd2a7994aa83daaf113285b0f551 AS build
WORKDIR /src
COPY go.mod ./
COPY src ./src
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/payment-api ./src

# No shell, no package manager, non-root (uid 65532).
FROM gcr.io/distroless/static-debian13:nonroot@sha256:25ac8f0c3b2334a9eb05452266bd4697864a8c8ef0ef71e5e6480d7f92868329
COPY --from=build /out/payment-api /payment-api
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/payment-api"]
