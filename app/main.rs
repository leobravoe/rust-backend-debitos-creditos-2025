// src/main.rs — versão mínima para o teste de carga fixo (sem logs, edition = "2024")
// Rotas, validações mínimas, SQL e mapeamento de status HTTP (200/422/404).

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

// ------------------------ Payload enxuto ------------------------
#[derive(Deserialize)]
struct TxPayload {
    valor: u32,        // número positivo
    tipo:  char,       // "c" ou "d"
    descricao: String, // 1..=10 bytes
}

// ------------------------ SQL prontos (::text) ------------------------
const Q_GET_EXTRATO: &str = "SELECT get_extrato($1)::text";
const Q_PROCESS_TX:  &str = "SELECT process_transaction($1, $2, $3, $4)::text";

// ------------------------ Helpers ------------------------
#[inline(always)]
fn json_text(status: StatusCode, body: impl Into<Body>) -> Response {
    Response::builder()
        .status(status)
        .header(CONTENT_TYPE, "application/json; charset=utf-8")
        .body(body.into())
        .unwrap()
}

#[inline(always)]
fn empty(status: StatusCode) -> Response {
    Response::builder().status(status).body(Body::empty()).unwrap()
}

// ------------------------ Handlers ------------------------
async fn get_extrato(State(pool): State<PgPool>, Path(id): Path<u8>) -> Response {
    let uid = id as u32;
    if uid.wrapping_sub(1) > 4 {
        return empty(StatusCode::NOT_FOUND);
    }

    // Statement persistente
    match sqlx::query_scalar::<Postgres, Option<String>>(Q_GET_EXTRATO)
        .persistent(true)
        .bind(id as i32)
        .fetch_one(&pool)
        .await
    {
        Ok(Some(body)) => json_text(StatusCode::OK, body),
        Ok(None) => empty(StatusCode::NOT_FOUND),
        Err(_) => empty(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

async fn post_transacao(
    State(pool): State<PgPool>,
    Path(id): Path<u8>,
    Json(payload): Json<TxPayload>,
) -> Response {
    let uid = id as u32;
    if uid.wrapping_sub(1) > 4 {
        return empty(StatusCode::NOT_FOUND);
    }

    let v = payload.valor;
    if v == 0 {
        return empty(StatusCode::UNPROCESSABLE_ENTITY);
    }

    let dlen = payload.descricao.len();
    if dlen == 0 || dlen > 10 {
        return empty(StatusCode::UNPROCESSABLE_ENTITY);
    }

    let tipo = match payload.tipo {
        'c' => "c",
        'd' => "d",
        _ => return empty(StatusCode::UNPROCESSABLE_ENTITY),
    };

    // Statement persistente
    match sqlx::query_scalar::<Postgres, String>(Q_PROCESS_TX)
        .persistent(true)
        .bind(id as i32)
        .bind(v as i32)
        .bind(tipo)
        .bind(&payload.descricao)
        .fetch_one(&pool)
        .await
    {
        Ok(body) if body.contains("\"error\"") => empty(StatusCode::UNPROCESSABLE_ENTITY),
        Ok(body) => json_text(StatusCode::OK, body),
        Err(_) => empty(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

// ------------------------ Main ------------------------
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let db_host = std::env::var("DB_HOST").unwrap_or_else(|_| "localhost".to_string());
    let db_port = std::env::var("DB_PORT").unwrap_or_else(|_| "5432".to_string());
    let db_user = std::env::var("DB_USER").unwrap_or_else(|_| "postgres".to_string());
    let db_password = std::env::var("DB_PASSWORD").unwrap_or_else(|_| "postgres".to_string());
    let db_database = std::env::var("DB_DATABASE").unwrap_or_else(|_| "postgres_api_db".to_string());
    let min_conns: u32 = std::env::var("PG_MIN").ok().and_then(|s| s.parse().ok()).unwrap_or(5);
    let max_conns: u32 = std::env::var("PG_MAX").ok().and_then(|s| s.parse().ok()).unwrap_or(30);
    let database_url = format!("postgres://{}:{}@{}:{}/{}", db_user, db_password, db_host, db_port, db_database);

    // after_connect com reborrow do &mut PgConnection para evitar mover 'conn'
    let pool = PgPoolOptions::new()
        .min_connections(min_conns)
        .max_connections(max_conns)
        .after_connect(|conn, _meta| {
            Box::pin(async move {
                sqlx::query("SET synchronous_commit = 'off'")
                    .execute(&mut *conn)
                    .await?;
                Ok::<_, sqlx::Error>(())
            })
        })
        .connect(&database_url)
        .await?;

    sqlx::query(CREATE_INDEX_SQL).execute(&pool).await?;
    sqlx::query(CREATE_EXTRACT_FUNCTION_SQL).execute(&pool).await?;
    sqlx::query(CREATE_TRANSACTION_FUNCTION_SQL).execute(&pool).await?;

    let app = Router::new()
        .route("/clientes/{id}/extrato", get(get_extrato))
        .route("/clientes/{id}/transacoes", post(post_transacao))
        .with_state(pool);

    let port: u16 = std::env::var("PORT").ok().and_then(|s| s.parse().ok()).unwrap_or(8080);
    let addr: SocketAddr = ([0, 0, 0, 0], port).into();
    
    use axum::serve::ListenerExt; // <- importe isso

    let listener = tokio::net::TcpListener::bind(addr).await?
    .tap_io(|tcp| {
        let _ = tcp.set_nodelay(true); // força TCP_NODELAY em cada conexão aceita
    });

    // HTTP/1.1 e keep-alive permanecem por padrão no Hyper/Axum
    axum::serve(listener, app).await?;

    Ok(())
}