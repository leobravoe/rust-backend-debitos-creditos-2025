#!/usr/bin/env bash
# =========================================================================================
# GUIA DIDÁTICO (PASSO A PASSO)
# -----------------------------------------------------------------------------------------
# Este script é um “lançador” de testes para Linux. Ele chama um script principal de teste
# várias vezes em sequência e, para cada execução, inicia também um coletor de estatísticas.
# Você informa quantas execuções deseja rodar passando 1 parâmetro obrigatório na linha de comando.
# Exemplo:  ./_linux_run-test-launcher.sh 5  → roda 5 execuções completas (com logs separados).
#
# Características importantes:
# - Parâmetro obrigatório valida se é inteiro ≥ 1.
# - Gera nomes de arquivos de log únicos por execução usando timestamp.
# - Cria e limpa um “flag” (arquivo STOP_FLAG) para sinalizar o término ao logger.
# - Usa trap para que CTRL+C (SIGINT) ou SIGTERM interrompam graciosamente a execução corrente,
#   encerrando o processo principal e seu grupo, e também o logger.
# - Não altera seus scripts de teste: apenas orquestra a execução repetida e o logging.
# =========================================================================================

set -Eeuo pipefail                  # “Modo estrito”:
                                    #  E: faz a shell falhar em erros dentro de funções/pipe (erre e pare).
                                    #  e: encerra se um comando falhar (status ≠ 0), salvo onde usamos “|| true”.
                                    #  u: erro ao usar variável não definida (evita typos).
                                    #  o pipefail: um pipeline falha se QUALQUER comando falhar, não só o último.

export LANG=C.UTF-8                 # Garante locale/charset consistente em UTF-8 (evita caracteres “quebrados” em logs).
export LC_ALL=C.UTF-8               # Define locale global para toda a execução do script.
export JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8 ${JAVA_TOOL_OPTIONS:-}"  # Força UTF-8 para ferramentas Java (se usadas nos testes).
export MAVEN_OPTS="-Dfile.encoding=UTF-8 ${MAVEN_OPTS:-}"                # Força UTF-8 para Maven (builds/relatórios com acentuação).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
                                    # Descobre a pasta onde este script está salvo.
                                    # - BASH_SOURCE[0]: caminho do script atual (mesmo quando chamado via symlink).
                                    # - dirname: pega só a pasta (sem o nome do arquivo).
                                    # - cd && pwd: resolve para um caminho absoluto e “limpo”.
                                    # - redirecionamentos para /dev/null evitam ruído no terminal.

if [[ $# -lt 1 ]]; then             # Verifica se pelo menos 1 argumento foi passado na linha de comando.
  echo "Uso: $0 <quantidade_execucoes>" >&2   # Mensagem de uso vai para STDERR (>&2).
  exit 64                            # Sai com código 64 (EX_USAGE): uso incorreto da linha de comando.
fi
RUNS="$1"                            # Captura o 1º parâmetro como número de execuções (string por enquanto).
if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
  echo "Erro: <quantidade_execucoes> deve ser um inteiro >= 1" >&2  # Valida: apenas dígitos e ≥ 1.
  exit 64                        # Mantém o mesmo código de erro de uso inválido.
fi

MAIN_PID=""                         # PID do processo “main” (script de teste) na execução atual (preenchido em runtime).
MAIN_PGID=""                        # PGID (ID do grupo de processos) do “main”; usamos para sinalizar todo o grupo.
LOGGER_PID=""                       # PID do processo logger (coletor de estatísticas) da execução atual.
STOP_FLAG=""                        # Caminho de um arquivo “sentinela” usado para avisar o logger que deve encerrar.

cleanup_interrupt() {               # Função chamada pelo trap para encerrar com segurança em SIGINT/SIGTERM.
  if [[ -n "${MAIN_PID:-}" ]] && kill -0 "${MAIN_PID}" 2>/dev/null; then
    kill -INT -- -"${MAIN_PGID}" 2>/dev/null || true   # 1) Envia SIGINT ao GRUPO (sinal “educado”: peça para parar).
    sleep 1                                            #    Intervalos curtos permitem encerramento ordenado.
    kill -TERM -- -"${MAIN_PGID}" 2>/dev/null || true  # 2) Se necessário, SIGTERM (mais incisivo).
    sleep 1
    kill -KILL -- -"${MAIN_PGID}" 2>/dev/null || true  # 3) Último recurso: SIGKILL (encerra imediatamente).
  fi

  [[ -n "${STOP_FLAG:-}" ]] && touch "${STOP_FLAG}" 2>/dev/null || true
                                    # Toca/cria o arquivo-flag para o logger detectar e finalizar sua iteração atual.

  if [[ -n "${LOGGER_PID:-}" ]] && kill -0 "${LOGGER_PID}" 2>/dev/null; then
    kill "${LOGGER_PID}" 2>/dev/null || true          # Tenta terminar o logger normalmente.
    sleep 1
    kill -9 "${LOGGER_PID}" 2>/dev/null || true       # Se ainda estiver vivo, força com SIGKILL.
  fi

  [[ -n "${STOP_FLAG:-}" ]] && rm -f "${STOP_FLAG}" 2>/dev/null || true
                                    # Remove o arquivo-flag para não deixar lixo se interrompido no meio.
  echo                              # Linha em branco só para legibilidade no terminal.
  echo "[INTERRUPT] Execução interrompida pelo usuário."  # Mensagem informativa sobre a interrupção.
  exit 130                          # Código 130 é convencional para “terminated by Ctrl+C (SIGINT)”.
}
trap cleanup_interrupt INT TERM     # Registra a função acima para rodar automaticamente em SIGINT/SIGTERM.

run_once() {                        # Executa UMA iteração completa do teste (main + logger + limpeza).
  local iter="$1"                   # Número da iteração atual (1, 2, 3, ...).

  local TIMESTAMP                    # Gera timestamp único para diferenciar arquivos desta iteração.
  TIMESTAMP="$(date +%Y%m%d-%H%M%S)" # Formato AAAAMMDD-HHMMSS (legível e ordenável).

  local MAIN_LOG_FILE="${SCRIPT_DIR}/__${TIMESTAMP}-iter${iter}-test_logs.txt"
                                    # Arquivo de log “principal” desta execução (saída do script de teste).
  local STATS_LOG_FILE="${SCRIPT_DIR}/__${TIMESTAMP}-iter${iter}-stats_logs.txt"
                                    # Arquivo de log de estatísticas (por exemplo, CPU/memória/rede, conforme o logger implementa).

  STOP_FLAG="${SCRIPT_DIR}/stop-logging.iter${iter}.${TIMESTAMP}.flg"
                                    # Caminho do arquivo-flag que vai sinalizar ao logger para encerrar (único por iteração).

  echo "===================================================================="  # Cabeçalho visual para separar execuções.
  echo " Iniciando execução ${iter}/${RUNS} — ${TIMESTAMP}"                   # Indica a iteração atual e o timestamp.
  echo "  Logs:"                                                              # Mostra onde encontrar os arquivos de log.
  echo "    Main : ${MAIN_LOG_FILE}"
  echo "    Stats: ${STATS_LOG_FILE}"
  echo "===================================================================="

  setsid bash "${SCRIPT_DIR}/_linux_run-test-main-logic.sh" "${MAIN_LOG_FILE}" &  # Inicia o “main” em NOVA SESSÃO (setsid).
  MAIN_PID=$!                      # $! captura o PID do processo recém-colocado em background; guardamos para gestão/sinais.

  MAIN_PGID="${MAIN_PID}"          # Por padrão, usamos o próprio PID como PGID (fallback).
  if command -v ps >/dev/null 2>&1; then                                         # Se “ps” existir, perguntamos o PGID real.
    local MAIN_PGID_PS
    MAIN_PGID_PS="$(ps -o pgid= -p "${MAIN_PID}" 2>/dev/null | tr -d " ")" || true
    if [[ -n "${MAIN_PGID_PS}" ]]; then MAIN_PGID="${MAIN_PGID_PS}"; fi          # Se obtivemos um PGID válido, usamos ele.
  fi

  bash "${SCRIPT_DIR}/_linux_run-test-stats-logger.sh" "${STATS_LOG_FILE}" "${MAIN_PID}" "${STOP_FLAG}" &  # Inicia o logger.
  LOGGER_PID=$!                   # Guarda o PID do logger para poder encerrá-lo de forma controlada depois.

  wait "${MAIN_PID}" || true      # Espera o script “main” terminar. Se ele falhar, NÃO derruba o launcher (|| true).

  touch "${STOP_FLAG}" || true    # Sinaliza ao logger para encerrar (ele deve observar a existência deste arquivo).
  sleep 2                         # Dá tempo para que o logger faça o flush final e se desligue.
  rm -f "${STOP_FLAG}" || true    # Remove o arquivo-flag para esta iteração.

  if kill -0 "${LOGGER_PID}" 2>/dev/null; then   # Se o logger ainda estiver vivo…
    kill "${LOGGER_PID}" 2>/dev/null || true     # …pede para encerrar (SIGTERM por padrão).
  fi

  echo "[OK] Execução ${iter}/${RUNS} concluída. Veja os logs acima."  # Confirma término da iteração atual.
}

for (( i=1; i<=RUNS; i++ )); do     # Laço principal: repete de 1 até RUNS, chamando a função de execução única.
  run_once "$i"                     # Roda a iteração “i” com todo o ciclo (main + logger + limpeza).
done

echo "=============================================================="   # Rodapé organizando a saída no terminal.
echo "[DONE] Todas as ${RUNS} execuções foram concluídas."             # Mensagem final de sucesso após o loop.
