// src/main.rs — versão mínima para o teste de carga fixo (sem logs, edition = "2024")
// Mantém apenas o essencial exigido pela simulação: rotas, validações mínimas,
// SQL (índice + funções), e mapeamento de status HTTP (200/422/404).

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::Response,
    routing::{get, post},
    Json, Router,
};

use axum::body::Body;
use axum::http::header::CONTENT_TYPE;
use serde::Deserialize;
use sqlx::{postgres::PgPoolOptions, PgPool, Postgres};
use std::net::SocketAddr;
use tokio::net::TcpListener;

// --------------------- SQL necessárias para o teste ---------------------
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
    p_type CHAR,
    p_description VARCHAR(10)
)
RETURNS JSON AS $$
DECLARE
    response JSON;
BEGIN
    WITH updated_account AS (
        UPDATE accounts
        SET balance = balance + CASE WHEN p_type = 'c' THEN p_amount ELSE -p_amount END
        WHERE id = p_account_id 
          AND (p_type = 'c' OR (balance - p_amount) >= -account_limit)
        RETURNING balance, account_limit
    ),
    inserted_transaction AS (
        INSERT INTO transactions (account_id, amount, type, description)
        SELECT p_account_id, p_amount, p_type, p_description
        FROM updated_account
        RETURNING 1
    )
    SELECT json_build_object('saldo', ua.balance, 'limite', ua.account_limit)
    INTO response
    FROM updated_account ua;

    IF response IS NULL THEN
        RETURN '{"error": 1}'::json;
    END IF;

    RETURN response;
END;
$$ LANGUAGE plpgsql;
"#;

// ------------------------ Tipos de payload ------------------------
#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum TipoTransacao { #[serde(rename = "c")] Credito, #[serde(rename = "d")] Debito }
impl TipoTransacao { fn as_str(&self) -> &'static str { match self { Self::Credito => "c", Self::Debito => "d" } } }

#[derive(Deserialize)]
struct TransactionPayload {
    valor: u32,
    tipo: TipoTransacao,
    descricao: String,
}

// ------------------------ SQL prontos (::text) ------------------------
const Q_GET_EXTRATO: &str = "SELECT get_extrato($1)::text";
const Q_PROCESS_TX: &str   = "SELECT process_transaction($1, $2, $3, $4)::text";

// ------------------------ Helpers mínimos ------------------------
fn json_text(status: StatusCode, body: impl Into<Body>) -> Response {
    Response::builder()
        .status(status)
        .header(CONTENT_TYPE, "application/json; charset=utf-8")
        .body(body.into())
        .unwrap()
}

fn empty(status: StatusCode) -> Response {
    Response::builder()
        .status(status)
        .body(Body::empty())
        .unwrap()
}

// ------------------------ Handlers ------------------------
async fn get_extrato(State(pool): State<PgPool>, Path(id): Path<i32>) -> Response {
    if id < 1 || id > 5 { return empty(StatusCode::NOT_FOUND); }

    match sqlx::query_scalar::<Postgres, String>(Q_GET_EXTRATO).bind(id).fetch_optional(&pool).await {
        Ok(Some(json_text_body)) => json_text(StatusCode::OK, json_text_body),
        Ok(None) => empty(StatusCode::NOT_FOUND),
        Err(_) => empty(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

async fn post_transacao(
    State(pool): State<PgPool>,
    Path(id): Path<i32>,
    Json(payload): Json<TransactionPayload>,
) -> Response {
    if id < 1 || id > 5 { return empty(StatusCode::NOT_FOUND); }
    if payload.descricao.is_empty() || payload.descricao.len() > 10 { return empty(StatusCode::UNPROCESSABLE_ENTITY); }
    if payload.valor == 0 { return empty(StatusCode::UNPROCESSABLE_ENTITY); }

    let tipo = payload.tipo.as_str();

    match sqlx::query_scalar::<Postgres, String>(Q_PROCESS_TX)
        .bind(id)
        .bind(payload.valor as i32)
        .bind(tipo)
        .bind(payload.descricao)
        .fetch_one(&pool)
        .await
    {
        Ok(body) if body.contains("\"error\"") => empty(StatusCode::UNPROCESSABLE_ENTITY),
        Ok(body) => json_text(StatusCode::OK, body),
        Err(_) => empty(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

// ------------------------ Main enxuto ------------------------
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Conexão ao Postgres
    let db_host = std::env::var("DB_HOST").unwrap_or_else(|_| "localhost".to_string());
    let db_port = std::env::var("DB_PORT").unwrap_or_else(|_| "5432".to_string());
    let db_user = std::env::var("DB_USER").unwrap_or_else(|_| "postgres".to_string());
    let db_password = std::env::var("DB_PASSWORD").unwrap_or_else(|_| "postgres".to_string());
    let db_database = std::env::var("DB_DATABASE").unwrap_or_else(|_| "postgres_api_db".to_string());

    let min_conns: u32 = std::env::var("PG_MIN").ok().and_then(|s| s.parse().ok()).unwrap_or(5);
    let max_conns: u32 = std::env::var("PG_MAX").ok().and_then(|s| s.parse().ok()).unwrap_or(30);

    let database_url = format!("postgres://{}:{}@{}:{}/{}", db_user, db_password, db_host, db_port, db_database);

    let pool = PgPoolOptions::new()
        .min_connections(min_conns)
        .max_connections(max_conns)
        .connect(&database_url)
        .await?;

    // SQL essenciais
    sqlx::query(CREATE_INDEX_SQL).execute(&pool).await?;
    sqlx::query(CREATE_EXTRACT_FUNCTION_SQL).execute(&pool).await?;
    sqlx::query(CREATE_TRANSACTION_FUNCTION_SQL).execute(&pool).await?;

    // Router mínimo
    let app = Router::new()
        .route("/clientes/{id}/extrato", get(get_extrato))
        .route("/clientes/{id}/transacoes", post(post_transacao))
        .with_state(pool);

    // Servidor simples
    let port: u16 = std::env::var("PORT").ok().and_then(|s| s.parse().ok()).unwrap_or(8080);
    let addr: SocketAddr = ([0, 0, 0, 0], port).into();
    let listener = TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
