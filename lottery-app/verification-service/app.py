import json
import logging
import time
import types
import boto3
from datetime import date, datetime, timezone
from flask import Flask, render_template, request, redirect, url_for, flash, jsonify
from flask_login import LoginManager, login_user, logout_user, login_required, current_user
from flask_wtf.csrf import CSRFProtect
from werkzeug.middleware.proxy_fix import ProxyFix
from models import db, User, Draw, Ticket, AuditLog
from config import Config
from seed_data import seed_database
from sqlalchemy.exc import OperationalError

logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}'
)
logger = logging.getLogger(__name__)


# ── SQS helper ────────────────────────────────────────────────────────────────

def _publish_winner_event(queue_url, region, ticket, draw, draw_date_str, verified_by_id):
    """Publish a winner-verified event to SQS. Errors are logged but never re-raised
    so a SQS outage cannot break the verification flow."""
    if not queue_url:
        return
    try:
        sqs = boto3.client("sqs", region_name=region)
        sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=json.dumps({
                "ticket_id":     ticket.id,
                "ticket_number": ticket.ticket_number,
                "draw_id":       draw.id,
                "draw_date":     draw_date_str,
                "prize_amount":  str(ticket.prize_amount),
                "verified_by":   verified_by_id,
                "verified_at":   datetime.now(timezone.utc).isoformat(),
            }),
        )
        logger.info(f"WINNER_QUEUED ticket={ticket.ticket_number}")
    except Exception as exc:
        logger.error(f"SQS_PUBLISH_FAILED ticket={ticket.ticket_number} error={exc}")


# ── CloudWatch metrics ────────────────────────────────────────────────────────

def _publish_metrics(region, cache_hit, latency_ms):
    """Emit cache and latency metrics to the LotteryPlatform/VerificationService namespace."""
    try:
        cw = boto3.client("cloudwatch", region_name=region)
        cw.put_metric_data(
            Namespace="LotteryPlatform/VerificationService",
            MetricData=[
                {"MetricName": "CacheHit",           "Value": 1 if cache_hit else 0,   "Unit": "Count"},
                {"MetricName": "CacheMiss",          "Value": 0 if cache_hit else 1,   "Unit": "Count"},
                # CacheHitRate as a per-request binary value (0.0 or 1.0); CloudWatch
                # Average over a window gives the hit-rate fraction for that window.
                {"MetricName": "CacheHitRate",       "Value": 1.0 if cache_hit else 0.0, "Unit": "None"},
                {"MetricName": "VerificationLatency","Value": latency_ms,               "Unit": "Milliseconds"},
            ],
        )
    except Exception as exc:
        logger.warning(f"CW_METRICS_FAILED error={exc}")


# ── Redis serialization helpers ───────────────────────────────────────────────

def _result_to_cache(result):
    """Serialize a verification result dict to JSON for Redis storage.

    Only the fields the Jinja template actually reads are included; SQLAlchemy
    model objects are converted to plain dicts so they survive JSON round-trips.
    """
    payload = {"outcome": result["outcome"]}
    if result.get("ticket"):
        t = result["ticket"]
        payload["ticket"] = {
            "ticket_number": t.ticket_number,
            "prize_amount":  float(t.prize_amount) if t.prize_amount is not None else None,
            "id":            t.id,
            "status":        t.status,
        }
    if result.get("draw"):
        d = result["draw"]
        payload["draw"] = {
            "draw_name": d.draw_name,
            "draw_date": str(d.draw_date),
        }
    if result.get("claim"):
        c = result["claim"]
        payload["claim"] = {"claim_ref": c.claim_ref}
    return json.dumps(payload)


def _cache_to_result(raw):
    """Deserialize a Redis cache entry back to a result dict.

    Nested dicts become SimpleNamespace objects so template attribute access
    (result.ticket.ticket_number etc.) works identically to the live-query path.
    """
    data = json.loads(raw)
    result = {"outcome": data["outcome"], "_from_cache": True}
    if "ticket" in data:
        result["ticket"] = types.SimpleNamespace(**data["ticket"])
    if "draw" in data:
        result["draw"] = types.SimpleNamespace(**data["draw"])
    if "claim" in data:
        result["claim"] = types.SimpleNamespace(**data["claim"])
    return result


# ── Redis initialization ──────────────────────────────────────────────────────

def _init_redis(redis_url):
    """Connect to Redis and return a client, or None if unconfigured / unreachable.

    A 2-second connect/socket timeout prevents startup delays when ElastiCache is
    temporarily unavailable; the service falls back to direct DB queries in that case.
    """
    if not redis_url:
        return None
    try:
        import redis as redis_lib
        client = redis_lib.from_url(
            redis_url,
            socket_connect_timeout=2,
            socket_timeout=2,
            decode_responses=True,
        )
        client.ping()
        logger.info(f"REDIS_CONNECTED url={redis_url}")
        return client
    except Exception as exc:
        logger.warning(f"REDIS_UNAVAILABLE url={redis_url} error={exc}")
        return None


# ── Application factory ───────────────────────────────────────────────────────

def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)
    db.init_app(app)
    CSRFProtect(app)
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_port=1)

    redis_client = _init_redis(app.config.get("REDIS_URL"))

    with app.app_context():
        for i in range(10):
            try:
                db.create_all()
                seed_database()
                print("Database initialized.")
                break
            except OperationalError:
                print(f"Database not ready. Retry {i+1}/10")
                time.sleep(10)

    @app.context_processor
    def inject_service_urls():
        return dict(
            verify_url=app.config["VERIFY_SERVICE_URL"],
            claims_url=app.config["CLAIMS_SERVICE_URL"]
        )

    login_manager = LoginManager(app)
    login_manager.login_view = "login"
    login_manager.login_message_category = "info"

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, int(user_id))

    def log_audit(action, entity_type=None, entity_id=None, details=None):
        entry = AuditLog(
            user_id=current_user.id if current_user.is_authenticated else None,
            action=action, entity_type=entity_type,
            entity_id=str(entity_id) if entity_id else None, details=details,
        )
        db.session.add(entry)
        db.session.flush()

    # ── Health check ──────────────────────────────────────────────────────────

    @app.route("/health")
    def health():
        try:
            db.session.execute(db.text("SELECT 1"))
        except Exception as e:
            logger.error(f"Health check DB failure: {e}")
            return jsonify({"status": "degraded", "db": "unreachable"}), 500

        redis_status = "disabled"
        if redis_client:
            try:
                redis_client.ping()
                redis_status = "reachable"
            except Exception:
                redis_status = "unreachable"

        return jsonify({"status": "ok", "db": "reachable", "redis": redis_status}), 200

    # ── Auth ──────────────────────────────────────────────────────────────────

    @app.route("/login", methods=["GET", "POST"])
    def login():
        if current_user.is_authenticated:
            return redirect(url_for("verify"))
        if request.method == "POST":
            username = request.form.get("username", "").strip()
            password = request.form.get("password", "")
            user = User.query.filter_by(username=username).first()
            if user and user.check_password(password):
                login_user(user)
                logger.info(f"LOGIN_SUCCESS user={username}")
                return redirect(url_for("verify"))
            logger.warning(f"LOGIN_FAIL user={username}")
            flash("Invalid username or password.", "danger")
        return render_template("login.html")

    @app.route("/logout")
    @login_required
    def logout():
        logger.info(f"LOGOUT user={current_user.username}")
        logout_user()
        flash("You have been logged out.", "info")
        return redirect(url_for("login"))

    # ── Verify ticket ─────────────────────────────────────────────────────────

    @app.route("/", methods=["GET"])
    @app.route("/verify", methods=["GET", "POST"])
    @login_required
    def verify():
        result = None
        ticket_number = ""
        draw_date_str = ""

        if request.method == "POST":
            ticket_number = request.form.get("ticket_number", "").strip().upper()
            draw_date_str = request.form.get("draw_date", "").strip()
            errors = []
            if not ticket_number: errors.append("Ticket number is required.")
            if not draw_date_str: errors.append("Draw date is required.")
            if errors:
                for e in errors: flash(e, "danger")
                return render_template("verify.html", result=None,
                                       ticket_number=ticket_number, draw_date=draw_date_str)
            try:
                draw_date = date.fromisoformat(draw_date_str)
            except ValueError:
                flash("Invalid date format.", "danger")
                return render_template("verify.html", result=None,
                                       ticket_number=ticket_number, draw_date=draw_date_str)

            region = app.config.get("AWS_REGION", "us-east-1")
            ttl = int(app.config.get("CACHE_TTL_SECONDS", 3600))
            cache_key = f"verify:{ticket_number}:{draw_date_str}"
            t_start = time.monotonic()
            cache_hit = False

            # ── Cache-aside: check Redis ──────────────────────────────────────
            if redis_client:
                try:
                    cached = redis_client.get(cache_key)
                    if cached:
                        result = _cache_to_result(cached)
                        cache_hit = True
                        logger.info(f"CACHE_HIT ticket={ticket_number} date={draw_date_str}")
                except Exception as exc:
                    logger.warning(f"REDIS_GET_FAILED key={cache_key} error={exc}")

            # ── Cache miss: query RDS ─────────────────────────────────────────
            if result is None:
                draw = Draw.query.filter_by(draw_date=draw_date).first()
                ticket = None
                if draw:
                    ticket = Ticket.query.filter_by(
                        ticket_number=ticket_number, draw_id=draw.id).first()

                if not ticket:
                    result = {"outcome": "NOT_FOUND"}
                    logger.info(f"VERIFY_NOT_FOUND ticket={ticket_number} date={draw_date_str}")
                elif not ticket.is_winner:
                    result = {"outcome": "NOT_WINNER", "ticket": ticket, "draw": draw}
                    logger.info(f"VERIFY_NOT_WINNER ticket={ticket_number}")
                elif ticket.status == "CLAIMED":
                    result = {"outcome": "ALREADY_CLAIMED", "ticket": ticket,
                              "draw": draw, "claim": ticket.claim}
                    logger.info(f"VERIFY_ALREADY_CLAIMED ticket={ticket_number}")
                else:
                    result = {"outcome": "WINNER", "ticket": ticket, "draw": draw}
                    logger.info(f"VERIFY_WINNER ticket={ticket_number} prize={ticket.prize_amount}")

                # WINNER is intentionally excluded: its status can change to CLAIMED
                # shortly after verification, so it must always read from RDS.
                if redis_client and result["outcome"] != "WINNER":
                    try:
                        redis_client.setex(cache_key, ttl, _result_to_cache(result))
                    except Exception as exc:
                        logger.warning(f"REDIS_SET_FAILED key={cache_key} error={exc}")

            latency_ms = (time.monotonic() - t_start) * 1000

            # Emit metrics whenever Redis is configured regardless of hit/miss
            if app.config.get("REDIS_URL"):
                _publish_metrics(region, cache_hit=cache_hit, latency_ms=latency_ms)

            # Audit every verification attempt (cache hit or miss) for compliance
            ticket_id_for_audit = (
                result["ticket"].id if result.get("ticket") else None
            )
            log_audit(
                "VERIFY_TICKET", "ticket", ticket_id_for_audit,
                f"ticket={ticket_number} outcome={result['outcome']} cached={'yes' if cache_hit else 'no'}",
            )
            db.session.commit()

            # SQS event only on a fresh DB-sourced WINNER result (not from cache)
            if result["outcome"] == "WINNER" and not result.get("_from_cache"):
                _publish_winner_event(
                    queue_url=app.config.get("SQS_QUEUE_URL", ""),
                    region=region,
                    ticket=result["ticket"],
                    draw=result["draw"],
                    draw_date_str=draw_date_str,
                    verified_by_id=current_user.id,
                )

        return render_template("verify.html", result=result,
                               ticket_number=ticket_number, draw_date=draw_date_str)

    return app


app = create_app()

if __name__ == "__main__":
    app.run(debug=False, host="0.0.0.0", port=8000)
