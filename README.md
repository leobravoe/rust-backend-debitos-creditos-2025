# Guia de Comandos — `node-fastify-backend-2025`

Este documento reúne comandos e procedimentos operacionais do repositório, com variações por sistema operacional quando aplicável.

---

## Sumário
1. [Clonar o repositório](#1-clonar-o-repositório)
2. [Ajustar portas efêmeras TCP (Windows)](#2-ajustar-portas-efêmeras-tcp-windows)
3. [Derrubar containers, redes e volumes](#3-derrubar-containers-redes-e-volumes)
4. [Subir a stack com Docker Compose](#4-subir-a-stack-com-docker-compose)
5. [Monitorar uso de recursos](#5-monitorar-uso-de-recursos)
6. [Entrar na pasta do Gatling](#6-entrar-na-pasta-do-gatling)
7. [Resetar o banco e rodar a simulação (Gatling)](#7-resetar-o-banco-e-rodar-a-simulação-gatling)
8. [Atualizar o projeto (sincronizar com o remoto)](#8-atualizar-o-projeto-sincronizar-com-o-remoto)
9. [Informações do projeto](#9-informações-do-projeto)

---

## 1) Clonar o repositório

```bash
git clone https://github.com/leobravoe/node-fastify-backend-2025.git
```

Outras formas de clonagem:
```bash
# Clonar apenas a branch principal
git clone --branch main --single-branch https://github.com/leobravoe/node-fastify-backend-2025.git

# Clonagem rasa (histórico reduzido)
git clone --depth=1 https://github.com/leobravoe/node-fastify-backend-2025.git
```

---

## 2) Ajustar portas efêmeras TCP (Windows)

Comando para definir a faixa de portas efêmeras IPv4 (executar em CMD com privilégios administrativos):

```cmd
netsh int ipv4 set dynamicport tcp start=10000 num=55535
```
Consulta da configuração atual:
```cmd
netsh int ipv4 show dynamicport tcp
```

---

## 3) Derrubar containers, redes e volumes

```bash
# Docker Compose v1
docker-compose down -v

# Docker Compose v2
docker compose down -v
```

---

## 4) Subir a stack com Docker Compose

```bash
# v1
docker-compose up -d --build

# v2
docker compose --compatibility up -d --build
```

---

## 5) Monitorar uso de recursos

```bash
docker stats
docker stats --no-stream
docker stats postgres app1
```

---

## 6) Entrar na pasta do Gatling

```bash
cd gatling
# Windows PowerShell: cd .\gatling
```

---

## 7) Resetar o banco e rodar a simulação (Gatling)

Para iniciar as simulações, a partir da raiz do projeto digite:

**Windows (CMD):**
```cmd
docker compose down -v && ^
docker compose --compatibility up -d --build --force-recreate && ^
docker exec postgres psql -U postgres -d postgres_api_db -v ON_ERROR_STOP=1 ^
  -c "TRUNCATE TABLE transactions" ^
  -c "UPDATE accounts SET balance = 0" ^
&& cmd /c "cd /d gatling && mvnw.cmd gatling:test -Dgatling.simulationClass=simulations.RinhaBackendCrebitosSimulation"
```

ou

```cmd
_win_run-test-launcher.bat 1
```

**Windows (PowerShell):**
```powershell
docker compose down -v; if ($LASTEXITCODE) { exit $LASTEXITCODE }
docker compose --compatibility up -d --build --force-recreate; if ($LASTEXITCODE) { exit $LASTEXITCODE }
docker exec postgres psql -U postgres -d postgres_api_db -v ON_ERROR_STOP=1 `
  -c "TRUNCATE TABLE transactions" `
  -c "UPDATE accounts SET balance = 0"; if ($LASTEXITCODE) { exit $LASTEXITCODE }
cmd /c "cd /d gatling && mvnw.cmd gatling:test -Dgatling.simulationClass=simulations.RinhaBackendCrebitosSimulation"

```

ou

```powershell
.\_win_run-test-launcher.bat 1
```

**Linux/macOS (bash):**
```bash
docker compose down -v \
&& docker compose --compatibility up -d --build --force-recreate \
&& docker compose exec -T postgres \
  psql -U postgres -d postgres_api_db -v ON_ERROR_STOP=1 \
  -c "BEGIN; TRUNCATE TABLE transactions; UPDATE accounts SET balance = 0; COMMIT;" \
&& ( cd gatling && mvn gatling:test -Dgatling.simulationClass=simulations.RinhaBackendCrebitosSimulation )
```

ou

```bash
./_linux_run-test-launcher.sh 1
```

Relatórios do Gatling:
```
gatling/target/gatling/**/index.html
```

---

## 8) Atualizar o projeto (sincronizar com o remoto)

```bash
git fetch --all
git switch main
git reset --hard origin/main
git clean -fdx
```

Comandos de referência:

```bash
# Reposiciona branch e descarta alterações locais
git reset --hard origin/main

# Remove arquivos e pastas não rastreados
git clean -fd      # remoção forçada
git clean -fdn     # simulação (sem remover)
git clean -fdx     # inclui ignorados (ex.: node_modules)
```

---

## 9) Informações do projeto

**Serviços:** NGINX (proxy/reverso), aplicações Node.js (Fastify), PostgreSQL e cenários de carga com Gatling (Maven Wrapper).

**Pastas principais:**
```
/nginx      # configuração do NGINX
/app        # código da aplicação (Node.js/Fastify)
/sql        # scripts SQL e arquivos de banco
/gatling    # simulações de carga (Scala/Gatling via Maven Wrapper)
```

**Ferramentas utilizadas:**
- Docker / Docker Compose
- Node.js / Fastify
- PostgreSQL
- NGINX
- Gatling (via Maven Wrapper)

**Variáveis de ambiente usadas pela aplicação (exemplos comuns):**
```
DB_HOST
DB_PORT
DB_USER
DB_PASSWORD
DB_DATABASE
PG_MAX
```

Este guia descreve os procedimentos em uso no repositório conforme a estrutura atual.
