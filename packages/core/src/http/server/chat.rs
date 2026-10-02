//! LocalSend Chat fork extension. Independent of the file-upload session slot.
use super::common::error::AppError;
use super::common::response::{BoxedBody, JsonResponse};
use super::v2::ServerEventV2;
use super::{AppState, RequestClientInfo};
use http_body_util::{BodyExt, Limited};
use hyper::{Request, Response, StatusCode, body::Incoming};
use serde::Deserialize;
use std::time::Duration;
use tokio::sync::oneshot;

pub const MAX_TEXT_BYTES: usize = 32 * 1024;
pub const MAX_BODY_BYTES: usize = 64 * 1024;

#[derive(Debug)]
pub struct ChatReply {
    pub status: u16,
    pub body: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MessageRequest {
    id: String,
    text: String,
    sent_at_utc: String,
}

pub fn validate_message(body: &str) -> Result<(), AppError> {
    let message: MessageRequest =
        serde_json::from_str(body).map_err(|_| AppError::BadRequest("Invalid message".into()))?;
    if uuid::Uuid::parse_str(&message.id).is_err() || message.text.trim().is_empty() {
        return Err(AppError::BadRequest("Invalid message".into()));
    }
    if message.text.len() > MAX_TEXT_BYTES {
        return Err(AppError::Status(StatusCode::PAYLOAD_TOO_LARGE));
    }
    time::OffsetDateTime::parse(
        &message.sent_at_utc,
        &time::format_description::well_known::Rfc3339,
    )
    .map_err(|_| AppError::BadRequest("Invalid timestamp".into()))?;
    Ok(())
}

pub(crate) async fn request(
    req: Request<Incoming>,
    state: AppState,
    client: RequestClientInfo,
    operation: &'static str,
) -> Result<Response<BoxedBody>, AppError> {
    // Web sharing makes client certificates optional at the TLS handshake.
    // This guard is mandatory for chat even in that mode, and rejects HTTP.
    let fingerprint = client
        .cert_fingerprint()
        .ok_or(AppError::Status(StatusCode::UNAUTHORIZED))?;
    let v2 = state.v2.ok_or(AppError::Status(StatusCode::NOT_FOUND))?;
    let bytes = tokio::time::timeout(
        Duration::from_secs(15),
        Limited::new(req.into_body(), MAX_BODY_BYTES).collect(),
    )
    .await
    .map_err(|_| AppError::Status(StatusCode::REQUEST_TIMEOUT))?
    .map_err(|_| AppError::Status(StatusCode::PAYLOAD_TOO_LARGE))?
    .to_bytes();
    let body = String::from_utf8(bytes.to_vec())
        .map_err(|_| AppError::BadRequest("Invalid UTF-8".into()))?;
    if operation == "messages" {
        validate_message(&body)?;
    }
    let (reply_tx, reply_rx) = oneshot::channel();
    let event = ServerEventV2::ChatRequest {
        request_id: uuid::Uuid::new_v4().to_string(),
        ip: client.ip,
        fingerprint,
        operation: operation.to_string(),
        body,
        reply_tx,
    };
    // Do not block file events behind an unbounded backlog of chat requests.
    v2.event_tx
        .try_send(event)
        .map_err(|_| AppError::Status(StatusCode::SERVICE_UNAVAILABLE))?;
    let timeout = if operation == "authorize" { 60 } else { 15 };
    let reply = tokio::time::timeout(Duration::from_secs(timeout), reply_rx)
        .await
        .map_err(|_| AppError::Status(StatusCode::REQUEST_TIMEOUT))?
        .map_err(|_| AppError::Status(StatusCode::SERVICE_UNAVAILABLE))?;
    let body: serde_json::Value = serde_json::from_str(&reply.body)
        .map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?;
    Ok(JsonResponse {
        status: StatusCode::from_u16(reply.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
        body,
    }
    .into_response())
}
