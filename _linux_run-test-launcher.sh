#!/usr/bin/env bash
# _linux_run-test-launcher.sh — Linux launcher com múltiplas execuções
# Agora aceita 1 parâmetro obrigatório: quantidade de vezes que o teste será executado.

set -Eeuo pipefail

# Locale/encoding (UTF-8 end-to-end)
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8 ${JAVA_TOOL_OPTIONS:-}"
export MAVEN_OPTS="-Dfile.encoding=UTF-8 ${MAVEN_OPTS:-}"

# Descobre o diretório deste script
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# ---------------------------
# Parse do parâmetro obrigatório
# ---------------------------
if [[ $# -lt 1 ]]; then
  echo "Uso: $0 <quantidade_execucoes>" >&2
  exit 64
fi
RUNS="$1"
if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
  echo "Erro: <quantidade_execucoes> deve ser um inteiro >= 1" >&2
  exit 64
fi

# Variáveis globais usadas pelo trap para encerrar a execução corrente (iterativa)
MAIN_PID=""
MAIN_PGID=""
LOGGER_PID=""
STOP_FLAG=""

# Trap para interromper a execução corrente (qualquer iteração) com Ctrl+C/TERM
cleanup_interrupt() {
  if [[ -n "${MAIN_PID:-}" ]] && kill -0 "${MAIN_PID}" 2>/dev/null; then
    # Envia sinais em escalonamento para TODO o grupo do processo principal
    kill -INT -- -"${MAIN_PGID}" 2>/dev/null || true
    sleep 1
    kill -TERM -- -"${MAIN_PGID}" 2>/dev/null || true
    sleep 1
    kill -KILL -- -"${MAIN_PGID}" 2>/dev/null || true
  fi

  # Sinaliza o logger da iteração atual para parar
  [[ -n "${STOP_FLAG:-}" ]] && touch "${STOP_FLAG}" 2>/dev/null || true

  if [[ -n "${LOGGER_PID:-}" ]] && kill -0 "${LOGGER_PID}" 2>/dev/null; then
    kill "${LOGGER_PID}" 2>/dev/null || true
    sleep 1
    kill -9 "${LOGGER_PID}" 2>/dev/null || true
  fi

  [[ -n "${STOP_FLAG:-}" ]] && rm -f "${STOP_FLAG}" 2>/dev/null || true
  echo
  echo "[INTERRUPT] Execução interrompida pelo usuário."
  exit 130
}
trap cleanup_interrupt INT TERM

# ---------------------------
# Função que roda UMA execução
# ---------------------------
run_once() {
  local iter="$1"

  # Timestamp único por execução (garante nomes de logs distintos)
  local TIMESTAMP
  TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

  # Caminhos de log para esta execução
  local MAIN_LOG_FILE="${SCRIPT_DIR}/__${TIMESTAMP}-iter${iter}-test_logs.txt"
  local STATS_LOG_FILE="${SCRIPT_DIR}/__${TIMESTAMP}-iter${iter}-stats_logs.txt"

  # STOP_FLAG exclusivo por iteração (evita colisão entre rodadas)
  STOP_FLAG="${SCRIPT_DIR}/stop-logging.iter${iter}.${TIMESTAMP}.flg"

  echo "===================================================================="
  echo " Iniciando execução ${iter}/${RUNS} — ${TIMESTAMP}"
  echo "  Logs:"
  echo "    Main : ${MAIN_LOG_FILE}"
  echo "    Stats: ${STATS_LOG_FILE}"
  echo "===================================================================="

  # Inicia o processo principal em nova sessão/grupo
  setsid bash "${SCRIPT_DIR}/_linux_run-test-main-logic.sh" "${MAIN_LOG_FILE}" &
  MAIN_PID=$!

  # Descobre/ajusta o PGID para enviar sinais ao grupo
  MAIN_PGID="${MAIN_PID}"
  if command -v ps >/dev/null 2>&1; then
    local MAIN_PGID_PS
    MAIN_PGID_PS="$(ps -o pgid= -p "${MAIN_PID}" 2>/dev/null | tr -d " ")" || true
    if [[ -n "${MAIN_PGID_PS}" ]]; then MAIN_PGID="${MAIN_PGID_PS}"; fi
  fi

  # Inicia o logger de estatísticas para esta execução
  bash "${SCRIPT_DIR}/_linux_run-test-stats-logger.sh" "${STATS_LOG_FILE}" "${MAIN_PID}" "${STOP_FLAG}" &
  LOGGER_PID=$!

  # Espera o main terminar (não aborta o launcher em caso de erro do main)
  wait "${MAIN_PID}" || true

  # Sinaliza encerramento limpo do logger
  touch "${STOP_FLAG}" || true
  sleep 2
  rm -f "${STOP_FLAG}" || true

  # Garante término do logger
  if kill -0 "${LOGGER_PID}" 2>/dev/null; then
    kill "${LOGGER_PID}" 2>/dev/null || true
  fi

  echo "[OK] Execução ${iter}/${RUNS} concluída. Veja os logs acima."
}

# ---------------------------
# Loop principal de execuções
# ---------------------------
for (( i=1; i<=RUNS; i++ )); do
  run_once "$i"
done

echo "=============================================================="
echo "[DONE] Todas as ${RUNS} execuções foram concluídas."
