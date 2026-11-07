use super::*;
use axum::{Router, http::StatusCode, routing::post};
use std::time::Duration;

async fn upstream(
    search: (StatusCode, &'static str),
    ml: (StatusCode, &'static str),
) -> (String, tokio::task::JoinHandle<()>) {
    let app = Router::new()
        .route("/api/search/smart", post(move || async move { search }))
        .route("/predict", post(move || async move { ml }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (base, task)
}

fn assert_category_and_is_error(actual: ApiError, expected: ApiError) {
    assert_eq!(
        std::mem::discriminant(&actual),
        std::mem::discriminant(&expected)
    );
    assert_eq!(crate::tools::api_error(actual).is_error, Some(true));
}

#[tokio::test]
async fn only_explicit_ml_load_failure_diagnoses_model() {
    let cases = [
        (
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                r#"{"message":"Failed to search smart"}"#,
            ),
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                r#"{"detail":"Failed to load model 'ViT-B-32__openai'"}"#,
            ),
            ApiError::ModelUnavailable,
        ),
        (
            (StatusCode::INTERNAL_SERVER_ERROR, "Internal Server Error"),
            (StatusCode::INTERNAL_SERVER_ERROR, "Internal Server Error"),
            ApiError::Upstream(String::new()),
        ),
        (
            (StatusCode::INTERNAL_SERVER_ERROR, "Internal Server Error"),
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                r#"{"detail":"Failed to load model 'buffalo_l'"}"#,
            ),
            ApiError::Upstream(String::new()),
        ),
        (
            (StatusCode::INTERNAL_SERVER_ERROR, "Internal Server Error"),
            (
                StatusCode::OK,
                r#"{"detail":"Failed to load model 'ViT-B-32__openai'"}"#,
            ),
            ApiError::Upstream(String::new()),
        ),
        (
            (StatusCode::INTERNAL_SERVER_ERROR, "Internal Server Error"),
            (StatusCode::OK, r#"{"clip":"embedding"}"#),
            ApiError::Upstream(String::new()),
        ),
        (
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                r#"{"detail":"Failed to load model 'ViT-B-32__openai'"}"#,
            ),
            (StatusCode::NOT_FOUND, "Not Found"),
            ApiError::Upstream(String::new()),
        ),
        (
            (StatusCode::UNAUTHORIZED, r#"{"message":"Invalid API key"}"#),
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                r#"{"detail":"Failed to load model 'ViT-B-32__openai'"}"#,
            ),
            ApiError::Auth(String::new()),
        ),
        (
            (StatusCode::OK, "not JSON"),
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                r#"{"detail":"Failed to load model 'ViT-B-32__openai'"}"#,
            ),
            ApiError::Upstream(String::new()),
        ),
        (
            (StatusCode::OK, r#"{"assets":{"items":null}}"#),
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                r#"{"detail":"Failed to load model 'ViT-B-32__openai'"}"#,
            ),
            ApiError::Upstream(String::new()),
        ),
    ];
    for (search, ml, expected) in cases {
        let (base, task) = upstream(search, ml).await;
        let result = Client::new(base.clone(), "test-key".into())
            .smart_search("beach", 5, &base)
            .await;
        task.abort();
        assert_category_and_is_error(result.unwrap_err(), expected);
    }
}

#[tokio::test]
async fn successful_search_does_not_depend_on_ml_probe() {
    let (base, task) = upstream(
        (StatusCode::OK, r#"{"assets":{"items":[{"id":"photo-1","originalFileName":"beach.jpg","localDateTime":"2026-11-01"}]}}"#),
        (StatusCode::INTERNAL_SERVER_ERROR, r#"{"detail":"Failed to load model 'ViT-B-32__openai'"}"#),
    ).await;
    let assets = Client::new(base.clone(), "test-key".into())
        .smart_search("beach", 5, &base)
        .await
        .unwrap();
    task.abort();
    assert_eq!(assets[0].id, "photo-1");
    assert_eq!(assets[0].file_name, "beach.jpg");
    assert_eq!(assets[0].taken_at, "2026-11-01");
}

#[tokio::test]
async fn unreachable_server_is_not_ready() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    let error = Client::new(base.clone(), "test-key".into())
        .smart_search("beach", 5, &base)
        .await
        .unwrap_err();
    assert_category_and_is_error(error, ApiError::NotReady);
}

#[tokio::test]
async fn search_timeout_is_upstream_not_a_model_diagnosis() {
    let app = Router::new().route(
        "/api/search/smart",
        post(|| async {
            tokio::time::sleep(Duration::from_secs(1)).await;
            StatusCode::OK
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let mut client = Client::new(base.clone(), "test-key".into());
    client.http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_millis(50))
        .build()
        .unwrap();
    let result = client.smart_search("beach", 5, &base).await;
    task.abort();
    assert_category_and_is_error(result.unwrap_err(), ApiError::Upstream(String::new()));
}

#[tokio::test]
async fn ml_probe_timeout_preserves_upstream_category() {
    let app = Router::new()
        .route(
            "/api/search/smart",
            post(|| async { (StatusCode::INTERNAL_SERVER_ERROR, "search failed") }),
        )
        .route(
            "/predict",
            post(|| async {
                tokio::time::sleep(Duration::from_secs(4)).await;
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    r#"{"detail":"Failed to load model 'ViT-B-32__openai'"}"#,
                )
            }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let result = Client::new(base.clone(), "test-key".into())
        .smart_search("beach", 5, &base)
        .await;
    task.abort();
    assert_category_and_is_error(result.unwrap_err(), ApiError::Upstream(String::new()));
}
