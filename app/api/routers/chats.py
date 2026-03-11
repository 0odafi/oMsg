from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_db
from app.models.chat import MediaKind, Message
from app.models.user import User
from app.realtime.fanout import realtime_fanout
from app.schemas.chat import (
    ChatCreate,
    ChatMemberAdd,
    ChatOut,
    MessageCreate,
    MessageContextOut,
    MessageCursorOut,
    MessageOut,
    MessageSearchOut,
    ChatStateOut,
    ChatStateUpdate,
    MessageUpdate,
    ReactionCreate,
    ScheduledMessageCreate,
    ScheduledMessageOut,
    SharedMediaItemOut,
)
from app.services.chat_service import (
    add_member,
    chat_member_ids,
    create_or_get_private_chat,
    create_or_get_saved_messages_chat,
    create_chat,
    cancel_scheduled_message,
    create_message,
    create_scheduled_message,
    delete_message,
    clear_chat_history_for_user,
    get_message_context,
    get_user_chats,
    list_messages,
    list_messages_cursor,
    list_chat_media,
    list_scheduled_messages,
    search_messages,
    pin_message,
    react_to_message,
    remove_message_reaction,
    serialize_messages,
    serialize_scheduled_messages,
    unpin_message,
    update_chat_state,
    update_message_content,
)

router = APIRouter(prefix="/chats", tags=["Chats"])


async def _broadcast_chat_event(db: Session, chat_id: int, payload: dict) -> None:
    await realtime_fanout.broadcast_chat_event(
        chat_id=chat_id,
        member_ids=chat_member_ids(db, chat_id),
        payload=payload,
    )


@router.post("", response_model=ChatOut, status_code=status.HTTP_201_CREATED)
def create_chat_endpoint(
    payload: ChatCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ChatOut:
    try:
        chat = create_chat(db, owner_id=current_user.id, payload=payload)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    return ChatOut.model_validate(chat)


@router.get("", response_model=list[ChatOut])
def list_chats(
    include_archived: bool = Query(default=False),
    archived_only: bool = Query(default=False),
    pinned_only: bool = Query(default=False),
    folder: str | None = Query(default=None, min_length=1, max_length=32),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[ChatOut]:
    chats = get_user_chats(
        db,
        user_id=current_user.id,
        include_archived=include_archived,
        archived_only=archived_only,
        pinned_only=pinned_only,
        folder=folder,
    )
    return [ChatOut.model_validate(chat) for chat in chats]


@router.get("/saved", response_model=ChatOut)
def open_saved_messages_chat(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ChatOut:
    chat = create_or_get_saved_messages_chat(db, user_id=current_user.id)
    return ChatOut(
        id=chat.id,
        title="Saved Messages",
        description=chat.description,
        type=chat.type,
        is_public=chat.is_public,
        owner_id=chat.owner_id,
        created_at=chat.created_at,
        last_message_preview=None,
        last_message_at=None,
        unread_count=0,
        is_archived=False,
        is_pinned=True,
        folder="personal",
        is_saved_messages=True,
    )


@router.post("/private", response_model=ChatOut)
def open_private_chat(
    query: str = Query(..., min_length=3, max_length=120),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ChatOut:
    try:
        chat = create_or_get_private_chat(db, owner_id=current_user.id, query=query)
    except ValueError as exc:
        message = str(exc)
        status_code = status.HTTP_404_NOT_FOUND if message.lower() == "user not found" else status.HTTP_400_BAD_REQUEST
        raise HTTPException(status_code=status_code, detail=message) from exc
    return ChatOut.model_validate(chat)


@router.patch("/{chat_id}/state", response_model=ChatStateOut)
async def patch_chat_state(
    chat_id: int,
    payload: ChatStateUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ChatStateOut:
    try:
        membership = update_chat_state(
            db,
            chat_id=chat_id,
            user_id=current_user.id,
            is_archived=payload.is_archived,
            is_pinned=payload.is_pinned,
            folder=payload.folder,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    state_payload = {
        "type": "chat_state",
        "chat_id": chat_id,
        "is_archived": membership.is_archived,
        "is_pinned": membership.is_pinned,
        "folder": membership.folder,
    }
    await realtime_fanout.broadcast_user_event(
        user_id=current_user.id,
        payload=state_payload,
    )
    return ChatStateOut(
        chat_id=chat_id,
        is_archived=membership.is_archived,
        is_pinned=membership.is_pinned,
        folder=membership.folder,
    )


@router.get("/messages/search", response_model=list[MessageSearchOut])
def search_chat_messages(
    q: str = Query(..., min_length=2, max_length=250),
    limit: int = Query(default=30, ge=1, le=100),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[MessageSearchOut]:
    rows = search_messages(db, user_id=current_user.id, query=q, limit=limit)
    return [MessageSearchOut(**row) for row in rows]


@router.post("/{chat_id}/members", status_code=status.HTTP_201_CREATED)
def add_chat_member(
    chat_id: int,
    payload: ChatMemberAdd,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    try:
        member = add_member(
            db,
            chat_id=chat_id,
            requester_id=current_user.id,
            user_id=payload.user_id,
            role=payload.role,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    return {"chat_id": member.chat_id, "user_id": member.user_id, "role": member.role}


@router.get("/{chat_id}/messages", response_model=list[MessageOut])
def get_messages(
    chat_id: int,
    limit: int = Query(default=100, ge=1, le=500),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[MessageOut]:
    try:
        messages = list_messages(db, chat_id=chat_id, user_id=current_user.id, limit=limit)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return serialize_messages(db, messages, user_id=current_user.id)


@router.get("/{chat_id}/messages/search", response_model=list[MessageSearchOut])
def search_chat_messages_in_chat(
    chat_id: int,
    q: str = Query(..., min_length=2, max_length=250),
    limit: int = Query(default=30, ge=1, le=100),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[MessageSearchOut]:
    try:
        rows = search_messages(db, user_id=current_user.id, query=q, limit=limit, chat_id=chat_id)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return [MessageSearchOut(**row) for row in rows]


@router.get("/{chat_id}/messages/context/{message_id}", response_model=MessageContextOut)
def get_messages_context(
    chat_id: int,
    message_id: int,
    before_limit: int = Query(default=20, ge=0, le=100),
    after_limit: int = Query(default=20, ge=0, le=100),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> MessageContextOut:
    try:
        messages, next_before_id = get_message_context(
            db,
            chat_id=chat_id,
            user_id=current_user.id,
            anchor_message_id=message_id,
            before_limit=before_limit,
            after_limit=after_limit,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return MessageContextOut(
        items=serialize_messages(db, messages, user_id=current_user.id),
        anchor_message_id=message_id,
        next_before_id=next_before_id,
    )


@router.get("/{chat_id}/messages/cursor", response_model=MessageCursorOut)
def get_messages_cursor(
    chat_id: int,
    limit: int = Query(default=50, ge=1, le=200),
    before_id: int | None = Query(default=None, ge=1),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> MessageCursorOut:
    try:
        messages, next_before_id = list_messages_cursor(
            db,
            chat_id=chat_id,
            user_id=current_user.id,
            limit=limit,
            before_id=before_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return MessageCursorOut(items=serialize_messages(db, messages, user_id=current_user.id), next_before_id=next_before_id)


@router.get("/{chat_id}/media", response_model=list[SharedMediaItemOut])
def get_shared_media(
    chat_id: int,
    kind: MediaKind | None = Query(default=None),
    limit: int = Query(default=200, ge=1, le=500),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[SharedMediaItemOut]:
    try:
        return list_chat_media(
            db,
            chat_id=chat_id,
            user_id=current_user.id,
            limit=limit,
            media_kind=kind,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc


@router.get("/{chat_id}/scheduled-messages", response_model=list[ScheduledMessageOut])
def get_scheduled_messages(
    chat_id: int,
    limit: int = Query(default=100, ge=1, le=200),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[ScheduledMessageOut]:
    try:
        rows = list_scheduled_messages(db, chat_id=chat_id, user_id=current_user.id, limit=limit)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return serialize_scheduled_messages(db, rows)


@router.post("/{chat_id}/scheduled-messages", response_model=ScheduledMessageOut, status_code=status.HTTP_201_CREATED)
def post_scheduled_message(
    chat_id: int,
    payload: ScheduledMessageCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ScheduledMessageOut:
    try:
        scheduled_message = create_scheduled_message(
            db,
            chat_id=chat_id,
            sender_id=current_user.id,
            payload=payload,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    return serialize_scheduled_messages(db, [scheduled_message])[0]


@router.delete("/scheduled-messages/{scheduled_message_id}")
def remove_scheduled_message(
    scheduled_message_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    try:
        scheduled_message = cancel_scheduled_message(
            db,
            scheduled_message_id=scheduled_message_id,
            user_id=current_user.id,
        )
    except ValueError as exc:
        detail = str(exc)
        status_code = status.HTTP_404_NOT_FOUND if detail == "Scheduled message not found" else status.HTTP_400_BAD_REQUEST
        raise HTTPException(status_code=status_code, detail=detail) from exc
    return {
        "scheduled_message_id": scheduled_message.id,
        "chat_id": scheduled_message.chat_id,
        "removed": True,
    }


@router.post("/{chat_id}/messages", response_model=MessageOut, status_code=status.HTTP_201_CREATED)
async def post_message(
    chat_id: int,
    payload: MessageCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> MessageOut:
    try:
        message = create_message(
            db,
            chat_id=chat_id,
            sender_id=current_user.id,
            content=payload.content,
            reply_to_message_id=payload.reply_to_message_id,
            forward_from_message_id=payload.forward_from_message_id,
            attachment_ids=payload.attachment_ids,
            client_message_id=payload.client_message_id,
            is_silent=payload.is_silent,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    serialized = serialize_messages(db, [message], user_id=current_user.id)[0]
    await _broadcast_chat_event(
        db,
        chat_id,
        {
            "type": "message",
            "chat_id": chat_id,
            "message": serialized.model_dump(mode="json"),
        },
    )
    return serialized


@router.patch("/messages/{message_id}", response_model=MessageOut)
async def patch_message(
    message_id: int,
    payload: MessageUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> MessageOut:
    try:
        message = update_message_content(db, message_id=message_id, user_id=current_user.id, content=payload.content)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    serialized = serialize_messages(db, [message], user_id=current_user.id)[0]
    await _broadcast_chat_event(
        db,
        message.chat_id,
        {
            "type": "message_updated",
            "chat_id": message.chat_id,
            "message": serialized.model_dump(mode="json"),
        },
    )
    return serialized


@router.delete("/messages/{message_id}")
async def remove_message(
    message_id: int,
    scope: str = Query(default="all", pattern="^(all|me)$"),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    try:
        result = delete_message(db, message_id=message_id, user_id=current_user.id, scope=scope)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc

    if result is None:
        return {"message_id": message_id, "removed": False}

    removed_chat_id = int(result["chat_id"])
    removed_scope = result["scope"]
    if removed_scope == "all":
        await _broadcast_chat_event(
            db,
            removed_chat_id,
            {
                "type": "message_deleted",
                "chat_id": removed_chat_id,
                "message_id": message_id,
            },
        )
    return {
        "message_id": message_id,
        "chat_id": removed_chat_id,
        "removed": True,
        "scope": removed_scope,
    }


@router.post("/{chat_id}/history/clear")
def clear_chat_history(
    chat_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    try:
        removed_count = clear_chat_history_for_user(db, chat_id=chat_id, user_id=current_user.id)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    return {"chat_id": chat_id, "removed_count": removed_count, "scope": "me"}


@router.post("/{chat_id}/messages/{message_id}/pin")
async def pin_chat_message(
    chat_id: int,
    message_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    try:
        pin = pin_message(db, chat_id=chat_id, message_id=message_id, user_id=current_user.id)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    await _broadcast_chat_event(
        db,
        chat_id,
        {
            "type": "message_pinned",
            "chat_id": chat_id,
            "message_id": message_id,
            "pinned_at": pin.pinned_at.isoformat(),
        },
    )
    return {"chat_id": chat_id, "message_id": message_id, "pinned": True}


@router.delete("/{chat_id}/messages/{message_id}/pin")
async def unpin_chat_message(
    chat_id: int,
    message_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    try:
        removed = unpin_message(db, chat_id=chat_id, message_id=message_id, user_id=current_user.id)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    if removed:
        await _broadcast_chat_event(
            db,
            chat_id,
            {
                "type": "message_unpinned",
                "chat_id": chat_id,
                "message_id": message_id,
            },
        )
    return {"chat_id": chat_id, "message_id": message_id, "pinned": False, "removed": removed}


@router.post("/messages/{message_id}/reactions", status_code=status.HTTP_201_CREATED)
async def add_message_reaction(
    message_id: int,
    payload: ReactionCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    try:
        reaction = react_to_message(db, message_id=message_id, user_id=current_user.id, emoji=payload.emoji)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    message = db.scalar(select(Message).where(Message.id == message_id))
    chat_id = message.chat_id if message else None
    if chat_id is not None:
        await _broadcast_chat_event(
            db,
            chat_id,
            {
                "type": "reaction_added",
                "chat_id": chat_id,
                "message_id": message_id,
                "emoji": reaction.emoji,
                "user_id": reaction.user_id,
            },
        )
    return {
        "id": reaction.id,
        "chat_id": chat_id,
        "message_id": reaction.message_id,
        "user_id": reaction.user_id,
        "emoji": reaction.emoji,
    }


@router.delete("/messages/{message_id}/reactions")
async def delete_message_reaction(
    message_id: int,
    emoji: str = Query(..., min_length=1, max_length=12),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    message = db.scalar(select(Message).where(Message.id == message_id))
    chat_id = message.chat_id if message else None
    removed = remove_message_reaction(db, message_id=message_id, user_id=current_user.id, emoji=emoji)
    if removed and chat_id is not None:
        await _broadcast_chat_event(
            db,
            chat_id,
            {
                "type": "reaction_removed",
                "chat_id": chat_id,
                "message_id": message_id,
                "emoji": emoji,
                "user_id": current_user.id,
            },
        )
    return {"chat_id": chat_id, "message_id": message_id, "emoji": emoji, "removed": removed}
