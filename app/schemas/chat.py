from datetime import datetime

from pydantic import BaseModel, Field, model_validator

from app.models.chat import (
    ChatType,
    MediaKind,
    MemberRole,
    MessageDeliveryStatus,
    ScheduledMessageStatus,
)


class ChatCreate(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    description: str = Field(default="", max_length=2000)
    type: ChatType = ChatType.GROUP
    is_public: bool = False
    member_ids: list[int] = Field(default_factory=list)


class ChatOut(BaseModel):
    id: int
    title: str
    description: str
    type: ChatType
    is_public: bool
    owner_id: int
    created_at: datetime
    last_message_preview: str | None = None
    last_message_at: datetime | None = None
    unread_count: int = 0
    is_archived: bool = False
    is_pinned: bool = False
    folder: str | None = None
    is_saved_messages: bool = False

    model_config = {"from_attributes": True}


class ChatStateUpdate(BaseModel):
    is_archived: bool | None = None
    is_pinned: bool | None = None
    folder: str | None = Field(default=None, max_length=32)


class ChatStateOut(BaseModel):
    chat_id: int
    is_archived: bool
    is_pinned: bool
    folder: str | None


class ChatMemberAdd(BaseModel):
    user_id: int
    role: MemberRole = MemberRole.MEMBER


class MessageCreate(BaseModel):
    content: str = Field(default="", max_length=10000)
    reply_to_message_id: int | None = None
    forward_from_message_id: int | None = None
    attachment_ids: list[int] = Field(default_factory=list)
    client_message_id: str | None = Field(default=None, min_length=8, max_length=64)
    is_silent: bool = False

    @model_validator(mode="after")
    def validate_payload(self):
        has_content = bool(self.content.strip())
        has_attachments = bool(self.attachment_ids)
        has_forward = self.forward_from_message_id is not None
        if not has_content and not has_attachments and not has_forward:
            raise ValueError("Message must contain text, attachment or forwarded source")
        return self


class MessageAttachmentOut(BaseModel):
    id: int
    file_name: str
    mime_type: str
    media_kind: MediaKind = MediaKind.FILE
    size_bytes: int
    url: str
    is_image: bool = False
    is_audio: bool = False
    is_video: bool = False
    is_voice: bool = False
    width: int | None = None
    height: int | None = None
    duration_seconds: int | None = None
    thumbnail_url: str | None = None


class MessageReactionSummary(BaseModel):
    emoji: str
    count: int
    reacted_by_me: bool = False


class MessageOut(BaseModel):
    id: int
    chat_id: int
    sender_id: int
    content: str
    client_message_id: str | None = None
    created_at: datetime
    edited_at: datetime | None
    status: MessageDeliveryStatus = MessageDeliveryStatus.SENT
    reply_to_message_id: int | None = None
    forwarded_from_message_id: int | None = None
    forwarded_from_sender_name: str | None = None
    forwarded_from_chat_title: str | None = None
    is_silent: bool = False
    is_pinned: bool = False
    reactions: list[MessageReactionSummary] = Field(default_factory=list)
    attachments: list[MessageAttachmentOut] = Field(default_factory=list)

    model_config = {"from_attributes": True}


class ScheduledMessageCreate(BaseModel):
    content: str = Field(default="", max_length=10000)
    scheduled_for: datetime | None = None
    send_when_user_online: bool = False
    reply_to_message_id: int | None = None
    forward_from_message_id: int | None = None
    attachment_ids: list[int] = Field(default_factory=list)

    @model_validator(mode="after")
    def validate_payload(self):
        has_content = bool(self.content.strip())
        has_attachments = bool(self.attachment_ids)
        has_forward = self.forward_from_message_id is not None
        if not has_content and not has_attachments and not has_forward:
            raise ValueError("Message must contain text, attachment or forwarded source")
        if not self.send_when_user_online and self.scheduled_for is None:
            raise ValueError("scheduled_for is required")
        return self


class ScheduledMessageOut(BaseModel):
    id: int
    chat_id: int
    sender_id: int
    content: str
    scheduled_for: datetime
    send_when_user_online: bool = False
    created_at: datetime
    sent_at: datetime | None = None
    status: ScheduledMessageStatus = ScheduledMessageStatus.PENDING
    reply_to_message_id: int | None = None
    forwarded_from_message_id: int | None = None
    attachments: list[MessageAttachmentOut] = Field(default_factory=list)

    model_config = {"from_attributes": True}


class ReactionCreate(BaseModel):
    emoji: str = Field(min_length=1, max_length=12)


class MessageCursorOut(BaseModel):
    items: list[MessageOut]
    next_before_id: int | None = None


class MessageContextOut(BaseModel):
    items: list[MessageOut]
    anchor_message_id: int
    next_before_id: int | None = None


class SharedMediaItemOut(BaseModel):
    message_id: int
    message_created_at: datetime
    sender_id: int
    content: str
    attachment: MessageAttachmentOut


class MessageSearchOut(BaseModel):
    chat_id: int
    message_id: int
    chat_title: str
    sender_id: int
    content: str
    created_at: datetime


class MessageUpdate(BaseModel):
    content: str = Field(min_length=1, max_length=10000)


class MediaUploadOut(BaseModel):
    id: int
    file_name: str
    mime_type: str
    media_kind: MediaKind = MediaKind.FILE
    size_bytes: int
    url: str
    is_image: bool = False
    is_audio: bool = False
    is_video: bool = False
    is_voice: bool = False
    width: int | None = None
    height: int | None = None
    duration_seconds: int | None = None
    thumbnail_url: str | None = None
