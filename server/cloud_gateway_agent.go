package main

import (
	"encoding/json"
	"log"
	"net/url"
	"os"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
)

// cloudGatewayEnvelope matches outbound WebSocket wire format used by PLANULIX_CLOUD_* pairing.
type cloudGatewayEnvelope struct {
	ID      string                 `json:"id,omitempty"`
	Op      string                 `json:"op"`
	Payload map[string]interface{} `json:"payload,omitempty"`
	Error   string                 `json:"error,omitempty"`
}

// RunCloudGatewayAgentWorker connects outbound to the configured gateway URL and serves RPC using local SessionServer state.
// No HTTP listener — same machine/session data as full planulix-server, for use alongside manual pairing env vars.
func RunCloudGatewayAgentWorker() {
	gatewayWS := os.Getenv("PLANULIX_CLOUD_GATEWAY_WS")
	serverID := os.Getenv("PLANULIX_CLOUD_SERVER_ID")
	secret := os.Getenv("PLANULIX_CLOUD_AGENT_SECRET")
	if gatewayWS == "" || serverID == "" || secret == "" {
		log.Fatal("PLANULIX_CLOUD_GATEWAY_WS, PLANULIX_CLOUD_SERVER_ID, PLANULIX_CLOUD_AGENT_SECRET are required")
	}
	claudeHome := os.Getenv("CLAUDE_HOME")
	if claudeHome == "" {
		home, _ := os.UserHomeDir()
		claudeHome = home + "/.claude"
	}
	srv := NewSessionServer(claudeHome)
	u, err := url.Parse(gatewayWS)
	if err != nil {
		log.Fatal(err)
	}
	q := u.Query()
	q.Set("server_id", serverID)
	q.Set("token", secret)
	u.RawQuery = q.Encode()
	d := websocket.Dialer{HandshakeTimeout: 15 * time.Second}
	for {
		conn, _, err := d.Dial(u.String(), nil)
		if err != nil {
			log.Printf("cloud-gateway-agent: dial %v, retry in 5s", err)
			time.Sleep(5 * time.Second)
			continue
		}
		log.Printf("cloud-gateway-agent: connected")
		serveCloudGatewayAgentConn(conn, srv)
		log.Printf("cloud-gateway-agent: disconnected, reconnect in 3s")
		time.Sleep(3 * time.Second)
	}
}

func serveCloudGatewayAgentConn(conn *websocket.Conn, srv *SessionServer) {
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(120 * time.Second))
	conn.SetPongHandler(func(string) error {
		_ = conn.SetReadDeadline(time.Now().Add(120 * time.Second))
		return nil
	})
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return
		}
		var env cloudGatewayEnvelope
		if err := json.Unmarshal(data, &env); err != nil {
			continue
		}
		switch env.Op {
		case "ping":
			cloudGatewayReply(conn, cloudGatewayEnvelope{ID: env.ID, Op: "pong", Payload: map[string]interface{}{"ok": true, "service": "planulix-server-agent"}})
		case "list_sessions":
			limit := 50
			if env.Payload != nil {
				switch v := env.Payload["limit"].(type) {
				case float64:
					if n := int(v); n > 0 {
						limit = n
					}
				case int:
					if v > 0 {
						limit = v
					}
				}
			}
			list, total := srv.CollectSessionsList(limit)
			raw, err := json.Marshal(list)
			if err != nil {
				cloudGatewayReply(conn, cloudGatewayEnvelope{ID: env.ID, Op: "error", Error: "marshal sessions"})
				continue
			}
			var sessions []interface{}
			if err := json.Unmarshal(raw, &sessions); err != nil {
				cloudGatewayReply(conn, cloudGatewayEnvelope{ID: env.ID, Op: "error", Error: "sessions shape"})
				continue
			}
			cloudGatewayReply(conn, cloudGatewayEnvelope{
				ID: env.ID,
				Op: "list_sessions",
				Payload: map[string]interface{}{
					"sessions": sessions,
					"total":    total,
				},
			})
		default:
			cloudGatewayReply(conn, cloudGatewayEnvelope{ID: env.ID, Op: "error", Error: "unknown op"})
		}
	}
}

func cloudGatewayReply(conn *websocket.Conn, env cloudGatewayEnvelope) {
	if env.ID == "" {
		env.ID = uuid.NewString()
	}
	raw, err := json.Marshal(env)
	if err != nil {
		return
	}
	_ = conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
	_ = conn.WriteMessage(websocket.TextMessage, raw)
}
