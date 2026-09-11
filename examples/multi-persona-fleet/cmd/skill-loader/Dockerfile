# Build stage: Statically compiled Go binary
FROM golang:1.23-alpine AS builder

WORKDIR /build

COPY main.go .

# Build a statically linked binary with no CGO dependencies
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -ldflags="-w -s" -o skill-loader .

# Final stage: minimal distroless base image
FROM gcr.io/distroless/static:latest

WORKDIR /

# Copy the static binary
COPY --from=builder /build/skill-loader /skill-loader

# Copy the skill catalog and personas into the image
COPY personas /catalog/personas
COPY skills /catalog/skills

ENTRYPOINT ["/skill-loader"]
