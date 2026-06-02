import logging
from datetime import date
from flask import Flask, render_template, request, redirect, url_for, flash, jsonify
from flask_login import LoginManager, login_user, logout_user, login_required, current_user
from flask_wtf.csrf import CSRFProtect
from werkzeug.middleware.proxy_fix import ProxyFix
from models import db, User, Draw, Ticket, AuditLog
from config import Config
from seed_data import seed_database
import time
from sqlalchemy.exc import OperationalError

logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}'
)
logger = logging.getLogger(__name__)


def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)
    db.init_app(app)
    CSRFProtect(app)
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_port=1)

    with app.app_context():

        for i in range(10):

            try:
                db.create_all()
                seed_database()
                print("Database initialized.")
                break

            except OperationalError as e:
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

    # ── Helpers ───────────────────────────────────────────────────────────────
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
            return jsonify({"status": "ok", "db": "reachable"}), 200
        except Exception as e:
            logger.error(f"Health check DB failure: {e}")
            return jsonify({"status": "degraded", "db": "unreachable"}), 500

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

            log_audit("VERIFY_TICKET", "ticket",
                      ticket.id if ticket else None,
                      f"ticket={ticket_number} outcome={result['outcome']}")
            db.session.commit()
        return render_template("verify.html", result=result,
                               ticket_number=ticket_number, draw_date=draw_date_str)

    return app


app = create_app()

if __name__ == "__main__":
    app.run(debug=False, host="0.0.0.0", port=8000)