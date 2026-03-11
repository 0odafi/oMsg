from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect
from sqlalchemy import select

from app.api.deps import get_current_user_from_raw_token
from app.core.database import SessionLocal
from app.models.chat import ChatMember, MessageDeliveryStatus
from app.realtime.fanout import realtime_fanout
from app.realtime.manager import chat_manager, user_realtime_manager
from app.services.realtime_service import (
    latest_realtime_cursor,
    list_realtime_events_for_user,
)
from app.services.chat_service import (
    can_access_chat,
    chat_member_ids,
    create_message,
    serialize_messages,
    update_message_delivery_status,
)

router = APIRouter(tags=["Realtime"])


def _as_int(value: object) -> int | None:
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return None


def _user_chat_ids(user_id: int) -> set[int]:
    db = SessionLocal()
    try:
        return set(db.scalars(select(ChatMember.chat_id).where(ChatMember.user_id == user_id)).all())
    finally:
        db.close()


async def _broadcast_chat_event(
    chat_id: int,
    payload: dict,
    *,
    exclude_chat_socket: WebSocket | None = None,
) -> None:
    db = SessionLocal()
    try:
        member_ids = chat_member_ids(db, chat_id)
    finally:
        db.close()
    await realtime_fanout.broadcast_chat_event(
        chat_id=chat_id,
        member_ids=member_ids,
        payload=payload,
        exclude_chat_socket=exclude_chat_socket,
    )


async def _broadcast_user_presence(user_id: int, status: str) -> None:
    for chat_id in _user_chat_ids(user_id):
        await _broadcast_chat_event(
            chat_id,
            {
                "type": "presence",
                "chat_id": chat_id,
                "user_id": user_id,
                "status": status,
            },
        )


def _parse_ack_status(event_type: str, raw_status: object) -> MessageDeliveryStatus | None:
    if event_type == "seen":
        return MessageDeliveryStatus.READ

    status_value = str(raw_status or "").strip().lower()
    if not status_value:
        return MessageDeliveryStatus.DELIVERED
    if status_value == "delivered":
        return MessageDeliveryStatus.DELIVERED
    if status_value == "read":
        return MessageDeliveryStatus.READ
    return None


@router.websocket("/me/ws")
async def me_socket(
    websocket: WebSocket,
    token: str = Query(...),
    cursor: int = Query(default=0, ge=0),
) -> None:
    user = None
    db = SessionLocal()
    try:
        user = get_current_user_from_raw_token(token, db)
    except Exception:
        await websocket.close(code=4401, reason="Invalid token")
        return
    finally:
        db.close()

    await websocket.accept()
    db = SessionLocal()
    try:
        replay_events = list_realtime_events_for_user(
            db,
            user_id=user.id,
            after_cursor=cursor,
            limit=250,
        )
        latest_cursor = latest_realtime_cursor(db, user_id=user.id)
    finally:
        db.close()

    first_connection_for_user = await user_realtime_manager.connect(
        user.id,
        websocket,
        accept_socket=False,
    )
    await websocket.send_json(
        {
            "type": "ready",
            "user_id": user.id,
            "resume_cursor": cursor,
            "latest_cursor": latest_cursor,
            "replayed_count": len(replay_events),
        }
    )
    for event in replay_events:
        await websocket.send_json(event)
    if first_connection_for_user:
        await _broadcast_user_presence(user.id, "online")

    try:
        while True:
            incoming = await websocket.receive_json()
            event_type = incoming.get("type")

            if event_type == "ping":
                await websocket.send_json({"type": "pong"})
                continue

            if event_type == "typing":
                chat_id = _as_int(incoming.get("chat_id"))
                if chat_id is None:
                    await websocket.send_json({"type": "error", "message": "chat_id is required"})
                    continue

                db = SessionLocal()
                try:
                    if not can_access_chat(db, chat_id=chat_id, user_id=user.id):
                        await websocket.send_json({"type": "error", "message": "Access denied"})
                        continue
                finally:
                    db.close()

                is_typing = bool(incoming.get("is_typing", True))
                await _broadcast_chat_event(
                    chat_id,
                    {
                        "type": "typing",
                        "chat_id": chat_id,
                        "user_id": user.id,
                        "is_typing": is_typing,
                    },
                )
                continue

            if event_type in {"ack", "seen"}:
                chat_id = _as_int(incoming.get("chat_id"))
                message_id = _as_int(incoming.get("message_id"))
                status = _parse_ack_status(event_type, incoming.get("status"))
                if chat_id is None or message_id is None:
                    await websocket.send_json(
                        {"type": "error", "message": "chat_id and message_id are required"},
                    )
                    continue
                if status is None:
                    await websocket.send_json({"type": "error", "message": "Unsupported ack status"})
                    continue

                db = SessionLocal()
                try:
                    if not can_access_chat(db, chat_id=chat_id, user_id=user.id):
                        await websocket.send_json({"type": "error", "message": "Access denied"})
                        continue

                    message, user_status, sender_status, changed = update_message_delivery_status(
                        db,
                        message_id=message_id,
                        user_id=user.id,
                        status=status,
                        chat_id=chat_id,
                    )
                except ValueError as exc:
                    await websocket.send_json({"type": "error", "message": str(exc)})
                    continue
                finally:
                    db.close()

                if changed:
                    await _broadcast_chat_event(
                        message.chat_id,
                        {
                            "type": "message_status",
                            "chat_id": message.chat_id,
                            "message_id": message_id,
                            "user_id": user.id,
                            "status": user_status.value,
                            "sender_id": message.sender_id,
                            "sender_status": sender_status.value,
                        },
                    )
                continue

            if event_type == "message":
                chat_id = _as_int(incoming.get("chat_id"))
                content = str(incoming.get("content", "")).strip()
                if chat_id is None:
                    await websocket.send_json({"type": "error", "message": "chat_id is required"})
                    continue
                if not content:
                    await websocket.send_json({"type": "error", "message": "Message content is empty"})
                    continue

                db = SessionLocal()
                serialized = None
                try:
                    message = create_message(db, chat_id=chat_id, sender_id=user.id, content=content)
                    serialized = serialize_messages(db, [message], user_id=user.id)[0]
                except ValueError as exc:
                    await websocket.send_json({"type": "error", "message": str(exc)})
                    continue
                finally:
                    db.close()

                if serialized is None:
                    continue

                await _broadcast_chat_event(
                    chat_id,
                    {
                        "type": "message",
                        "chat_id": chat_id,
                        "message": serialized.model_dump(mode="json"),
                    },
                )
                continue

            await websocket.send_json({"type": "error", "message": "Unknown event type"})
    except (WebSocketDisconnect, Exception):
        pass
    finally:
        _, last_connection_for_user = user_realtime_manager.disconnect(user.id, websocket)
        if last_connection_for_user:
            await _broadcast_user_presence(user.id, "offline")


@router.websocket("/chats/{chat_id}/ws")
async def chat_socket(
    websocket: WebSocket,
    chat_id: int,
    token: str = Query(...),
) -> None:
    user = None
    db = SessionLocal()
    try:
        user = get_current_user_from_raw_token(token, db)
        if not can_access_chat(db, chat_id=chat_id, user_id=user.id):
            await websocket.close(code=4403, reason="Access denied")
            return
    except Exception:
        await websocket.close(code=4401, reason="Invalid token")
        return
    finally:
        db.close()

    first_connection_for_user = await chat_manager.connect(chat_id, websocket, user.id)
    await websocket.send_json({"type": "ready", "chat_id": chat_id, "user_id": user.id})
    if first_connection_for_user:
        await _broadcast_chat_event(
            chat_id,
            {"type": "presence", "chat_id": chat_id, "user_id": user.id, "status": "online"},
            exclude_chat_socket=websocket,
        )

    try:
        while True:
            incoming = await websocket.receive_json()
            event_type = incoming.get("type")

            if event_type == "ping":
                await websocket.send_json({"type": "pong"})
                continue

            if event_type == "typing":
                is_typing = bool(incoming.get("is_typing", True))
                await _broadcast_chat_event(
                    chat_id,
                    {
                        "type": "typing",
                        "chat_id": chat_id,
                        "user_id": user.id,
                        "is_typing": is_typing,
                    },
                    exclude_chat_socket=websocket,
                )
                continue

            if event_type in {"ack", "seen"}:
                message_id = _as_int(incoming.get("message_id"))
                status = _parse_ack_status(event_type, incoming.get("status"))
                if message_id is None:
                    await websocket.send_json({"type": "error", "message": "message_id is required"})
                    continue
                if status is None:
                    await websocket.send_json({"type": "error", "message": "Unsupported ack status"})
                    continue

                db = SessionLocal()
                try:
                    message, user_status, sender_status, changed = update_message_delivery_status(
                        db,
                        message_id=message_id,
                        user_id=user.id,
                        status=status,
                        chat_id=chat_id,
                    )
                except ValueError as exc:
                    await websocket.send_json({"type": "error", "message": str(exc)})
                    continue
                finally:
                    db.close()

                if changed:
                    await _broadcast_chat_event(
                        message.chat_id,
                        {
                            "type": "message_status",
                            "chat_id": message.chat_id,
                            "message_id": message_id,
                            "user_id": user.id,
                            "status": user_status.value,
                            "sender_id": message.sender_id,
                            "sender_status": sender_status.value,
                        },
                    )
                continue

            if event_type != "message":
                await websocket.send_json({"type": "error", "message": "Unknown event type"})
                continue

            content = str(incoming.get("content", "")).strip()
            if not content:
                await websocket.send_json({"type": "error", "message": "Message content is empty"})
                continue

            db = SessionLocal()
            serialized = None
            try:
                message = create_message(db, chat_id=chat_id, sender_id=user.id, content=content)
                serialized = serialize_messages(db, [message], user_id=user.id)[0]
            except ValueError as exc:
                await websocket.send_json({"type": "error", "message": str(exc)})
                continue
            finally:
                db.close()

            if serialized is None:
                continue

            payload = serialized.model_dump(mode="json")
            await _broadcast_chat_event(
                chat_id,
                {"type": "message", "chat_id": chat_id, "message": payload},
            )
    except (WebSocketDisconnect, Exception):
        pass
    finally:
        disconnected_user_id, last_connection_for_user = chat_manager.disconnect(chat_id, websocket)
        if disconnected_user_id is not None and last_connection_for_user:
            await _broadcast_chat_event(
                chat_id,
                {
                    "type": "presence",
                    "chat_id": chat_id,
                    "user_id": disconnected_user_id,
                    "status": "offline",
                },
            )
