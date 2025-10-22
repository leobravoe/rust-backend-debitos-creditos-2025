/*
===================================================================================
                   Arquivo principal da API (main.rs)
===================================================================================

Olá, iniciante! Este é o arquivo 'main.rs', o ponto de entrada e o "cérebro"
de toda a sua aplicação web em Rust.

Vamos dissecar o que cada parte faz, passo a passo.
*/

/*
-----------------------------------------------------------------------------------
 1) IMPORTAÇÕES (`use`)
-----------------------------------------------------------------------------------
A primeira coisa que fazemos é "importar" as ferramentas (tipos, funções, etc.)
de outras bibliotecas (chamadas de 'crates') que dissemos que usaríamos no
arquivo `Cargo.toml`.
*/

// Importações do 'axum': Nosso framework web.
use axum::{
    extract::{Path, State}, // 'Path' extrai dados da URL (ex: o 'id' em /clientes/{id}/...)
                           // 'State' nos dá acesso ao "estado compartilhado" (nosso pool de banco de dados).
    http::StatusCode,      // Permite enviar códigos de status HTTP (como 200 OK, 404 NOT FOUND, etc.).
    response::IntoResponse, // Um 'trait' (tipo especial) que permite converter nossos retornos em respostas HTTP.
    routing::{get, post},  // Funções para definir rotas HTTP (uma rota GET e uma rota POST).
    Json, Router,         // 'Json' extrai/cria corpos de requisição/resposta JSON.
                          // 'Router' é o que usamos para "mapear" as URLs para nossas funções.
};

// Importação do 'serde': O "tradutor" de JSON.
use serde::Deserialize; // Especificamente, só precisamos "Deserializar" (converter JSON -> Struct Rust).

// Importação do 'serde_json': O "dicionário" de JSON para o serde.
use serde_json::Value as JsonValue; // Usamos 'Value' (renomeado para 'JsonValue') como um
                                    // tipo genérico para lidar com o JSON que vem do banco.

// Importações do 'sqlx': Nosso kit de ferramentas para falar com o banco de dados.
use sqlx::{
    postgres::PgPoolOptions, // O construtor do "Pool de Conexões".
    PgPool,                  // O tipo do nosso "Pool de Conexões" com o PostgreSQL.
    Postgres,                // Um 'marker type' que diz ao sqlx que estamos falando com PostgreSQL.
    Row,                     // Um 'trait' que nos permite extrair dados de uma linha ('row') do banco.
};

// Importações da Biblioteca Padrão ('std') do Rust.
use std::{
    net::SocketAddr, // Um tipo que representa um endereço de IP + Porta (ex: "0.0.0.0:8080").
    sync::Arc,       // "Atomic Reference Counting". É um "ponteiro inteligente" que nos
                     // permite COMPARTILHAR um valor (como nosso pool de banco)
                     // entre MÚLTIPLAS threads de forma segura. Essencial para um
                     // servidor web.
};

// Importações do 'tokio': O "motor" assíncrono da nossa aplicação.
use tokio::time::{sleep, Duration}; // 'sleep' e 'Duration' são usados no nosso loop
                                   // de retentativa de conexão com o banco.

/*
-----------------------------------------------------------------------------------
 2) CONSTANTES SQL (A LÓGICA NO BANCO DE DADOS)
-----------------------------------------------------------------------------------
Aqui, definimos nossa lógica de banco de dados como "constantes" de string.
Usamos `r#"...#"` (raw strings) para que possamos escrever SQL em múltiplas
linhas sem nos preocupar com caracteres de escape.

Esta é uma OTIMIZAÇÃO DE PERFORMANCE crucial: em vez da API fazer várias
consultas ao banco (ex: 1. Travar a linha, 2. Ler o saldo, 3. Inserir transação,
4. Atualizar saldo), nós movemos TODA essa lógica para dentro do próprio
banco de dados usando funções PL/pgSQL.

A API simplesmente chama a função (ex: `SELECT get_extrato(...)`) e o
banco de dados faz todo o trabalho pesado em uma única "viagem" de rede.
*/

// SQL para criar um ÍNDICE.
// Um índice é como o índice de um livro: ele torna as buscas MUITO mais rápidas.
// Estamos criando um índice na tabela `transactions` com base em `account_id`
// e `id DESC` (decrescente). Isso torna a busca das "últimas 10 transações"
// para um cliente específico (feita pela função `get_extrato`) quase instantânea.
const CREATE_INDEX_SQL: &str = r#"
CREATE INDEX IF NOT EXISTS idx_account_id_id_desc ON transactions (account_id, id DESC);
"#;

// SQL para criar a FUNÇÃO DE EXTRATO.
// `CREATE OR REPLACE FUNCTION` cria (ou atualiza) uma função dentro do PostgreSQL.
// `RETURNS JSON` significa que esta função fará todo o trabalho e retornará
// um único objeto JSON formatado, pronto para a API enviar ao cliente.
const CREATE_EXTRACT_FUNCTION_SQL: &str = r#"
CREATE OR REPLACE FUNCTION get_extrato(p_account_id INT)
RETURNS JSON AS $$
DECLARE
    -- Declaração de variáveis locais da função SQL
    account_info JSON;
    last_transactions JSON;
BEGIN
    -- 1. Busca informações da conta (saldo e limite) e já formata como um objeto JSON.
    SELECT json_build_object(
        'total', balance,
        'limite', account_limit,
        'data_extrato', NOW() -- NOW() pega a data/hora ATUAL do banco.
    )
    INTO account_info -- Armazena o JSON resultante na variável 'account_info'
    FROM accounts
    WHERE id = p_account_id; -- Usando o ID do cliente que recebemos como parâmetro

    -- Se 'account_info' for nulo (ou seja, o 'SELECT' não encontrou o cliente),
    -- a função retorna NULL. Nossa API vai tratar isso como um "Not Found 404".
    IF account_info IS NULL THEN
        RETURN NULL;
    END IF;

    -- 2. Busca as últimas 10 transações e as formata como um array JSON.
    SELECT json_agg(t) -- 'json_agg' agrega todas as linhas 't' em um único array JSON.
    INTO last_transactions
    FROM (
        -- Este sub-select busca as 10 transações mais recentes.
        -- Graças ao nosso `CREATE_INDEX_SQL`, isso é super rápido.
        SELECT amount AS valor, type AS tipo, description AS descricao, created_at AS realizada_em
        FROM transactions
        WHERE account_id = p_account_id
        ORDER BY id DESC -- Ordena do mais novo (maior ID) para o mais velho
        LIMIT 10       -- Pega apenas os 10 primeiros
    ) t;

    -- 3. Constrói o JSON final de resposta.
    -- 'COALESCE(last_transactions, '[]'::json)' é um truque: se 'last_transactions'
    -- for NULL (cliente não tem transações), ele usa um array JSON vazio `[]`
    -- em vez de `null`, como é exigido pela Rinha.
    RETURN json_build_object(
        'saldo', account_info,
        'ultimas_transacoes', COALESCE(last_transactions, '[]'::json)
    );
END;
$$ LANGUAGE plpgsql; -- Informa ao Postgres que estamos usando a linguagem PL/pgSQL.
"#;

// SQL para criar a FUNÇÃO DE TRANSAÇÃO.
// Esta é a função mais crítica e otimizada. Ela usa "Common Table Expressions" (CTEs),
// que são os blocos `WITH ... AS (...)`.
const CREATE_TRANSACTION_FUNCTION_SQL: &str = r#"
CREATE OR REPLACE FUNCTION process_transaction(
    p_account_id INT,
    p_amount INT,
    p_type CHAR,
    p_description VARCHAR(10)
)
RETURNS JSON AS $$
DECLARE
    response JSON;
BEGIN
    -- O 'WITH' nos permite executar "passos" de forma atômica.
    
    -- PASSO 1: Tenta atualizar a conta.
    -- O 'UPDATE ... RETURNING' é a "mágica" aqui. Ele tenta atualizar a linha
    -- e, se conseguir, *retorna* os valores (balance, account_limit).
    -- Isso "trava" a linha da conta, garantindo que não haja "corridas"
    -- (duas transações tentando atualizar o saldo ao mesmo tempo).
    WITH updated_account AS (
        UPDATE accounts
        -- Lógica de Crédito/Débito: Se for 'c', soma; senão, subtrai.
        SET balance = balance + CASE WHEN p_type = 'c' THEN p_amount ELSE -p_amount END
        WHERE id = p_account_id 
          -- CONDIÇÃO DE TRAVA:
          -- Se for crédito ('c'), sempre permite.
          -- Se for débito ('d'), SÓ permite se o novo saldo (balance - p_amount)
          -- for maior ou igual ao limite negativo (-account_limit).
          AND (p_type = 'c' OR (balance - p_amount) >= -account_limit)
        -- Se a atualização for bem-sucedida, retorna o novo saldo e limite.
        RETURNING balance, account_limit
    ),
    -- PASSO 2: Insere a transação.
    -- Este passo SÓ executa se o PASSO 1 (updated_account) for bem-sucedido
    -- (ou seja, se ele retornou uma linha).
    inserted_transaction AS (
        INSERT INTO transactions (account_id, amount, type, description)
        SELECT p_account_id, p_amount, p_type, p_description
        FROM updated_account -- Pega os dados do passo 1 (garante que só rode se o update funcionou)
        RETURNING 1 -- Apenas retorna '1' para sinalizar sucesso.
    )
    -- PASSO 3: Prepara a resposta JSON.
    -- Este 'SELECT' final também só roda se o PASSO 1 funcionou.
    SELECT json_build_object('saldo', ua.balance, 'limite', ua.account_limit)
    INTO response
    FROM updated_account ua; -- Pega os dados retornados pelo 'UPDATE'.

    -- Se 'response' for NULL, significa que o 'UPDATE' no PASSO 1 falhou
    -- (porque a condição de limite de débito não foi atendida).
    IF response IS NULL THEN
        -- Retornamos um JSON de erro customizado que nossa API saberá
        -- interpretar como "Unprocessable Entity 422".
        RETURN '{"error": 1}'::json;
    END IF;

    -- Se tudo deu certo, retorna o JSON com o novo saldo e limite.
    RETURN response;
END;
$$ LANGUAGE plpgsql;
"#;

/*
-----------------------------------------------------------------------------------
 3) O ESTADO COMPARTILHADO DA APLICAÇÃO (`AppState`)
-----------------------------------------------------------------------------------
*/

// `#[derive(Clone)]` permite que o Axum "clone" (copie) este estado
// para cada thread de worker que ele usa.
#[derive(Clone)]
struct AppState {
    // `pool` é o nosso "Pool de Conexões" com o banco.
    // Pense em um "pool" (piscina) como um "balde" de conexões de banco de dados
    // que já estão abertas e prontas para uso.
    //
    // Quando uma requisição chega, em vez de gastar o tempo caro de "abrir
    // uma nova conexão" com o banco, a API simplesmente "pega uma emprestada"
    // do balde, usa e a devolve. Isso é essencial para alta performance.
    //
    // `Arc<...>` (Atomic Reference Counting) é o "invólucro" que permite
    // que este 'pool' seja acessado por múltiplas threads ao mesmo tempo
    // de forma segura.
    pool: Arc<PgPool>,
    //
    // OTIMIZAÇÃO: O tipo `PgPool` do SQLx já é, internamente, um `Arc`.
    // Envolvê-lo em *outro* `Arc` (Arc<PgPool>) funciona, mas é redundante.
    // Você poderia remover a `struct AppState` e usar `PgPool` diretamente
    // como o estado, simplificando o código.
}

/*
-----------------------------------------------------------------------------------
 4) A FUNÇÃO PRINCIPAL (`main`)
-----------------------------------------------------------------------------------
Esta é a função que é executada quando você roda seu programa.
*/

// `#[tokio::main]` é uma "macro" (um pedaço de código que escreve outro código).
// Ela é a "chave de ignição" que liga o "motor" assíncrono do Tokio.
// Ela transforma nossa `fn main` normal em uma `fn main` assíncrona.
#[tokio::main]
// Nossa 'main' é 'async' (pode ser "pausada" e "retomada" pelo Tokio)
// e retorna um `anyhow::Result<()>`. Isso é um atalho de tratamento de erros.
// Significa que a função retorna "Ok" (com nada `()`) em sucesso, ou
// qualquer tipo de erro (`anyhow::Error`) em falha. Isso nos permite
// usar o operador `?` para propagar erros automaticamente.
async fn main() -> anyhow::Result<()> {
    
    // --- LENDO CONFIGURAÇÕES DO AMBIENTE ---
    // A aplicação lê suas configurações (como senhas de banco) de
    // "Variáveis de Ambiente" (configurações passadas pelo sistema
    // operacional ou pelo Docker Compose).
    //
    // `.unwrap_or("...".to_string())` tenta ler a variável; se ela
    // não existir, usa um valor padrão (default).
    //
    // OTIMIZAÇÃO DE ROBUSTEZ: Para variáveis críticas (como DB_HOST, DB_USER),
    // é melhor usar `.expect("DB_HOST must be set")`. Isso fará a
    // aplicação "quebrar" imediatamente na inicialização se uma
    // variável essencial estiver faltando, o que é melhor do que
    // falhar de forma misteriosa depois.
    let db_host = std::env::var("DB_HOST").unwrap_or("localhost".to_string());
    let db_port = std::env::var("DB_PORT").unwrap_or("5432".to_string());
    let db_user = std::env::var("DB_USER").unwrap_or("postgres".to_string());
    let db_password = std::env::var("DB_PASSWORD").unwrap_or("postgres".to_string());
    let db_database = std::env::var("DB_DATABASE").unwrap_or("postgres_api_db".to_string());
    
    // Lê o número máximo de conexões do pool. `.parse::<u32>()?`
    // tenta converter a String (ex: "10") em um número (u32).
    // O `?` no final propagará o erro se a conversão falhar.
    let pg_max_connections = std::env::var("PG_MAX").unwrap_or("10".to_string()).parse::<u32>()?;

    // Monta a "String de Conexão" (o "endereço" completo do banco)
    // no formato que o PostgreSQL espera.
    let database_url = format!(
        "postgres://{}:{}@{}:{}/{}",
        db_user, db_password, db_host, db_port, db_database
    );

    // --- CONFIGURANDO O POOL DE CONEXÕES ---
    let pool_options = PgPoolOptions::new()
        .max_connections(pg_max_connections) // Define o tamanho máximo do "balde" de conexões.
        .min_connections(5); // Mantém 5 conexões sempre "quentes" e prontas.

    // --- LOOP DE RETENTATIVA DE CONEXÃO ---
    // Esta é uma prática EXCELENTE para robustez, especialmente com Docker.
    // Às vezes, a API (este container) sobe *antes* do banco de dados (o
    // container do Postgres) estar pronto para aceitar conexões.
    // Este loop tenta conectar 10 vezes, com uma pausa de 3 segundos
    // entre as tentativas, antes de desistir.
    let mut retries = 10;
    let pool = loop {
        // Tenta conectar usando as opções e a URL.
        // `.await` "pausa" a função aqui até a tentativa de conexão terminar.
        match pool_options.clone().connect(&database_url).await {
            // Se der 'Ok', a conexão foi um sucesso!
            Ok(p) => {
                // 'break p' sai do loop e retorna o pool ('p') para a variável 'pool'.
                break p;
            }
            // Se der 'Err', a conexão falhou.
            Err(_) => { // `_` ignora o erro específico
                retries -= 1; // Decrementa o contador de tentativas
                if retries == 0 {
                    // Se as tentativas acabaram, desiste e encerra o processo.
                    eprintln!("Não foi possível conectar ao banco após 10 tentativas.");
                    std::process::exit(1);
                }
                // Pausa (dorme) por 3 segundos antes de tentar novamente.
                sleep(Duration::from_secs(3)).await;
            }
        }
    };
    
    // --- RODANDO AS "MIGRAÇÕES" (SETUP DO BANCO) ---
    // Agora que temos certeza de que estamos conectados, executamos
    // nossas três constantes SQL para configurar o banco.
    // O `?` no final garante que, se qualquer uma falhar, a aplicação
    // irá parar e reportar o erro.
    sqlx::query(CREATE_INDEX_SQL).execute(&pool).await?;
    sqlx::query(CREATE_EXTRACT_FUNCTION_SQL).execute(&pool).await?;
    sqlx::query(CREATE_TRANSACTION_FUNCTION_SQL).execute(&pool).await?;


    // --- PREPARANDO O ESTADO E O ROTEADOR ---
    // Cria a instância do nosso 'AppState', envolvendo o 'pool'
    // dentro de um 'Arc' (ponteiro atômico) para ser compartilhado.
    let state = AppState {
        pool: Arc::new(pool),
    };

    // Este é o coração do Axum.
    // `Router::new()` cria um novo roteador.
    // `.route(...)` "mapeia" uma URL e um método HTTP para uma função "handler".
    let app = Router::new()
        // Quando uma requisição GET chegar em "/clientes/{id}/extrato",
        // chame a nossa função `get_extrato`.
        .route("/clientes/{id}/extrato", get(get_extrato))
        // Quando uma requisição POST chegar em "/clientes/{id}/transacoes",
        // chame a nossa função `post_transacao`.
        .route("/clientes/{id}/transacoes", post(post_transacao))
        // `.with_state(state)` "injeta" nosso 'AppState' (o pool) no roteador,
        // tornando-o disponível para todas as funções handler.
        .with_state(state);

    // --- INICIANDO O SERVIDOR WEB ---
    // Lê a porta em que o servidor deve "escutar" (padrão: 8080).
    let port_str = std::env::var("PORT").unwrap_or("8080".to_string());
    let port = port_str.parse::<u16>()?;
    
    // Cria o endereço completo: "0.0.0.0" significa "aceitar conexões
    // de qualquer endereço de IP", não apenas 'localhost'.
    let addr: SocketAddr = format!("0.0.0.0:{}", port).parse()?;

    // "Amarra" (bind) um "ouvinte" (listener) de rede ao endereço.
    let listener = tokio::net::TcpListener::bind(addr).await?;
    
    // "Serve" (inicia) a aplicação, dizendo ao Axum para usar o
    // 'listener' para aceitar conexões e o 'app' (nosso roteador)
    // para processá-las.
    // `.await` aqui faz a 'main' "travar" nesta linha para sempre,
    // mantendo o servidor rodando e aceitando requisições.
    axum::serve(listener, app).await?;

    // Se `axum::serve` terminar (ex: por um erro fatal),
    // a função 'main' termina, retornando 'Ok'.
    Ok(())
}

/*
-----------------------------------------------------------------------------------
 5) ESTRUTURA DO PAYLOAD (O "MOLDE" DO JSON)
-----------------------------------------------------------------------------------
*/

// `#[derive(Deserialize)]` é a "mágica" do 'serde'.
// Ela diz ao serde para ler esta 'struct' e gerar automaticamente
// o código que converte (deserializa) um JSON para ela.
//
// Esta 'struct' age como um "molde" para o corpo (body) da requisição POST.
// O Axum e o Serde vão automaticamente validar se o JSON recebido
// "se encaixa" neste molde.
#[derive(Deserialize)]
struct TransactionPayload {
    valor: u32,     // Espera um campo "valor" que seja um número positivo
    tipo: String,   // Espera um campo "tipo" que seja uma string (ex: "c" ou "d")
    descricao: String, // Espera um campo "descricao" que seja uma string
}

/*
-----------------------------------------------------------------------------------
 6) HANDLERS (As Funções que Processam as Rotas)
-----------------------------------------------------------------------------------
Estas são as funções que o Roteador chama.
*/

// --- Handler da Rota GET /clientes/{id}/extrato ---

// Funções de handler são quase sempre 'async fn'.
async fn get_extrato(
    // Este é um "Extrator" do Axum. Ele "extrai" o 'AppState'
    // (que definimos com `.with_state`) e o injeta na variável 'state'.
    State(state): State<AppState>,
    
    // Este é outro "Extrator". Ele "extrai" a parte dinâmica da URL
    // (o `{id}`) e a "parseia" (converte) para um 'i32' (número).
    Path(id): Path<i32>,
) -> impl IntoResponse { // O retorno pode ser "qualquer coisa" que
                         // possa ser convertida em uma Resposta HTTP.

    // --- Validação de Regra de Negócio (Hardcoded para a Rinha) ---
    // Se o ID não for um dos clientes válidos (1 a 5), paramos
    // imediatamente e retornamos um 404 NOT FOUND.
    if id < 1 || id > 5 {
        // A tupla `(StatusCode, Json)` é uma forma fácil do Axum
        // criar uma resposta. Aqui: (Código 404, Corpo JSON `null`).
        return (StatusCode::NOT_FOUND, Json(JsonValue::Null)).into_response();
    }

    // --- Execução da Query ---
    // Usamos `sqlx::query_scalar`. "Scalar" significa que esperamos
    // *exatamente um valor* (neste caso, o JSON) de volta do banco.
    match sqlx::query_scalar::<Postgres, JsonValue>("SELECT get_extrato($1)")
        .bind(id) // `.bind(id)` insere o 'id' de forma segura no '$1' da query.
        
        // `&*state.pool` parece complicado, mas é só como acessamos
        // o `PgPool` que está dentro do `Arc`.
        .fetch_one(&*state.pool) 
        .await // "Pausa" até o banco de dados responder.
    {
        // --- Tratamento de Sucesso ---
        // A query funcionou e o banco retornou 'json_data'.
        Ok(json_data) => {
            // Verificamos se o JSON retornado é 'null'.
            // (Lembra que nossa função SQL retorna NULL se não achar o cliente?)
            if json_data.is_null() {
                // Isso não deveria acontecer por causa da validação (id < 1 || id > 5),
                // mas é uma boa defesa. Retorna 404.
                (StatusCode::NOT_FOUND, Json(JsonValue::Null)).into_response()
            } else {
                // SUCESSO! Retorna (Código 200 OK, Corpo JSON com os dados do extrato).
                (StatusCode::OK, Json(json_data)).into_response()
            }
        }
        // --- Tratamento de Erro ---
        // A query falhou (ex: o banco caiu, a query está errada).
        Err(_) => { // `_` ignora o erro
            // Retorna um erro genérico 500 INTERNAL SERVER ERROR.
            (StatusCode::INTERNAL_SERVER_ERROR, Json(JsonValue::Null)).into_response()
        }
    }
}

// --- Handler da Rota POST /clientes/{id}/transacoes ---
async fn post_transacao(
    State(state): State<AppState>, // Extrator de Estado (o pool)
    Path(id): Path<i32>,           // Extrator de Path (o {id})
    
    // Extrator de JSON: Este é o mais legal.
    // O Axum lê o corpo (body) da requisição POST, e o 'serde'
    // tenta automaticamente "despejar" o JSON dentro do nosso "molde"
    // `TransactionPayload`. Se falhar (ex: JSON mal formatado,
    // ou campo 'valor' faltando), o Axum já retorna um erro 400
    // Bad Request *automaticamente* para nós.
    Json(payload): Json<TransactionPayload>,
) -> impl IntoResponse {
    
    // --- Validações de Regra de Negócio ---
    if id < 1 || id > 5 {
        return (StatusCode::NOT_FOUND, Json(JsonValue::Null)).into_response();
    }
    // Descrição não pode ser vazia nem maior que 10.
    if payload.descricao.is_empty() || payload.descricao.len() > 10 {
        return (StatusCode::UNPROCESSABLE_ENTITY, Json(JsonValue::Null)).into_response();
    }
    // Tipo deve ser 'c' ou 'd'.
    if payload.tipo != "c" && payload.tipo != "d" {
         return (StatusCode::UNPROCESSABLE_ENTITY, Json(JsonValue::Null)).into_response();
    }
    // Valor não pode ser zero (a Rinha usa 'u32', então já é positivo).
    if payload.valor == 0 {
        return (StatusCode::UNPROCESSABLE_ENTITY, Json(JsonValue::Null)).into_response();
    }

    // --- Execução da Query ---
    // Aqui usamos `sqlx::query` (não 'query_scalar') porque
    // estamos interessados na *linha* ('row') que o banco retorna,
    // para podermos ler a coluna "response_json" dela.
    match sqlx::query("SELECT process_transaction($1, $2, $3, $4) AS response_json")
        .bind(id)
        .bind(payload.valor as i32) // Converte o 'u32' para 'i32' (que o Postgres prefere)
        
        // OTIMIZAÇÃO: Esta linha é complexa porque o 'tipo' é uma `String`
        // e a função SQL espera um `CHAR`.
        // `.chars().next().unwrap()` pega o primeiro caractere (ex: 'c')
        // e `.to_string()` o converte de volta para uma String (que o
        // 'sqlx' espera para o tipo CHAR).
        //
        // SERIA MELHOR: Mudar `tipo: String` para `tipo: char` na
        // `struct TransactionPayload` (linha 308). O 'serde' lidaria
        // com a conversão de "c" (JSON) para 'c' (Rust)
        // automaticamente, e aqui você poderia simplesmente fazer `.bind(payload.tipo)`.
        .bind(payload.tipo.chars().next().unwrap().to_string())
        
        .bind(payload.descricao)
        .fetch_one(&*state.pool)
        .await
    {
        // --- Tratamento de Sucesso ---
        // A query rodou.
        Ok(row) => {
            // Agora, tentamos ler a coluna "response_json" da linha.
            // `try_get(...).ok()` retorna um `Option<JsonValue>`
            // (um 'Some(json)' se deu certo, ou 'None' se falhou).
            let response: Option<JsonValue> = row.try_get("response_json").ok();
            match response {
                // Conseguimos extrair o JSON retornado pela função SQL.
                Some(json) => {
                    // Verificamos se o JSON é o nosso erro customizado `{"error": 1}`
                    // (que a função SQL retorna se o limite for estourado).
                    let is_error = json.get("error")
                        .and_then(|v| v.as_i64())
                        .map(|v| v == 1)
                        .unwrap_or(false);
                        
                    if is_error {
                        // Se for, retornamos 422 UNPROCESSABLE ENTITY.
                        (StatusCode::UNPROCESSABLE_ENTITY, Json(JsonValue::Null)).into_response()
                    } else {
                        // Se não for, SUCESSO! Retornamos 200 OK e o
                        // JSON com o novo saldo e limite.
                        (StatusCode::OK, Json(json)).into_response()
                    }
                }
                // Não conseguimos ler a coluna "response_json".
                // Isso indica um erro grave no nosso código.
                None => {
                    (StatusCode::INTERNAL_SERVER_ERROR, Json(JsonValue::Null)).into_response()
                }
            }
        }
        // --- Tratamento de Erro ---
        // A query falhou (ex: o banco caiu).
        Err(_) => {
            (StatusCode::INTERNAL_SERVER_ERROR, Json(JsonValue::Null)).into_response()
        },
    }
}