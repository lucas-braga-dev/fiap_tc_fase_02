# syntax=docker/dockerfile:1

# ============================================================
# Estágio 1: compilação
# ============================================================
FROM golang:1.21-alpine AS builder

WORKDIR /src

COPY go.mod go.sum* ./

RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/service \
    .

# ============================================================
# Estágio 2: execução
# ============================================================
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

WORKDIR /app

COPY --from=builder --chown=nonroot:nonroot \
    /out/service \
    /app/service

USER nonroot:nonroot

ENV PORT=8004

EXPOSE 8001

ENTRYPOINT ["/app/service"]