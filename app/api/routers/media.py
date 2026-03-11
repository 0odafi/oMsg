from pathlib import Path
from uuid import uuid4

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile, status
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_db
from app.core.config import get_settings
from app.models.chat import MediaFile
from app.models.user import User
from app.schemas.chat import MediaUploadOut
from app.services.chat_service import get_chat_for_member
from app.services.media_service import (
    MediaValidationError,
    analyze_media,
    classify_media_kind,
    detect_mime_type,
    sanitize_kind_hint,
    stream_upload_to_path,
)

router = APIRouter(prefix="/media", tags=["Media"])


def _serialize_media_upload(media: MediaFile) -> MediaUploadOut:
    settings = get_settings()
    base = settings.media_url_path.rstrip("/")
    if not base:
        base = "/media"
    if not base.startswith("/"):
        base = f"/{base}"

    return MediaUploadOut(
        id=media.id,
        file_name=media.original_name,
        mime_type=media.mime_type,
        media_kind=media.media_kind,
        size_bytes=media.size_bytes,
        url=f"{base}/{media.storage_name}",
        is_image=media.media_kind.value == "image",
        is_audio=media.media_kind.value in {"audio", "voice"},
        is_video=media.media_kind.value == "video",
        is_voice=media.media_kind.value == "voice",
        width=media.width,
        height=media.height,
        duration_seconds=media.duration_seconds,
        thumbnail_url=f"{base}/{media.thumbnail_storage_name}" if media.thumbnail_storage_name else None,
    )


def _safe_original_name(raw_name: str | None) -> str:
    name = (raw_name or "").strip()
    if not name:
        return "file.bin"
    cleaned = Path(name).name
    return cleaned[:255] if cleaned else "file.bin"


@router.post("/upload", response_model=MediaUploadOut, status_code=status.HTTP_201_CREATED)
async def upload_media(
    chat_id: int = Query(..., ge=1),
    kind_hint: str | None = Query(default=None, max_length=40),
    client_upload_id: str | None = Query(default=None, min_length=8, max_length=64),
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> MediaUploadOut:
    try:
        _ = get_chat_for_member(db, chat_id=chat_id, user_id=current_user.id)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc

    settings = get_settings()
    normalized_client_upload_id = (client_upload_id or "").strip() or None
    media_root = Path(settings.media_root).resolve()
    media_root.mkdir(parents=True, exist_ok=True)

    if normalized_client_upload_id is not None:
        existing = (
            db.query(MediaFile)
            .filter(
                MediaFile.chat_id == chat_id,
                MediaFile.uploader_id == current_user.id,
                MediaFile.client_upload_id == normalized_client_upload_id,
            )
            .order_by(MediaFile.id.desc())
            .first()
        )
        if existing is not None and (media_root / existing.storage_name).exists():
            return _serialize_media_upload(existing)

    original_name = _safe_original_name(file.filename)
    suffix = Path(original_name).suffix.lower()
    storage_name = f"{uuid4().hex}{suffix}" if suffix else uuid4().hex
    mime_type = detect_mime_type(original_name, file.content_type)
    media_kind = classify_media_kind(
        mime_type=mime_type,
        original_name=original_name,
        kind_hint=sanitize_kind_hint(kind_hint),
    )

    target = media_root / storage_name
    try:
        stored_upload = await stream_upload_to_path(
            file,
            target_path=target,
            max_upload_bytes=settings.max_upload_bytes,
        )
    except MediaValidationError as exc:
        detail = str(exc)
        status_code = (
            status.HTTP_413_REQUEST_ENTITY_TOO_LARGE
            if "too large" in detail.lower()
            else status.HTTP_400_BAD_REQUEST
        )
        raise HTTPException(status_code=status_code, detail=detail) from exc

    analysis = analyze_media(
        file_path=target,
        media_root=media_root,
        storage_name=storage_name,
        media_kind=media_kind,
    )

    media = MediaFile(
        uploader_id=current_user.id,
        chat_id=chat_id,
        storage_name=storage_name,
        original_name=original_name,
        mime_type=mime_type,
        media_kind=analysis.media_kind,
        size_bytes=stored_upload.size_bytes,
        sha256=stored_upload.sha256,
        client_upload_id=normalized_client_upload_id,
        width=analysis.width,
        height=analysis.height,
        duration_seconds=analysis.duration_seconds,
        thumbnail_storage_name=analysis.thumbnail_storage_name,
        is_committed=False,
    )
    db.add(media)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        target.unlink(missing_ok=True)
        if analysis.thumbnail_storage_name:
            (media_root / analysis.thumbnail_storage_name).unlink(missing_ok=True)
        existing = (
            db.query(MediaFile)
            .filter(
                MediaFile.chat_id == chat_id,
                MediaFile.uploader_id == current_user.id,
                MediaFile.client_upload_id == normalized_client_upload_id,
            )
            .order_by(MediaFile.id.desc())
            .first()
        )
        if existing is None:
            raise
        return _serialize_media_upload(existing)

    db.refresh(media)
    return _serialize_media_upload(media)
