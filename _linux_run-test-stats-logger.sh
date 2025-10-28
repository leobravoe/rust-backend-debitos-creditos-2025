#!/usr/bin/env bash
# ============================ VISÃO GERAL PARA INICIANTES =============================
# Este script é um “coletor de estatísticas” do Docker durante um teste de carga.
# Ele roda em paralelo ao processo principal do seu teste e, enquanto esse processo
# existir, captura instantâneos de uso de CPU/Memória/Rede/etc. com `docker stats`.
# O resultado vai para um arquivo de log, com data/hora em cada linha, em UTF-8.
# Também há um mecanismo de parada: se surgir um arquivo “bandeira” (STOP_FLAG) ou
# se o processo principal finalizar, o coletor encerra de forma limpa. Além disso,
# se você apertar Ctrl+C, registramos o evento e saímos com um código padrão (130).
# A ideia é deixar um rastro confiável do consumo dos containers durante a prova.
# =====================================================================================

set -Eeuo pipefail
# “Modo estrito” do Bash:
#  -E: mantém o comportamento de traps de erro dentro de funções/subshells;
#  -e: se um comando falhar (status ≠ 0), o script aborta (salvo onde tratamos);
#  -u: uso de variáveis não definidas vira erro (evita typos silenciosos);
#  -o pipefail: num pipeline, falha se QUALQUER comando falhar (não só o último).
# Isso ajuda a detectar problemas cedo e evita logs “enganosamente verdes”.

# --------------------------- PARÂMETROS OBRIGATÓRIOS/OPCIONAIS ---------------------------
LOGFILE="${1:?Usage: $0 <logfile> <main_pid> [stop_flag]}"
# 1º argumento: caminho do arquivo que vai receber as estatísticas. Se faltar, erro.

MAIN_PID="${2:?Usage: $0 <logfile> <main_pid> [stop_flag]}"
# 2º argumento: PID do processo “principal” do teste. Monitoramos sua existência.

STOP_FLAG="${3:-}"
# 3º argumento (opcional): caminho de um arquivo-sentinela. Se ele aparecer, paramos.

# --------------------------------- LOCALIZAÇÃO/ENCODING ---------------------------------
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
# Garantimos que timestamps e textos usem UTF-8, evitando acentos corrompidos.
# O locale “C.UTF-8” é leve e suficiente para a maioria dos ambientes de CI/containers.

# -------------------------------- FUNÇÃO DE TIMESTAMP -----------------------------------
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
# Retorna algo como 2025-10-28T15:42:07-0300. Usamos em cada linha para reconstruir a linha do tempo.

# ------------------------------ PREPARO DO ARQUIVO DE LOG --------------------------------
touch "${LOGFILE}"
# Cria o arquivo (se não existir) e garante permissão de escrita antes do loop.

echo "$(ts) Logger iniciado. Monitorando PID=${MAIN_PID}" >> "${LOGFILE}"
# Primeira linha do log: marca o início e informa qual PID estamos vigiando.

# ----------------------------- TRATAMENTO DE SINAIS (CTRL+C) -----------------------------
cleanup() { echo "$(ts) Logger interrompido por sinal. Encerrando." >> "${LOGFILE}"; exit 130; }
# Se recebermos SIGINT (Ctrl+C) ou SIGTERM, registramos e encerramos com 130 (convencional para “interrompido pelo usuário”).

trap cleanup INT TERM
# Conecta os sinais INT/TERM à função acima. Assim, mesmo em interrupções, o log fica coerente.

# --------------------------------- LOOP DE COLETA (2s) ----------------------------------
while true; do
  # Laço infinito controlado por condições de saída claras. A cada volta:
  # 1) Checamos se foi pedido para parar via STOP_FLAG.
  # 2) Checamos se o processo principal ainda existe.
  # 3) Tentamos coletar `docker stats --no-stream` e gravar com timestamp.
  # 4) Esperamos 2s e repetimos, criando uma série temporal leve e legível.

  if [[ -n "${STOP_FLAG}" && -f "${STOP_FLAG}" ]]; then
    # Sinal de parada externo: outro script criou o arquivo-bandeira.
    echo "$(ts) Sinal de parada detectado. Encerrando logger." >> "${LOGFILE}"
    break
  fi

  if ! kill -0 "${MAIN_PID}" 2>/dev/null; then
    # O “kill -0” não mata: apenas testa se o PID existe. Se falhar, o main terminou.
    echo "$(ts) Processo principal finalizado. Encerrando logger." >> "${LOGFILE}"
    break
  fi

  if docker stats --no-stream >/dev/null 2>&1; then
    # Se o Docker estiver acessível e o daemon responder, coletamos um snapshot único.
    docker stats --no-stream | while IFS= read -r line; do
      # Prefixamos cada linha com timestamp e gravamos no arquivo, mantendo o formato de tabela.
      printf '%s %s\n' "$(ts)" "$line" >> "${LOGFILE}"
    done
    printf '\n' >> "${LOGFILE}"
    # Linha em branco separa “blocos” de amostras, facilitando leitura posterior.
  else
    # Falha pontual (sem Docker, permissão, ou daemon indisponível): registramos o erro e seguimos.
    printf '%s [docker stats erro]\n' "$(ts)" >> "${LOGFILE}"
  fi

  sleep 2
  # Intervalo entre amostras. 2s costuma equilibrar granularidade e tamanho do log.
done
# Fim do loop. Chegamos aqui por STOP_FLAG, por término do processo principal ou por sinal capturado.
