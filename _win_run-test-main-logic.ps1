# =========================================================================================
# GUIA DIDÁTICO (PARA QUEM ESTÁ COMEÇANDO)
# -----------------------------------------------------------------------------------------
# Este script PowerShell é o “cérebro” do seu fluxo de teste no Windows. Ele:
# 1) Garante que TUDO use UTF-8 (console, arquivos, ferramentas externas) para evitar
#    textos quebrados com acentos (o famoso “mojibake”).
# 2) Mantém um arquivo de log único (com datas/horas) e escreve nele em tempo real.
# 3) Fornece uma função utilitária para rodar comandos externos (docker, maven, etc.)
#    sempre em UTF-8, registrando saída e erros no log e no console.
# 4) Sobe os containers, espera ficarem prontos, aquece as APIs, limpa o banco e
#    por fim executa o Gatling; se algo der errado, mostra um erro detalhado.
# =========================================================================================

param (
    [string]$FinalLogFile
)
# A diretiva “param” declara os parâmetros de entrada do script.
# Aqui recebemos o caminho completo do arquivo de log final para esta execução.
# Observação: este parâmetro é obrigatório no fluxo atual; se vier vazio/nulo, a abertura do arquivo falhará.

# ========================= BLOCO 1 — CONFIGURAÇÃO DE UTF-8 =========================
# A ideia deste bloco é “blindar” toda a sessão para que NADA escape do padrão UTF-8.
# Assim, tudo que for escrito em arquivo/console e toda ferramenta chamada (Java/Maven)
# trabalha no mesmo encoding, evitando caracteres tortos em qualquer etapa.

[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
# Define que o console vai LER (Input) em UTF-8 (ex.: se algo for digitado/encaminhado).

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# Define que o console vai ESCREVER (Output) em UTF-8 (o que vemos na tela).

$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
# Ajusta o encoding do pipeline do PowerShell (quando redireciona para executáveis),
# usando UTF-8 “sem BOM” para manter compatibilidade em saídas redirecionadas.

cmd.exe /d /c "chcp 65001 >nul" | Out-Null
# Garante que sessões de CMD herdadas usem codepage 65001 (UTF-8). Isso é importante
# porque às vezes chamamos “cmd /c” por baixo (ex.: para rodar docker/maven).

$env:PYTHONIOENCODING = "utf-8"
# Fixa o encoding do Python (se usado em ferramentas do ambiente), garantindo UTF-8.

$env:LC_ALL = "en_US.UTF-8"
# Ajusta locale geral (influencia mensagens/formatos em algumas ferramentas).

$env:JAVA_TOOL_OPTIONS = "-Dfile.encoding=UTF-8"
# Força a JVM a operar em UTF-8. Essencial para plugins/saídas do Gatling/Maven.

$env:MAVEN_OPTS = "-Dfile.encoding=UTF-8"
# Força o Maven a trabalhar com UTF-8. Evita relatos/relatórios com acentuação quebrada.

$Utf8WithBom = New-Object System.Text.UTF8Encoding($true)
# Prepara um encoding UTF-8 COM BOM. O Notepad clássico detecta melhor quando há BOM,
# então escolhemos usar BOM nos arquivos de log para evitar detecção ambígua.

$fs = [System.IO.File]::Open($FinalLogFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
# Abre (ou cria zerado) o arquivo de log no caminho recebido. “Share ReadWrite” permite
# ler o arquivo enquanto ele está sendo escrito (útil para acompanhamento ao vivo).

$sw = New-Object System.IO.StreamWriter($fs, $Utf8WithBom)
# Envolve o FileStream em um escritor de texto, indicando explicitamente UTF-8 com BOM.
# A partir de agora, tudo que gravarmos via $sw sai corretamente em UTF-8.

$PSDefaultParameterValues['Out-File:Encoding']   = 'utf8BOM'
# Define o padrão para cmdlets que usam Out-File: sempre salvar com UTF-8 e BOM.
# Nota: $PSDefaultParameterValues afeta apenas a sessão atual.

$PSDefaultParameterValues['Add-Content:Encoding'] = 'utf8BOM'
# Define o padrão para Add-Content: também manter UTF-8 com BOM ao anexar textos.

function Close-Log {
    # Função utilitária para fechar/“descarregar” (flush/close) com segurança o arquivo de log.
    try { $sw.Flush() } catch {}
    try { $sw.Close() } catch {}
    try { $fs.Close() } catch {}
}
# Ter essa função facilita encerrar o log corretamente em fluxos mais complexos.

function WLog([string]$msg) {
    # Função de LOG: prefixa a mensagem com timestamp legível e grava em arquivo e console.
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    # Timestamp com milissegundos para investigar ordem/tempo exato dos eventos.

    $line = "$ts $msg"
    # Concatena data/hora e a mensagem de log numa única linha.

    try {
        $sw.WriteLine($line)
        # Escreve a linha no arquivo (via StreamWriter, em UTF-8 com BOM).

        $sw.Flush()
        # Força a gravação imediata (útil durante erros ou interrupções).
    } catch {}

    Write-Host $line
    # Imprime no console também, para feedback em tempo real.
}

function fixEncoding {
    param([string]$Text)
    # Esta função tenta “sanear” palavras comuns que podem chegar corrompidas
    # (ex.: vindas de ferramentas que misturam encodings). Ela troca padrões
    # defeituosos por formas ASCII equivalentes, mantendo a leitura dos logs.

    $result = $Text
    # Começamos da string original e aplicamos substituições graduais.

    $result = $result -replace 'valida[^a-zA-Z]*es', 'validacoes'
    # Corrige “validações” que tenham sido quebradas por bytes estranhos entre letras.

    $result = $result -replace 'valida[^a-zA-Z]*o', 'validacao'
    # Corrige “validação” em variantes corrompidas.

    $result = $result -replace 'concorr[^a-zA-Z]*ncia', 'concorrencia'
    # Corrige “concorrência” quando aparecem caracteres inválidos no meio.

    $result = $result -replace 'transa[^a-zA-Z]*es', 'transacoes'
    # Corrige “transações” para “transacoes” (ASCII), evitando símbolos ilegíveis.

    $result = $result -replace 'd[^a-zA-Z]*bitos', 'debitos'
    # Corrige “débitos” para “debitos” em ASCII.

    $result = $result -replace 'cr[^a-zA-Z]*ditos', 'creditos'
    # Corrige “créditos” para “creditos” em ASCII.

    return $result
    # Devolve o texto “higienizado”, mais seguro para armazenar/filtrar em logs.
}

function runCmdUTF8 {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        # Um título amigável que aparecerá no log (ex.: “docker-compose up”).

        [Parameter(Mandatory = $true)][string]$CommandLine,
        # A linha de comando exata que será repassada para o cmd.exe /c (como uma string única).
        # Dica: quando precisar de aspas no comando, escape-as com crase (`") dentro de strings PowerShell.

        [switch]$IgnoreExitCode
        # Se informado, não lançamos erro quando o comando retorna código diferente de 0.
    )

    WLog "[CMD] $Title"
    # Registra o que vamos executar, deixando o histórico do passo.

    $cmd = 'chcp 65001 >nul & ' + $CommandLine
    # Garante que DENTRO do cmd.exe a codepage seja 65001 (UTF-8), depois roda o comando real.

    & cmd.exe /d /c $cmd 2>&1 | ForEach-Object {
        # Executa o comando via cmd.exe; juntamos stdout+stderr (2>&1) e percorremos cada linha.

        $line = $_.ToString()
        # Convertemos o objeto de pipeline para string pura (uma linha de saída).

        $line = fixEncoding $line
        # Corrigimos possíveis bytes estranhos (acentos quebrados) para versões ASCII legíveis.

        $sw.WriteLine($line)
        # Gravamos direto no arquivo de log (sem passar por encoding implícito).

        Write-Host $line
        # E também no console, para acompanhar ao vivo.
    }

    $exit = $LASTEXITCODE
    # Captura o código de saída do comando externo (0 = OK; outros = erro específico).

    $sw.Flush()
    # Garante que as últimas linhas foram, de fato, escritas no arquivo antes de seguirmos.

    if (-not $IgnoreExitCode -and $exit -ne 0) {
        throw "Comando falhou (exit $exit): $Title"
        # Se não podemos ignorar e houve erro, interrompemos o fluxo com uma mensagem clara.
    }

    return $exit
    # Devolve o exit code para quem chamou (às vezes queremos tratá-lo manualmente).
}

try {
    # ========================= BLOCO 2 — GERENCIAR CONTAINERS =========================
    # Nesta fase, derrubamos qualquer resquício de execução anterior, subimos tudo novamente
    # (recriando imagens/containers) e só avançamos quando os serviços essenciais estiverem
    # “de pé” e saudáveis.

    WLog "[PASSO 1/6] Parando e removendo containers antigos (a ignorar falhas)..."
    runCmdUTF8 -Title "docker-compose down -v" -CommandLine 'docker-compose down -v' -IgnoreExitCode
    # Tenta parar/remover containers/volumes antigos. Se não houver nada, não falha.

    WLog "[PASSO 2/6] Forcando a remocao dos containers..."
    runCmdUTF8 -Title "docker rm -f postgres app1 app2 nginx" -CommandLine 'docker rm -f postgres app1 app2 nginx' -IgnoreExitCode
    # “Força” a remoção (caso ainda exista algum container zumbi com esses nomes).

    WLog "`n[PASSO 3/6] Construindo e subindo novos containers (a ignorar falhas)..."
    # Observação: o `n acima insere quebra de linha no próprio texto logado, facilitando leitura.
    runCmdUTF8 -Title "docker-compose up -d --build" -CommandLine 'docker-compose --compatibility up -d --build' -IgnoreExitCode
    # Sobe em modo destacado (-d), reconstruindo imagens; “--compatibility” traduz limites
    # do Compose para ambientes sem Swarm.

    WLog "`n[PASSO 4/6] Verificacao de Saude dos Containers..."
    $timeoutSeconds = 90
    # Tempo máximo de espera (em segundos) para que tudo fique pronto (evita loop infinito).

    $services = "postgres", "app1", "app2", "nginx"
    # Lista dos serviços essenciais. Se mudar sua stack, ajuste aqui.

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # Cronômetro simples para saber quando o timeout foi atingido.

    $healthyServices = 0
    # Contador de quantos serviços já estão prontos (Up/healthy).

    while ($stopwatch.Elapsed.TotalSeconds -lt $timeoutSeconds) {
        # Loop de espera ativa com feedback a cada iteração (a cada 5s mais abaixo).

        $tmpFile = [System.IO.Path]::GetTempFileName()
        # Criamos um arquivo temporário para capturar a saída do “docker-compose ps”.
        # Vantagem: evita problemas de encoding ao redirecionar direto do pipeline.

        runCmdUTF8 -Title "docker-compose ps" -CommandLine "docker-compose ps > `"$tmpFile`"" -IgnoreExitCode
        # Executa o ps e redireciona a saída (em UTF-8) para o arquivo temporário.
        # As aspas foram escapadas com crase para preservar caminhos com espaços.

        $statuses = Get-Content -LiteralPath $tmpFile -Encoding UTF8
        # Lemos o arquivo temporário como UTF-8 e obtemos todas as linhas de status.

        Remove-Item $tmpFile -ErrorAction SilentlyContinue
        # Limpamos o temporário para não gerar lixo.

        $healthyServices = 0
        # Reiniciamos o contador para esta “fotografia” do momento.

        foreach ($service in $services) {
            # Para cada serviço essencial, vamos verificar se está “Up” e/ou “healthy”.

            $serviceLines = $statuses | Where-Object { $_ -match "\b$([Regex]::Escape($service))\b" }
            # Filtra linhas relativas ao serviço corrente (regex seguro com Escape).
            # Usamos \b para casar palavra inteira e evitar falsos positivos.

            if ($serviceLines -and ($serviceLines -match 'healthy' -or $serviceLines -match '\bUp\b')) {
                # Se a linha falar em “healthy” (healthcheck) OU pelo menos “Up”, contamos como pronto.
                # “Up” cobre imagens sem healthcheck explícito.
                $healthyServices++
            }
        }

        WLog "Aguardando... ($healthyServices de $($services.Length) servicos prontos)"
        # Feedback incremental para acompanhar quais serviços já responderam.

        if ($healthyServices -eq $services.Length) {
            WLog "Todos os servicos essenciais estao prontos! A continuar."
            # Se todos os serviços atenderam aos critérios, saímos do loop.
            break
        }

        Start-Sleep -Seconds 5
        # Aguardamos alguns segundos antes de tentar de novo, para não “martelar” o Docker.
    }

    $stopwatch.Stop()
    # Paramos o cronômetro: ou porque ficou tudo pronto, ou porque estourou o tempo.

    if ($healthyServices -ne $services.Length) {
        # Se o número de serviços prontos não bateu com o total, estourou o timeout.

        $tmpFile = [System.IO.Path]::GetTempFileName()
        # Vamos capturar um snapshot final de “docker-compose ps” para diagnóstico.

        runCmdUTF8 -Title "docker-compose ps (final)" -CommandLine "docker-compose ps > `"$tmpFile`"" -IgnoreExitCode
        # Gera a saída atual no arquivo temporário (em UTF-8).

        $statusLog = Get-Content -LiteralPath $tmpFile -Encoding UTF8 | Out-String
        # Lemos e juntamos as linhas em uma única string para log.

        Remove-Item $tmpFile -ErrorAction SilentlyContinue
        # Limpamos o temporário.

        WLog "`n--- ESTADO ATUAL DOS CONTAINERS ---`n$statusLog"
        # Escrevemos um diagnóstico completo no log para facilitar o troubleshooting.

        throw "Timeout: Nem todos os containers ficaram prontos em $timeoutSeconds segundos."
        # Interrompemos a execução com erro claro (vai para o catch).
    }

    # ========================= BLOCO 3 — AQUECIMENTO E LIMPEZA =========================
    # Aqui “esquentamos” as rotas (GET/POST) para inicializar conexões/caches e depois
    # zeramos o banco, garantindo que o teste comece em estado conhecido e repetível.

    WLog "`n[PASSO 4.5/6] Aquecendo as APIs (Warm-up)..."
    Start-Sleep -Seconds 3
    # Breve espera para estabilizar o sistema antes do aquecimento.

    $baseUrl = "http://localhost:9999/clientes"
    # Endereço exposto pelo Nginx (balanceador) para nossas instâncias de app.

    $warmupPayload = @{
        valor     = 1
        tipo      = "c"
        descricao = "warmup"
    } | ConvertTo-Json -Compress
    # Payload mínimo e válido para exercitar a rota POST /transacoes (crédito de 1).
    # O -Compress evita espaços desnecessários no corpo enviado.

    foreach ($round in 1..5) {
        WLog "=== Rodada $round de aquecimento ==="

        foreach ($id in 1..5) {
            $extratoUrl = "$baseUrl/$id/extrato"
            WLog "Aquecendo ID ${id}: GET $extratoUrl"
            try {
                Invoke-WebRequest -Uri $extratoUrl -Method Get -UseBasicParsing -ErrorAction SilentlyContinue | Out-Null
                # UseBasicParsing mantém compatibilidade com PS 5; em PS 6+ é ignorado sem quebrar.
                # -ErrorAction SilentlyContinue evita exceções “barulhentas” de falhas transitórias.
            } catch {
                WLog " (Ignorando erro de aquecimento GET: $($_.Exception.Message))"
                # Capturamos e registramos a mensagem, mas seguimos o aquecimento.
            }
        }

        foreach ($id in 1..5) {
            $transacaoUrl = "$baseUrl/$id/transacoes"
            WLog "Aquecendo ID ${id}: POST $transacaoUrl"
            try {
                Invoke-WebRequest -Uri $transacaoUrl -Method Post -UseBasicParsing -ContentType "application/json" -Body $warmupPayload -ErrorAction SilentlyContinue | Out-Null
                # Postamos JSON compacto; descartamos corpo (Out-Null) para não poluir o log.
            } catch {
                WLog " (Ignorando erro de aquecimento POST: $($_.Exception.Message))"
                # Erros pontuais no warm-up não devem interromper o fluxo.
            }
        }
    }

    WLog "Aquecimento concluido. O banco sera limpo a seguir."
    # Aviso para separar mentalmente as fases do processo.

    Start-Sleep -Seconds 4
    # Pequena espera para garantir que o aquecimento terminou.

    WLog "`n[PASSO 5/6] Limpando o banco de dados..."
    runCmdUTF8 -Title "docker exec postgres psql reset" -CommandLine `
        'docker exec postgres psql -U postgres -d postgres_api_db -v ON_ERROR_STOP=1 -c "TRUNCATE TABLE transactions" -c "UPDATE accounts SET balance = 0"'
    # Zera as transações e saldos; ON_ERROR_STOP faz o psql parar no primeiro erro.
    # Observação: as aspas duplas internas são necessárias para o psql interpretar cada -c corretamente.

    # ========================= BLOCO 4 — EXECUTAR O GATLING =========================
    # Por fim, rodamos a simulação de carga. Voltamos a reforçar o UTF-8 para Maven/Java
    # dentro da mesma linha de comando (via cmd), para não dar chance a divergências.

    WLog "`n[PASSO 6/6] Executando o teste de carga com Gatling..."
    Push-Location "gatling"
    # Entramos na pasta do projeto Gatling (onde estão pom/arquivos de simulação).
    # Push-Location guarda a pasta anterior para facilitar o retorno com Pop-Location.

    $gatlingExit = runCmdUTF8 -Title "mvnw gatling:test" -CommandLine `
        'set "JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8 -Dconsole.encoding=UTF-8" & set "MAVEN_OPTS=-Dfile.encoding=UTF-8 -Dconsole.encoding=UTF-8" & set "MAVEN_OPTS=%MAVEN_OPTS% -Dmaven.compiler.encoding=UTF-8" & mvnw.cmd gatling:test -Dgatling.simulationClass=simulations.RinhaBackendCrebitosSimulation' `
        -IgnoreExitCode
    # Rodamos via mvnw.cmd (wrapper do Maven), especificando a classe de simulação.
    # Repare que expandimos MAVEN_OPTS (+=) em vez de sobrescrever, preservando flags anteriores.

    Pop-Location
    # Voltamos para a pasta original para manter o ambiente consistente.

    if ($gatlingExit -ne 0) { throw "Falha ao executar o teste do Gatling. Exit=$gatlingExit" }
    # Se o Maven/Gatling retornou erro, interrompemos com mensagem clara.

    WLog "Teste concluido com sucesso."
    # Chegamos ao fim com tudo certo. Agora é analisar os relatórios/metrics gerados.
}
catch {
    # ========================= BLOCO 5 — TRATAMENTO DE ERROS =========================
    # Se QUALQUER passo acima lançar exceção, entramos aqui. Registramos um erro detalhado
    # no log (com stack e mensagem) para simplificar a investigação do problema.

    WLog ""
    # Linha em branco só para separar visualmente o bloco de erro no log.

    WLog ("ERRO DETALHADO: " + $_.ToString())
    # Imprime a exceção completa (mensagem + stack) no log e no console.
}
