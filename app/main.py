"""URL shortener API (FastAPI) — Postgres-backed, with structured logging.

This is the same application from the AWS/ECS version of this project, moved onto
Kubernetes. The only thing that changed is where the database URL comes from: on
ECS it was fetched from AWS Secrets Manager at startup; here it's injected as the
DATABASE_URL environment variable from a Kubernetes Secret. The app code doesn't
know or care about the orchestrator — that's the whole point of a container.

Observability: a middleware writes one JSON line per request to stdout (method,
path, status, latency). In Kubernetes those lines are collected by the container
runtime and visible via `kubectl logs`; Phase 5 also scrapes Prometheus metrics
from /metrics for dashboards.

Where the database URL comes from:
  - Locally (docker compose): DATABASE_URL is set in docker-compose.yml.
  - On Kubernetes: DATABASE_URL is injected from a Secret (see the app
    Deployment manifest). The password is never baked into the image.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import string
import sys
import time

import psycopg2
import psycopg2.extras
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel, HttpUrl

app = FastAPI(title="URL Shortener")

# Characters used to build short codes (a-z, A-Z, 0-9).
_ALPHABET = string.ascii_letters + string.digits


# ---------------------------------------------------------------------------
# Structured request logging (observability)
# ---------------------------------------------------------------------------
# One JSON object per request, written to stdout. Kubernetes captures container
# stdout, so `kubectl logs` (and any log shipper) sees these lines. JSON instead
# of plain text so a log backend can filter structurally (e.g. `status >= 500`).
_logger = logging.getLogger("access")
_logger.setLevel(logging.INFO)
_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(logging.Formatter("%(message)s"))  # we pre-format as JSON
_logger.addHandler(_handler)
_logger.propagate = False


@app.middleware("http")
async def log_requests(request: Request, call_next):
    """Time each request and emit a structured JSON access log line."""
    start = time.perf_counter()
    response = await call_next(request)
    duration_ms = round((time.perf_counter() - start) * 1000, 1)
    _logger.info(
        json.dumps(
            {
                "event": "request",
                "method": request.method,
                "path": request.url.path,
                "status": response.status_code,
                "duration_ms": duration_ms,
            }
        )
    )
    return response


# ---------------------------------------------------------------------------
# Database connection
# ---------------------------------------------------------------------------
def _dsn() -> str:
    """Resolve the Postgres connection string from the environment.

    DATABASE_URL is injected from a Kubernetes Secret (or docker-compose locally).
    Failing loudly here is intentional: a pod with no DB config should crash on
    startup so Kubernetes surfaces it, rather than limp along and error per-request.
    """
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise RuntimeError("DATABASE_URL is not set.")
    return url


# Resolve once at import time; reuse for every connection.
_DSN = _dsn()


def _connect():
    """Open a fresh Postgres connection (one per request — simple and robust)."""
    return psycopg2.connect(_DSN)


def _init_db() -> None:
    """Create the tables if they don't exist yet.

    This is a tiny hand-rolled migration. A larger project would use a proper
    migration tool (e.g. Alembic); for two tables, idempotent CREATE TABLE IF NOT
    EXISTS run at startup is enough.
    """
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS links (
                code       TEXT PRIMARY KEY,
                long_url   TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS clicks (
                id         BIGSERIAL PRIMARY KEY,
                code       TEXT NOT NULL REFERENCES links(code) ON DELETE CASCADE,
                clicked_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            """
        )
        conn.commit()


@app.on_event("startup")
def _startup() -> None:
    _init_db()


def _new_code(cur, length: int = 6) -> str:
    """Generate a random short code that isn't already taken."""
    while True:
        code = "".join(secrets.choice(_ALPHABET) for _ in range(length))
        cur.execute("SELECT 1 FROM links WHERE code = %s", (code,))
        if cur.fetchone() is None:
            return code


class CreateLink(BaseModel):
    """Request body for creating a short link."""

    url: HttpUrl


# ---------------------------------------------------------------------------
# Web UI — a lightweight front end
# ---------------------------------------------------------------------------
# A single self-contained HTML page (inline CSS + vanilla JS, no framework, no
# build step, no static files). It's a thin client over the existing JSON API:
# the form calls POST /api/links and renders the result. Kept minimal on
# purpose — the project's focus is the infra, and this just makes the service
# usable by a human in a browser instead of only via curl.
_INDEX_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>URL Shortener</title>
  <style>
    :root { color-scheme: light dark; }
    body { font-family: system-ui, -apple-system, sans-serif; max-width: 32rem;
           margin: 4rem auto; padding: 0 1rem; line-height: 1.5; }
    h1 { margin-bottom: .25rem; }
    p.sub { margin-top: 0; opacity: .7; }
    form { display: flex; gap: .5rem; margin: 1.5rem 0; }
    input[type=url] { flex: 1; padding: .6rem .7rem; font-size: 1rem;
                      border: 1px solid #8888; border-radius: .4rem; }
    button { padding: .6rem 1rem; font-size: 1rem; border: 0; border-radius: .4rem;
             background: #2563eb; color: #fff; cursor: pointer; }
    button:disabled { opacity: .6; cursor: progress; }
    #result { margin-top: 1rem; padding: 1rem; border: 1px solid #8884;
              border-radius: .5rem; display: none; }
    #result.show { display: block; }
    #result.error { border-color: #dc2626; }
    .short a { font-weight: 600; font-size: 1.1rem; word-break: break-all; }
    .long { opacity: .7; font-size: .9rem; word-break: break-all; }
    .copy { margin-left: .5rem; padding: .25rem .6rem; font-size: .85rem;
            background: #4b5563; }
  </style>
</head>
<body>
  <h1>URL Shortener</h1>
  <p class="sub">Paste a long URL, get a short link.</p>

  <form id="form">
    <input id="url" type="url" placeholder="https://example.com/very/long/link"
           required autocomplete="off" />
    <button id="go" type="submit">Shorten</button>
  </form>

  <div id="result"></div>

  <script>
    const form = document.getElementById('form');
    const input = document.getElementById('url');
    const go = document.getElementById('go');
    const result = document.getElementById('result');

    function show(html, isError) {
      result.innerHTML = html;
      result.className = 'show' + (isError ? ' error' : '');
    }

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      go.disabled = true;
      show('Shortening…', false);
      try {
        const resp = await fetch('/api/links', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ url: input.value })
        });
        if (!resp.ok) {
          show("That doesn't look like a valid URL. Try including http:// or https://.", true);
          return;
        }
        const data = await resp.json();
        const shortUrl = window.location.origin + data.short_url;
        show(
          '<div class="short">→ <a href="' + shortUrl + '" target="_blank">' + shortUrl + '</a>' +
          '<button class="copy" type="button" id="copy">Copy</button></div>' +
          '<div class="long">redirects to ' + data.long_url + '</div>',
          false
        );
        document.getElementById('copy').addEventListener('click', () => {
          navigator.clipboard.writeText(shortUrl);
          document.getElementById('copy').textContent = 'Copied';
        });
        input.value = '';
      } catch (err) {
        show('Something went wrong reaching the server.', true);
      } finally {
        go.disabled = false;
      }
    });
  </script>
</body>
</html>
"""


@app.get("/", response_class=HTMLResponse)
def root():
    """Serve the web UI — a thin client over POST /api/links."""
    return _INDEX_HTML


@app.get("/healthz")
def healthz():
    """Liveness/readiness probe. Kubernetes hits this to check the app is alive.

    Kept deliberately DB-free: it answers as long as the web process is up, so a
    brief database hiccup doesn't make Kubernetes kill an otherwise-healthy pod.
    """
    return {"status": "ok"}


@app.post("/api/links", status_code=201)
def create_link(body: CreateLink):
    """Create a short link for a long URL."""
    with _connect() as conn, conn.cursor() as cur:
        code = _new_code(cur)
        cur.execute(
            "INSERT INTO links (code, long_url) VALUES (%s, %s)",
            (code, str(body.url)),
        )
        conn.commit()
    return {"code": code, "short_url": f"/{code}", "long_url": str(body.url)}


@app.get("/api/links/{code}/stats")
def link_stats(code: str):
    """Return click stats for a short link, read from Postgres."""
    with _connect() as conn, conn.cursor(
        cursor_factory=psycopg2.extras.RealDictCursor
    ) as cur:
        cur.execute(
            "SELECT code, long_url, created_at FROM links WHERE code = %s", (code,)
        )
        link = cur.fetchone()
        if link is None:
            raise HTTPException(status_code=404, detail="code not found")

        cur.execute("SELECT count(*) AS n FROM clicks WHERE code = %s", (code,))
        click_count = cur.fetchone()["n"]

        cur.execute(
            "SELECT clicked_at FROM clicks WHERE code = %s "
            "ORDER BY clicked_at DESC LIMIT 5",
            (code,),
        )
        recent = [{"at": r["clicked_at"].isoformat()} for r in cur.fetchall()]

    return {
        "code": link["code"],
        "long_url": link["long_url"],
        "created_at": link["created_at"].isoformat(),
        "click_count": click_count,
        "recent_clicks": recent,
    }


@app.get("/{code}")
def follow(code: str):
    """Redirect a short code to its long URL and record the click."""
    with _connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT long_url FROM links WHERE code = %s", (code,))
        row = cur.fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="code not found")
        long_url = row[0]
        cur.execute("INSERT INTO clicks (code) VALUES (%s)", (code,))
        conn.commit()
    return RedirectResponse(url=long_url, status_code=307)
