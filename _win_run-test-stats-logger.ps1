# =========================================================================================
# LOGGER DE ESTATÍSTICAS (PowerShell) — EXPLICAÇÃO PASSO A PASSO PARA INICIANTES
# Este script acompanha um processo “principal” (identificado por PID) e, enquanto ele
# estiver ativo, escreve periodicamente no arquivo de log um cabeçalho com data/hora em GMT
# e a fotografia do uso de recursos dos containers via `docker stats --no-stream`.
# Ele também respeita um “arquivo-sinal” (stop-logging.flg): se existir, o logger encerra.
# Todos os textos são gravados em UTF-8 para evitar problemas com acentuação.
# =========================================================================================

param (
    [string]$LogFile,
    # Caminho do arquivo onde registraremos as mensagens e as estatísticas coletadas.

    [int]$ProcessId
    # O número (PID) do processo que estamos vigiando; quando ele termina, o logger para.
)

# A linha abaixo configura o padrão de codificação para que qualquer uso de Out-File no script
# escreva em UTF-8. Isso ajuda a manter acentuação correta em editores e em pipelines.
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

# Aqui fazemos o mesmo ajuste para Add-Content, garantindo que os acréscimos ao log também
# usem UTF-8 (sem depender do padrão do sistema).
$PSDefaultParameterValues['Add-Content:Encoding'] = 'utf8'

# Registramos no começo do arquivo de log que o logger iniciou e qual PID está sendo monitorado.
# Isso é útil para auditoria e para entender, depois, qual execução gerou aquele log.
Add-Content -Path $LogFile -Value "[Logger] Iniciado. A monitorizar o Processo com ID: $ProcessId"

# Entramos em um laço “infinito” controlado por condições de parada:
# 1) se aparecer o arquivo stop-logging.flg, encerramos com elegância;
# 2) se o processo monitorado (PID) não existir mais, também encerramos;
# 3) caso contrário, coletamos as estatísticas e dormimos 2s antes da próxima rodada.
while ($true) {

    # Condição de parada 1: “arquivo-sinal” (flag) criado externamente para pedir que o logger pare.
    # É um mecanismo simples de coordenação entre scripts.
    if (Test-Path "stop-logging.flg") {
        # Registramos no log que recebemos o sinal e saímos com código 0 (sucesso).
        Add-Content -Path $LogFile -Value "[Logger] Sinal de parada recebido. Encerrando."
        exit 0
    }

    # Condição de parada 2: verificamos se o processo monitorado ainda existe.
    # Se o Get-Process falhar (ou devolver $null), significa que o PID terminou.
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue

    # Se o processo não está mais rodando, avisamos no log e encerramos o logger.
    if ($null -eq $process) {
        Add-Content -Path $LogFile -Value "[Logger] Processo principal (PID: $ProcessId) foi fechado. Encerrando o logger."
        exit 0
    }

    # A partir daqui sabemos que devemos coletar uma “amostra” de estatísticas.
    # Primeiro, criamos um timestamp em GMT/UTC para padronizar a linha do tempo no log,
    # independente do fuso horário da máquina que rodou o teste.
    $utcDate = (Get-Date).ToUniversalTime()

    # Em seguida, formatamos a data como “YYYY-MM-DD HH:mm:ss” e acrescentamos “GMT” ao final,
    # deixando explícito para quem lê o log que a marca de tempo está em horário universal.
    $timestamp = $utcDate.ToString("yyyy-MM-dd HH:mm:ss")
    $header = "`n$timestamp GMT --- Stats coletados ---"

    # Escrevemos um cabeçalho separando visualmente os blocos de amostras.
    # O acento grave (`) é o caractere de escape do PowerShell; aqui ele cria uma quebra de linha inicial.
    Add-Content -Path $LogFile -Value $header

    # Agora coletamos a fotografia de uso de recursos dos containers Docker.
    # A opção --no-stream pede apenas uma “foto” do momento, e não um fluxo contínuo.
    $stats = docker stats --no-stream

    # Anexamos a saída do docker ao arquivo. Assim, cada bloco no log contém:
    #  - um cabeçalho com timestamp em GMT
    #  - a tabela de CPU/Memória/Rede/etc por container naquele instante
    Add-Content -Path $LogFile -Value $stats

    # Pausamos 2 segundos entre as coletas para não gerar overhead desnecessário nem inflar o log.
    Start-Sleep -Seconds 2
}
