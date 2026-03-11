import json

from sqlalchemy import Select, or_, select
from sqlalchemy.orm import Session

from app.models.chat import ChatMember
from app.models.realtime import RealtimeEvent


def store_realtime_event(
    db: Session,
    *,
    target_type: str,
    target_id: int,
    payload: dict,
) -> int:
    event = RealtimeEvent(
        target_type=target_type,
        target_id=target_id,
        payload_json=json.dumps(payload),
    )
    db.add(event)
    db.commit()
    db.refresh(event)
    return event.id


def list_realtime_events_for_user(
    db: Session,
    *,
    user_id: int,
    after_cursor: int,
    limit: int = 200,
) -> list[dict]:
    rows = list(db.scalars(_events_statement(user_id, after_cursor, limit)).all())
    output: list[dict] = []
    for event in rows:
        payload = json.loads(event.payload_json)
        if not isinstance(payload, dict):
            continue
        output.append({**payload, "cursor": event.id})
    return output


def latest_realtime_cursor(db: Session, *, user_id: int) -> int:
    statement = _events_statement(user_id, 0, 1, descending=True).with_only_columns(
        RealtimeEvent.id,
    )
    value = db.scalar(statement)
    return int(value or 0)


def _events_statement(
    user_id: int,
    after_cursor: int,
    limit: int,
    *,
    descending: bool = False,
) -> Select[tuple[RealtimeEvent]]:
    accessible_chat_ids = select(ChatMember.chat_id).where(ChatMember.user_id == user_id)
    statement = select(RealtimeEvent).where(
        RealtimeEvent.id > after_cursor,
        or_(
            (RealtimeEvent.target_type == "user") & (RealtimeEvent.target_id == user_id),
            (RealtimeEvent.target_type == "chat") & (RealtimeEvent.target_id.in_(accessible_chat_ids)),
        ),
    )
    if descending:
        statement = statement.order_by(RealtimeEvent.id.desc())
    else:
        statement = statement.order_by(RealtimeEvent.id.asc())
    return statement.limit(limit)
