# Stage 1: builder
FROM --platform=linux/amd64 rust:latest AS builder
WORKDIR /usr/src/app

COPY app/Cargo.toml ./
RUN mkdir src && echo "fn main() {}" > src/main.rs
RUN cargo build --release

COPY app/main.rs src/main.rs
RUN cargo build --release

# Stage 2: runtime
FROM --platform=linux/amd64 debian:bookworm-slim AS runtime
ARG BINARY_NAME=rust_api
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/src/app/target/release/${BINARY_NAME} /usr/local/bin/

USER 1000
EXPOSE 8080
ENV RUST_LOG=info
CMD ["/usr/local/bin/rust_api"]