# _win_run-test-main-logic.ps1
# Versão robusta contra mojibake: UTF-8 de ponta a ponta, sem janelas extras.

param (
    [string]$FinalLogFile
)

# ====== UTF-8 de ponta a ponta ======
# 1) Console/host e pipeline
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = New-Object System.Text.UTF8Encoding($false)  # influencia redirecionamento de PS->exe

# 2) Code page do conhost herdado por processos CMD
#    (executamos um 'chcp 65001' válido para a sessão atual)
cmd.exe /d /c "chcp 65001 >nul" | Out-Null

# 3) Força UTF-8 no ambiente PowerShell
$env:PYTHONIOENCODING = "utf-8"
$env:LC_ALL = "en_US.UTF-8"

# 3) Maven/Java sempre em UTF-8
$env:JAVA_TOOL_OPTIONS = "-Dfile.encoding=UTF-8"
$env:MAVEN_OPTS        = "-Dfile.encoding=UTF-8"

# 4) Abrimos o arquivo com UTF-8 COM BOM (Notepad adora BOM; evita detecção ambígua)
$Utf8WithBom = New-Object System.Text.UTF8Encoding($true)
# Cria/zera o arquivo com BOM
$fs = [System.IO.File]::Open($FinalLogFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
$sw = New-Object System.IO.StreamWriter($fs, $Utf8WithBom)

# Configuração adicional para garantir UTF-8 em todas as operações
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8BOM'
$PSDefaultParameterValues['Add-Content:Encoding'] = 'utf8BOM'

function Close-Log {
    try { $sw.Flush() } catch {}
    try { $sw.Close() } catch {}
    try { $fs.Close() } catch {}
}

function WLog([string]$msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    $line = "$ts $msg"
    try { 
        # Escreve diretamente no arquivo usando UTF-8
        $sw.WriteLine($line)
        $sw.Flush() 
    } catch {}
    # Para o console, usa a string original
    Write-Host $line
}

# Função para converter caracteres acentuados para ASCII
function Fix-Encoding {
    param([string]$Text)
    
    # Converte caracteres acentuados para suas versões ASCII
    $result = $Text
    
    # Trata caracteres que aparecem como no arquivo de log (usando regex mais específico)
    $result = $result -replace 'valida[^a-zA-Z]*es', 'validacoes'
    $result = $result -replace 'valida[^a-zA-Z]*o', 'validacao'
    $result = $result -replace 'concorr[^a-zA-Z]*ncia', 'concorrencia'
    $result = $result -replace 'transa[^a-zA-Z]*es', 'transacoes'
    $result = $result -replace 'd[^a-zA-Z]*bitos', 'debitos'
    $result = $result -replace 'cr[^a-zA-Z]*ditos', 'creditos'
    
    return $result
}

# Executa comando externo sob 'cmd /c chcp 65001 & <comando>', capturando stdout+stderr
function Run-CmdUTF8 {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string]$CommandLine,  # string única a ser interpretada pelo cmd.exe
        [switch]$IgnoreExitCode
    )
    WLog "[CMD] $Title"
    # Garante code page 65001 dentro do cmd, depois executa o comando
    $cmd = 'chcp 65001 >nul & ' + $CommandLine
    & cmd.exe /d /c $cmd 2>&1 | ForEach-Object {
        # Cada linha que chega já foi decodificada com OutputEncoding=UTF8
        $line = $_.ToString()
        
        # Trata caracteres especiais que podem vir do Gatling/Maven
        # Converte caracteres mal codificados para UTF-8 correto
        $line = Fix-Encoding $line
        
        # Escreve no arquivo de log
        $sw.WriteLine($line)
        # Para o console
        Write-Host $line
    }
    $exit = $LASTEXITCODE
    $sw.Flush()
    if (-not $IgnoreExitCode -and $exit -ne 0) {
        throw "Comando falhou (exit $exit): $Title"
    }
    return $exit
}

try {
    WLog "[PASSO 1/6] Parando e removendo containers antigos (a ignorar falhas)..."
    Run-CmdUTF8 -Title "docker-compose down -v" -CommandLine 'docker-compose down -v' -IgnoreExitCode

    WLog "[PASSO 2/6] Forcando a remocao dos containers..."
    Run-CmdUTF8 -Title "docker rm -f postgres app1 app2 nginx" -CommandLine 'docker rm -f postgres app1 app2 nginx' -IgnoreExitCode

    WLog "`n[PASSO 3/6] Construindo e subindo novos containers (a ignorar falhas)..."
    Run-CmdUTF8 -Title "docker-compose up -d --build" -CommandLine 'docker-compose --compatibility up -d --build' -IgnoreExitCode

    WLog "`n[PASSO 4/6] Verificacao de Saude dos Containers..."
    $timeoutSeconds = 90
    $services = "postgres", "app1", "app2", "nginx"   # <-- inclui nginx
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $healthyServices = 0
    while ($stopwatch.Elapsed.TotalSeconds -lt $timeoutSeconds) {
        # Captura 'ps' por cmd para manter UTF-8 consistente
        $tmpFile = [System.IO.Path]::GetTempFileName()
        Run-CmdUTF8 -Title "docker-compose ps" -CommandLine "docker-compose ps > `"$tmpFile`"" -IgnoreExitCode
        $statuses = Get-Content -LiteralPath $tmpFile -Encoding UTF8
        Remove-Item $tmpFile -ErrorAction SilentlyContinue

        $healthyServices = 0
        foreach ($service in $services) {
            $serviceLines = $statuses | Where-Object { $_ -match "\b$([Regex]::Escape($service))\b" }
            # 'healthy' (quando houver HEALTHCHECK) OU pelo menos 'Up'
            if ($serviceLines -and ($serviceLines -match 'healthy' -or $serviceLines -match '\bUp\b')) {
                $healthyServices++
            }
        }

        WLog "Aguardando... ($healthyServices de $($services.Length) servicos prontos)"
        if ($healthyServices -eq $services.Length) {
            WLog "Todos os servicos essenciais estao prontos! A continuar."
            break
        }
        Start-Sleep -Seconds 5
    }
    $stopwatch.Stop()

    if ($healthyServices -ne $services.Length) {
        # Loga o estado atual com caminho 100% UTF-8
        $tmpFile = [System.IO.Path]::GetTempFileName()
        Run-CmdUTF8 -Title "docker-compose ps (final)" -CommandLine "docker-compose ps > `"$tmpFile`"" -IgnoreExitCode
        $statusLog = Get-Content -LiteralPath $tmpFile -Encoding UTF8 | Out-String
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
        WLog "`n--- ESTADO ATUAL DOS CONTAINERS ---`n$statusLog"
        throw "Timeout: Nem todos os containers ficaram prontos em $timeoutSeconds segundos."
    }

    WLog "`n[PASSO 5/6] Limpando o banco de dados..."
    Run-CmdUTF8 -Title "docker exec postgres psql reset" -CommandLine `
        'docker exec postgres psql -U postgres -d postgres_api_db -v ON_ERROR_STOP=1 -c "TRUNCATE TABLE transactions" -c "UPDATE accounts SET balance = 0"'

    WLog "`n[PASSO 6/6] Executando o teste de carga com Gatling..."
    Push-Location "gatling"
    # Refazemos envs dentro da sessão cmd chamada com configurações específicas para UTF-8:
    $gatlingExit = Run-CmdUTF8 -Title "mvnw gatling:test" -CommandLine `
        'set "JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8 -Dconsole.encoding=UTF-8" & set "MAVEN_OPTS=-Dfile.encoding=UTF-8 -Dconsole.encoding=UTF-8" & set "MAVEN_OPTS=%MAVEN_OPTS% -Dmaven.compiler.encoding=UTF-8" & mvnw.cmd gatling:test -Dgatling.simulationClass=simulations.RinhaBackendCrebitosSimulation' `
        -IgnoreExitCode
    Pop-Location
    if ($gatlingExit -ne 0) { throw "Falha ao executar o teste do Gatling. Exit=$gatlingExit" }

    WLog "Teste concluido com sucesso."

} catch {
    WLog ""
    WLog ("ERRO DETALHADO: " + $_.ToString())
}
