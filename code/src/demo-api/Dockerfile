# ── Build stage ──────────────────────────────────────────
FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /demo-api .

# ── Runtime stage ────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /demo-api /demo-api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/demo-api"]