# ======================================================================
# Dockerfile Multi-Stage — Aplicação Rust
# ======================================================================
#
# O QUE É ESTE ARQUIVO?
# Este é um "Dockerfile Multi-Stage". Pense nele como uma receita com
# duas partes (ou "estágios").
#
# - Estágio 1 ("O Construtor"): Uma grande "oficina" com todas as
#   ferramentas pesadas (compilador de Rust, etc.) para construir
#   nosso programa a partir do código-fonte.
#
# - Estágio 2 ("O Executor"): Um "mini-computador" super leve e limpo
#   que contém APENAS o programa já construído, pronto para rodar.
#
# POR QUE FAZER ISSO?
# O resultado final é uma imagem Docker minúscula e segura.
# A imagem final não carrega o compilador de Rust, código-fonte
# ou qualquer outra ferramenta de desenvolvimento, apenas o essencial.
#
# ======================================================================

# ----------------------------------------------------------------------
# ESTÁGIO 1: A "OFICINA" DE CONSTRUÇÃO (BUILDER)
# ----------------------------------------------------------------------
# Começamos com a imagem oficial do Rust, que é grande porque contém
# todo o necessário para compilar código Rust (o 'toolchain').
# 'AS builder' dá um nome a este estágio para que possamos nos referir
# a ele mais tarde.
FROM rust:latest AS builder

# Define nosso diretório de trabalho dentro da "oficina".
# Pense nisso como: "crie a pasta e dê 'cd /usr/src/app'".
WORKDIR /usr/src/app

# --- O Truque do Cache de Dependências (para builds rápidos) ---

# 1. Copiamos apenas o 'Cargo.toml'.
# O 'Cargo.toml' é como o 'package.json' do Node: ele lista as
# dependências (chamadas de "crates") do nosso projeto.
COPY app/Cargo.toml ./

# 2. Criamos um projeto Rust falso.
# Como o 'cargo build' precisa de um arquivo de código para rodar,
# criamos um 'main.rs' vazio que não faz nada.
RUN mkdir src && echo "fn main() {}" > src/main.rs

# 3. Construímos o projeto falso.
# O Cargo vai ler o 'Cargo.toml', baixar e compilar TODAS as
# dependências externas. Como nosso código é vazio, este passo
# foca 100% nas dependências. O resultado (lento) fica em cache.
RUN cargo build --release

# --- Compilando o Código Real ---

# 4. Agora copiamos nosso código de verdade, substituindo o falso.
# Se no futuro você mudar apenas seu código e não as dependências,
# o passo anterior (lento) será pulado (usado do cache), e o Docker
# pulará direto para este ponto.
COPY app/main.rs src/main.rs

# 5. Construímos de verdade!
# Desta vez, o Cargo vê que todas as dependências já estão compiladas
# (graças ao passo 3) e só precisa compilar nosso 'main.rs',
# o que é extremamente rápido.
RUN cargo build --release

# Ao final deste estágio, temos nosso programa pronto em:
# /usr/src/app/target/release/rust_api
# ----------------------------------------------------------------------

# ----------------------------------------------------------------------
# ESTÁGIO 2: A IMAGEM FINAL (RUNTIME)
# ----------------------------------------------------------------------
# Agora, jogamos fora a "oficina" inteira e começamos de novo
# com uma imagem base Debian super pequena ('bookworm-slim').
# Ela não tem NADA de Rust, só o sistema operacional básico.
FROM debian:bookworm-slim AS runtime

# Cria uma variável para o nome do nosso programa, para não
# precisarmos repetir o texto "rust_api" em vários lugares.
ARG BINARY_NAME=rust_api

# Instala 'ca-certificates', que são necessários para que nossa
# aplicação possa fazer conexões seguras na internet (HTTPS/TLS).
# Limpamos o cache do 'apt-get' para manter a imagem pequena.
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

# A MÁGICA DO MULTI-STAGE ACONTECE AQUI!
# O comando '--from=builder' nos permite "olhar de volta" para o
# estágio anterior ('builder') e copiar algo de lá.
# Estamos copiando APENAS o programa final compilado da "oficina"
# para a nossa nova imagem limpa.
# O resto (código-fonte, ferramentas) é deixado para trás.
COPY --from=builder /usr/src/app/target/release/${BINARY_NAME} /usr/local/bin/

# Medida de segurança: cria e usa um usuário não-root (sem privilégios).
# Evita que, em caso de falha de segurança na aplicação, um invasor
# tenha controle total sobre o container.
USER 1000

# Define uma variável de ambiente para configurar os logs da aplicação.
ENV RUST_LOG=info

# O comando final que será executado quando o container iniciar.
# Ele simplesmente executa nosso programa, que está pronto em '/usr/local/bin/'.
CMD ["/usr/local/bin/rust_api"]