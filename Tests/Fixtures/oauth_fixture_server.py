#!/usr/bin/env python3
"""MCP resource server and OAuth authorization server in one process, for OAuthTests.

Prints `PORT <n>` as its first stdout line and logs only to stderr. Runs under
the Command Line Tools Python 3.9, so it uses the standard library only.
"""

import argparse
import base64
import hashlib
import json
import re
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote_plus, urlencode, urlparse


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-prm", action="store_true",
                        help="404 the protected resource metadata and serve the authorization server at the root")
    parser.add_argument("--prm-root-only", action="store_true",
                        help="serve the protected resource metadata only at the root well-known URL")
    parser.add_argument("--no-as-metadata", action="store_true",
                        help="404 every authorization server metadata document")
    parser.add_argument("--no-registration", action="store_true", help="advertise no registration endpoint")
    parser.add_argument("--registration-fails", action="store_true", help="reject every registration")
    parser.add_argument("--deny", action="store_true", help="redirect back with error=access_denied")
    parser.add_argument("--bad-state", action="store_true", help="redirect back with the wrong state")
    parser.add_argument("--expires-in", type=int, default=3600,
                        help="expires_in of tokens from the authorization code grant; refreshed tokens last an hour")
    parser.add_argument("--refresh-fails", action="store_true", help="answer every refresh with invalid_grant")
    parser.add_argument("--refresh-keeps-token", action="store_true",
                        help="refresh without rotating: no refresh_token in the response, the old one stays valid")
    parser.add_argument("--no-s256", action="store_true", help="advertise only the plain PKCE method")
    parser.add_argument("--insecure-token-endpoint", action="store_true",
                        help="advertise http://example.invalid/token")
    parser.add_argument("--client-id", help="a pre-registered client accepted without registration")
    parser.add_argument("--client-auth", choices=["none", "client_secret_basic", "client_secret_post"], default="none",
                        help="issue a client secret at registration and require this token endpoint auth method")
    parser.add_argument("--token-delay", type=float, default=0.0,
                        help="seconds the token endpoint waits before answering")
    return parser.parse_args()


ARGS = parse_args()
SCOPES = ["mcp:read", "mcp:write"]
PREFIX = "" if ARGS.no_prm else "/auth"
LOCK = threading.Lock()
BASE = ""
CLIENTS = {}
CODES = {}
ACCESS_TOKENS = {}
REFRESH_TOKENS = {}
STATE = {
    "registrations": 0,
    "authorize": 0,
    "token_grants": {"authorization_code": 0, "refresh_token": 0},
    "pkce_verified": 0,
    "last_resource": None,
    "last_scope": None,
    "last_redirect_uri": None,
    "last_client_id": None,
    "last_token_resource": None,
    "last_client_auth": None,
}


def issuer():
    return BASE + PREFIX


def pkce_s256(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


class Handler(BaseHTTPRequestHandler):
    server_version = "OAuthFixture/1"

    def log_message(self, fmt, *args):
        sys.stderr.write("oauth fixture: %s\n" % (fmt % args))

    def send_json(self, status, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def do_GET(self):
        url = urlparse(self.path)
        query = {name: values[0] for name, values in parse_qs(url.query, keep_blank_values=True).items()}
        if url.path == "/test/state":
            with LOCK:
                snapshot = json.loads(json.dumps(STATE))
            return self.send_json(200, snapshot)
        if url.path in ("/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource"):
            return self.protected_resource_metadata(url.path)
        if url.path == "/.well-known/oauth-authorization-server" + PREFIX and not ARGS.no_as_metadata:
            return self.authorization_server_metadata()
        if url.path == PREFIX + "/authorize":
            return self.authorize(query)
        self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        path = urlparse(self.path).path
        body = self.read_body()
        if path == "/mcp":
            return self.mcp(body)
        if path == PREFIX + "/register" and not ARGS.no_registration:
            return self.register(body)
        if path == PREFIX + "/token":
            return self.token(body)
        if path == "/test/revoke":
            with LOCK:
                ACCESS_TOKENS.clear()
            return self.send_json(200, {})
        self.send_json(404, {"error": "not_found"})

    # Resource server

    def mcp(self, body):
        authorization = self.headers.get("Authorization", "")
        token = authorization[len("Bearer "):] if authorization.startswith("Bearer ") else None
        with LOCK:
            expiry = ACCESS_TOKENS.get(token) if token else None
        if expiry is None or expiry < time.time():
            if ARGS.no_prm:
                challenge = 'Bearer realm="mcp"'
            else:
                challenge = 'Bearer resource_metadata="%s/.well-known/oauth-protected-resource/mcp"' % BASE
            if token:
                challenge += ', error="invalid_token", error_description="The access token is not valid"'
            return self.send_json(401, {"error": "unauthorized"}, {"WWW-Authenticate": challenge})
        try:
            request = json.loads(body or b"{}")
        except ValueError:
            request = {}
        self.send_json(200, {"jsonrpc": "2.0", "id": request.get("id"), "result": {"ok": True}})

    def protected_resource_metadata(self, path):
        if ARGS.no_prm or (ARGS.prm_root_only and path.endswith("/mcp")):
            return self.send_json(404, {"error": "not_found"})
        self.send_json(200, {
            "resource": BASE + "/mcp",
            "authorization_servers": [BASE + "/auth"],
            "scopes_supported": SCOPES,
            "bearer_methods_supported": ["header"],
        })

    # Authorization server

    def authorization_server_metadata(self):
        metadata = {
            "issuer": issuer(),
            "authorization_endpoint": issuer() + "/authorize",
            "token_endpoint": "http://example.invalid/token" if ARGS.insecure_token_endpoint else issuer() + "/token",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["plain"] if ARGS.no_s256 else ["S256"],
            "token_endpoint_auth_methods_supported": ["none", "client_secret_basic", "client_secret_post"],
            "scopes_supported": SCOPES,
        }
        if not ARGS.no_registration:
            metadata["registration_endpoint"] = issuer() + "/register"
        self.send_json(200, metadata)

    def register(self, body):
        if ARGS.registration_fails:
            return self.send_json(400, {"error": "invalid_redirect_uri",
                                        "error_description": "Redirect URIs must use https."})
        try:
            request = json.loads(body)
        except ValueError:
            return self.send_json(400, {"error": "invalid_client_metadata", "error_description": "Body is not JSON."})
        uris = request.get("redirect_uris")
        problems = []
        if not isinstance(uris, list) or not uris:
            problems.append("redirect_uris is required")
        if request.get("token_endpoint_auth_method") != "none":
            problems.append("expected a public client")
        if "authorization_code" not in (request.get("grant_types") or []):
            problems.append("grant_types must include authorization_code")
        if problems:
            return self.send_json(400, {"error": "invalid_client_metadata", "error_description": "; ".join(problems)})
        client_id = "client-" + secrets.token_hex(8)
        secret = secrets.token_urlsafe(16) if ARGS.client_auth != "none" else None
        with LOCK:
            CLIENTS[client_id] = {"redirect_uris": uris, "secret": secret, "auth": ARGS.client_auth}
            STATE["registrations"] += 1
        response = {
            "client_id": client_id,
            "client_name": request.get("client_name"),
            "redirect_uris": uris,
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": ARGS.client_auth,
        }
        if secret:
            response["client_secret"] = secret
        self.send_json(201, response)

    def authorize(self, query):
        redirect_uri = query.get("redirect_uri", "")
        with LOCK:
            STATE["authorize"] += 1
            STATE["last_resource"] = query.get("resource")
            STATE["last_scope"] = query.get("scope")
            STATE["last_redirect_uri"] = redirect_uri
            STATE["last_client_id"] = query.get("client_id")
            client = CLIENTS.get(query.get("client_id"))
        problems = []
        if query.get("response_type") != "code":
            problems.append("response_type must be code")
        if client is None:
            problems.append("unknown client_id")
        elif client["redirect_uris"] is None:
            # Claude Code registers its pre-registered clients with this form.
            if not re.fullmatch(r"http://localhost:\d+/callback", redirect_uri):
                problems.append("redirect_uri must be http://localhost:<port>/callback")
        elif redirect_uri not in client["redirect_uris"]:
            problems.append("redirect_uri is not registered")
        if query.get("code_challenge_method") != "S256" or not query.get("code_challenge"):
            problems.append("PKCE with S256 is required")
        if query.get("resource") != BASE + "/mcp":
            problems.append("resource must be %s/mcp" % BASE)
        if not query.get("state"):
            problems.append("state is required")
        if problems:
            return self.send_json(400, {"error": "invalid_request", "error_description": "; ".join(problems)})
        if ARGS.deny:
            return self.redirect(redirect_uri + "?" + urlencode({
                "error": "access_denied", "error_description": "The user denied access", "state": query["state"]}))
        code = secrets.token_urlsafe(24)
        with LOCK:
            CODES[code] = {
                "client_id": query["client_id"],
                "redirect_uri": redirect_uri,
                "challenge": query["code_challenge"],
                "resource": query["resource"],
                "scope": query.get("scope"),
            }
        state = "not-the-state-you-sent" if ARGS.bad_state else query["state"]
        self.redirect(redirect_uri + "?" + urlencode({"code": code, "state": state}))

    def token(self, body):
        if ARGS.token_delay:
            time.sleep(ARGS.token_delay)
        form = {name: values[0] for name, values in parse_qs(body.decode(), keep_blank_values=True).items()}
        grant_type = form.get("grant_type")
        with LOCK:
            if grant_type in STATE["token_grants"]:
                STATE["token_grants"][grant_type] += 1
        client_id, problem = self.authenticate_client(form)
        if problem:
            return self.send_json(401, {"error": "invalid_client", "error_description": problem})
        if grant_type == "authorization_code":
            return self.authorization_code_grant(form, client_id)
        if grant_type == "refresh_token":
            return self.refresh_token_grant(form, client_id)
        self.send_json(400, {"error": "unsupported_grant_type"})

    def authenticate_client(self, form):
        client_id = form.get("client_id")
        secret = None
        method = "none"
        authorization = self.headers.get("Authorization", "")
        if authorization.startswith("Basic "):
            decoded = base64.b64decode(authorization[len("Basic "):]).decode()
            basic_id, _, basic_secret = decoded.partition(":")
            basic_id, basic_secret = unquote_plus(basic_id), unquote_plus(basic_secret)
            if client_id and client_id != basic_id:
                return None, "client_id does not match the Basic credentials"
            client_id, secret, method = basic_id, basic_secret, "client_secret_basic"
        elif "client_secret" in form:
            secret, method = form["client_secret"], "client_secret_post"
        with LOCK:
            STATE["last_client_auth"] = method
            client = CLIENTS.get(client_id)
        if client is None:
            return None, "unknown client"
        if client["auth"] != method:
            return None, "expected %s client authentication, got %s" % (client["auth"], method)
        if client["secret"] is not None and secret != client["secret"]:
            return None, "wrong client secret"
        return client_id, None

    def authorization_code_grant(self, form, client_id):
        with LOCK:
            grant = CODES.pop(form.get("code"), None)
        if grant is None or grant["client_id"] != client_id:
            return self.send_json(400, {"error": "invalid_grant", "error_description": "Unknown or used code."})
        if form.get("redirect_uri") != grant["redirect_uri"]:
            return self.send_json(400, {"error": "invalid_grant", "error_description": "redirect_uri does not match."})
        if form.get("resource") != grant["resource"]:
            return self.send_json(400, {"error": "invalid_target", "error_description": "resource does not match."})
        verifier = form.get("code_verifier", "")
        if not 43 <= len(verifier) <= 128 or pkce_s256(verifier) != grant["challenge"]:
            return self.send_json(400, {"error": "invalid_grant", "error_description": "PKCE verification failed."})
        with LOCK:
            STATE["pkce_verified"] += 1
            STATE["last_token_resource"] = form.get("resource")
        self.issue_tokens(client_id, grant["resource"], grant["scope"], ARGS.expires_in, rotate=True)

    def refresh_token_grant(self, form, client_id):
        if ARGS.refresh_fails:
            return self.send_json(400, {"error": "invalid_grant", "error_description": "The refresh token was revoked."})
        token = form.get("refresh_token")
        with LOCK:
            record = REFRESH_TOKENS.get(token)
            if record is not None and not ARGS.refresh_keeps_token:
                del REFRESH_TOKENS[token]
        if record is None or record["client_id"] != client_id:
            return self.send_json(400, {"error": "invalid_grant", "error_description": "Unknown refresh token."})
        if form.get("resource") != record["resource"]:
            return self.send_json(400, {"error": "invalid_target", "error_description": "resource does not match."})
        with LOCK:
            STATE["last_token_resource"] = form.get("resource")
        self.issue_tokens(client_id, record["resource"], record["scope"], 3600, rotate=not ARGS.refresh_keeps_token)

    def issue_tokens(self, client_id, resource, scope, expires_in, rotate):
        access_token = "at-" + secrets.token_urlsafe(24)
        body = {"access_token": access_token, "token_type": "Bearer", "expires_in": expires_in}
        with LOCK:
            ACCESS_TOKENS[access_token] = time.time() + expires_in
            if rotate:
                refresh_token = "rt-" + secrets.token_urlsafe(24)
                REFRESH_TOKENS[refresh_token] = {"client_id": client_id, "resource": resource, "scope": scope}
                body["refresh_token"] = refresh_token
        if scope:
            body["scope"] = scope
        self.send_json(200, body, {"Cache-Control": "no-store"})


def main():
    global BASE
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    BASE = "http://127.0.0.1:%d" % server.server_address[1]
    if ARGS.client_id:
        CLIENTS[ARGS.client_id] = {"redirect_uris": None, "secret": None, "auth": "none"}
    print("PORT %d" % server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
