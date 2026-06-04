import io
import json
import threading
import time
import uuid
import base64
import logging
import boto3
from datetime import datetime, timezone
from flask import Flask, render_template, request, redirect, url_for, flash, jsonify
from flask_login import LoginManager, login_user, logout_user, login_required, current_user
from flask_wtf.csrf import CSRFProtect
from sqlalchemy.exc import IntegrityError
import qrcode
from models import db, User, Ticket, Claimant, Claim, AuditLog
from config import Config
from werkzeug.middleware.proxy_fix import ProxyFix

logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}'
)
logger = logging.getLogger(__name__)


def _handle_winner_message(body):
    """Process one SQS winner message inside an active app context.

    Writes a WINNER_QUEUED audit entry so ops can see that the claims service
    received the event. If the ticket is ALREADY CLAIMED the message is a
    harmless duplicate and is acknowledged WITHOUT writing anything.

    Raises on unexpected errors so the caller can choose NOT to delete the
    message - letting SQS retry up to maxReceiveCount times before routing
    to the DLQ.
    """
    data = json.loads(body)
    ticket_id     = data["ticket_id"]
    ticket_number = data.get("ticket_number", str(ticket_id))

    ticket = db.session.get(Ticket, ticket_id)
    if ticket is None:
        logger.warning(f"WINNER_QUEUE_UNKNOWN_TICKET ticket_id={ticket_id}")
        return

    if ticket.status == "CLAIMED":
        logger.info(f"WINNER_QUEUE_ALREADY_CLAIMED ticket={ticket_number}")
        return

    entry = AuditLog(
        user_id=None,
        action="WINNER_QUEUED",
        entity_type="ticket",
        entity_id=str(ticket_id),
        details=(
            f"ticket={ticket_number} "
            f"draw={data.get('draw_date')} "
            f"prize={data.get('prize_amount')} "
            f"verified_by={data.get('verified_by')} "
            f"verified_at={data.get('verified_at')}"
        ),
    )
    db.session.add(entry)
    db.session.commit()
    logger.info(f"WINNER_QUEUED_RECEIVED ticket={ticket_number}")


def start_sqs_consumer(app):
    """Start a daemon thread that long-polls SQS for winner events.

    Daemon threads are killed automatically when the main process exits, so
    no explicit shutdown logic is needed. The thread is only started when
    SQS_QUEUE_URL is configured - running without it (e.g. local dev without
    AWS credentials) leaves the app fully functional via HTTP alone.
    """
    queue_url = app.config.get("SQS_QUEUE_URL", "")
    if not queue_url:
        logger.info("SQS_QUEUE_URL not set - SQS consumer not started")
        return

    region = app.config.get("AWS_REGION", "us-east-1")

    def poll():
        sqs = boto3.client("sqs", region_name=region)
        logger.info(f"SQS consumer started queue={queue_url}")

        while True:
            try:
                response = sqs.receive_message(
                    QueueUrl=queue_url,
                    MaxNumberOfMessages=10,
                    # Long polling: blocks up to 20 s before returning empty.
                    # Matches the receive_wait_time_seconds set in Terraform.
                    WaitTimeSeconds=20,
                    VisibilityTimeout=30,
                )
                for msg in response.get("Messages", []):
                    receipt = msg["ReceiptHandle"]
                    try:
                        with app.app_context():
                            _handle_winner_message(msg["Body"])
                        # Only delete after successful processing.
                        sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt)
                    except Exception as exc:
                        # Log but do NOT delete - SQS will make the message
                        # visible again after VisibilityTimeout expires and
                        # retry up to maxReceiveCount (3) times before the DLQ.
                        logger.error(f"SQS_MESSAGE_FAILED error={exc} body={msg['Body'][:200]}")

            except Exception as exc:
                logger.error(f"SQS_RECEIVE_ERROR error={exc}")
                time.sleep(5)  # brief back-off before retrying the receive call

    thread = threading.Thread(target=poll, daemon=True, name="sqs-consumer")
    thread.start()


def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)
    db.init_app(app)
    CSRFProtect(app)
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_port=1)

    @app.context_processor
    def inject_service_urls():
        return dict(
            verify_url=app.config["VERIFY_SERVICE_URL"],
            claims_url=app.config["CLAIMS_SERVICE_URL"]
        )

    login_manager = LoginManager(app)
    login_manager.login_message_category = "info"
    login_manager.login_view = None  # no local login route

    @login_manager.unauthorized_handler
    def unauthorized():
        return redirect(f"{app.config['VERIFY_SERVICE_URL']}/login")

    @login_manager.user_loader
    def load_user(user_id):
        return db.session.get(User, int(user_id))

    # ── Helpers ───────────────────────────────────────────────────────────────
    def log_audit(action, entity_type=None, entity_id=None, details=None):
        entry = AuditLog(
            user_id=current_user.id if current_user.is_authenticated else None,
            action=action, entity_type=entity_type,
            entity_id=str(entity_id) if entity_id else None, details=details,
        )
        db.session.add(entry)
        db.session.flush()

    def make_qr_b64(data: str) -> str:
        img = qrcode.make(data)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return base64.b64encode(buf.getvalue()).decode()

    # ── Health check ──────────────────────────────────────────────────────────
    @app.route("/health")
    def health():
        try:
            db.session.execute(db.text("SELECT 1"))
            return jsonify({"status": "ok", "db": "reachable"}), 200
        except Exception as e:
            logger.error(f"Health check DB failure: {e}")
            return jsonify({"status": "degraded", "db": "unreachable"}), 500
        
    @app.route("/claims/health")
    def claims_health():
        try:
            db.session.execute(db.text("SELECT 1"))
            return jsonify({"status": "ok", "db": "reachable"}), 200
        except Exception as e:
            logger.error(f"Health check DB failure: {e}")
            return jsonify({"status": "degraded", "db": "unreachable"}), 500

    # ── Auth ──────────────────────────────────────────────────────────────────
    @app.route("/login", methods=["GET", "POST"])
    def login():
        if current_user.is_authenticated:
            return redirect(url_for("search_claims"))
        if request.method == "POST":
            username = request.form.get("username", "").strip()
            password = request.form.get("password", "")
            user = User.query.filter_by(username=username).first()
            if user and user.check_password(password):
                login_user(user)
                logger.info(f"LOGIN_SUCCESS user={username}")
                return redirect(url_for("search_claims"))
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

    # ── Claim form ────────────────────────────────────────────────────────────
    @app.route("/claims/new/<int:ticket_id>", methods=["GET"])
    @login_required
    def claim_form(ticket_id):
        ticket = db.session.get(Ticket, ticket_id)
        if not ticket or not ticket.is_winner or ticket.status == "CLAIMED":
            flash("This ticket cannot be registered.", "danger")
            return redirect(url_for("search_claims"))
        return render_template("claim_form.html", ticket=ticket, draw=ticket.draw)

    # ── Register claim ────────────────────────────────────────────────────────
    @app.route("/claims", methods=["POST"])
    @login_required
    def register_claim():
        ticket_id = request.form.get("ticket_id", type=int)
        full_name = request.form.get("full_name", "").strip()
        email = request.form.get("email", "").strip()
        phone = request.form.get("phone", "").strip()
        address = request.form.get("address", "").strip()

        errors = []
        if not full_name: errors.append("Full name is required.")
        if not email: errors.append("Email is required.")
        if not phone: errors.append("Phone is required.")
        if errors:
            for e in errors: flash(e, "danger")
            ticket = db.session.get(Ticket, ticket_id)
            return render_template("claim_form.html", ticket=ticket,
                                   draw=ticket.draw if ticket else None)

        ticket = db.session.get(Ticket, ticket_id)
        if not ticket:
            flash("Ticket not found.", "danger")
            return redirect(url_for("search_claims"))
        if not ticket.is_winner:
            flash("This ticket is not a winning ticket.", "danger")
            return redirect(url_for("search_claims"))
        if ticket.status == "CLAIMED":
            flash("This ticket has already been registered.", "warning")
            return redirect(url_for("search_claims"))

        try:
            claimant = Claimant(full_name=full_name, email=email,
                                phone=phone, address=address or None)
            db.session.add(claimant)
            db.session.flush()

            claim = Claim(
                claim_ref=str(uuid.uuid4()),  # unique placeholder replaced after flush
                ticket_id=ticket.id,
                claimant_id=claimant.id, registered_by=current_user.id,
                claim_status="REGISTERED", qr_payload=None,
            )
            db.session.add(claim)
            db.session.flush()  # assigns claim.id from DB sequence
            claim_ref = f"CLM-{datetime.now(timezone.utc).year}-{claim.id:06d}"
            qr_data = url_for("claim_detail", claim_ref=claim_ref, _external=True)
            claim.claim_ref = claim_ref
            claim.qr_payload = qr_data
            ticket.status = "CLAIMED"
            log_audit("CLAIM_REGISTERED", "claim", claim_ref,
                      f"ticket={ticket.ticket_number} claimant={full_name}")
            db.session.commit()
            logger.info(f"CLAIM_REGISTERED claim={claim_ref} ticket={ticket.ticket_number}")
            return redirect(url_for("claim_detail", claim_ref=claim_ref))

        except IntegrityError:
            db.session.rollback()
            logger.warning(f"DUPLICATE_CLAIM_ATTEMPT ticket_id={ticket_id}")
            flash("This ticket has already been registered (duplicate detected).", "warning")
            return redirect(url_for("search_claims"))

    # ── Claim detail ──────────────────────────────────────────────────────────
    @app.route("/claims/<claim_ref>")
    @login_required
    def claim_detail(claim_ref):
        claim = Claim.query.filter_by(claim_ref=claim_ref).first_or_404()
        qr_b64 = make_qr_b64(claim.qr_payload or claim_ref)
        return render_template("claim_detail.html", claim=claim,
                               ticket=claim.ticket, draw=claim.ticket.draw,
                               claimant=claim.claimant, qr_b64=qr_b64)

    # ── Search claims ─────────────────────────────────────────────────────────
    @app.route("/claims/search")
    @login_required
    def search_claims():
        q_name = request.args.get("name", "").strip()
        q_ticket = request.args.get("ticket", "").strip().upper()
        q_ref = request.args.get("ref", "").strip().upper()
        results = []
        searched = any([q_name, q_ticket, q_ref])

        if searched:
            query = (db.session.query(Claim)
                     .join(Claim.claimant).join(Claim.ticket))
            if q_name: query = query.filter(Claimant.full_name.ilike(f"%{q_name}%"))
            if q_ticket: query = query.filter(Ticket.ticket_number.ilike(f"%{q_ticket}%"))
            if q_ref: query = query.filter(Claim.claim_ref.ilike(f"%{q_ref}%"))
            results = query.order_by(Claim.claimed_at.desc()).limit(100).all()
            logger.info(f"SEARCH name={q_name} ticket={q_ticket} ref={q_ref} hits={len(results)}")

        return render_template("search.html", results=results, searched=searched,
                               q_name=q_name, q_ticket=q_ticket, q_ref=q_ref)

    # ── Landing redirect ──────────────────────────────────────────────────────
    @app.route("/")
    @login_required
    def index():
        return redirect(url_for("search_claims"))

    start_sqs_consumer(app)

    return app


app = create_app()

if __name__ == "__main__":
    app.run(debug=False, host="0.0.0.0", port=8001)
