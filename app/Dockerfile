# ======================================================================
# Dockerfile Multi-Stage — Aplicação Rust (Correção Final)
# ======================================================================

# ----------------------------------------------------------------------
# ESTÁGIO 1: A "OFICINA" DE CONSTRUÇÃO (BUILDER)
# ----------------------------------------------------------------------
FROM rust:latest AS builder

WORKDIR /usr/src/app

# Define o ARG. O valor "rust_api" deve ser o 'name' no app/Cargo.toml
ARG BINARY_NAME=rust_api

# 1. Cria o diretório 'src' que o Cargo espera.
RUN mkdir src

# 2. Copia o seu Cargo.toml (de app/) para a raiz.
COPY app/Cargo.toml app/Cargo.lock* ./

# 3. Copia o seu main.rs (de app/main.rs) para DENTRO de src/
COPY app/main.rs ./src/main.rs

# 4. Compila o projeto de verdade.
RUN cargo build --release

# ----------------------------------------------------------------------
# ESTÁGIO 2: A IMAGEM FINAL (RUNTIME)
# ----------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

# Define o ARG de novo, com o mesmo valor padrão
ARG BINARY_NAME=rust_api

# --- A CORREÇÃO ESTÁ AQUI (1/2) ---
#
# "Converte" o argumento de build (ARG) para uma variável
# de ambiente (ENV). O CMD só consegue ler ENV, não ARG.
ENV BIN_NAME=${BINARY_NAME}

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

# Copia o binário usando o ARG (que funciona no build)
COPY --from=builder /usr/src/app/target/release/${BINARY_NAME} /usr/local/bin/

# Adiciona permissão de execução
RUN chmod +x /usr/local/bin/${BINARY_NAME}

USER 1000

ENV RUST_LOG=info

# --- A CORREÇÃO ESTÁ AQUI (2/2) ---
#
# O CMD agora usa a variável de ambiente (ENV) $BIN_NAME,
# que o shell consegue expandir corretamente.
CMD /usr/local/bin/${BIN_NAME}