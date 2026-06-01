from datetime import datetime, timezone
from flask_sqlalchemy import SQLAlchemy
from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash

db = SQLAlchemy()

class User(UserMixin, db.Model):
    __tablename__ = "users"
    id            = db.Column(db.Integer, primary_key=True)
    username      = db.Column(db.String(80), unique=True, nullable=False)
    password_hash = db.Column(db.String(256), nullable=False)
    role          = db.Column(db.String(20), nullable=False, default="AGENT")
    created_at    = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

class Draw(db.Model):
    __tablename__ = "draws"
    id         = db.Column(db.Integer, primary_key=True)
    draw_name  = db.Column(db.String(120), nullable=False)
    draw_date  = db.Column(db.Date, nullable=False)
    jackpot    = db.Column(db.Numeric(12, 2), nullable=False)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    tickets    = db.relationship("Ticket", backref="draw", lazy=True)

class Ticket(db.Model):
    __tablename__  = "tickets"
    id             = db.Column(db.Integer, primary_key=True)
    ticket_number  = db.Column(db.String(40), nullable=False)
    draw_id        = db.Column(db.Integer, db.ForeignKey("draws.id"), nullable=False)
    is_winner      = db.Column(db.Boolean, nullable=False, default=False)
    prize_amount   = db.Column(db.Numeric(12, 2), nullable=True)
    status         = db.Column(db.String(20), nullable=False, default="UNCLAIMED")
    created_at     = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    __table_args__ = (
        db.UniqueConstraint("ticket_number", "draw_id", name="uq_ticket_draw"),
    )

class Claimant(db.Model):
    __tablename__ = "claimants"
    id         = db.Column(db.Integer, primary_key=True)
    full_name  = db.Column(db.String(120), nullable=False)
    email      = db.Column(db.String(120), nullable=False)
    phone      = db.Column(db.String(30), nullable=False)
    address    = db.Column(db.String(255), nullable=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

class Claim(db.Model):
    __tablename__  = "claims"
    id             = db.Column(db.Integer, primary_key=True)
    claim_ref      = db.Column(db.String(30), unique=True, nullable=False)
    ticket_id      = db.Column(db.Integer, db.ForeignKey("tickets.id"), unique=True, nullable=False)
    claimant_id    = db.Column(db.Integer, db.ForeignKey("claimants.id"), nullable=False)
    registered_by  = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    claim_status   = db.Column(db.String(20), nullable=False, default="REGISTERED")
    qr_payload     = db.Column(db.String(255), nullable=True)
    claimed_at     = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    ticket             = db.relationship("Ticket",   backref=db.backref("claim", uselist=False))
    claimant           = db.relationship("Claimant", backref="claims")
    registered_by_user = db.relationship("User",     backref="claims")

class AuditLog(db.Model):
    __tablename__ = "audit_logs"
    id          = db.Column(db.Integer, primary_key=True)
    user_id     = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    action      = db.Column(db.String(60), nullable=False)
    entity_type = db.Column(db.String(40), nullable=True)
    entity_id   = db.Column(db.String(40), nullable=True)
    details     = db.Column(db.Text, nullable=True)
    timestamp   = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))