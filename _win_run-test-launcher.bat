:: ================================================================================
:: LAUNCHER DE TESTES EM WINDOWS (.BAT) — EXPLICAÇÃO PASSO A PASSO PARA INICIANTES
:: Este arquivo automatiza execuções repetidas do seu teste de carga. Ele valida a
:: quantidade pedida de execuções, prepara nomes de logs com timestamp, abre o teste
:: em uma nova janela do PowerShell, descobre o PID dessa janela para monitorar o
:: andamento, inicia um logger de Docker em paralelo e, ao final de cada rodada,
:: encerra o logger com um “arquivo-sinal”. O objetivo é garantir repetibilidade,
:: organização de logs e controle claro do ciclo de vida de cada execução.
:: ================================================================================

@echo off
:: Desativa a “ecoagem” de comandos para que o console mostre apenas mensagens úteis.

chcp 65001 > nul
:: Configura o console para UTF-8 (65001), evitando acentos quebrados e garantindo logs legíveis.

setlocal EnableExtensions
:: Habilita extensões do CMD (necessárias para recursos modernos em scripts .bat).

:: ===================== ENTRADA: QUANTAS EXECUÇÕES RODAR =====================
set "RUNS=%~1"
:: Pega o 1º argumento como a quantidade total de execuções desejadas (pode vir vazio).

if not defined RUNS set "RUNS=1"
:: Se o usuário não informou valor, padroniza para 1 execução (executa ao menos uma vez).

:: ===================== VALIDAÇÃO: GARANTIR INTEIRO >= 1 =====================
set "NONNUM="
:: Variável auxiliar: se contiver algo, significa que RUNS tinha caracteres não numéricos.

for /f "tokens=* delims=0123456789" %%A in ("%RUNS%") do set "NONNUM=%%A"
:: Remove os dígitos 0–9 da string; se sobrar algo (letra/símbolo), então não é número puro.

if defined NONNUM (
  :: Mensagem amigável orientando o uso correto quando o valor não for numérico válido.
  echo ERRO: Informe um numero inteiro positivo de execucoes. Ex.: _win_run-test-launcher.bat 3
  exit /b 1
)
if %RUNS% lss 1 (
  :: Rejeita zero ou negativos, pois não faria sentido executar menos de uma vez.
  echo ERRO: O numero de execucoes deve ser >= 1.
  exit /b 1
)

:: ============================ CABEÇALHO VISUAL =============================
echo.
echo ====================================================================
echo      INICIANDO TESTE DE CARGA E MONITORAMENTO  (Total: %RUNS%x)
echo ====================================================================
echo.
:: As linhas acima organizam a saída do console, facilitando identificar o início da bateria.

:: ====================== LAÇO PRINCIPAL: RODAR N VEZES ======================
for /L %%R in (1,1,%RUNS%) do (
  :: Para cada rodada (%%R), chamamos a rotina :one_run que executa um ciclo completo.
  call :one_run %%R
  if errorlevel 1 (
    :: Se a rodada sinalizar erro, interrompemos as demais para não mascarar falhas.
    echo.
    echo [ERRO] na execucao %%R. Abortando as demais.
    exit /b 1
  )
  :: Feedback simples para marcar a conclusão de cada rodada na tela.
  echo.
  echo --- Execucao %%R concluida ---
  echo.
)

echo Todas as %RUNS% execucoes foram finalizadas.
:: Mensagem final de sucesso quando todo o conjunto termina sem erros.
exit /b 0

:: =============================================================================
:: :one_run — UMA EXECUÇÃO COMPLETA (abre janela, descobre PID, inicia logger)
:: Esta rotina encapsula uma única rodada: gera nomes únicos, inicia o teste
:: principal em uma nova janela, encontra o PID para monitorar, lança o logger
:: de Docker stats em background, aguarda o término e finaliza o logger.
:: =============================================================================
:one_run
setlocal EnableDelayedExpansion
:: Ativa expansão adiada (!) para que variáveis atualizadas dentro de parênteses reflitam seus novos valores.

set "RUN_IDX=%~1"
:: Índice numérico desta execução (ex.: 1, 2, 3...), preservado para compor nomes e mensagens.

:: --------------------------- TIMESTAMP ÚNICO ---------------------------
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /format:list') do set DATETIME=%%I
:: Coleta data/hora local em formato compacto via WMIC, compatível em versões clássicas do Windows.

set "TIMESTAMP=%DATETIME:~0,8%-%DATETIME:~8,6%"
:: Converte para “AAAAMMDD-HHMMSS”, formato legível e ordenável para nomes de arquivos.

:: -------------------- PREPARA NOMES DE LOGS E JANELA --------------------
set "MAIN_LOG_FILE=%~dp0__%TIMESTAMP%-run%RUN_IDX%-gatling_logs.txt"
:: Arquivo de log principal desta execução; %~dp0 é o diretório absoluto onde está o .bat.

set "STATS_LOG_FILE=%~dp0__%TIMESTAMP%-run%RUN_IDX%-docker-stats_logs.txt"
:: Arquivo de log do coletor de estatísticas (Docker stats) correspondente a esta rodada.

set "WINDOW_TITLE=Teste_Rinha_Backend-%TIMESTAMP%-run%RUN_IDX%"
:: Título exclusivo da janela PowerShell para identificar de forma inequívoca ao buscar o PID.

set "STOP_FLAG=stop-logging-run%RUN_IDX%.flg"
:: Arquivo-sinal para encerrar o logger com limpeza ao final desta execução.

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
:: Bloco informativo no console para deixar claro onde estão os logs e como interromper apenas esta rodada.

if exist "!STOP_FLAG!" del "!STOP_FLAG!" >nul 2>&1
:: Remove eventual STOP_FLAG remanescente de uma execução anterior, evitando paradas indevidas do logger.

:: -------------------- LANÇA O TESTE EM NOVA JANELA --------------------
echo Iniciando a janela de teste (via PowerShell)...
start "!WINDOW_TITLE!" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_win_run-test-main-logic.ps1" -FinalLogFile "!MAIN_LOG_FILE!"
:: Abre uma janela PowerShell com título único e executa o script principal, já indicando o arquivo de log final.

:: -------------------- DESCOBRE O PID DA JANELA --------------------
echo Aguardando a janela de teste ser criada para capturar o seu PID...
set "PID="
:: Inicializa o PID vazio; a seguir, um pequeno loop espera a janela aparecer para então capturar.

:find_pid_loop
for /f "tokens=2 delims=," %%a in ('
  tasklist /v /fi "WINDOWTITLE eq !WINDOW_TITLE!" /fo csv /nh
') do set "PID=%%~a"
:: Consulta a lista de processos verbosa (/v), filtra pelo título exato da janela, pede saída em CSV e sem cabeçalho;
:: a 2ª coluna corresponde ao PID e é atribuída à variável PID.

if defined PID (
  :: Se já achamos o PID, confirmamos no console e seguimos para iniciar o logger.
  echo Janela de teste encontrada com PID: !PID!
) else (
  :: Se ainda não apareceu, aguardamos 1 segundo e tentamos novamente (loop leve e não intrusivo).
  timeout /t 1 /nobreak > nul
  goto :find_pid_loop
)

:: -------------------- INICIA O LOGGER (DOCKER STATS) --------------------
echo Iniciando o logger do Docker Stats em segundo plano...
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_win_run-test-stats-logger.ps1" -LogFile "!STATS_LOG_FILE!" -ProcessId !PID!
:: Lança o coletor em background (/B), apontando para o arquivo de log desta execução e passando o PID monitorado.

:: -------------------- MONITORA O PROCESSO DO TESTE --------------------
echo O teste esta em execucao. Este terminal esta monitorizando a execucao !RUN_IDX!.
:wait_for_process_end
  tasklist /fi "PID eq !PID!" | find "!PID!" > nul
  :: Enquanto o PID estiver presente, significa que a janela de teste segue ativa; então permanecemos aguardando.
  if errorlevel 1 (
    :: Quando o PID some da lista, a execução terminou (janela fechada); partimos para a limpeza.
    echo Janela de teste foi fechada.
    goto :cleanup_and_return
  )
  timeout /t 5 /nobreak > nul
  :: Pausa curta para evitar polling agressivo; reduz consumo de CPU sem perder responsividade.
  goto :wait_for_process_end

:: -------------------- LIMPA E FINALIZA ESTA RODADA --------------------
:cleanup_and_return
echo Finalizando o logger...
echo stop > "!STOP_FLAG!"
:: Cria o arquivo-sinal para o logger detectar e encerrar de forma ordenada (flush de logs, etc.).

timeout /t 3 > nul
:: Aguarda alguns segundos para garantir que o logger finalize com tranquilidade.

del "!STOP_FLAG!" >nul 2>&1
:: Remove o arquivo-sinal para não interferir em execuções futuras.

echo Execucao !RUN_IDX! concluida. Verifique os arquivos de log gerados.
endlocal & exit /b 0
:: Retorna sucesso ao chamador e encerra o escopo local desta rotina (variáveis com expansão adiada).