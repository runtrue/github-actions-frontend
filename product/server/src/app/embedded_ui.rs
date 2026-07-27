use axum::body::Bytes;
use axum::extract::Path;
use axum::http::header::{CACHE_CONTROL, CONTENT_TYPE, LOCATION, REFERRER_POLICY};
use axum::http::{HeaderMap, HeaderName, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};

const INDEX_HTML: &[u8] = include_bytes!("../../../../ui/public/index.html");
const APP_JS: &[u8] = include_bytes!("../../../../ui/public/app.js");
const STYLES_CSS: &[u8] = include_bytes!("../../../../ui/public/styles.css");
const FAVICON_SVG: &[u8] = include_bytes!("../../../../ui/public/favicon.svg");
const CONTENT_SECURITY_POLICY: &str = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'";
const MAX_CLIENT_ERROR_BYTES: usize = 2048;

fn static_response(
    body: &'static [u8],
    content_type: &'static str,
    cache_control: &'static str,
) -> Response {
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static(content_type));
    headers.insert(CACHE_CONTROL, HeaderValue::from_static(cache_control));
    headers.insert(
        HeaderName::from_static("content-security-policy"),
        HeaderValue::from_static(CONTENT_SECURITY_POLICY),
    );
    headers.insert(REFERRER_POLICY, HeaderValue::from_static("same-origin"));
    headers.insert(
        HeaderName::from_static("x-content-type-options"),
        HeaderValue::from_static("nosniff"),
    );
    (headers, body).into_response()
}

pub(in crate::app) async fn index() -> Response {
    static_response(INDEX_HTML, "text/html; charset=utf-8", "no-store")
}

pub(in crate::app) async fn repository_index(
    Path((_owner, _repository)): Path<(String, String)>,
) -> Response {
    index().await
}

pub(in crate::app) async fn repository_section_index(
    Path((_owner, _repository, section)): Path<(String, String, String)>,
) -> Response {
    if matches!(
        section.as_str(),
        "overview" | "runs" | "secrets" | "variables" | "settings"
    ) {
        index().await
    } else {
        StatusCode::NOT_FOUND.into_response()
    }
}

pub(in crate::app) async fn app_js() -> Response {
    static_response(APP_JS, "text/javascript; charset=utf-8", "no-cache")
}

pub(in crate::app) async fn styles_css() -> Response {
    static_response(STYLES_CSS, "text/css; charset=utf-8", "no-cache")
}

pub(in crate::app) async fn favicon() -> Response {
    static_response(FAVICON_SVG, "image/svg+xml", "public, max-age=86400")
}

pub(in crate::app) async fn frontend_health() -> Response {
    (
        [
            (
                CONTENT_TYPE,
                HeaderValue::from_static("application/json; charset=utf-8"),
            ),
            (CACHE_CONTROL, HeaderValue::from_static("no-store")),
        ],
        r#"{"status":"ok"}"#,
    )
        .into_response()
}

pub(in crate::app) async fn frontend_client_error(body: Bytes) -> Response {
    let bounded = &body[..body.len().min(MAX_CLIENT_ERROR_BYTES)];
    let detail = serde_json::from_slice::<serde_json::Value>(bounded)
        .ok()
        .and_then(|value| value["detail"].as_str().map(str::to_owned))
        .unwrap_or_else(|| "unknown client error".to_owned());
    let sanitized = detail
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .take(500)
        .collect::<String>();
    eprintln!("runtrue-quickstart: frontend client error: {sanitized}");
    StatusCode::NO_CONTENT.into_response()
}

pub(in crate::app) async fn legacy_index() -> Response {
    (
        StatusCode::PERMANENT_REDIRECT,
        [(LOCATION, HeaderValue::from_static("/"))],
    )
        .into_response()
}

pub(in crate::app) async fn legacy_repository_section(
    Path((owner, repository, section)): Path<(String, String, String)>,
) -> Response {
    if !matches!(
        section.as_str(),
        "overview" | "runs" | "secrets" | "variables" | "settings"
    ) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let location = format!("/repositories/{owner}/{repository}/{section}");
    match HeaderValue::from_str(&location) {
        Ok(location) => (StatusCode::PERMANENT_REDIRECT, [(LOCATION, location)]).into_response(),
        Err(_) => StatusCode::BAD_REQUEST.into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_ui_is_the_product_surface() {
        let html = std::str::from_utf8(INDEX_HTML).unwrap();
        assert!(html.contains("data-view=\"repositories\""));
        assert!(html.contains("data-view=\"github\""));
        assert!(html.contains("/assets/app.js"));
    }

    #[test]
    fn content_security_policy_remains_closed() {
        assert!(CONTENT_SECURITY_POLICY.contains("default-src 'none'"));
        assert!(CONTENT_SECURITY_POLICY.contains("script-src 'self'"));
        assert!(!CONTENT_SECURITY_POLICY.contains("unsafe-inline"));
    }
}
