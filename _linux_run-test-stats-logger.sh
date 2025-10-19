#!/usr/bin/env bash
# ^ Shebang: instrui o sistema a executar este arquivo com o interpretador "bash".
#   Usar "/usr/bin/env" ajuda a encontrar o bash no PATH, tornando o script mais portátil.

# _linux_run-test-stats-logger.sh — Linux docker stats logger
# ---------------------------------------------------------------------------
# O QUE ESTE SCRIPT FAZ?
# - É um "logger" de estatísticas do Docker.
# - Enquanto o processo principal (MAIN_PID) estiver vivo, ele coleta periodicamente
#   a saída do comando `docker stats --no-stream` e grava em um arquivo de log.
# - Ele também pode parar quando detecta um "arquivo sinal" (STOP_FLAG) criado por outro script.
# - Trata sinais (CTRL+C / SIGTERM) para encerrar de forma limpa.
# ---------------------------------------------------------------------------

set -Eeuo pipefail
# set -E : mantém o comportamento do "ERR trap" em funções/subshells.
# set -e : encerra o script se algum comando falhar (exit code != 0).
# set -u : erro ao usar variável não definida (evita bugs silenciosos).
# pipefail : se houver "cmd1 | cmd2", o pipeline falha se QUALQUER etapa falhar.
# Esses flags deixam o script mais robusto e previsível.

# ---------------------------------------------------------------------------
# PARÂMETROS DE ENTRADA
# ---------------------------------------------------------------------------
# 1º argumento: caminho do arquivo de log onde serão gravadas as estatísticas.
# 2º argumento: PID do processo principal (aquele que estamos monitorando).
# 3º argumento (opcional): caminho de um arquivo-flag; se existir, sinaliza para parar.
# A notação ${var:?msg} força erro (e encerra) se o argumento obrigatório não for fornecido.
LOGFILE="${1:?Usage: $0 <logfile> <main_pid> [stop_flag]}"
MAIN_PID="${2:?Usage: $0 <logfile> <main_pid> [stop_flag]}"
STOP_FLAG="${3:-}"

# ---------------------------------------------------------------------------
# LOCALE/ENCODING
# ---------------------------------------------------------------------------
# Garante que timestamps, acentos e caracteres especiais sejam consistentes (UTF-8).
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# ---------------------------------------------------------------------------
# FUNÇÃO DE TIMESTAMP
# ---------------------------------------------------------------------------
# ts() imprime data/hora no formato ISO-like com timezone, ex: 2025-09-24T13:22:05-0300
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# ---------------------------------------------------------------------------
# PREPARA O ARQUIVO DE LOG
# ---------------------------------------------------------------------------
# touch cria o arquivo se não existir (ou atualiza o "modified time" se existir).
touch "${LOGFILE}"

# Registra uma linha inicial avisando que o logger começou e qual PID está sendo monitorado.
echo "$(ts) Logger iniciado. Monitorando PID=${MAIN_PID}" >> "${LOGFILE}"

# ---------------------------------------------------------------------------
# TRATAMENTO DE SINAIS (CTRL+C / SIGTERM)
# ---------------------------------------------------------------------------
# Se o usuário interromper (SIGINT) ou o sistema pedir término (SIGTERM),
# registramos no log e saímos com código 130 (convenção para interrupt).
cleanup() { echo "$(ts) Logger interrompido por sinal. Encerrando." >> "${LOGFILE}"; exit 130; }
trap cleanup INT TERM

# ---------------------------------------------------------------------------
# LOOP PRINCIPAL DE COLETA
# ---------------------------------------------------------------------------
# Enquanto for verdadeiro (infinito até condição de parada), fazemos:
# 1) Checar condições de parada (STOP_FLAG e vida do MAIN_PID).
# 2) Se Docker disponível, coletar `docker stats --no-stream` e anexar ao log.
# 3) Esperar 2 segundos e repetir.
while true; do
  # ---------------------------------------------------------
  # CONDIÇÕES DE PARADA
  # ---------------------------------------------------------

  # 1) Se foi passado um STOP_FLAG e o arquivo existe, encerramos o logger.
  if [[ -n "${STOP_FLAG}" && -f "${STOP_FLAG}" ]]; then
    echo "$(ts) Sinal de parada detectado. Encerrando logger." >> "${LOGFILE}"
    break
  fi

  # 2) Se o processo principal já morreu, também paramos o logger.
  #    O "kill -0 <PID>" NÃO MATA o processo: apenas testa se o PID existe e é acessível.
  #    Se retornar erro, significa que o processo não está mais rodando.
  if ! kill -0 "${MAIN_PID}" 2>/dev/null; then
    echo "$(ts) Processo principal finalizado. Encerrando logger." >> "${LOGFILE}"
    break
  fi

  # ---------------------------------------------------------
  # COLETA DE ESTATÍSTICAS DO DOCKER
  # ---------------------------------------------------------
  # `docker stats --no-stream` imprime uma tabela de uso de CPU/Memória/Rede/etc
  # dos containers, mas somente uma fotografia (sem ficar atualizando ao vivo).
  # Checamos primeiro se o comando funciona (Docker rodando, permissão, etc).
  if docker stats --no-stream >/dev/null 2>&1; then
    # Se o comando funciona, executamos de verdade e lemos linha a linha.
    docker stats --no-stream | while IFS= read -r line; do
      # Para cada linha, prefixamos com timestamp e gravamos no LOGFILE.
      printf '%s %s
' "$(ts)" "$line" >> "${LOGFILE}"
    done
    # Linha em branco para separar blocos de amostras (melhora leitura do log).
    printf '\n' >> "${LOGFILE}"
  else
    # Se não conseguimos rodar `docker stats`, registramos um erro pontual no log.
    printf '%s [docker stats erro]\n' "$(ts)" >> "${LOGFILE}"
  fi

  # Aguarda 2 segundos antes da próxima coleta, controlando a frequência do log.
  sleep 2
done
