// Axum on tokio: serves / and /json on port 8080 (or the argument)
use axum::{Json, Router, routing::get};
use serde::Serialize;

#[derive(Serialize)]
struct Info {
    os: &'static str,
    framework: &'static str,
}

#[tokio::main]
async fn main() {
    let port = std::env::args().nth(1).unwrap_or_else(|| "8080".into());
    let app = Router::new()
        .route("/", get(|| async { "Hello from Axum on ZDOS!\n" }))
        .route("/json", get(|| async { Json(Info { os: "ZDOS", framework: "axum" }) }));
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}")).await.unwrap();
    println!("listening on {}", listener.local_addr().unwrap());
    axum::serve(listener, app).await.unwrap();
}
