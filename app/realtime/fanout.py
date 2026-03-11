import asyncio
import json
import logging
import uuid
from typing import Any

from fastapi import WebSocket

from app.core.config import get_settings
from app.core.database import SessionLocal
from app.realtime.manager import chat_manager, user_realtime_manager
from app.services.realtime_service import store_realtime_event

logger = logging.getLogger(__name__)

try:
    from redis.asyncio import Redis
except ModuleNotFoundError:  # pragma: no cover - dependency is installed in normal runtime
    Redis = None  # type: ignore[assignment]


class RealtimeFanout:
    def __init__(self) -> None:
        self._settings = get_settings()
        self._instance_id = uuid.uuid4().hex
        self._publisher: Any = None
        self._subscriber: Any = None
        self._pubsub: Any = None
        self._listener_task: asyncio.Task | None = None

    async def startup(self) -> None:
        redis_url = (self._settings.redis_url or "").strip()
        if not redis_url:
            return
        if Redis is None:
            logger.warning("REDIS_URL is configured, but redis package is unavailable.")
            return

        self._publisher = Redis.from_url(redis_url, encoding="utf-8", decode_responses=True)
        self._subscriber = Redis.from_url(redis_url, encoding="utf-8", decode_responses=True)
        self._pubsub = self._subscriber.pubsub()
        await self._pubsub.subscribe(self._channel_name)
        self._listener_task = asyncio.create_task(self._listen())

    async def shutdown(self) -> None:
        if self._listener_task is not None:
            self._listener_task.cancel()
            try:
                await self._listener_task
            except asyncio.CancelledError:
                pass
            self._listener_task = None

        if self._pubsub is not None:
            await self._pubsub.aclose()
            self._pubsub = None
        if self._subscriber is not None:
            await self._subscriber.aclose()
            self._subscriber = None
        if self._publisher is not None:
            await self._publisher.aclose()
            self._publisher = None

    async def broadcast_chat_event(
        self,
        *,
        chat_id: int,
        member_ids: set[int] | None,
        payload: dict,
        exclude_chat_socket: WebSocket | None = None,
    ) -> None:
        event_id = self._persist_event(
            target_type="chat",
            target_id=chat_id,
            payload=payload,
        )
        payload_with_cursor = {**payload, "cursor": event_id}
        normalized_member_ids = member_ids or set()
        await chat_manager.broadcast(
            chat_id,
            payload_with_cursor,
            exclude=exclude_chat_socket,
        )
        await user_realtime_manager.broadcast_many(
            normalized_member_ids,
            payload_with_cursor,
        )
        await self._publish(
            {
                "origin": self._instance_id,
                "target": "chat",
                "chat_id": chat_id,
                "member_ids": sorted(normalized_member_ids),
                "payload": payload_with_cursor,
            }
        )

    async def broadcast_user_event(self, *, user_id: int, payload: dict) -> None:
        event_id = self._persist_event(
            target_type="user",
            target_id=user_id,
            payload=payload,
        )
        payload_with_cursor = {**payload, "cursor": event_id}
        await user_realtime_manager.broadcast(user_id, payload_with_cursor)
        await self._publish(
            {
                "origin": self._instance_id,
                "target": "user",
                "user_id": user_id,
                "payload": payload_with_cursor,
            }
        )

    @property
    def _channel_name(self) -> str:
        prefix = self._settings.redis_channel_prefix.strip() or "omsg"
        return f"{prefix}:realtime"

    async def _publish(self, envelope: dict) -> None:
        if self._publisher is None:
            return
        try:
            await self._publisher.publish(self._channel_name, json.dumps(envelope))
        except Exception:  # pragma: no cover - external redis failures
            logger.exception("Realtime fanout publish failed.")

    async def _listen(self) -> None:
        assert self._pubsub is not None
        while True:
            try:
                message = await self._pubsub.get_message(
                    ignore_subscribe_messages=True,
                    timeout=1.0,
                )
            except asyncio.CancelledError:
                raise
            except Exception:  # pragma: no cover - external redis failures
                logger.exception("Realtime fanout listener failed to read from Redis.")
                await asyncio.sleep(1)
                continue

            if message is None:
                await asyncio.sleep(0.05)
                continue

            raw_data = message.get("data")
            if not isinstance(raw_data, str):
                continue

            try:
                envelope = json.loads(raw_data)
            except json.JSONDecodeError:
                logger.warning("Skipping malformed realtime payload from Redis.")
                continue

            if envelope.get("origin") == self._instance_id:
                continue

            target = envelope.get("target")
            payload = envelope.get("payload")
            if not isinstance(payload, dict):
                continue

            if target == "chat":
                chat_id = envelope.get("chat_id")
                member_ids = envelope.get("member_ids") or []
                if isinstance(chat_id, int):
                    await chat_manager.broadcast(chat_id, payload)
                normalized_member_ids = {
                    member_id for member_id in member_ids if isinstance(member_id, int)
                }
                if normalized_member_ids:
                    await user_realtime_manager.broadcast_many(normalized_member_ids, payload)
                continue

            if target == "user":
                user_id = envelope.get("user_id")
                if isinstance(user_id, int):
                    await user_realtime_manager.broadcast(user_id, payload)

    def _persist_event(self, *, target_type: str, target_id: int, payload: dict) -> int:
        db = SessionLocal()
        try:
            return store_realtime_event(
                db,
                target_type=target_type,
                target_id=target_id,
                payload=payload,
            )
        finally:
            db.close()


realtime_fanout = RealtimeFanout()
