# _win_run-test-stats-logger.ps1
# Monitoriza o processo principal através do seu PID, adicionando um timestamp GMT a cada entrada.

param (
    [string]$LogFile,
    [int]$ProcessId
)

# Garante que toda a escrita de ficheiros seja UTF-8.
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
$PSDefaultParameterValues['Add-Content:Encoding'] = 'utf8'

Add-Content -Path $LogFile -Value "[Logger] Iniciado. A monitorizar o Processo com ID: $ProcessId"

while ($true) {
    if (Test-Path "stop-logging.flg") {
        Add-Content -Path $LogFile -Value "[Logger] Sinal de parada recebido. Encerrando."
        exit 0
    }

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        Add-Content -Path $LogFile -Value "[Logger] Processo principal (PID: $ProcessId) foi fechado. Encerrando o logger."
        exit 0
    }

    # --- AJUSTE CRÍTICO AQUI ---
    # 1. Obtém a data/hora atual e converte para o fuso horário universal (GMT/UTC).
    $utcDate = (Get-Date).ToUniversalTime()
    
    # 2. Formata o timestamp no formato solicitado, adicionando "GMT" no final.
    $timestamp = $utcDate.ToString("yyyy-MM-dd HH:mm:ss")
    $header = "`n$timestamp GMT --- Stats coletados ---"
    
    # 3. Escreve o cabeçalho no ficheiro de log.
    Add-Content -Path $LogFile -Value $header
    
    # 4. Executa 'docker stats' e anexa a sua saída.
    $stats = docker stats --no-stream
    Add-Content -Path $LogFile -Value $stats

    Start-Sleep -Seconds 2
}