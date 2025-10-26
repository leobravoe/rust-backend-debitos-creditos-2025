// src/main.rs
// High-performance, sem logs, edition = "2024", PG_MAX obrigatório.
// Otimizações adicionais nesta versão:
// - State<PgPool> direto (sem AppState)
// - json_null() com bytes estáticos e helpers #[inline]
// - Retry de conexão com backoff exponencial real (cap em 30s) + acquire_timeout
// - Pool com min_connections(5), idle_timeout, max_lifetime
// - Limite de tamanho de corpo (DefaultBodyLimit) para requests JSON
// - Listener explícito via TcpSocket com reuseaddr + backlog maior (1024)
// - Conteúdo JSON cru (::text) vindo do Postgres; validações textuais baratas

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};

use axum::body::Body;
use axum::http::header::CONTENT_TYPE;
use serde::Deserialize;
use sqlx::{postgres::PgPoolOptions, PgPool, Postgres};
use std::net::SocketAddr;
use tokio::net::TcpSocket;
use tokio::time::{sleep, Duration};
use tower_http::limit::RequestBodyLimitLayer;

// ------------------------------------------------------------
// SQL constantes (PL/pgSQL) — mantidas da versão do usuário
// ------------------------------------------------------------
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
enum TipoTransacao {
    #[serde(rename = "c")] Credito,
    #[serde(rename = "d")] Debito,
}
impl TipoTransacao {
    #[inline(always)]
    fn as_str(&self) -> &'static str {
        match self {
            TipoTransacao::Credito => "c",
            TipoTransacao::Debito => "d",
        }
    }
}

#[derive(Debug, Deserialize)]
struct TransactionPayload {
    valor: u32,
    tipo: TipoTransacao,
    descricao: String,
}

// Queries promovidas a const (executadas como TEXT via ::text)
const Q_GET_EXTRATO: &str = "SELECT get_extrato($1)::text";
const Q_PROCESS_TX: &str   = "SELECT process_transaction($1, $2, $3, $4)::text";

// ------------------------------------------------------------
// Helpers de resposta
// ------------------------------------------------------------
const NULL_JSON: &[u8] = b"null";

#[inline(always)]
fn json_text(status: StatusCode, body: impl Into<Body>) -> Response {
    Response::builder()
        .status(status)
        .header(CONTENT_TYPE, "application/json; charset=utf-8")
        .body(body.into())
        .unwrap()
}

#[inline(always)]
fn json_null(status: StatusCode) -> Response {
    json_text(status, NULL_JSON)
}

// Checagens textuais baratas (evitam parse de JSON no hot-path)
#[inline]
fn is_tx_success_body(s: &str) -> bool {
    let s = s.trim_start();
    s.starts_with('{') && s.contains("\"saldo\"") && s.contains("\"limite\"")
}

#[inline]
fn is_tx_error_body(s: &str) -> bool {
    let s = s.trim_start();
    s.starts_with('{') && s.contains("\"error\"") && s.contains(":") && s.contains("1")
}

// ------------------------------------------------------------
// Handlers
// ------------------------------------------------------------
async fn get_extrato(
    State(pool): State<PgPool>,
    Path(id): Path<i32>,
) -> impl IntoResponse {
    if id < 1 || id > 5 {
        return json_null(StatusCode::NOT_FOUND);
    }

    match sqlx::query_scalar::<Postgres, String>(Q_GET_EXTRATO)
        .bind(id)
        .fetch_optional(&pool)
        .await
    {
        Ok(Some(json_text_body)) => {
            let s = json_text_body.trim_start();
            if s.starts_with('{') && s.contains("\"saldo\"") {
                json_text(StatusCode::OK, json_text_body)
            } else {
                // Defesa: se vier algo inesperado, melhor 500 do que 200 inválido
                json_null(StatusCode::INTERNAL_SERVER_ERROR)
            }
        }
        Ok(None) => json_null(StatusCode::NOT_FOUND),
        Err(_) => json_null(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

async fn post_transacao(
    State(pool): State<PgPool>,
    Path(id): Path<i32>,
    Json(payload): Json<TransactionPayload>,
) -> impl IntoResponse {
    if id < 1 || id > 5 {
        return json_null(StatusCode::NOT_FOUND);
    }
    if payload.descricao.is_empty() || payload.descricao.len() > 10 {
        return json_null(StatusCode::UNPROCESSABLE_ENTITY);
    }
    if payload.valor == 0 {
        return json_null(StatusCode::UNPROCESSABLE_ENTITY);
    }

    let tipo_str = payload.tipo.as_str();

    match sqlx::query_scalar::<Postgres, String>(Q_PROCESS_TX)
        .bind(id)
        .bind(payload.valor as i32)
        .bind(tipo_str)
        .bind(payload.descricao)
        .fetch_one(&pool)
        .await
    {
        Ok(json_text_body) => {
            if is_tx_error_body(&json_text_body) {
                // Limite estourado, etc. => 422
                json_null(StatusCode::UNPROCESSABLE_ENTITY)
            } else if is_tx_success_body(&json_text_body) {
                // Sucesso garantido com {"saldo":..., "limite":...}
                json_text(StatusCode::OK, json_text_body)
            } else {
                // Qualquer outra coisa (ex.: "null", objeto sem campos esperados) => 500
                json_null(StatusCode::INTERNAL_SERVER_ERROR)
            }
        }
        Err(_) => json_null(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

// ------------------------------------------------------------
// Main — pool endurecido + listener com backlog
// ------------------------------------------------------------
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // --- Variáveis de ambiente (PG_MAX obrigatório) ---
    let db_host = std::env::var("DB_HOST").unwrap_or_else(|_| "localhost".to_string());
    let db_port = std::env::var("DB_PORT").unwrap_or_else(|_| "5432".to_string());
    let db_user = std::env::var("DB_USER").unwrap_or_else(|_| "postgres".to_string());
    let db_password = std::env::var("DB_PASSWORD").unwrap_or_else(|_| "postgres".to_string());
    let db_database = std::env::var("DB_DATABASE").unwrap_or_else(|_| "postgres_api_db".to_string());

    // PG_MAX é exigido e convertido para u32 (falha cedo se inválido)
    let pg_max_connections: u32 = std::env::var("PG_MAX")?.parse::<u32>()?;

    let database_url = format!(
        "postgres://{}:{}@{}:{}/{}",
        db_user, db_password, db_host, db_port, db_database
    );

    // --- Retry de conexão com backoff exponencial real (cap em 30s) ---
    let mut attempt: u32 = 0;
    let pool: PgPool = loop {
        let pool_options = PgPoolOptions::new()
            .max_connections(pg_max_connections)
            .min_connections(5)
            .idle_timeout(Duration::from_secs(300))   // 5 min
            .max_lifetime(Duration::from_secs(1800))  // 30 min
            .acquire_timeout(Duration::from_secs(2)); // evita hang sob saturação

        match pool_options.connect(&database_url).await {
            Ok(p) => break p,
            Err(_) => {
                attempt = attempt.saturating_add(1);
                if attempt >= 10 {
                    std::process::exit(1);
                }
                // 1, 2, 4, 8, 16, 30 (cap em 30)
                let exp = attempt.min(5); // até 2^5 = 32
                let mut backoff = 1u64 << exp;
                if backoff > 30 { backoff = 30; }
                sleep(Duration::from_secs(backoff)).await;
            }
        }
    };

    // --- SQLs iniciais (índice + funções) ---
    sqlx::query(CREATE_INDEX_SQL).execute(&pool).await?;
    sqlx::query(CREATE_EXTRACT_FUNCTION_SQL).execute(&pool).await?;
    sqlx::query(CREATE_TRANSACTION_FUNCTION_SQL).execute(&pool).await?;

    // --- Router + estado (passa PgPool direto) ---
    let app = Router::new()
        .route("/clientes/{id}/extrato", get(get_extrato))
        .route("/clientes/{id}/transacoes", post(post_transacao))
        .layer(RequestBodyLimitLayer::new(512)) // ~payloads minúsculos; rejeita bombas
        .with_state(pool);

    // --- Servidor com backlog maior ---
    let port: u16 = std::env::var("PORT")
        .unwrap_or_else(|_| "8080".to_string())
        .parse()?;
    let addr: SocketAddr = format!("0.0.0.0:{}", port).parse()?;

    let socket = TcpSocket::new_v4()?;
    socket.set_reuseaddr(true)?;
    socket.bind(addr)?;
    let listener = socket.listen(1024)?; // backlog maior que o padrão

    axum::serve(listener, app).await?;
    Ok(())
}
