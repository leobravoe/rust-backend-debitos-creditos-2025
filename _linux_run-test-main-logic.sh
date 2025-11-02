#!/usr/bin/env bash
# VISÃO GERAL: este script é a “espinha dorsal” do seu fluxo de testes em Linux. Ele prepara um ambiente limpo com Docker Compose, valida que todos os serviços estejam prontos, aquece as APIs para evitar “cold start” enviesando métricas, limpa o banco para começar do zero e dispara a simulação de carga do Gatling. Tudo isso é cuidadosamente logado em UTF-8, com timestamps, e com tratamento de sinais para encerrar com elegância quando você interrompe.

set -Eeuo pipefail
# Estes flags deixam o shell previsível e seguro para testes: “-e” faz o script parar se um comando falhar, “-u” evita uso de variáveis não definidas, “-o pipefail” propaga falhas em pipelines, e “-E” garante que handlers de erro funcionem dentro de funções e subshells. Isso reduz erros silenciosos e facilita detectar causas reais.

on_signal() {
  # Este manipulador é chamado quando você pressiona Ctrl+C (SIGINT) ou o processo recebe SIGTERM. A ideia é interromper com cuidado, pedindo ao Docker Compose que pare os serviços, para não deixar recursos “pendurados”. Ao final, saímos com código 130, que é o padrão para interrupção pelo usuário.
  if command -v docker >/dev/null 2>&1; then
    docker compose stop >/dev/null 2>&1 || true
  fi
  exit 130
}
trap on_signal INT TERM
# Aqui amarramos os sinais a “on_signal”. Isso significa que, se você interromper, o script não desaba de repente: ele primeiro tenta parar os containers de forma limpa e só então termina.

LOGFILE="${1:-__test_logs-$(date +%Y%m%d-%H%M%S).txt}"
# O primeiro argumento do script, se fornecido, define o arquivo de log principal. Se não houver argumento, criamos um nome automático com data e hora (como 2025-10-28-15:22:41), garantindo que execuções diferentes não sobrescrevam logs.

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8 -Dsun.stdout.encoding=UTF-8 -Dsun.stderr.encoding=UTF-8 ${JAVA_TOOL_OPTIONS:-}"
export MAVEN_OPTS="-Dfile.encoding=UTF-8 ${MAVEN_OPTS:-}"
# Estas variáveis garantem que tudo fale a mesma “língua” de caracteres: UTF-8 do início ao fim. Isso evita que acentos e símbolos apareçam corrompidos no console e nos arquivos, inclusive para ferramentas Java/Maven que o Gatling usa.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# Descobrimos a pasta onde o script está salvo, de forma absoluta e robusta, mesmo quando ele é chamado por atalhos. Isso nos permite usar caminhos relativos previsíveis a partir daqui.
cd "${SCRIPT_DIR}"
# Entramos na pasta do script para que todos os comandos subsequentes usem os caminhos que esperamos, sem depender da pasta onde o usuário estava.

ts() { date '+%Y-%m-%d %H:%M:%S.%3N'; }
# Pequena função utilitária que devolve um timestamp legível com milissegundos. Usamos em cada linha de log para reconstruir a linha do tempo depois.

wlog() {
  # Função de logging centralizada: imprime no console e também anexa no arquivo de log. Assim você acompanha ao vivo e, ao mesmo tempo, mantém um histórico completo para comparar execuções.
  printf '%s %s
' "$(ts)" "$*" | tee -a "${LOGFILE}"
}

run_cmd() {
  # Executor genérico com registro. Recebe um título (para contexto no log), um meio de falha (“ignore” para não abortar em falha, “strict” para propagar erro) e o comando real com seus argumentos. Também força buffer por linha para evitar travamentos em pipes longos.
  local title="$1"; shift
  local ignore="${1}"; shift
  wlog "[CMD] ${title}"
  if ! stdbuf -oL -eL "$@" 2>&1 | tee -a "${LOGFILE}"; then
    if [[ "${ignore}" != "ignore" ]]; then
      return 1
    fi
  fi
}

wlog "[PASSO 1/6] Parando e removendo containers antigos (ignorar falhas)..."
run_cmd "docker compose down -v" "ignore" docker compose down -v || true
# Começamos sempre “do zero”: desligamos e removemos containers e volumes anteriores. Ignoramos erros aqui porque, se não houver nada para remover, isso não deve abortar todo o fluxo.

wlog "[PASSO 2/6] Forcando a remocao dos containers......"
run_cmd "docker rm -f postgres app1 app2 nginx" "ignore" docker rm -f postgres app1 app2 nginx || true
# Garantimos que nenhum container com esses nomes sobreviveu à primeira limpeza. É uma segunda camada de proteção para evitar estados zumbis que baguncem os próximos passos.

wlog ""
# Linha em branco proposital para separar visualmente as fases no log.
wlog "[PASSO 3/6] Construindo e subindo novos containers (ignorar falhas)..."
run_cmd "docker compose up -d --build --compatibility --force-recreate " "ignore" docker compose --compatibility up -d --build --force-recreate || true
# Agora subimos tudo de novo. “--build” recompila imagens caso algo tenha mudado, “--force-recreate” não tenta reaproveitar containers antigos, e “--compatibility” traduz limites de recursos do Compose para ambientes sem Swarm. Rodamos em modo destacado (-d) para que o script continue controlando o restante.

wlog ""
# Nova quebra visual para destacar a etapa de readiness.
wlog "[PASSO 4/6] Verificacao de Saude dos Containers..."
# Entramos na fase de espera ativa (“readiness”). Não basta os processos estarem “de pé”: precisamos saber se estão prontos para receber tráfego. Para isso, conversamos com o Docker e, se houver healthcheck, exigimos estado “healthy”.

SERVICES=("postgres" "app1" "app2" "nginx")
# Serviços essenciais que precisamos ver prontos. A ordem aqui influencia apenas a apresentação nos logs, não a lógica.

TIMEOUT=90
DEADLINE=$(( $(date +%s) + TIMEOUT ))
# Prazo máximo (em segundos) para toda a verificação de readiness. Evita loops infinitos em caso de configuração incorreta.

get_ids_for_service() {
  docker compose ps -q "$1" 2>/dev/null | sed '/^$/d' || true
}
# Devolve os IDs (hashes) dos containers do serviço informado. Trabalhar por ID é mais robusto do que por nome para inspeções.

is_container_running() {
  local id="$1"
  [[ "$(docker inspect -f '{{.State.Status}}' "${id}" 2>/dev/null || echo 'unknown')" == "running" ]]
}
# Verifica se o container está no estado “running”. Só depois faz sentido cobrar healthcheck.

has_healthcheck() {
  local id="$1"
  [[ -n "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${id}" 2>/dev/null)" ]]
}
# Detecta se existe healthcheck configurado para esse container (pode não haver, dependendo da imagem).

is_container_healthy() {
  local id="$1"
  [[ "$(docker inspect -f '{{.State.Health.Status}}' "${id}" 2>/dev/null || echo 'none')" == "healthy" ]]
}
# Quando há healthcheck, “healthy” indica que passou nas verificações internas (ex.: resposta a um endpoint).

all_services_ready() {
  # A regra de ouro: cada serviço precisa ter ao menos um container running; se o serviço tem healthcheck, esse container também precisa estar healthy. Só então consideramos o conjunto pronto.
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
  # Versão “contador” da função anterior, útil para logs progressivos. Ela não decide; apenas informa quantos serviços já atendem aos critérios.
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
  # Loop de espera com feedback: mostramos quantos serviços já estão prontos e saímos assim que todos estiverem. Se não atingir a condição, tentamos de novo depois de alguns segundos.
  hc=$(healthy_count)
  # Armazenamos em “hc” a contagem atual de serviços prontos para registrar no log.
  wlog "Aguardando... (${hc} de ${#SERVICES[@]} servicos prontos)"
  if all_services_ready; then
    wlog "Todos os servicos essenciais estao prontos! A continuar."
    break
  fi
  sleep 5
  # Pause curto antes de tentar novamente; reduz churn de inspeções e dá tempo para os healthchecks atualizarem.
done

if ! all_services_ready; then
  # Se chegou aqui, o tempo acabou e o conjunto não está OK. Escrevemos um snapshot do estado dos containers para você diagnosticar rapidamente e abortamos com código de erro simples.
  wlog ""
  wlog "--- ESTADO ATUAL DOS CONTAINERS ---"
  docker compose ps | tee -a "${LOGFILE}" >/dev/null || true
  wlog "Timeout: Nem todos os containers ficaram prontos em ${TIMEOUT} segundos."
  exit 1
fi

wlog ""
# Quebra visual antes do aquecimento.
wlog "[PASSO 4.5/6] Aquecendo as APIs (Warm-up)..."
# O aquecimento faz chamadas leves antes do teste real para “esquentar” caches, JITs, conexões e pools. Isso melhora a repetibilidade das medições e aproxima o cenário de produção, onde raramente tudo está 100% frio.
sleep 3
# Pequena espera para garantir que serviços recém-“healthy” tenham estabilizado antes do primeiro acesso real.
BASE_URL="http://localhost:9999/clientes"
# Esta URL passa pelo Nginx, que distribui entre as instâncias de aplicação. Isso aquece também o balanceador e o caminho real do tráfego.
WARMUP_PAYLOAD=$(printf '{"valor":1,"tipo":"c","descricao":"warmup"}')
# Enviamos um payload mínimo, válido e barato. O foco é ativar o caminho crítico da aplicação com o menor custo possível.

for run in {1..5}; do
    # Repetimos o aquecimento algumas vezes para fixar caches e JIT, reduzindo variabilidade inicial entre execuções.
    wlog "=== Rodada ${run} de aquecimento ==="

    for id in {1..5}; do
        EXTRATO_URL="${BASE_URL}/${id}/extrato"
        wlog "Aquecendo ID ${id}: GET ${EXTRATO_URL}"
        # Flags do curl: -f (falha em HTTP >= 400), -s (silencioso) e -o /dev/null (descarta corpo da resposta). Mantemos apenas o status.
        curl -f -s -o /dev/null "${EXTRATO_URL}" \
            || wlog " (Ignorando erro de aquecimento GET para ID ${id})"
    done

    for id in {1..5}; do
        TRANSACAO_URL="${BASE_URL}/${id}/transacoes"
        wlog "Aquecendo ID ${id}: POST ${TRANSACAO_URL}"
        # POST com JSON leve aquecendo a trilha de gravação/validação. Novamente descartamos o corpo e registramos somente falhas relevantes.
        curl -f -s -o /dev/null \
            -H "Content-Type: application/json" \
            -d "${WARMUP_PAYLOAD}" \
            "${TRANSACAO_URL}" \
            || wlog " (Ignorando erro de aquecimento POST para ID ${id})"
    done
done

wlog "Aquecimento concluído. O banco será limpo a seguir."
# Após o warm-up, voltamos o estado dos dados ao “ponto zero” para que o teste tenha condições iniciais padronizadas e comparáveis entre execuções.

sleep 4
# Pequena espera para garantir que o aquecimento terminou.

wlog ""
# Separador visual antes da rotina de limpeza do banco.
wlog "[PASSO 5/6] Limpando o banco de dados..."
PG_ID="$(docker compose ps -q postgres | head -n1 || true)"
# Capturamos o ID do container Postgres (se houver mais de um por algum motivo, pegamos o primeiro).

if [[ -z "${PG_ID}" ]]; then
  wlog "Aviso: container do postgres nao encontrado; pulando limpeza."
else
  DB_TIMEOUT=90
  DB_DEADLINE=$(( $(date +%s) + DB_TIMEOUT ))
  # Antes de rodar comandos SQL, garantimos que o banco aceite conexões. Tentamos “pg_isready” se existir; se não, caímos para um SELECT simples. Isso evita erros transitórios de inicialização.

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
    # Pequena espera entre tentativas para não saturar o container durante a subida.
  done

  docker exec "${PG_ID}" psql -U postgres -d postgres_api_db -v ON_ERROR_STOP=1 \
    -c "TRUNCATE TABLE transactions" \
    -c "UPDATE accounts SET balance = 0" \
    2>&1 | tee -a "${LOGFILE}"
  # Limpeza efetiva: TRUNCATE remove todas as transações; UPDATE zera saldos. ON_ERROR_STOP aborta na primeira falha para evitar estado parcial. Tudo é registrado no log.
fi

wlog ""
# Separador visual antes da etapa final de execução do teste.
wlog "[PASSO 6/6] Executando o teste de carga com Gatling..."
# Chegamos ao grande momento: disparamos a simulação configurada no projeto Gatling. Entramos na pasta “gatling” para que o Maven encontre o pom e as classes corretas.
pushd "${SCRIPT_DIR}/gatling" >/dev/null

stdbuf -oL -eL mvn -B -Dfile.encoding=UTF-8 \
  gatling:test -Dgatling.simulationClass=simulations.RinhaBackendCrebitosSimulation \
  2>&1 | tee -a "${LOGFILE}"
# Executamos o plugin do Gatling via Maven (modo batch -B), forçando UTF-8 e buffer por linha para logs previsíveis. A classe de simulação é informada explicitamente para controlar qual carga rodar.

G_EXIT=${PIPESTATUS[0]}
# Em pipelines, “$?” só captura o último comando. “PIPESTATUS[0]” guarda o status do primeiro (o mvn), que é o que nos importa para saber se a simulação foi bem-sucedida.

popd >/dev/null
# Voltamos para a pasta original, mantendo o ambiente limpo e previsível para scripts que venham depois.

if [[ ${G_EXIT} -ne 0 ]]; then
  wlog "Falha ao executar o teste do Gatling. Exit=${G_EXIT}"
  exit ${G_EXIT}
fi
# Se o Gatling falhou, propagamos o mesmo código de saída. Isso é importante em CI/CD para marcar a etapa como falha e interromper pipelines subsequentes com base em critério objetivo.

wlog "Teste concluido com sucesso."
# Mensagem final feliz. A partir deste ponto, você deve analisar os relatórios do Gatling e os logs gerados para extrair métricas (p95, p99, médias) e comparar as versões sob teste.