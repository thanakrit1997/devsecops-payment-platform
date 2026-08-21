FROM golang:1.23 AS build
WORKDIR /src
COPY . .
RUN go build -o /out/payment-api ./src

FROM debian:bookworm-slim
COPY --from=build /out/payment-api /usr/local/bin/payment-api
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/payment-api"]
