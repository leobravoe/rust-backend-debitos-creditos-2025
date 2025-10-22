#!/usr/bin/env bash
# ^ Shebang: instrui o sistema a executar este arquivo com o interpretador "bash"
#   Usar "/usr/bin/env" ajuda a achar o bash no PATH, tornando o script mais portátil.

# _linux_run-test-main-logic.sh — Linux main logic with robust UTF-8 and health checks
# Descrição geral:
# - Orquestra o ciclo de testes usando Docker Compose e Gatling.
# - Garante logs com timestamps e encoding UTF-8 (fim a fim).
# - Faz verificações de saúde (health checks) dos containers antes de rodar o teste.
# - Limpa e prepara o banco (Postgres) para o teste.
# - Trata sinais (CTRL+C/TERM) para encerrar com elegância.

set -Eeuo pipefail
# set -E : mantém o comportamento de ERR em funções/subshells
# set -e : encerra o script se qualquer comando falhar (exit != 0)
# set -u : falha ao usar variável não definida (evita erros silenciosos)
# pipefail : em "cmd1 | cmd2", uma falha em qualquer etapa faz o pipeline falhar
# Esses flags tornam o script mais robusto e previsível.

# On interrupt/term, propagate to our child process group (docker/mvn) then exit
on_signal() {
  # Função de limpeza chamada ao receber SIGINT (CTRL+C) ou SIGTERM.
  # Objetivo: tentar parar serviços do Docker Compose com elegância e sair com código 130.
  # Try to stop docker compose gracefully
  if command -v docker >/dev/null 2>&1; then
    docker compose stop >/dev/null 2>&1 || true
    # ^ "|| true" evita que eventual erro aqui derrube o script por causa do "set -e".
  fi
  exit 130
}
trap on_signal INT TERM
# ^ "trap" conecta sinais (INT/TERM) à função on_signal,
#   garantindo encerramento controlado quando o usuário interrompe.

LOGFILE="${1:-__test_logs-$(date +%Y%m%d-%H%M%S).txt}"
# ^ Caminho do arquivo de log principal.
#   - Se o script receber um 1º argumento, usa esse caminho.
#   - Caso contrário, gera um nome com timestamp (__test_logs-AAAAMMDD-HHMMSS.txt).

# Locale/encoding (UTF-8 end-to-end)
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8 -Dsun.stdout.encoding=UTF-8 -Dsun.stderr.encoding=UTF-8 ${JAVA_TOOL_OPTIONS:-}"
export MAVEN_OPTS="-Dfile.encoding=UTF-8 ${MAVEN_OPTS:-}"
# ^ Garante que tudo rode em UTF-8 (stdout/stderr do Java e Maven inclusive),
#   evitando problemas com acentos/ç nos logs.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# ^ Descobre a pasta onde este script está salvo (caminho absoluto), de forma portátil.
cd "${SCRIPT_DIR}"
# ^ Garante que os comandos seguintes rodem a partir do diretório do script.

ts() { date '+%Y-%m-%d %H:%M:%S.%3N'; }
# ^ Função utilitária: retorna timestamp no formato "YYYY-MM-DD HH:MM:SS.mmm".

wlog() {
  # Função de log: imprime uma linha com timestamp e mensagem,
  # e também anexa ao arquivo de log indicado em LOGFILE.
  printf '%s %s
' "$(ts)" "$*" | tee -a "${LOGFILE}"
  # - printf imprime "timestamp + mensagem".
  # - tee -a: mostra no console e adiciona ("-a") ao arquivo de log.
}

# Runs a command, streaming output to console and file (UTF-8) — ignores failures if asked
run_cmd() {
  # Função genérica para executar comandos com log e política de erro.
  # Parâmetros:
  #   $1 (title)  : texto descritivo do comando (apenas para log)
  #   $2 (ignore) : "ignore" para não falhar no erro; qualquer outra coisa → "strict"
  #   $@ restantes: o comando real a executar
  local title="$1"; shift
  local ignore="${1}"; shift  # "ignore" or "strict"
  wlog "[CMD] ${title}"
  # stdbuf for line-buffered tee; prevents blocking
  # ^ "stdbuf -oL -eL" força buffer por linha (stdout/stderr), evitando travamentos de pipe.
  if ! stdbuf -oL -eL "$@" 2>&1 | tee -a "${LOGFILE}"; then
    # Se o comando falhou (exit != 0) e o modo não é "ignore", propaga a falha.
    if [[ "${ignore}" != "ignore" ]]; then
      return 1
    fi
  fi
}

# =============== Steps ===============
# Abaixo, a sequência de passos do fluxo de teste.

wlog "[PASSO 1/6] Parando e removendo containers antigos (ignorar falhas)..."
run_cmd "docker compose down -v" "ignore" docker compose down -v || true
# ^ Para e remove containers/volumes anteriores para garantir ambiente limpo.
#   "ignore" e "|| true" garantem que falhas aqui não interrompam o fluxo.

wlog "[PASSO 2/6] Forçando a remoção dos containers..."
run_cmd "docker rm -f postgres app1 app2 nginx" "ignore" docker rm -f postgres app1 app2 nginx || true

wlog ""
wlog "[PASSO 3/6] Construindo e subindo novos containers (ignorar falhas)..."
run_cmd "docker compose up -d --build --compatibility --force-recreate " "ignore" docker compose --compatibility up -d --build --force-recreate || true
# ^ Sobe os serviços em modo destacado (-d), reconstruindo imagens (--build),
#   e ajustando recursos com --compatibility quando necessário.

wlog ""
wlog "[PASSO 4/6] Verificacao de Saude dos Containers..."
# ^ Agora aguardamos todos os serviços essenciais estarem "rodando" e, se houver healthcheck,
#   que estejam "healthy".

SERVICES=("postgres" "app1" "app2" "nginx")
# ^ Lista de serviços que consideramos essenciais para o teste.

TIMEOUT=90
DEADLINE=$(( $(date +%s) + TIMEOUT ))
# ^ Tempo máximo (em segundos) para os serviços ficarem prontos. DEADLINE = agora + TIMEOUT.

get_ids_for_service() {
  # Retorna (via stdout) os IDs de container de um serviço (podem existir réplicas).
  docker compose ps -q "$1" 2>/dev/null | sed '/^$/d' || true
}

is_container_running() {
  # Verifica se um container está no estado "running".
  local id="$1"
  [[ "$(docker inspect -f '{{.State.Status}}' "${id}" 2>/dev/null || echo 'unknown')" == "running" ]]
}

has_healthcheck() {
  # Verifica se o container possui healthcheck definido no Docker (State.Health).
  local id="$1"
  [[ -n "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${id}" 2>/dev/null)" ]]
}

is_container_healthy() {
  # Verifica se o status de saúde do container é "healthy".
  local id="$1"
  [[ "$(docker inspect -f '{{.State.Health.Status}}' "${id}" 2>/dev/null || echo 'none')" == "healthy" ]]
}

all_services_ready() {
  # Retorna 0 (sucesso) se TODOS os serviços estiverem prontos.
  # Critérios por serviço:
  #   - Pelo menos 1 container do serviço existe e está "running".
  #   - Se houver healthcheck, todos os containers com healthcheck devem estar "healthy".
  local ready=0 total=0
  for svc in "${SERVICES[@]}"; do
    total=$((total+1))
    local ids; mapfile -t ids < <(get_ids_for_service "${svc}")
    if [[ "${#ids[@]}" -eq 0 ]]; then
      return 1
    fi
    local ok_running=1 ok_health=1
    for id in "${ids[@]}"; do is_container_running "${id}" || { ok_running=0; break; }; done
    if [[ $ok_running -eq 1 ]]; then
      local any_health=0
      for id in "${ids[@]}"; do has_healthcheck "${id}" && { any_health=1; break; }; done
      if [[ $any_health -eq 1 ]]; then
        for id in "${ids[@]}"; do is_container_healthy "${id}" || { ok_health=0; break; }; done
      fi
    else
      ok_health=0
    fi
    if [[ $ok_running -eq 1 && $ok_health -eq 1 ]]; then
      ready=$((ready+1))
    fi
  done
  [[ "${ready}" -eq "${total}" ]]
}

healthy_count() {
  # Conta quantos serviços (da lista SERVICES) já atendem aos critérios de "pronto".
  local cnt=0
  for svc in "${SERVICES[@]}"; do
    local ids; mapfile -t ids < <(get_ids_for_service "${svc}")
    [[ "${#ids[@]}" -gt 0 ]] || continue
    local ok_running=1 ok_health=1
    for id in "${ids[@]}"; do is_container_running "${id}" || { ok_running=0; break; }; done
    if [[ $ok_running -eq 1 ]]; then
      local any_health=0
      for id in "${ids[@]}"; do has_healthcheck "${id}" && { any_health=1; break; }; done
      if [[ $any_health -eq 1 ]]; then
        for id in "${ids[@]}"; do is_container_healthy "${id}" || { ok_health=0; break; }; done
      fi
    else
      ok_health=0
    fi
    if [[ $ok_running -eq 1 && $ok_health -eq 1 ]]; then
      cnt=$((cnt+1))
    fi
  done
  echo "${cnt}"
}

while (( $(date +%s) < DEADLINE )); do
  # Laço de espera: a cada 5s, verifica quantos serviços estão prontos.
  hc=$(healthy_count)
  wlog "Aguardando... (${hc} de ${#SERVICES[@]} servicos prontos)"
  if all_services_ready; then
    wlog "Todos os servicos essenciais estao prontos! A continuar."
    break
  fi
  sleep 5
done

if ! all_services_ready; then
  # Se o tempo esgotar, mostra o estado atual e sai com erro.
  wlog ""
  wlog "--- ESTADO ATUAL DOS CONTAINERS ---"
  docker compose ps | tee -a "${LOGFILE}" >/dev/null || true
  wlog "Timeout: Nem todos os containers ficaram prontos em ${TIMEOUT} segundos."
  exit 1
fi

# Postgres readiness + cleanup
wlog ""
wlog "[PASSO 5/6] Limpando o banco de dados..."
PG_ID="$(docker compose ps -q postgres | head -n1 || true)"
# ^ Pega o ID do container do Postgres (o primeiro, caso haja mais de um).
if [[ -z "${PG_ID}" ]]; then
  wlog "Aviso: container do postgres nao encontrado; pulando limpeza."
else
  # Espera o banco aceitar conexões (usando pg_isready se existir, senão um SELECT simples).
  DB_TIMEOUT=90
  DB_DEADLINE=$(( $(date +%s) + DB_TIMEOUT ))
  while (( $(date +%s) < DB_DEADLINE )); do
    if docker exec "${PG_ID}" sh -lc 'command -v pg_isready >/dev/null 2>&1' ; then
      if docker exec "${PG_ID}" pg_isready -U postgres -d postgres_api_db -q ; then
        break
      fi
    else
      if docker exec "${PG_ID}" psql -U postgres -d postgres_api_db -c "SELECT 1;" >/dev/null 2>&1 ; then
        break
      fi
    fi
    wlog "Aguardando DB aceitar conexões..."
    sleep 3
  done
  # Limpeza de dados para começar o teste sempre do zero.
  docker exec "${PG_ID}" psql -U postgres -d postgres_api_db -v ON_ERROR_STOP=1     -c "TRUNCATE TABLE transactions"     -c "UPDATE accounts SET balance = 0"     2>&1 | tee -a "${LOGFILE}"
  # ^ TRUNCATE transactions → remove transações anteriores
  #   UPDATE accounts SET balance = 0 → zera saldos para um estado conhecido
fi

# Gatling
wlog ""
wlog "[PASSO 6/6] Executando o teste de carga com Gatling..."
# ^ Agora que tudo está pronto, executamos o Gatling (via Maven) para rodar a simulação de carga.
pushd "${SCRIPT_DIR}/gatling" >/dev/null
# ^ Entra na pasta "gatling" (salva a pasta anterior numa pilha para depois voltar com popd).

stdbuf -oL -eL mvn -B -Dfile.encoding=UTF-8 \
  gatling:test -Dgatling.simulationClass=simulations.RinhaBackendCrebitosSimulation \
  2>&1 | tee -a "${LOGFILE}"
# ^ Executa o plugin do Gatling:
#   - stdbuf -oL -eL : buffer por linha (melhor para logs ao vivo)
#   - mvn -B : modo batch (sem interações)
#   - -Dfile.encoding=UTF-8 : reforço de encoding
#   - gatling:test : alvo do plugin Gatling para rodar a simulação
#   - -Dgatling.simulationClass=... : qual classe de simulação usar
#   - "2>&1 | tee -a LOGFILE" : envia stdout+stderr para o console e para o arquivo de log

G_EXIT=${PIPESTATUS[0]}
# ^ Captura o código de saída do "mvn" dentro do pipeline (PIPESTATUS[0] = status do 1º comando).

popd >/dev/null
# ^ Volta para a pasta anterior (onde o script começou).

if [[ ${G_EXIT} -ne 0 ]]; then
  # Se o Gatling falhou, registramos e saímos com o mesmo código de erro.
  wlog "Falha ao executar o teste do Gatling. Exit=${G_EXIT}"
  exit ${G_EXIT}
fi

wlog "Teste concluido com sucesso."
# ^ Final feliz: tudo ok!