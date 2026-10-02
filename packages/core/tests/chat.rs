#![cfg(feature = "http")]

use localsend::crypto::cert::{SelfSignedCert, generate_self_signed};
use localsend::http::client::{ClientError, LsHttpClientV2};
use localsend::http::dto_v2::{PrepareUploadRequestDtoV2, RegisterDtoV2};
use localsend::http::server::chat::ChatReply;
use localsend::http::server::v2::PrepareUploadDecisionV2;
use localsend::http::server::v2::ServerEventV2;
use localsend::http::server::web::{WebConfig, WebMode};
use localsend::http::server::{ServerConfigV2, TlsConfig, start_with_port};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::ProtocolType;
use localsend::model::transfer::FileDto;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

#[tokio::test]
async fn chat_remains_available_during_a_file_session() {
    let receiver = generate_self_signed().unwrap();
    let sender = generate_self_signed().unwrap();
    let (port, mut events, _stop) = server(Some(&receiver), false).await;
    let sender_client = client(&sender, &receiver.fingerprint);
    let payload = PrepareUploadRequestDtoV2 {
        info: RegisterDtoV2 {
            alias: "Phone".into(),
            version: "2.2".into(),
            device_model: None,
            device_type: None,
            fingerprint: sender.fingerprint.clone(),
            port: 53318,
            protocol: ProtocolType::Https,
            download: false,
        },
        files: [(
            "file".into(),
            FileDto {
                id: "file".into(),
                file_name: "file.txt".into(),
                size: 5,
                file_type: "text/plain".into(),
                sha256: None,
                preview: None,
                metadata: None,
            },
        )]
        .into_iter()
        .collect(),
    };
    let upload = tokio::spawn(async move {
        sender_client
            .prepare_upload(
                ProtocolType::Https,
                "127.0.0.1",
                port,
                None,
                payload,
                None,
                CancellationToken::new(),
            )
            .await
    });
    if let ServerEventV2::PrepareUpload { decision_tx, .. } = events.recv().await.unwrap() {
        decision_tx
            .send(PrepareUploadDecisionV2::Accept(["file".into()].into_iter().collect()))
            .unwrap();
    } else {
        panic!("Expected file session");
    }
    assert!(upload.await.unwrap().unwrap().response.is_some());
    let sender_client = client(&sender, &receiver.fingerprint);
    let chat = tokio::spawn(async move {
        sender_client
            .chat_request("127.0.0.1", port, "messages", message("while transferring"))
            .await
    });
    if let ServerEventV2::ChatRequest { reply_tx, .. } = events.recv().await.unwrap() {
        // Storage failures must remain failures to the sender, even during a file session.
        reply_tx
            .send(ChatReply {
                status: 503,
                body: "{}".into(),
            })
            .unwrap();
    } else {
        panic!("Chat used the file session slot");
    }
    assert_status(chat.await.unwrap().unwrap_err(), 503);
}

async fn server(
    identity: Option<&SelfSignedCert>,
    web: bool,
) -> (u16, mpsc::Receiver<ServerEventV2>, oneshot::Sender<()>) {
    let (tx, rx) = mpsc::channel(16);
    let (stop, stopped) = oneshot::channel();
    let handle = start_with_port(
        0,
        identity.map(|i| TlsConfig {
            cert: i.certificate_pem.clone(),
            private_key: i.private_key_pem.clone(),
        }),
        ClientInfo {
            alias: "Chat test".into(),
            version: "2.2".into(),
            device_model: None,
            device_type: None,
            token: "test".into(),
        },
        None,
        Some(ServerConfigV2 {
            pin: None,
            verify_checksums: true,
            event_tx: tx,
        }),
        WebConfig {
            mode: if web {
                WebMode::Upload
            } else {
                WebMode::Disabled
            },
            ..Default::default()
        },
        stopped,
    )
    .await
    .unwrap();
    (handle.port(), rx, stop)
}

fn client(identity: &SelfSignedCert, fingerprint: &str) -> LsHttpClientV2 {
    LsHttpClientV2::try_new(
        &identity.private_key_pem,
        &identity.certificate_pem,
        Some(fingerprint.to_string()),
        None,
    )
    .unwrap()
}

fn message(text: &str) -> String {
    serde_json::json!({"id": uuid::Uuid::new_v4().to_string(), "text": text, "sentAtUtc": "2026-10-02T12:34:56.123Z"}).to_string()
}

fn assert_status(error: ClientError, expected: u16) {
    match error {
        ClientError::StatusCode(error) => assert_eq!(error.status, expected),
        other => panic!("Unexpected error: {other:?}"),
    }
}

#[tokio::test]
async fn waits_for_persistence_and_authenticates_sender() {
    let receiver = generate_self_signed().unwrap();
    let sender = generate_self_signed().unwrap();
    let (port, mut events, _stop) = server(Some(&receiver), false).await;
    let client = client(&sender, &receiver.fingerprint);
    let body = message("你好 👋\nsecond line");
    let expected = body.clone();
    let request = tokio::spawn(async move {
        client
            .chat_request("127.0.0.1", port, "messages", body)
            .await
    });
    let event = events.recv().await.unwrap();
    match event {
        ServerEventV2::ChatRequest {
            fingerprint,
            operation,
            body,
            reply_tx,
            ..
        } => {
            assert_eq!(fingerprint, sender.fingerprint);
            assert_eq!(operation, "messages");
            assert_eq!(body, expected);
            // No acknowledgement is sent until the application commits its transaction.
            tokio::time::sleep(Duration::from_millis(30)).await;
            assert!(!request.is_finished());
            reply_tx
                .send(ChatReply {
                    status: 200,
                    body: "{\"saved\":true}".into(),
                })
                .unwrap();
        }
        other => panic!("Unexpected event: {other:?}"),
    }
    assert_eq!(request.await.unwrap().unwrap(), "{\"saved\":true}");
}

#[tokio::test]
async fn concurrent_requests_keep_independent_reply_ids() {
    let receiver = generate_self_signed().unwrap();
    let sender = generate_self_signed().unwrap();
    let (port, mut events, _stop) = server(Some(&receiver), false).await;
    let a = client(&sender, &receiver.fingerprint);
    let b = client(&sender, &receiver.fingerprint);
    let first =
        tokio::spawn(async move { a.chat_request("127.0.0.1", port, "info", "{}".into()).await });
    let second = tokio::spawn(async move {
        b.chat_request(
            "127.0.0.1",
            port,
            "authorize",
            "{\"alias\":\"Phone\",\"port\":53318}".into(),
        )
        .await
    });
    let one = events.recv().await.unwrap();
    let two = events.recv().await.unwrap();
    let (id_a, id_b) = match (&one, &two) {
        (
            ServerEventV2::ChatRequest { request_id: a, .. },
            ServerEventV2::ChatRequest { request_id: b, .. },
        ) => (a, b),
        _ => panic!("Expected independent requests"),
    };
    assert_ne!(id_a, id_b);
    // Reply in reverse order, with different decisions.
    for event in [two, one] {
        if let ServerEventV2::ChatRequest {
            operation,
            reply_tx,
            ..
        } = event
        {
            reply_tx
                .send(ChatReply {
                    status: if operation == "info" { 200 } else { 403 },
                    body: "{}".into(),
                })
                .unwrap();
        }
    }
    assert_eq!(first.await.unwrap().unwrap(), "{}");
    assert_status(second.await.unwrap().unwrap_err(), 403);
}

#[tokio::test]
async fn limits_utf8_body_and_rejects_invalid_messages_before_event() {
    let receiver = generate_self_signed().unwrap();
    let sender = generate_self_signed().unwrap();
    let (port, mut events, _stop) = server(Some(&receiver), false).await;
    let client = client(&sender, &receiver.fingerprint);
    for (body, status) in [
        (message(" \n\t"), 400),
        (message(&"你".repeat(10923)), 413),
        ("x".repeat(65537), 413),
        (
            "{\"id\":\"bad\",\"text\":\"hello\",\"sentAtUtc\":\"invalid\"}".into(),
            400,
        ),
    ] {
        assert_status(
            client
                .chat_request("127.0.0.1", port, "messages", body)
                .await
                .unwrap_err(),
            status,
        );
        assert!(events.try_recv().is_err());
    }
    let text = "a".repeat(32768);
    let request = tokio::spawn(async move {
        client
            .chat_request("127.0.0.1", port, "messages", message(&text))
            .await
    });
    if let ServerEventV2::ChatRequest { reply_tx, .. } = events.recv().await.unwrap() {
        reply_tx
            .send(ChatReply {
                status: 200,
                body: "{}".into(),
            })
            .unwrap();
    } else {
        panic!("Expected message at exact boundary");
    }
    assert!(request.await.unwrap().is_ok());
}

#[tokio::test]
async fn rejects_anonymous_web_clients_http_and_wrong_certificate_pin() {
    let receiver = generate_self_signed().unwrap();
    let sender = generate_self_signed().unwrap();
    let (port, mut events, _stop) = server(Some(&receiver), true).await;
    let anonymous = localsend::reqwest::Client::builder()
        .tls_danger_accept_invalid_certs(true)
        .no_proxy()
        .build()
        .unwrap();
    let response = anonymous
        .get(format!(
            "https://127.0.0.1:{port}/api/localsend-chat/v1/info"
        ))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 401);
    assert!(events.try_recv().is_err());
    let wrong = client(&sender, &sender.fingerprint);
    assert!(
        wrong
            .chat_request("127.0.0.1", port, "info", "{}".into())
            .await
            .is_err()
    );
    assert!(events.try_recv().is_err());
    let (port, mut events, _stop) = server(None, false).await;
    let response = anonymous
        .post(format!(
            "http://127.0.0.1:{port}/api/localsend-chat/v1/messages"
        ))
        .body(message("hello"))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 401);
    assert!(events.try_recv().is_err());
}
