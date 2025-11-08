/* 
============================== GUIA DIDÁTICO PARA INICIANTES ==============================
Este arquivo implementa uma API HTTP mínima usando o framework web Axum (Rust) e o driver SQLx
para falar com um banco PostgreSQL. A API tem duas funcionalidades principais: consultar o
extrato de um cliente e registrar transações (crédito ou débito). O objetivo é ser simples
e muito rápido em testes de carga: o código Rust faz apenas validações baratas e delega a
lógica de negócio pesada para funções SQL (criadas no próprio PostgreSQL).

Como ler este arquivo:
- Comentários longos explicam o "porquê" de cada parte existir.
- Comentários curtos perto de quase cada linha explicam "o que" ela faz.
==========================================================================================
*/

/* Imports do Axum: trazem tipos e funções para lidar com rotas, extração de parâmetros,
   montagem de respostas e escolha de métodos HTTP (GET/POST). */
use axum::{
    extract::{Path, State},      // Path extrai valores da URL (ex.: {id}); State injeta objetos compartilhados (ex.: pool do banco).
    http::StatusCode,            // Enum com códigos HTTP (200, 404, 422, 500...).
    response::Response,          // Tipo de resposta HTTP bruta (permite montar manualmente cabeçalhos e corpo).
    routing::{get, post},        // Helpers para declarar rotas GET e POST.
    Json, Router,                // Json extrai/serializa JSON; Router registra rotas e estado da aplicação.
};

/* Imports complementares do Axum e std:
   - Body: representa corpo de uma resposta HTTP.
   - CONTENT_TYPE: cabeçalho padrão para informar "application/json".
   - Serde: desserializa JSON em structs Rust.
   - SQLx: cria pool de conexões e executa queries no Postgres.
   - SocketAddr/TcpListener: definem onde o servidor TCP escuta. */
use axum::body::Body;
use axum::http::header::CONTENT_TYPE;
use serde::Deserialize;
use sqlx::{postgres::PgPoolOptions, PgPool, Postgres}; // Postgres aqui é o "dialeto" usado pelos genéricos do SQLx.
use std::net::SocketAddr;
use tokio::net::TcpListener;

/* ============================== BLOCO DE SQL DE SUPORTE =================================
   As constantes abaixo contêm instruções SQL que são executadas na inicialização. Isso deixa
   o banco “pronto” para o teste: cria um índice útil e duas funções PL/pgSQL (get_extrato e
   process_transaction) que encapsulam a lógica de negócio do extrato e das transações.

   Observação importante para produção:
   - Este CREATE INDEX não usa CONCURRENTLY. Em bases grandes, prefira:
     CREATE INDEX CONCURRENTLY ... (não pode estar numa transação implícita e é mais seguro para carga).
   ======================================================================================= */
const CREATE_INDEX_SQL: &str = r#"
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_account_id_id_desc ON transactions (account_id, id DESC);
"#; // Índice composto acelera "últimas transações por conta" pois filtra por account_id e ordena por id desc.

/* Função get_extrato: devolve um JSON com saldo/limite/data e até 10 transações recentes.
   - Se a conta não existir, retorna NULL (o handler transforma isso em 404).
   - Agrega dados em JSON dentro do próprio Postgres para minimizar trabalho no Rust.
   - CURRENT_TIMESTAMP é avaliado no servidor e corresponde ao início da transação corrente. */
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
        'data_extrato', CURRENT_TIMESTAMP
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
"#; // Note que COALESCE garante lista vazia em vez de NULL quando não há transações.

/* Função process_transaction: tenta aplicar crédito ('c') ou débito ('d') de forma atômica.
   - O UPDATE já checa limite (para débito) e retorna saldo/limite novos.
   - O INSERT registra a transação apenas se o UPDATE ocorreu.
   - Se nada for atualizado (id inválido ou limite estourado), devolve {"error":1}.
   - Em pl/pgSQL, a execução da função ocorre dentro de um comando único/atômico; a CTE
     costura as etapas para evitar condições de corrida entre UPDATE e INSERT. */
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
"#; // A CTE evita condições de corrida e mantém tudo em uma operação transacional no servidor.

/* ============================== MODELO DE ENTRADA (JSON) ===============================
   Define como o corpo do POST /clientes/{id}/transacoes deve chegar. O Axum + Serde vai
   converter JSON → struct automaticamente, e depois faremos validações simples no handler.

   Notas didáticas:
   - Em JSON não existe tipo 'char'. O campo 'tipo' deve chegar como string de 1 caractere
     (ex.: "c" ou "d"); o Serde converte para char, validando implicitamente o tamanho.
   - .len() em String, no Rust, mede bytes UTF-8. Aqui o desafio usa ASCII; por isso o
     critério "1..=10 bytes" coincide com "1..=10 caracteres ASCII". Para texto multibyte,
     isso seria mais restritivo que VARCHAR(10) do Postgres (que conta caracteres). */
#[derive(Deserialize)]
struct TxPayload {
    valor: u32,        // inteiro sem sinal; mais adiante validamos que precisa ser > 0.
    tipo:  char,       // deve ser 'c' (crédito) ou 'd' (débito); qualquer outro caractere é rejeitado.
    descricao: String, // precisa ter de 1 a 10 bytes; usamos len() (bytes) por simplicidade no teste.
}

/* ============================== QUERIES DE ATALHO ======================================
   Em vez de escrever SQL completo em toda chamada, usamos constantes curtas que invocam as
   funções do banco e pedem o resultado como texto (::text). O texto já contém JSON pronto.

   Segurança:
   - Sempre usamos bind parameters (.bind(...)), evitando interpolação de strings e
     prevenindo injeção de SQL. */
const Q_GET_EXTRATO: &str = "SELECT get_extrato($1)::text";
const Q_PROCESS_TX:  &str = "SELECT process_transaction($1, $2, $3, $4)::text";

/* ============================== HELPERS DE RESPOSTA ====================================
   Pequenas funções utilitárias para padronizar respostas HTTP JSON e respostas vazias. */
#[inline(always)]
fn json_text(status: StatusCode, body: impl Into<Body>) -> Response {
    // Monta uma resposta HTTP com o status passado e corpo já em JSON text (String &str ou Bytes).
    Response::builder()
        .status(status)                                        // define o código HTTP (ex.: 200 OK).
        .header(CONTENT_TYPE, "application/json")              // garante Content-Type JSON.
        .body(body.into())                                     // coloca o corpo (já convertido em Body).
        .unwrap()                                              // unwrap é seguro aqui pois controlamos os dados.
}

#[inline(always)]
fn empty(status: StatusCode) -> Response {
    // Cria uma resposta sem corpo; útil para 404, 422 e 500 onde não vamos mandar JSON detalhado.
    Response::builder().status(status).body(Body::empty()).unwrap()
}

/* ============================== HANDLER: GET /health ===================================
   Observação: este endpoint simples é útil para health checks de orquestradores. */
async fn health() -> Response {
    empty(StatusCode::OK)
}

/* ============================== HANDLER: GET /extrato ==================================
   Recebe o id do cliente via Path e busca o extrato no banco. Regras:
   - Aceita apenas ids de 1 a 5 (checagem rápida com aritmética).
   - Se o banco retornar JSON, responde 200; se NULL, responde 404; se erro de banco, 500.

   Detalhe da checagem com wrapping_sub:
   - O teste "uid.wrapping_sub(1) > 4" é uma forma branch-friendly de verificar 1..=5 sem
     escrever duas comparações (id >= 1 && id <= 5). Para valores 1..=5, a expressão é falsa. */
async fn get_extrato(State(pool): State<PgPool>, Path(id): Path<u8>) -> Response {
    let uid = id as u32;                       // Converte para u32 para aplicar a checagem numérica barata.
    if uid.wrapping_sub(1) > 4 {               // Aceita apenas 1..=5: para esses valores a expressão é falsa.
        return empty(StatusCode::NOT_FOUND);   // Fora do intervalo esperado → 404 (cliente inexistente).
    }

    // Consulta escalar que devolve Option<String>: Some(JSON) se existir, None se não houver conta.
    match sqlx::query_scalar::<Postgres, Option<String>>(Q_GET_EXTRATO)
        .persistent(true)                      // Sinaliza uso de prepared statement persistente (melhor sob carga).
        .bind(id as i32)                       // Passa o parâmetro da função SQL (p_account_id).
        .fetch_one(&pool)                      // Executa no pool de conexões com o Postgres.
        .await
    {
        Ok(Some(body)) => json_text(StatusCode::OK, body),    // Conta existe: responde 200 com o JSON do banco.
        Ok(None) => empty(StatusCode::NOT_FOUND),             // Conta não existe: 404 sem corpo.
        Err(_) => empty(StatusCode::INTERNAL_SERVER_ERROR),   // Falha de banco: 500 sem detalhes (teste sintético).
    }
}

/* ============================== HANDLER: POST /transacoes ===============================
   Recebe id e um JSON com valor/tipo/descricao. Regras:
   - id deve estar entre 1 e 5 (como no extrato).
   - valor > 0; descricao 1..=10 bytes; tipo 'c' ou 'd'.
   - Se o Postgres indicar {"error":1}, a operação é inválida → 422; senão devolve 200 com saldo/limite.

   Observação sobre validação automática do Axum:
   - Se o JSON for malformado ou não bater com o schema de TxPayload, o extractor Json<T>
     já responde 400 Bad Request antes mesmo de o handler rodar. */
async fn post_transacao(
    State(pool): State<PgPool>,                // Injeta o pool de conexões no handler.
    Path(id): Path<u8>,                        // Extrai {id} da URL como u8 (suficiente para 1..=5).
    Json(payload): Json<TxPayload>,            // Desserializa o corpo JSON em TxPayload.
) -> Response {
    let uid = id as u32;                       // Converte para u32 para a mesma checagem barata.
    if uid.wrapping_sub(1) > 4 {               // Apenas ids 1..=5 são aceitos no cenário do teste.
        return empty(StatusCode::NOT_FOUND);   // Qualquer outro id retorna 404.
    }

    let v = payload.valor;                     // Lê o valor informado no JSON.
    if v == 0 {                                // Rejeita valores não positivos (precisa ser > 0).
        return empty(StatusCode::UNPROCESSABLE_ENTITY); // 422 indica erro de validação de domínio.
    }

    let dlen = payload.descricao.len();        // Mede o tamanho em bytes da descrição.
    if dlen == 0 || dlen > 10 {                // Exige entre 1 e 10 bytes (regra do desafio).
        return empty(StatusCode::UNPROCESSABLE_ENTITY); // Falhou na regra → 422.
    }

    let tipo = match payload.tipo {            // Converte o char em &str aceito pela função SQL.
        'c' => "c",                            // Crédito.
        'd' => "d",                            // Débito.
        _ => return empty(StatusCode::UNPROCESSABLE_ENTITY), // Qualquer outro caractere → 422.
    };

    // Executa a função process_transaction e trata retorno especial com {"error":1}.
    match sqlx::query_scalar::<Postgres, String>(Q_PROCESS_TX)
        .persistent(true)                      // Prepared statement persistente ajuda em cenários de alta repetição.
        .bind(id as i32)                       // p_account_id.
        .bind(v as i32)                        // p_amount (Postgres usa INT; convertendo de u32 para i32).
        .bind(tipo)                            // p_type ('c' ou 'd').
        .bind(&payload.descricao)              // p_description (tamanho já validado).
        .fetch_one(&pool)                      // Executa e coleta a string JSON.
        .await
    {
        Ok(body) if body.contains("\"error\"") => empty(StatusCode::UNPROCESSABLE_ENTITY), // Negócio inválido (ex.: limite).
        Ok(body) => json_text(StatusCode::OK, body), // Sucesso: retorna 200 com JSON vindo do banco.
        Err(_) => empty(StatusCode::INTERNAL_SERVER_ERROR), // Qualquer falha inesperada de banco → 500.
    }

    // Nota: o teste com .contains("\"error\"") é simples e suficiente aqui pois a função
    // process_transaction só retorna dois formatos: {"error":1} ou {"saldo":...,"limite":...}.
}

/* ============================== FUNÇÃO MAIN (INICIALIZAÇÃO) =============================
   Esta é a porta de entrada da aplicação. Ela:
   1) Lê variáveis de ambiente (ou usa padrões) para montar a URL do banco e configurar o pool.
   2) Cria o pool de conexões e aplica um ajuste de sessão (synchronous_commit='off') adequado a benchmarks.
   3) Executa o SQL de infraestrutura (índice + funções).
   4) Registra rotas e “anexa” o pool como estado compartilhado.
   5) Abre um socket na porta informada e ativa TCP_NODELAY para reduzir pequenas latências.
   6) Inicia o servidor Axum e fica aguardando requisições.

   Observações de operação:
   - synchronous_commit='off' pode perder transações nos últimos milissegundos em panes; use
     com cuidado e apenas quando a durabilidade imediata não for requisito (benchmarks).
   - PG_MIN/PG_MAX calibram o pool; exagerar no máximo pode aumentar contenção no Postgres.
   - 0.0.0.0 expõe o serviço na rede; para uso local, 127.0.0.1 é suficiente. */
#[tokio::main]                                 // Macro que inicializa o runtime assíncrono do Tokio (multi-thread por padrão).
async fn main() -> anyhow::Result<()> {        // Retorna Result para poder usar ? na inicialização.
    let db_host = std::env::var("DB_HOST").unwrap_or_else(|_| "localhost".to_string()); // Lê host do banco ou usa "localhost".
    let db_port = std::env::var("DB_PORT").unwrap_or_else(|_| "5432".to_string());      // Porta padrão do Postgres é 5432.
    let db_user = std::env::var("DB_USER").unwrap_or_else(|_| "postgres".to_string());  // Usuário padrão (ajuste em produção).
    let db_password = std::env::var("DB_PASSWORD").unwrap_or_else(|_| "postgres".to_string()); // Senha padrão (apenas para teste).
    let db_database = std::env::var("DB_DATABASE").unwrap_or_else(|_| "postgres_api_db".to_string()); // Nome do DB.
    let min_conns: u32 = std::env::var("PG_MIN").ok().and_then(|s| s.parse().ok()).unwrap_or(5);  // Tamanho mínimo do pool.
    let max_conns: u32 = std::env::var("PG_MAX").ok().and_then(|s| s.parse().ok()).unwrap_or(30); // Tamanho máximo do pool.
    let database_url = format!("postgres://{}:{}@{}:{}/{}", db_user, db_password, db_host, db_port, db_database); // Monta URL.

    let pool = PgPoolOptions::new()            // Constrói opções do pool de conexões do SQLx.
        .min_connections(min_conns)            // Define mínimo de conexões abertas.
        .max_connections(max_conns)            // Define máximo para limitar consumo e contenção.
        .after_connect(|conn, _meta| {         // Callback executado a cada conexão recém-criada no pool.
            Box::pin(async move {
                sqlx::query("SET synchronous_commit = 'off'") // Ajuste de sessão: melhora latência/throughput em benchmarks,
                    .execute(&mut *conn)                      // abrindo mão de durabilidade imediata dos últimos ms.
                    .await?;
                Ok::<_, sqlx::Error>(())
            })
        })
        .connect(&database_url)                // Abre conexões ao banco.
        .await?;                               // Espera a criação do pool (pode falhar se o banco estiver indisponível).

    // Observação: estas execuções são idempotentes (CREATE OR REPLACE / IF NOT EXISTS).
    // Em produção, é comum aplicar migrações com ferramentas (sqlx migrate, Flyway, Liquibase).
    sqlx::query(CREATE_INDEX_SQL).execute(&pool).await?;              // Garante a existência do índice (idempotente).
    sqlx::query(CREATE_EXTRACT_FUNCTION_SQL).execute(&pool).await?;   // Instala/atualiza função get_extrato.
    sqlx::query(CREATE_TRANSACTION_FUNCTION_SQL).execute(&pool).await?; // Instala/atualiza função process_transaction.

    let app = Router::new()                                           // Cria o roteador principal da API.
        .route("/health", get(health))                                // Registra rota GET de health.
        .route("/clientes/{id}/extrato", get(get_extrato))            // Registra rota GET de extrato.
        .route("/clientes/{id}/transacoes", post(post_transacao))     // Registra rota POST de transações.
        .with_state(pool);                                            // Anexa o pool como estado compartilhado para os handlers.

    let port: u16 = std::env::var("PORT").ok().and_then(|s| s.parse().ok()).unwrap_or(8080); // Porta configurável (padrão 8080).
    let addr: SocketAddr = ([0, 0, 0, 0], port).into();                                      // 0.0.0.0 expõe para outras máquinas na rede.
    
    use axum::serve::ListenerExt;                   // Importa extensão para ajustar propriedades de socket no listener.

    let listener = TcpListener::bind(addr).await?   // Abre um socket TCP e fica escutando na porta escolhida.
        .tap_io(|tcp| {                             // Permite “tocar” (customizar) cada conexão aceita.
            let _ = tcp.set_nodelay(true);          // Habilita TCP_NODELAY (desativa Nagle), útil para reduzir latências de micro-mensagens.
        });

    // Observação de performance: TCP_NODELAY evita coalescamento de pequenos pacotes, o que
    // reduz latência em endpoints de respostas curtas; pode aumentar overhead em redes ruidosas.
    axum::serve(listener, app).await?;        // Inicia o servidor HTTP do Axum usando o listener e o roteador.

    Ok(())                                    // Final feliz da função main.
}
