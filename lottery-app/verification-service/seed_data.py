# from app import create_app
from models import db, User, Draw, Ticket, Claimant, Claim
from datetime import date
import os

BASE_URL = os.getenv("BASE_URL", "http://localhost:8000")

def seed_database():

    # Prevent reseeding
    if User.query.first():
        print("Database already seeded.")
        return

    # Users
    agent = User(username="agent1", role="AGENT")
    agent.set_password("Agent@123")
    sup = User(username="supervisor", role="SUPERVISOR")
    sup.set_password("Super@123")
    db.session.add_all([agent, sup])
    db.session.commit()
    print("Users created.")

    # Draws
    draws_data = [
        ("Spring Jackpot 2026",   date(2026, 3, 15), 500000),
        ("Summer Mega Draw 2026", date(2026, 6, 20), 1200000),
        ("Winter Special 2025",   date(2025, 12, 1), 250000),
    ]

    draws = {}

    for name, d, jackpot in draws_data:
        existing = Draw.query.filter_by(draw_date=d).first()
        if not existing:
            draw = Draw(draw_name=name, draw_date=d, jackpot=jackpot)
            db.session.add(draw)
            db.session.flush()
            draws[d] = draw
        else:
            draws[d] = existing
    db.session.commit()

    # Tickets
    tickets_data = [
        ("TKT-001-WIN",  date(2026, 3, 15),  True,  50000,  "UNCLAIMED"),
        ("TKT-002-WIN",  date(2026, 3, 15),  True,  10000,  "CLAIMED"),
        ("TKT-003-LOSE", date(2026, 3, 15),  False, None,   "UNCLAIMED"),
        ("TKT-004-LOSE", date(2026, 3, 15),  False, None,   "UNCLAIMED"),
        ("TKT-005-WIN",  date(2026, 6, 20),  True,  100000, "UNCLAIMED"),
        ("TKT-006-WIN",  date(2026, 6, 20),  True,  25000,  "CLAIMED"),
        ("TKT-007-LOSE", date(2026, 6, 20),  False, None,   "UNCLAIMED"),
        ("TKT-008-WIN",  date(2025, 12, 1),  True,  5000,   "CLAIMED"),
        ("TKT-009-LOSE", date(2025, 12, 1),  False, None,   "UNCLAIMED"),
        ("TKT-010-WIN",  date(2026, 3, 15),  True,  75000,  "UNCLAIMED"),
    ]

    ticket_objs = {}

    for tn, dd, iw, prize, status in tickets_data:
        draw = draws[dd]
        existing = Ticket.query.filter_by(ticket_number=tn, draw_id=draw.id).first()
        if not existing:
            t = Ticket(ticket_number=tn, draw_id=draw.id,
                       is_winner=iw, prize_amount=prize, status=status)
            db.session.add(t)
            db.session.flush()
            ticket_objs[tn] = t
        else:
            ticket_objs[tn] = existing
    db.session.commit()

    # Pre-existing claimed tickets with claimants
    agent = User.query.filter_by(username="agent1").first()
    preclaims = [
        ("TKT-002-WIN", "Alice Johnson",  "alice@example.com",  "555-0101", "12 Oak St"),
        ("TKT-006-WIN", "Bob Martinez",   "bob@example.com",    "555-0202", "34 Elm Ave"),
        ("TKT-008-WIN", "Carol Williams", "carol@example.com",  "555-0303", None),
    ]
    for tn, name, email, phone, addr in preclaims:
        t = ticket_objs.get(tn)
        if t and not t.claim:
            claimant = Claimant(full_name=name, email=email, phone=phone, address=addr)
            db.session.add(claimant)
            db.session.flush()
            count = Claim.query.count() + 1
            ref = f"CLM-2026-{count:06d}"
            claim = Claim(
                claim_ref=ref, ticket_id=t.id, claimant_id=claimant.id,
                registered_by=agent.id, claim_status="REGISTERED",
                qr_payload=f"{BASE_URL}/claims/{ref}",
            )
            db.session.add(claim)
    db.session.commit()

    print("\nSeed complete. Demo tickets:")
    print("  TKT-001-WIN  / 2026-03-15 → winner, unclaimed")
    print("  TKT-002-WIN  / 2026-03-15 → winner, already claimed")
    print("  TKT-003-LOSE / 2026-03-15 → not a winner")
    print("  TKT-005-WIN  / 2026-06-20 → winner $100,000 unclaimed")
    print("  TKT-999-FAKE / 2026-03-15 → not found")