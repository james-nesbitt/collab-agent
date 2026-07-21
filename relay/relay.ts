/**
 * Self-hosted collab relay for the omp GKE cluster (`omp-system`).
 *
 * Vendored from upstream `packages/collab-web/scripts/local-relay.ts`
 * (room-routing logic unchanged) with two deployment-specific additions:
 * - a TLS listener on :8443 (upstream's ws:// only) fed certs from
 *   `/certs/fullchain.pem` + `/certs/privkey.pem`, hot-reloaded on change;
 * - a plain :8080 listener serving the ACME HTTP-01 challenge path and
 *   `/healthz`, so certbot (the sidecar container) can prove domain control.
 *
 * Speaks the exact relay contract the real clients expect:
 * - `GET /r/<roomId>?role=host|guest` upgrades to a WebSocket.
 * - The host creates the room; a second host is rejected with close 4009 and
 *   a guest joining a missing room with close 4004.
 * - Host binary frames: envelope peerId 0 broadcasts to every guest, peerId N
 *   targets that guest only — forwarded unchanged either way.
 * - Guest binary frames: the first 4 envelope bytes are rewritten to the
 *   sender's peerId, then forwarded to the host.
 * - TEXT control to the host: `{"t":"peer-joined","peer":N}` / `{"t":"peer-left","peer":N}`.
 * - Host disconnect: TEXT `{"t":"room-closed"}` to every guest, then close 4001
 *   and the room is garbage-collected.
 *
 * The relay never sees plaintext: payloads stay sealed end to end.
 */
import { spawnSync } from "node:child_process";
import { existsSync, watch } from "node:fs";
import { rewriteEnvelopePeer, unpackEnvelope } from "./link";

const ROOM_PATH_RE = /^\/r\/([A-Za-z0-9_-]{10,64})$/;

const TLS_PORT = 8443;
const HTTP_PORT = 8080;
const CERT_PATH = process.env.RELAY_CERT ?? "/certs/fullchain.pem";
const KEY_PATH = process.env.RELAY_KEY ?? "/certs/privkey.pem";
const ACME_ROOT = "/acme/.well-known/acme-challenge";

interface SocketData {
	roomId: string;
	role: "host" | "guest";
	/** Assigned on open for guests; the host stays 0. */
	peerId: number;
}

type RelaySocket = Bun.ServerWebSocket<SocketData>;

interface Room {
	host: RelaySocket;
	guests: Map<number, RelaySocket>;
	nextPeerId: number;
}

const rooms = new Map<string, Room>();

function fetch(req: Request, srv: Bun.Server): Response | undefined {
	const url = new URL(req.url);
	const match = ROOM_PATH_RE.exec(url.pathname);
	const role = url.searchParams.get("role");
	if (!match || (role !== "host" && role !== "guest")) {
		return new Response("not found", { status: 404 });
	}
	const data: SocketData = { roomId: match[1]!, role, peerId: 0 };
	if (srv.upgrade(req, { data })) return undefined;
	return new Response("websocket upgrade required", { status: 426 });
}

const websocket: Bun.WebSocketHandler<SocketData> = {
	open(ws: RelaySocket): void {
		const { roomId, role } = ws.data;
		if (role === "host") {
			if (rooms.has(roomId)) {
				ws.close(4009, "a host is already connected for this room");
				return;
			}
			rooms.set(roomId, { host: ws, guests: new Map(), nextPeerId: 1 });
			return;
		}
		const room = rooms.get(roomId);
		if (!room) {
			ws.close(4004, "no such room");
			return;
		}
		const peerId = room.nextPeerId++;
		ws.data.peerId = peerId;
		room.guests.set(peerId, ws);
		room.host.send(JSON.stringify({ t: "peer-joined", peer: peerId }));
	},
	message(ws: RelaySocket, message: string | Buffer): void {
		if (typeof message === "string") return; // clients never send TEXT
		const room = rooms.get(ws.data.roomId);
		if (!room) return;
		if (ws.data.role === "host") {
			const envelope = unpackEnvelope(message as unknown as Uint8Array);
			if (!envelope) return;
			if (envelope.peerId === 0) {
				for (const guest of room.guests.values()) guest.send(message);
			} else {
				room.guests.get(envelope.peerId)?.send(message);
			}
			return;
		}
		if (message.byteLength < 4) return;
		rewriteEnvelopePeer(message as unknown as Uint8Array, ws.data.peerId);
		room.host.send(message);
	},
	close(ws: RelaySocket): void {
		const { roomId, role, peerId } = ws.data;
		const room = rooms.get(roomId);
		if (!room) return;
		if (role === "host") {
			// Rejected second host: the live room is not ours to tear down.
			if (room.host !== ws) return;
			rooms.delete(roomId);
			const closure = JSON.stringify({ t: "room-closed" });
			for (const guest of room.guests.values()) {
				guest.send(closure);
				guest.close(4001, "room closed");
			}
			room.guests.clear();
			return;
		}
		if (room.guests.delete(peerId)) {
			room.host.send(JSON.stringify({ t: "peer-left", peer: peerId }));
		}
	},
};

function ensureBootstrapCert(): void {
	if (existsSync(CERT_PATH) && existsSync(KEY_PATH)) return;
	console.log("relay: no cert on disk yet, generating a throwaway self-signed bootstrap pair");
	const result = spawnSync("openssl", [
		"req", "-x509", "-newkey", "rsa:2048",
		"-keyout", KEY_PATH, "-out", CERT_PATH,
		"-days", "1", "-nodes", "-subj", "/CN=bootstrap",
	]);
	if (result.status !== 0) {
		throw new Error(`relay: bootstrap cert generation failed: ${result.stderr?.toString()}`);
	}
}

async function acmeFetch(req: Request): Promise<Response> {
	const url = new URL(req.url);
	if (url.pathname === "/healthz") return new Response("ok", { status: 200 });
	if (url.pathname.startsWith("/.well-known/acme-challenge/")) {
		const token = url.pathname.slice("/.well-known/acme-challenge/".length);
		const file = Bun.file(`${ACME_ROOT}/${token}`);
		if (await file.exists()) return new Response(file, { status: 200 });
	}
	return new Response("not found", { status: 404 });
}

ensureBootstrapCert();

const tlsServer = Bun.serve({
	port: TLS_PORT,
	tls: { cert: Bun.file(CERT_PATH), key: Bun.file(KEY_PATH) },
	fetch,
	websocket,
});

const httpServer = Bun.serve({ port: HTTP_PORT, fetch: acmeFetch });

// certbot (sidecar container) writes a renewed cert to the same PVC; pick it
// up without dropping active rooms. Fall back to a full restart (the
// Deployment brings the pod back with the same cert path) if this Bun
// version's `server.reload` cannot swap TLS material live.
watch(CERT_PATH, { persistent: true }, () => {
	try {
		tlsServer.reload({ tls: { cert: Bun.file(CERT_PATH), key: Bun.file(KEY_PATH) } });
		console.log("relay: reloaded TLS certificate");
	} catch (err) {
		console.error("relay: live cert reload unsupported, restarting to pick it up", err);
		process.exit(0);
	}
});

console.log(`relay: wss listening on :${TLS_PORT}, acme/healthz on :${HTTP_PORT}`);

function shutdown(): void {
	for (const room of rooms.values()) {
		const closure = JSON.stringify({ t: "room-closed" });
		for (const guest of room.guests.values()) {
			guest.send(closure);
			guest.close(4001, "room closed");
		}
		room.host.close(1001, "relay shutting down");
	}
	rooms.clear();
	tlsServer.stop(true);
	httpServer.stop(true);
	process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
