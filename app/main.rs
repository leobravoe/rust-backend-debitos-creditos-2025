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
use tokio::time::{sleep, Duration}; // Importação para o loop de retentativa
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
    p_type CHAR,
    p_description VARCHAR(10)
)
RETURNS JSON AS $$
DECLARE
    current_balance INT;
    current_limit INT;
    new_balance INT;
BEGIN
    -- Obter saldo e limite atuais com bloqueio de linha
    SELECT balance, account_limit INTO current_balance, current_limit
    FROM accounts WHERE id = p_account_id
    FOR UPDATE;

    IF p_type = 'd' THEN
        new_balance := current_balance - p_amount;
        IF new_balance < -current_limit THEN
            -- Retorna um JSON de erro (saldo insuficiente)
            RETURN '{"error": 1}';
        END IF;
    ELSE
        new_balance := current_balance + p_amount;
    END IF;

    -- Atualiza o saldo
    UPDATE accounts SET balance = new_balance WHERE id = p_account_id;

    -- Insere a transação
    INSERT INTO transactions (account_id, amount, type, description)
    VALUES (p_account_id, p_amount, p_type, p_description);

    -- Retorna o novo saldo e limite
    RETURN json_build_object('limite', current_limit, 'saldo', new_balance);
END;
$$ LANGUAGE plpgsql;
"#;

#[derive(Clone)]
struct AppState {
    pool: Arc<PgPool>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let db_host = std::env::var("DB_HOST").unwrap_or("localhost".to_string());
    let db_port = std::env::var("DB_PORT").unwrap_or("5432".to_string());
    let db_user = std::env::var("DB_USER").unwrap_or("postgres".to_string());
    let db_password = std::env::var("DB_PASSWORD").unwrap_or("postgres".to_string());
    let db_database = std::env::var("DB_DATABASE").unwrap_or("postgres_api_db".to_string());
    let pg_max_connections = std::env::var("PG_MAX").unwrap_or("10".to_string()).parse::<u32>()?;

    let database_url = format!(
        "postgres://{}:{}@{}:{}/{}",
        db_user, db_password, db_host, db_port, db_database
    );

    // Loop de retentativa para esperar o banco (e o init.sql)
    tracing::info!("Tentando conectar à base de dados: {}", database_url);
    let pool_options = PgPoolOptions::new()
        .max_connections(pg_max_connections);

    let mut retries = 10;
    let pool = loop {
        // .clone() corrige o erro de "moved value"
        match pool_options.clone().connect(&database_url).await {
            Ok(p) => {
                tracing::info!("Ligação à base de dados estabelecida com sucesso!");
                break p;
            }
            Err(e) => {
                retries -= 1;
                if retries == 0 {
                    tracing::error!("Falha ao conectar à base de dados após várias tentativas: {:?}", e);
                    std::process::exit(1);
                }
                tracing::warn!(
                    "Falha ao conectar à base de dados [{} tentativas restantes], tentando novamente em 3s... (Erro: {})",
                    retries, e
                );
                sleep(Duration::from_secs(3)).await;
            }
        }
    };
    
    // As migrações agora só rodam APÓS o healthcheck inteligente passar E a conexão ser estabelecida
    tracing::info!("Executando migrações (funções e índices)...");
    sqlx::query(CREATE_INDEX_SQL).execute(&pool).await?;
    sqlx::query(CREATE_EXTRACT_FUNCTION_SQL).execute(&pool).await?;
    sqlx::query(CREATE_TRANSACTION_FUNCTION_SQL).execute(&pool).await?;
    tracing::info!("Migrações concluídas.");


    let state = AppState {
        pool: Arc::new(pool),
    };

    // Sintaxe de rota com {id} (corrige o pânico do Axum)
    let app = Router::new()
        .route("/clientes/{id}/extrato", get(get_extrato))
        .route("/clientes/{id}/transacoes", post(post_transacao))
        .with_state(state);

    let port_str = std::env::var("PORT").unwrap_or("8080".to_string());
    let port = port_str.parse::<u16>()?; // Usar u16 para porta
    let addr: SocketAddr = format!("0.0.0.0:{}", port).parse()?;


    tracing::info!("Servidor ouvindo na porta {}", port);
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

#[derive(Deserialize)]
struct TransactionPayload {
    valor: u32,
    tipo: String, // 'c' ou 'd'
    descricao: String,
}

// Handler para /clientes/{id}/extrato
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
        Err(e) => {
            tracing::error!("Erro ao buscar extrato para cliente {}: {:?}", id, e);
            (StatusCode::INTERNAL_SERVER_ERROR, Json(JsonValue::Null)).into_response()
        }
    }
}

// Handler para /clientes/{id}/transacoes
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
        // .to_string() corrige o erro de compilação E0277
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