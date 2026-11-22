//! `lux mcp` with no Lux to reach: an MCP client starts it whatever the app's state, so it
//! answers from the binary alone and a tool's call says to open Lux, never ending itself.

#![allow(clippy::unwrap_used, clippy::indexing_slicing, reason = "a test's checks")]

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

#[tokio::test]
async fn without_lux_it_answers_and_a_tool_call_says_to_open_lux() {
    let folder = tempfile::tempdir().unwrap();
    // no app serves this socket.
    let socket = folder.path().join("agents.sock");
    let (client, server) = tokio::io::duplex(64 * 1024);
    let (server_read, server_write) = tokio::io::split(server);
    let mut running = tokio::task::JoinSet::new();
    running.spawn(lux_agent::serve_mcp(socket, server_read, server_write));
    let (client_read, mut client_write) = tokio::io::split(client);
    let mut lines = BufReader::new(client_read).lines();
    let mut ask = async |message: Value| -> Value {
        let mut line = serde_json::to_vec(&message).unwrap();
        line.push(b'\n');
        client_write.write_all(&line).await.unwrap();
        if message.get("id").is_none() {
            return Value::Null;
        }
        serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap()
    };

    let initialized = ask(json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": { "name": "test", "version": "1" } } }))
    .await;
    assert_eq!(initialized["result"]["serverInfo"]["name"], "lux");
    ask(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })).await;

    let tools = ask(json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list" })).await;
    let names: Vec<&str> = tools["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["name"].as_str().unwrap())
        .collect();
    assert!(names.contains(&"list_chats") && names.contains(&"organize_chats"));

    for id in [3, 4] {
        let call = ask(json!({ "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": { "name": "list_chats", "arguments": {} } }))
        .await;
        assert_eq!(call["result"]["isError"], true);
        let said = call["result"]["content"][0]["text"].as_str().unwrap();
        assert!(said.contains("Lux is not open"), "{said}");
    }
    // still serving: the calls ended nothing.
    assert!(running.try_join_next().is_none());
    running.abort_all();
}
