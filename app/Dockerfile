# ======================================================================
# Dockerfile Multi-Stage — Aplicação Rust
# ======================================================================
#
# Este arquivo é uma "receita" de Dockerfile "Multi-Stage".
# Isso significa que dividimos o processo em dois estágios (partes):
#
# 1. ESTÁGIO "BUILDER" (O Construtor / A Oficina):
#    Uma imagem grande que tem TODAS as ferramentas para COMPILAR o
#    código Rust (compilador, pacotes de desenvolvimento, etc.).
#
# 2. ESTÁGIO "RUNTIME" (O Final / O Carro de Corrida):
#    Uma imagem MINÚSCULA que contém APENAS o programa já compilado
#    e o mínimo necessário para ele rodar.
#
# VANTAGEM: A imagem final é extremamente pequena, segura e rápida.
#

# ----------------------------------------------------------------------
# ESTÁGIO 1: A "OFICINA" DE CONSTRUÇÃO (BUILDER)
# ----------------------------------------------------------------------

# `FROM` inicia um novo estágio e define a "imagem base".
# `rust:alpine`: Usamos uma imagem oficial do Rust que é baseada no
#                Alpine Linux. Isso é CRUCIAL. Para rodar no Alpine
#                (estágio 2), precisamos compilar no Alpine (estágio 1)
#                devido a diferenças na biblioteca C (musl vs glibc).
# `AS builder`: Damos um "apelido" a este estágio. Vamos usá-lo
#               mais tarde para copiar arquivos *deste* estágio.
FROM rust:alpine AS builder

# `WORKDIR` define o "diretório de trabalho" padrão dentro do contêiner.
# É como se déssemos `cd /usr/src/app` no terminal.
# Todos os comandos `RUN`, `COPY`, etc., serão executados a partir daqui.
WORKDIR /usr/src/app

# `RUN` executa um comando no shell do contêiner.
# `mkdir src`: O Cargo (gerenciador de pacotes do Rust) espera que
#              o código-fonte principal (main.rs) esteja dentro
#              de uma pasta chamada `src`. Estamos criando ela.
RUN mkdir src

# `COPY` copia arquivos do seu computador (host) para dentro do contêiner.
# `app/Cargo.toml app/Cargo.lock* ./`: Copiamos os arquivos de manifesto
#                                      do projeto para o diretório de
#                                      trabalho (`./`).
#
# *** TRUQUE DE CACHE DO DOCKER ***
# Copiamos SÓ o `Cargo.toml` primeiro, antes do código. Se o código-fonte
# mudar, mas as dependências (Cargo.toml) não, o Docker pode
# reutilizar a camada (lenta) de download de dependências.
COPY app/Cargo.toml app/Cargo.lock* ./

# `COPY` novamente, agora copiando o código-fonte principal.
# `app/main.rs ./src/main.rs`: Copia o `main.rs` do seu computador
#                             para dentro da pasta `src` que criamos
#                             no contêiner.
COPY app/main.rs ./src/main.rs

# `RUN` executa a instalação de dependências do *sistema operacional*.
# `apk add`: É o gerenciador de pacotes do Alpine (como o `apt-get` do Debian).
# `--no-cache`: Diz ao `apk` para não guardar o cache de pacotes,
#               mantendo esta camada de build menor.
#
# POR QUE ESTES PACOTES?
# `build-base`: Contém ferramentas essenciais de compilação (compilador C, make).
# `musl-dev`: Arquivos de desenvolvimento para a biblioteca C `musl` do Alpine.
# `openssl-dev`: Arquivos de desenvolvimento para OpenSSL (necessário para HTTPS).
#
# Muitas dependências do Rust (ex: `tokio`, `hyper`, `reqwest`) precisam
# compilar código C "por baixo dos panos". Sem isso, a compilação falha.
RUN apk add --no-cache build-base musl-dev openssl-dev

# `RUN` executa o comando de compilação do Rust.
# `cargo build`: O comando padrão para compilar um projeto Rust.
# `--release`: Diz ao Cargo para compilar uma versão OTIMIZADA,
#              pronta para produção (muito mais rápida e menor).
#
# Este comando pode demorar, pois baixa e compila todas as dependências.
RUN cargo build --release

# Fim do Estágio 1.
# Agora, temos nosso programa compilado em:
# `/usr/src/app/target/release/`
#
# O Docker vai "descartar" todo esse estágio, exceto pelos arquivos
# que vamos copiar explicitamente no próximo estágio.

# ----------------------------------------------------------------------
# ESTÁGIO 2: A IMAGEM FINAL (RUNTIME)
# ----------------------------------------------------------------------

# `FROM` inicia um NOVO estágio, totalmente limpo.
# `alpine:latest`: Usamos a imagem base do Alpine. Ela é minúscula
#                  (cerca de 5-6MB), o que é perfeito para produção.
# `AS runtime`: Damos um apelido a este estágio (apenas por clareza).
FROM alpine:latest AS runtime

# `ENV` define uma "Variável de Ambiente" dentro da imagem final.
# `BIN_NAME=rust_api`: Criamos uma variável chamada `BIN_NAME` e
#                     demos a ela o valor `rust_api`. Isso torna o
#                     nome do binário (programa) fácil de referenciar
#                     e de mudar em um só lugar.
ENV BIN_NAME=rust_api

# `ENV` define outra variável de ambiente.
# `RUST_LOG=off`: Esta é uma variável padrão usada por muitas
#                 bibliotecas de log do Rust (como `env_logger`).
#                 Ao definir como "off", estamos desabilitando
#                 os logs do aplicativo (conforme sua solicitação anterior).
ENV RUST_LOG=off

# `RUN` executa um comando de instalação no Alpine.
# `apk add --no-cache ca-certificates`:
#
# `ca-certificates`: É a "lista de certificados raiz" confiáveis.
#
# IMPORTANTE: Sem isso, seu aplicativo NÃO conseguirá fazer
# chamadas HTTPS para outras APIs, bancos de dados, etc.
# (Ele não saberia em quem "confiar" na internet).
RUN apk add --no-cache ca-certificates curl

# `COPY` é o "pulo do gato" do multi-stage!
# `--from=builder`: Diz ao Docker para copiar de um estágio anterior,
#                   no caso, o estágio que apelidamos de "builder".
#
# `/usr/src/app/target/release/${BIN_NAME}`: O caminho COMPLETO
#     do nosso programa compilado lá no estágio "builder".
#     (Usamos a variável ${BIN_NAME} que definimos).
#
# `/usr/local/bin/`: O destino na NOSSA nova imagem "runtime".
#     `/usr/local/bin` é um diretório padrão no Linux para
#     programas instalados manualmente.
#
# RESUMO: "Pegue SÓ o programa pronto da oficina e coloque
#          no nosso carro de corrida."
COPY --from=builder /usr/src/app/target/release/${BIN_NAME} /usr/local/bin/

# `RUN` executa um comando para dar permissão de execução.
# `chmod +x`: "Change Mode" (Mudar Modo), adicionando (+)
#             a permissão de "eXecução" (x).
#
# No Linux, arquivos não são "executáveis" por padrão.
# Precisamos dizer ao sistema: "Este arquivo é um programa,
# você tem permissão para executá-lo."
RUN chmod +x /usr/local/bin/${BIN_NAME}

# `USER` muda o usuário que irá rodar o programa.
#
# *** BOA PRÁTICA DE SEGURANÇA! ***
# Por padrão, contêineres rodam como `root` (superusuário).
# Se um invasor explorasse uma falha no seu app, ele teria
# controle total do contêiner.
#
# `USER nobody`: Mudamos para o usuário `nobody`, que é um
#                usuário padrão do Alpine sem privilégios.
#                Ele pode rodar o programa, mas não pode
#                instalar software ou modificar arquivos de sistema.
USER nobody

# `CMD` (Comando) define o comando padrão que será executado
#       QUANDO o contêiner for iniciado.
#
# (Diferente de `RUN`, que é executado durante a *construção* da imagem).
#
# `CMD /usr/local/bin/${BIN_NAME}`:
# "Quando este contêiner iniciar, execute o programa
#  /usr/local/bin/rust_api"
CMD /usr/local/bin/${BIN_NAME}