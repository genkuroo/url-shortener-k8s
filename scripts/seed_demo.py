#!/usr/bin/env python3
"""Seed a few demo links so the app has something visible to show.

This talks to the app over HTTP, NOT directly to the database — by design. In
Kubernetes the Postgres Service is only reachable from inside the cluster; the
way in is through the app (port-forward or ingress). That's the network model
working as intended.

Usage:
    # against a port-forward or ingress host
    python scripts/seed_demo.py http://localhost:8000
    # or set BASE_URL
    BASE_URL=http://urlshortener.localtest.me python scripts/seed_demo.py

For each demo link it creates the short code, then "clicks" it a few times so the
/stats endpoint shows real counts pulled from Postgres.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

# A handler that does NOT follow redirects, so visiting a short link records the
# click without us actually fetching the destination site.
_NO_REDIRECT = urllib.request.build_opener(
    type(
        "NoRedirect",
        (urllib.request.HTTPRedirectHandler,),
        {"redirect_request": lambda self, *a, **k: None},
    )()
)

# (long URL, how many times to click it)
DEMO_LINKS = [
    ("https://kubernetes.io/docs/concepts/workloads/controllers/deployment/", 5),
    ("https://helm.sh/docs/topics/charts/", 3),
    ("https://argo-cd.readthedocs.io/en/stable/", 8),
    ("https://fastapi.tiangolo.com/", 2),
]


def _post_json(url: str, payload: dict) -> dict:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def _click(url: str) -> None:
    """Hit a short link once, swallowing the redirect (that records a click)."""
    try:
        _NO_REDIRECT.open(url)
    except urllib.error.HTTPError as e:
        # 307 (redirect) is the success case here; anything else is a real error.
        if e.code not in (301, 302, 307, 308):
            raise


def main() -> None:
    base = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get("BASE_URL", "")).rstrip("/")
    if not base:
        sys.exit("Provide the app URL: python scripts/seed_demo.py http://<host>")

    print(f"Seeding demo links into {base}\n")
    for long_url, clicks in DEMO_LINKS:
        created = _post_json(f"{base}/api/links", {"url": long_url})
        code = created["code"]
        for _ in range(clicks):
            _click(f"{base}/{code}")
        print(f"  {code}  ←  {long_url}   ({clicks} clicks)")

    print("\nDone. Check stats, e.g.:")
    print(f"  curl {base}/api/links/{code}/stats")


if __name__ == "__main__":
    main()
