// =Main.rs — Versão Funcional Original (Logs Removidos)
// =================================================================================================

/* 1) IMPORTAÇÕES */
use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::Value as JsonValue;
use sqlx::{postgres::PgPoolOptions, PgPool, Postgres, Row};
use std::{net::SocketAddr, sync::Arc};
use tokio::time::{sleep, Duration};
// 'tracing_subscriber' foi removido.

/* 2) SQL DE INICIALIZAÇÃO */

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

// Esta é a função SQL original que funcionava para você (com SELECT FOR UPDATE)
const CREATE_TRANSACTION_FUNCTION_SQL: &str = r#"
CREATE OR REPLACE FUNCTION process_transaction(
    p_account_id INT,
    p_amount INT,
    p_type CHAR,
    p_description VARCHAR(10)
)
RETURNS JSON AS $$
DECLARE
    current_balance INT;
    current_limit INT;
    new_balance INT;
BEGIN
    SELECT balance, account_limit INTO current_balance, current_limit
    FROM accounts WHERE id = p_account_id
    FOR UPDATE;

    IF p_type = 'd' THEN
        new_balance := current_balance - p_amount;
        IF new_balance < -current_limit THEN
            RETURN '{"error": 1}';
        END IF;
    ELSE
        new_balance := current_balance + p_amount;
    END IF;

    UPDATE accounts SET balance = new_balance WHERE id = p_account_id;

    INSERT INTO transactions (account_id, amount, type, description)
    VALUES (p_account_id, p_amount, p_type, p_description);

    RETURN json_build_object('limite', current_limit, 'saldo', new_balance);
END;
$$ LANGUAGE plpgsql;
"#;

/* 3) O ESTADO DA APLICAÇÃO */
#[derive(Clone)]
struct AppState {
    pool: Arc<PgPool>,
}

/* 4) A FUNÇÃO PRINCIPAL */

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // --- INICIALIZAÇÃO DE LOGS REMOVIDA ---

    // --- LENDO CONFIGURAÇÕES DO AMBIENTE ---
    let db_host = std::env::var("DB_HOST").unwrap_or("localhost".to_string());
    let db_port = std::env::var("DB_PORT").unwrap_or("5432".to_string());
    let db_user = std::env::var("DB_USER").unwrap_or("postgres".to_string());
    let db_password = std::env::var("DB_PASSWORD").unwrap_or("postgres".to_string());
    let db_database = std::env::var("DB_DATABASE").unwrap_or("postgres_api_db".to_string());
    // O valor original "10" é mantido, pois era o que funcionava.
    let pg_max_connections = std::env::var("PG_MAX").unwrap_or("10".to_string()).parse::<u32>()?;

    let database_url = format!(
        "postgres://{}:{}@{}:{}/{}",
        db_user, db_password, db_host, db_port, db_database
    );

    // --- LOOP DE RETENTATIVA DE CONEXÃO ---
    let pool_options = PgPoolOptions::new()
        .max_connections(pg_max_connections);

    let mut retries = 10;
    let pool = loop {
        match pool_options.clone().connect(&database_url).await {
            Ok(p) => {
                // Log removido
                break p;
            }
            Err(_e) => { // Erro '_e' agora é ignorado
                retries -= 1;
                if retries == 0 {
                    // Log removido
                    std::process::exit(1);
                }
                // Log removido
                sleep(Duration::from_secs(3)).await;
            }
        }
    };
    
    // --- RODANDO AS "MIGRAÇÕES" (SQLs de Fundação) ---
    // Log removido
    sqlx::query(CREATE_INDEX_SQL).execute(&pool).await?;
    sqlx::query(CREATE_EXTRACT_FUNCTION_SQL).execute(&pool).await?;
    sqlx::query(CREATE_TRANSACTION_FUNCTION_SQL).execute(&pool).await?;
    // Log removido

    // --- PREPARANDO O ESTADO E O ROTEADOR ---
    let state = AppState {
        pool: Arc::new(pool),
    };

    // Usa a sintaxe de rota corrigida '{id}'
    let app = Router::new()
        .route("/clientes/{id}/extrato", get(get_extrato))
        .route("/clientes/{id}/transacoes", post(post_transacao))
        .with_state(state);

    // --- INICIANDO O SERVIDOR WEB ---
    let port_str = std::env::var("PORT").unwrap_or("8080".to_string());
    let port = port_str.parse::<u16>()?;
    let addr: SocketAddr = format!("0.0.0.0:{}", port).parse()?;

    // Log removido
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

/* 5) ESTRUTURA DO PAYLOAD */
#[derive(Deserialize)]
struct TransactionPayload {
    valor: u32,
    tipo: String,
    descricao: String,
}

/* 6) HANDLERS (AS FUNÇÕES QUE TRATAM AS ROTAS) */

// --- Handler da Rota GET /clientes/{id}/extrato ---
// Mantido o uso original de JsonValue
async fn get_extrato(
    State(state): State<AppState>,
    Path(id): Path<i32>,
) -> impl IntoResponse {
    if id < 1 || id > 5 {
        return (StatusCode::NOT_FOUND, Json(JsonValue::Null)).into_response();
    }

    match sqlx::query_scalar::<Postgres, JsonValue>("SELECT get_extrato($1)")
        .bind(id)
        .fetch_one(&*state.pool)
        .await
    {
        Ok(json_data) => {
            if json_data.is_null() {
                (StatusCode::NOT_FOUND, Json(JsonValue::Null)).into_response()
            } else {
                (StatusCode::OK, Json(json_data)).into_response()
            }
        }
        Err(_e) => { // Log removido
            (StatusCode::INTERNAL_SERVER_ERROR, Json(JsonValue::Null)).into_response()
        }
    }
}

// --- Handler da Rota POST /clientes/{id}/transacoes ---
// Mantido o uso original de JsonValue
async fn post_transacao(
    State(state): State<AppState>,
    Path(id): Path<i32>,
    Json(payload): Json<TransactionPayload>,
) -> impl IntoResponse {
    if id < 1 || id > 5 {
        return (StatusCode::NOT_FOUND, Json(JsonValue::Null)).into_response();
    }
    if payload.descricao.is_empty() || payload.descricao.len() > 10 {
        return (StatusCode::UNPROCESSABLE_ENTITY, Json(JsonValue::Null)).into_response();
    }
    if payload.tipo != "c" && payload.tipo != "d" {
         return (StatusCode::UNPROCESSABLE_ENTITY, Json(JsonValue::Null)).into_response();
    }
    if payload.valor == 0 {
        return (StatusCode::UNPROCESSABLE_ENTITY, Json(JsonValue::Null)).into_response();
    }

    match sqlx::query("SELECT process_transaction($1, $2, $3, $4) AS response_json")
        .bind(id)
        .bind(payload.valor as i32)
        .bind(payload.tipo.chars().next().unwrap().to_string())
        .bind(payload.descricao)
        .fetch_one(&*state.pool)
        .await
    {
        Ok(row) => {
            let response: Option<JsonValue> = row.try_get("response_json").ok();
            match response {
                Some(json) => {
                    let is_error = json.get("error").and_then(|v| v.as_i64()).map(|v| v == 1).unwrap_or(false);
                    if is_error {
                        (StatusCode::UNPROCESSABLE_ENTITY, Json(JsonValue::Null)).into_response()
                    } else {
                        (StatusCode::OK, Json(json)).into_response()
                    }
                }
                None => {
                    // Log removido
                    (StatusCode::INTERNAL_SERVER_ERROR, Json(JsonValue::Null)).into_response()
                }
            }
        }
        Err(_e) => { // Log removido
            (StatusCode::INTERNAL_SERVER_ERROR, Json(JsonValue::Null)).into_response()
        },
    }
}