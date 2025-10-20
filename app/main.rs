use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;
use sqlx::{postgres::PgPoolOptions, PgPool, Row};
use std::{net::SocketAddr, sync::Arc};
use tracing_subscriber;

const CREATE_INDEX_SQL: &str = r#"
CREATE INDEX IF NOT EXISTS idx_account_id_id_desc ON transactions (account_id, id DESC);
"#;

const CREATE_EXTRACT_FUNCTION_SQL: &str = r#"
CREATE OR REPLACE FUNCTION get_extrato(p_account_id INT)
RETURNS JSON AS $$
DECLARE
    account_info JSON;
    last_transactions JSON;
BEGIN
    SELECT json_build_object(
        'total', balance,
        'limite', account_limit,
        'data_extrato', NOW()
    )
    INTO account_info
    FROM accounts
    WHERE id = p_account_id;

    IF account_info IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT json_agg(t)
    INTO last_transactions
    FROM (
        SELECT amount AS valor, type AS tipo, description AS descricao, created_at AS realizada_em
        FROM transactions
        WHERE account_id = p_account_id
        ORDER BY id DESC
        LIMIT 10
    ) t;

    RETURN json_build_object(
        'saldo', account_info,
        'ultimas_transacoes', COALESCE(last_transactions, '[]'::json)
    );
END;
$$ LANGUAGE plpgsql;
"#;

const CREATE_TRANSACTION_FUNCTION_SQL: &str = r#"
CREATE OR REPLACE FUNCTION process_transaction(
    p_account_id INT,
    p_amount INT,
    p_type CHAR(1),
    p_description VARCHAR(10)
)
RETURNS JSON AS $$
DECLARE
    current_balance INT;
    current_limit INT;
    new_balance INT;
BEGIN
    SELECT balance, account_limit INTO current_balance, current_limit
    FROM accounts
    WHERE id = p_account_id
    FOR UPDATE;

    IF p_type = 'd' THEN
        new_balance := current_balance - p_amount;
        IF new_balance < -current_limit THEN
            RETURN '{"error":1}'; -- Indica saldo insuficiente
        END IF;
    ELSE -- 'c'
        new_balance := current_balance + p_amount;
    END IF;

    UPDATE accounts SET balance = new_balance WHERE id = p_account_id;

    INSERT INTO transactions (account_id, amount, type, description, created_at)
    VALUES (p_account_id, p_amount, p_type, p_description, NOW());

    RETURN json_build_object('limite', current_limit, 'saldo', new_balance);
END;
$$ LANGUAGE plpgsql;
"#;

#[derive(Debug, Deserialize)]
struct TransactionPayload {
    #[serde(rename = "valor")]
    valor: i64,
    #[serde(rename = "tipo")]
    tipo: String,
    #[serde(rename = "descricao")]
    descricao: String,
}

#[derive(Clone)]
struct AppState {
    pool: Arc<PgPool>,
}

#[tokio::main]
async fn main() {
    // Inicializa o sistema de logging
    tracing_subscriber::fmt::init();
    tracing::info!("A iniciar a aplicação...");

    // Lê as variáveis de ambiente com valores por defeito
    let db_user = std::env::var("DB_USER").unwrap_or_else(|_| "postgres".to_string());
    let db_password = std::env::var("DB_PASSWORD").unwrap_or_else(|_| "postgres".to_string());
    let db_host = std::env::var("DB_HOST").unwrap_or_else(|_| "localhost".to_string());
    let db_port = std::env::var("DB_PORT").unwrap_or_else(|_| "5432".to_string()); // Default para pgbouncer
    let db_database = std::env::var("DB_DATABASE").unwrap_or_else(|_| "postgres_api_db".to_string());
    let pg_max_conns_str = std::env::var("PG_MAX").unwrap_or_else(|_| "30".to_string());
    let pg_max_conns = pg_max_conns_str.parse::<u32>().unwrap_or(30);
    let app_port = std::env::var("PORT").unwrap_or_else(|_| "8080".to_string()); // Default interno

    let db_connection_str = format!(
        "postgres://{}:{}@{}:{}/{}",
        db_user, db_password, db_host, db_port, db_database
    );
    tracing::info!("String de conexão: postgres://{}:***@{}:{}/{}", db_user, db_host, db_port, db_database);


    // Tenta conectar-se à base de dados
    let pool = match PgPoolOptions::new()
        .max_connections(pg_max_conns)
        .connect(&db_connection_str)
        .await
    {
        Ok(p) => {
            tracing::info!("Ligação à base de dados estabelecida com sucesso!");
            p
        },
        Err(e) => {
            // Regista o erro detalhado e encerra a aplicação
            tracing::error!("Falha ao conectar à base de dados: {:?}", e);
            eprintln!("Falha ao conectar à base de dados. Verifique a URL de conexão e as credenciais.: {:?}", e);
            std::process::exit(1); // Encerra o processo com código de erro
        }
    };


    // Executa as inicializações do banco de dados (funções, índices)
    // Considerar fazer isto apenas uma vez ou num script de migração separado
    if let Err(e) = sqlx::query(CREATE_INDEX_SQL).execute(&pool).await {
       tracing::warn!("Falha ao criar índice (pode já existir): {:?}", e);
    }
    if let Err(e) = sqlx::query(CREATE_EXTRACT_FUNCTION_SQL).execute(&pool).await {
        tracing::error!("Falha ao criar/atualizar função get_extrato: {:?}", e);
        // Poderia decidir encerrar aqui se a função for crítica
    }
    if let Err(e) = sqlx::query(CREATE_TRANSACTION_FUNCTION_SQL).execute(&pool).await {
         tracing::error!("Falha ao criar/atualizar função process_transaction: {:?}", e);
         // Poderia decidir encerrar aqui se a função for crítica
    }

    let state = AppState {
        pool: Arc::new(pool),
    };

    // Configura as rotas da API
    let app = Router::new()
        .route("/clientes/:id/extrato", get(get_extrato))
        .route("/clientes/:id/transacoes", post(post_transacao))
        .with_state(state);

    // Configura o endereço e porta para o servidor web
    let addr_str = format!("0.0.0.0:{}", app_port);
    let addr = match addr_str.parse::<SocketAddr>() {
        Ok(a) => a,
        Err(e) => {
            tracing::error!("Porta inválida configurada: {}. Erro: {:?}", app_port, e);
            eprintln!("Porta inválida configurada: {}. Erro: {:?}", app_port, e);
            std::process::exit(1);
        }
    };

    tracing::info!("Servidor a ouvir em {}", addr);

    // Inicia o servidor Axum
    match tokio::net::TcpListener::bind(addr).await {
       Ok(listener) => {
           if let Err(e) = axum::serve(listener, app).await {
               tracing::error!("Erro no servidor: {:?}", e);
               eprintln!("Erro no servidor: {:?}", e);
           }
       },
       Err(e) => {
           tracing::error!("Falha ao ligar o servidor ao endereço {}: {:?}", addr, e);
           eprintln!("Falha ao ligar o servidor ao endereço {}: {:?}", addr, e);
           std::process::exit(1);
       }
    }
}


// --- Funções Handler ---

async fn get_extrato(
    State(state): State<AppState>,
    Path(id): Path<u32>,
) -> impl IntoResponse {
    // Validação básica do ID (conforme lógica original)
    if id == 0 || id > 5 {
        return (StatusCode::NOT_FOUND, Json(JsonValue::Null)).into_response();
    }
    match sqlx::query("SELECT get_extrato($1) AS extrato_json")
        .bind(id as i32)
        .fetch_one(&*state.pool)
        .await
    {
        Ok(row) => {
            let extrato_value: Option<JsonValue> = row.try_get("extrato_json").ok();
            match extrato_value {
                // Sucesso, retorna o JSON do extrato
                Some(json) => (StatusCode::OK, Json(json)).into_response(),
                // Função retornou NULL (conta não encontrada no DB)
                None => (StatusCode::NOT_FOUND, Json(JsonValue::Null)).into_response(),
            }
        }
        Err(e) => {
            tracing::error!("Erro ao buscar extrato para cliente {}: {:?}", id, e);
            (StatusCode::INTERNAL_SERVER_ERROR, Json(JsonValue::Null)).into_response()
        },
    }
}

async fn post_transacao(
    State(state): State<AppState>,
    Path(id): Path<u32>,
    Json(payload): Json<TransactionPayload>,
) -> impl IntoResponse {
     // Validação básica do ID (conforme lógica original)
    if id == 0 || id > 5 {
       return (StatusCode::NOT_FOUND, Json(JsonValue::Null)).into_response();
    }

    // Validações do payload
    if payload.tipo != "c" && payload.tipo != "d" {
        return (StatusCode::UNPROCESSABLE_ENTITY, Json(JsonValue::Null)).into_response();
    }
    if payload.descricao.is_empty() || payload.descricao.len() > 10 {
        return (StatusCode::UNPROCESSABLE_ENTITY, Json(JsonValue::Null)).into_response();
    }
     if payload.valor <= 0 { // Transações devem ter valor positivo
        return (StatusCode::UNPROCESSABLE_ENTITY, Json(JsonValue::Null)).into_response();
    }


    // Chama a função da base de dados para processar a transação
    match sqlx::query("SELECT process_transaction($1, $2, $3, $4) AS response_json")
        .bind(id as i32)
        .bind(payload.valor as i32)
        .bind(payload.tipo.chars().next().unwrap().to_string()) // Garante que é um char
        .bind(payload.descricao) // Move a descrição, já que não a usamos mais
        .fetch_one(&*state.pool)
        .await
    {
        Ok(row) => {
            let response: Option<JsonValue> = row.try_get("response_json").ok();
            match response {
                Some(json) => {
                    // Verifica se a função retornou um erro específico (saldo insuficiente)
                    let is_error = json.get("error").and_then(|v| v.as_i64()).map(|v| v == 1).unwrap_or(false);
                    if is_error {
                        (StatusCode::UNPROCESSABLE_ENTITY, Json(JsonValue::Null)).into_response()
                    } else {
                        // Sucesso, retorna o novo saldo e limite
                        (StatusCode::OK, Json(json)).into_response()
                    }
                }
                None => {
                    // A função não deveria retornar NULL em caso de sucesso
                     tracing::error!("Função process_transaction retornou NULL inesperadamente para cliente {}", id);
                    (StatusCode::INTERNAL_SERVER_ERROR, Json(JsonValue::Null)).into_response()
                }
            }
        }
        Err(e) => {
             tracing::error!("Erro ao processar transação para cliente {}: {:?}", id, e);
            (StatusCode::INTERNAL_SERVER_ERROR, Json(JsonValue::Null)).into_response()
        },
    }
}