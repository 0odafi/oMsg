from sqlalchemy import select

from app.core.database import SessionLocal, create_tables
from app.models.user import User
from app.schemas.auth import RegisterRequest
from app.schemas.chat import ChatCreate
from app.schemas.social import PostCreate
from app.services.auth_service import register_user
from app.services.chat_service import create_chat, create_message
from app.services.social_service import create_post
from app.services.user_service import follow_user


def _get_or_create_user(db, username: str, email: str, password: str) -> User:
    existing = db.scalar(select(User).where(User.username == username))
    if existing:
        return existing
    return register_user(
        db,
        RegisterRequest(username=username, email=email, password=password),
    )


def run() -> None:
    create_tables()
    db = SessionLocal()
    try:
        alice = _get_or_create_user(db, "alice", "alice@omsg.dev", "Password123")
        bob = _get_or_create_user(db, "bob", "bob@omsg.dev", "Password123")
        carol = _get_or_create_user(db, "carol", "carol@omsg.dev", "Password123")

        follow_user(db, follower_id=bob.id, following_id=alice.id)
        follow_user(db, follower_id=carol.id, following_id=alice.id)

        chat = create_chat(
            db,
            owner_id=alice.id,
            payload=ChatCreate(
                title="Astra Core Team",
                description="Roadmap, releases, experiments",
                type="group",
                member_ids=[bob.id, carol.id],
            ),
        )
        create_message(db, chat.id, alice.id, "Welcome to oMsg demo space.")
        create_message(db, chat.id, bob.id, "Realtime is online. Let's ship fast.")

        create_post(
            db,
            author_id=alice.id,
            payload=PostCreate(
                content="oMsg beta is now running locally.",
                visibility="public",
            ),
        )
        create_post(
            db,
            author_id=alice.id,
            payload=PostCreate(
                content="Follower-only update: channel reactions landed.",
                visibility="followers",
            ),
        )
        print("Seed data created. Users: alice / bob / carol (password: Password123)")
    finally:
        db.close()


if __name__ == "__main__":
    run()
