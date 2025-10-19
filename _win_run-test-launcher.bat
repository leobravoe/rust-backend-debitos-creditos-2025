:: _win_run-test-launcher.bat
:: Versão final com gestão de PID, repetição N vezes e caminhos de log absolutos.
@echo off
chcp 65001 > nul
setlocal EnableExtensions

:: =======================
:: Leitura do parâmetro N
:: =======================
set "RUNS=%~1"
if not defined RUNS set "RUNS=1"

:: ---- Validação numérica sem findstr (robusta com chcp 65001) ----
set "NONNUM="
for /f "tokens=* delims=0123456789" %%A in ("%RUNS%") do set "NONNUM=%%A"
if defined NONNUM (
  echo ERRO: Informe um numero inteiro positivo de execucoes. Ex.: _win_run-test-launcher.bat 3
  exit /b 1
)
if %RUNS% lss 1 (
  echo ERRO: O numero de execucoes deve ser >= 1.
  exit /b 1
)

echo.
echo ====================================================================
echo      INICIANDO TESTE DE CARGA E MONITORAMENTO  (Total: %RUNS%x)
echo ====================================================================
echo.

:: Loop principal: executa N vezes
for /L %%R in (1,1,%RUNS%) do (
  call :one_run %%R
  if errorlevel 1 (
    echo.
    echo [ERRO] na execucao %%R. Abortando as demais.
    exit /b 1
  )
  echo.
  echo --- Execucao %%R concluida ---
  echo.
)

echo Todas as %RUNS% execucoes foram finalizadas.
exit /b 0

:: ===========================================================
:: Rotina de uma execucao completa (%%R: indice da execucao)
:: ===========================================================
:one_run
setlocal EnableDelayedExpansion

set "RUN_IDX=%~1"

:: --- Timestamp por execucao ---
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /format:list') do set DATETIME=%%I
set "TIMESTAMP=%DATETIME:~0,8%-%DATETIME:~8,6%"

:: --- Arquivos de log e janela (únicos por execucao) ---
set "MAIN_LOG_FILE=%~dp0__%TIMESTAMP%-run%RUN_IDX%-gatling_logs.txt"
set "STATS_LOG_FILE=%~dp0__%TIMESTAMP%-run%RUN_IDX%-docker-stats_logs.txt"
set "WINDOW_TITLE=Teste_Rinha_Backend-%TIMESTAMP%-run%RUN_IDX%"
set "STOP_FLAG=stop-logging-run%RUN_IDX%.flg"

echo ================================================================
echo Execucao !RUN_IDX! de %RUNS%
echo Janela do teste:  "!WINDOW_TITLE!"
echo Log principal:     "!MAIN_LOG_FILE!"
echo Log docker stats:  "!STATS_LOG_FILE!"
echo ================================================================
echo.
echo UMA NOVA JANELA SERA ABERTA PARA EXECUTAR O TESTE.
echo PARA INTERROMPER APENAS ESTA EXECUCAO, FECHE ESSA JANELA.
echo.

if exist "!STOP_FLAG!" del "!STOP_FLAG!" >nul 2>&1

:: --- Inicia a Lógica Principal ---
echo Iniciando a janela de teste (via PowerShell)...
start "!WINDOW_TITLE!" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_win_run-test-main-logic.ps1" -FinalLogFile "!MAIN_LOG_FILE!"

:: --- Captura o PID pelo título da janela ---
echo Aguardando a janela de teste ser criada para capturar o seu PID...
set "PID="

:find_pid_loop
for /f "tokens=2 delims=," %%a in ('
  tasklist /v /fi "WINDOWTITLE eq !WINDOW_TITLE!" /fo csv /nh
') do set "PID=%%~a"

if defined PID (
  echo Janela de teste encontrada com PID: !PID!
) else (
  timeout /t 1 /nobreak > nul
  goto :find_pid_loop
)

:: --- Inicia o Logger, passando o PID ---
echo Iniciando o logger do Docker Stats em segundo plano...
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_win_run-test-stats-logger.ps1" -LogFile "!STATS_LOG_FILE!" -ProcessId !PID!

:: --- Monitoriza Ativamente o Processo de Teste ---
echo O teste esta em execucao. Este terminal esta monitorizando a execucao !RUN_IDX!.
:wait_for_process_end
  tasklist /fi "PID eq !PID!" | find "!PID!" > nul
  if errorlevel 1 (
    echo Janela de teste foi fechada.
    goto :cleanup_and_return
  )
  timeout /t 5 /nobreak > nul
  goto :wait_for_process_end

:cleanup_and_return
echo Finalizando o logger...
echo stop > "!STOP_FLAG!"
timeout /t 3 > nul
del "!STOP_FLAG!" >nul 2>&1

echo Execucao !RUN_IDX! concluida. Verifique os arquivos de log gerados.
endlocal & exit /b 0
