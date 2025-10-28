# ======================================================================================
# DOCKERFILE MULTI-STAGE — GUIA PASSO A PASSO PARA INICIANTES
# --------------------------------------------------------------------------------------
# Este arquivo descreve, linha por linha, como empacotar uma aplicação Rust em duas fases:
#   1) Fase de CONSTRUÇÃO (“builder”): usa uma imagem grande com todas as ferramentas
#      necessárias para compilar o código em modo otimizado (release).
#   2) Fase de EXECUÇÃO (“runtime”): usa uma imagem mínima, contendo apenas o binário
#      já compilado e o essencial para rodar. Isso deixa a imagem final pequena, rápida
#      para baixar e com superfície de ataque reduzida (mais segura).
#
# A grande sacada do “multi-stage” é: compilar em um ambiente completo e, depois, copiar
# só o resultado (o binário final) para uma imagem minúscula. Assim, você não carrega
# ferramentas de desenvolvimento desnecessárias para produção.
# ======================================================================================

# Escolhe a imagem base para a FASE DE CONSTRUÇÃO e dá a ela o nome “builder”.
# Usamos "rust:alpine" para compilar sobre Alpine Linux (musl). Compilar em Alpine
# facilita rodar no Alpine da fase final sem incompatibilidades (musl vs glibc).
FROM rust:alpine AS builder

# Define o diretório de trabalho dentro do contêiner durante a construção.
# Pense nele como o “cd /usr/src/app”; tudo a seguir acontece a partir daqui.
WORKDIR /usr/src/app

# Instala pacotes do sistema necessários para COMPILAR dependências nativas
# que algumas crates de Rust exigem (C toolchain, headers e OpenSSL).
# --no-cache evita guardar metadados de pacotes, reduzindo o tamanho da camada.
RUN apk add --no-cache build-base musl-dev openssl-dev

# Cria o diretório-fonte padrão do Cargo. O compilador espera encontrar
# o arquivo principal em "src/main.rs".
RUN mkdir src

# Primeiro copiamos manifestos do projeto (Cargo.toml e Cargo.lock) para aproveitar
# o cache do Docker: se as dependências não mudarem, as próximas builds reutilizam
# a camada de “download/compilação” das crates, acelerando MUITO a compilação.
COPY app/Cargo.toml app/Cargo.lock* ./

# Agora copiamos o código-fonte de fato (o main). Separar esta etapa da anterior
# garante melhor reuso de cache quando apenas o código muda, mas as deps não.
COPY app/main.rs ./src/main.rs

# Compila o projeto em modo release (otimizado). O resultado ficará em
# /usr/src/app/target/release/. Esta etapa é a que mais consome tempo em builds frias.
RUN cargo build --release

# ======================================================================================
# A partir daqui começa a FASE DE EXECUÇÃO (“runtime”): imagem limpa e mínima.
# Nada do ambiente de compilação vem junto — só o binário final entrará aqui.
# ======================================================================================

# Usa a imagem Alpine mínima para rodar o binário, e a apelida de “runtime”.
# Alpine costuma ter ~5–6 MB, o que ajuda a manter a imagem final bem enxuta.
FROM alpine:latest AS runtime

# Define uma variável de ambiente com o nome do binário. Centralizar o nome em
# uma variável torna mais fácil alterar o nome no futuro sem caçar em várias linhas.
ENV BIN_NAME=rust_api

# Desativa logs baseados em RUST_LOG (se sua aplicação/stack usar esse padrão).
# Útil em cenários de benchmark onde silêncio e previsibilidade interessam.
ENV RUST_LOG=off

# Instala certificados de autoridade (CA) e curl:
# - ca-certificates permite que o binário valide conexões HTTPS com outros serviços.
# - curl é útil para debug e healthchecks dentro do contêiner (opcional, mas prático).
RUN apk add --no-cache ca-certificates curl

# Copia APENAS o binário final da fase “builder” para esta imagem minimalista.
# Repare no "--from=builder": é assim que “puxamos” artefatos do estágio anterior.
# O destino /usr/local/bin é um local padrão para executáveis instalados manualmente.
COPY --from=builder /usr/src/app/target/release/${BIN_NAME} /usr/local/bin/

# Garante permissão de execução ao arquivo do binário. Em Linux, o bit “x” precisa
# estar setado para que o sistema reconheça o arquivo como programa executável.
RUN chmod +x /usr/local/bin/${BIN_NAME}

# Troca o usuário efetivo para “nobody” (sem privilégios). Boa prática de segurança:
# mesmo que ocorra uma falha no app, o atacante não terá poderes administrativos.
USER nobody

# Define o comando padrão ao iniciar o contêiner em produção. Diferente de RUN (que
# executa na construção), o CMD roda quando o contêiner “sobe”. Aqui, executamos
# diretamente o binário instalado anteriormente.
CMD /usr/local/bin/${BIN_NAME}
