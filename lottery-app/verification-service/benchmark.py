#!/usr/bin/env python3
"""
Verification service latency benchmark.

Sends N repeated verification requests for the same ticket + draw-date
combination. Because the app follows cache-aside, the first request (cold)
hits RDS; all subsequent requests return from Redis.

Usage (against deployed ALB):
  python benchmark.py \\
    --base-url https://<alb-dns-name> \\
    --ticket-number TKT-001-WIN \\
    --draw-date 2024-01-15 \\
    --username agent1 \\
    --password <password> \\
    --requests 100

Usage (against local dev server without Redis):
  python benchmark.py \\
    --base-url http://localhost:8000 \\
    --ticket-number TKT-001-WIN \\
    --draw-date 2024-01-15 \\
    --username agent1 \\
    --password <password> \\
    --requests 100

Methodology
-----------
1. Run the benchmark once before deploying Redis (or with REDIS_URL unset).
   All 100 requests hit RDS. Record the baseline latency stats.

2. Deploy the Redis Terraform module, rebuild the ECS task definition so
   REDIS_URL is set, then run the benchmark again. The first request is cold
   (RDS hit); requests 2-N are served from Redis.

Compare the "warm avg" latency and p95 across both runs to quantify the
cache benefit. The CloudWatch dashboard (LotteryPlatform/VerificationService)
shows live CacheHit / CacheMiss counts and the hit-rate trend.
"""

import argparse
import re
import statistics
import sys
import time

import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


def _get_csrf(session, url):
    resp = session.get(url, allow_redirects=True)
    match = re.search(r'name="csrf_token"\s+value="([^"]+)"', resp.text)
    return match.group(1) if match else ""


def login(session, base_url, username, password):
    csrf = _get_csrf(session, f"{base_url}/login")
    resp = session.post(
        f"{base_url}/login",
        data={"username": username, "password": password, "csrf_token": csrf},
        allow_redirects=True,
    )
    if "logout" not in resp.text and "/verify" not in resp.url:
        print(f"ERROR: Login failed (HTTP {resp.status_code}). Check credentials.")
        sys.exit(1)
    print(f"Logged in as '{username}'.")


def run_benchmark(session, base_url, ticket_number, draw_date, n_requests):
    csrf = _get_csrf(session, f"{base_url}/verify")

    latencies_ms = []
    print(f"\nSending {n_requests} POST /verify  ticket={ticket_number}  date={draw_date}")
    print("-" * 65)

    for i in range(n_requests):
        t0 = time.perf_counter()
        resp = session.post(
            f"{base_url}/verify",
            data={
                "ticket_number": ticket_number,
                "draw_date":     draw_date,
                "csrf_token":    csrf,
            },
            allow_redirects=True,
        )
        elapsed_ms = (time.perf_counter() - t0) * 1000
        latencies_ms.append(elapsed_ms)

        # Refresh CSRF from response for the next iteration
        match = re.search(r'name="csrf_token"\s+value="([^"]+)"', resp.text)
        if match:
            csrf = match.group(1)

        label = "COLD" if i == 0 else "warm"
        print(f"  [{i + 1:3d}] {label:4s}  {elapsed_ms:8.2f} ms  HTTP {resp.status_code}")

    print("-" * 65)
    _print_stats(latencies_ms)


def _percentile(data, pct):
    sorted_data = sorted(data)
    idx = max(0, int(len(sorted_data) * pct / 100) - 1)
    return sorted_data[idx]


def _print_stats(latencies_ms):
    n = len(latencies_ms)
    if n == 0:
        return

    cold = latencies_ms[0]
    warm = latencies_ms[1:] if n > 1 else latencies_ms

    print("\nSUMMARY")
    print("=" * 65)
    print(f"  Total requests : {n}")
    print(f"  Cold (req #1)  : {cold:.2f} ms")

    if len(warm) > 0:
        print(f"  Warm avg       : {statistics.mean(warm):.2f} ms")
        print(f"  Warm median    : {statistics.median(warm):.2f} ms")
        print(f"  Warm p95       : {_percentile(warm, 95):.2f} ms")
        print(f"  Warm p99       : {_percentile(warm, 99):.2f} ms")

        speedup = cold / statistics.mean(warm)
        print(f"\n  Cache speedup  : {speedup:.1f}x  (cold ÷ warm avg)")
        print()
        print("  Expected with Redis : warm avg < 20 ms, p95 < 50 ms")
        print("  Expected without   : all requests ≈ RDS query time (50-200 ms)")


def main():
    parser = argparse.ArgumentParser(
        description="Measure verification latency before and after Redis caching."
    )
    parser.add_argument("--base-url",      required=True,  help="Service base URL")
    parser.add_argument("--ticket-number", required=True,  help="Ticket number to verify")
    parser.add_argument("--draw-date",     required=True,  help="Draw date (YYYY-MM-DD)")
    parser.add_argument("--username",      default="agent1")
    parser.add_argument("--password",      required=True)
    parser.add_argument("--requests",      type=int, default=50,
                        help="Number of verification requests (default: 50)")
    args = parser.parse_args()

    session = requests.Session()
    session.verify = False  # Accept self-signed cert used in the demo deployment

    login(session, args.base_url, args.username, args.password)
    run_benchmark(session, args.base_url, args.ticket_number, args.draw_date, args.requests)


if __name__ == "__main__":
    main()
