from __future__ import annotations

import hashlib
import json
import mimetypes
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

from PIL import Image, UnidentifiedImageError

from app.models.chat import MediaKind

_CHUNK_SIZE = 1024 * 1024


@dataclass(slots=True)
class StoredUpload:
    size_bytes: int
    sha256: str


@dataclass(slots=True)
class MediaAnalysis:
    media_kind: MediaKind
    width: int | None = None
    height: int | None = None
    duration_seconds: int | None = None
    thumbnail_storage_name: str | None = None


class MediaValidationError(ValueError):
    pass


VOICE_HINTS = {"voice", "voice_note", "voice-note", "voice_message", "voice-message"}
FILE_HINTS = {"file", "document", "doc"}
IMAGE_HINTS = {"image", "photo", "compressed"}
VIDEO_HINTS = {"video", "movie"}
AUDIO_HINTS = {"audio", "music", "song"}


def sanitize_kind_hint(value: str | None) -> str | None:
    cleaned = (value or "").strip().lower().replace("_", "-")
    return cleaned or None


def detect_mime_type(original_name: str, declared_content_type: str | None) -> str:
    guessed = mimetypes.guess_type(original_name)[0]
    return (declared_content_type or "").strip() or guessed or "application/octet-stream"


def classify_media_kind(
    *,
    mime_type: str,
    original_name: str,
    kind_hint: str | None = None,
) -> MediaKind:
    normalized_mime = mime_type.lower()
    hint = sanitize_kind_hint(kind_hint)
    if hint in VOICE_HINTS:
        return MediaKind.VOICE
    if hint in FILE_HINTS:
        return MediaKind.FILE
    if hint in IMAGE_HINTS:
        return MediaKind.IMAGE
    if hint in VIDEO_HINTS:
        return MediaKind.VIDEO
    if hint in AUDIO_HINTS:
        return MediaKind.AUDIO
    if normalized_mime.startswith("image/"):
        return MediaKind.IMAGE
    if normalized_mime.startswith("video/"):
        return MediaKind.VIDEO
    if normalized_mime.startswith("audio/"):
        return MediaKind.AUDIO

    suffix = Path(original_name).suffix.lower()
    if suffix in {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".heic"}:
        return MediaKind.IMAGE
    if suffix in {".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v"}:
        return MediaKind.VIDEO
    if suffix in {".mp3", ".m4a", ".aac", ".ogg", ".wav", ".flac", ".opus"}:
        return MediaKind.AUDIO
    return MediaKind.FILE


async def stream_upload_to_path(
    upload_file: BinaryIO,
    *,
    target_path: Path,
    max_upload_bytes: int,
) -> StoredUpload:
    target_path.parent.mkdir(parents=True, exist_ok=True)
    total_size = 0
    digest = hashlib.sha256()
    try:
        with target_path.open("wb") as output:
            while True:
                chunk = await upload_file.read(_CHUNK_SIZE)
                if not chunk:
                    break
                total_size += len(chunk)
                if total_size > max_upload_bytes:
                    raise MediaValidationError(f"File is too large (max {max_upload_bytes} bytes)")
                output.write(chunk)
                digest.update(chunk)
    except Exception:
        if target_path.exists():
            target_path.unlink(missing_ok=True)
        raise

    if total_size <= 0:
        target_path.unlink(missing_ok=True)
        raise MediaValidationError("Uploaded file is empty")
    return StoredUpload(size_bytes=total_size, sha256=digest.hexdigest())


def analyze_media(
    *,
    file_path: Path,
    media_root: Path,
    storage_name: str,
    media_kind: MediaKind,
) -> MediaAnalysis:
    analysis = MediaAnalysis(media_kind=media_kind)

    if media_kind == MediaKind.IMAGE:
        image_result = _analyze_image(file_path=file_path, media_root=media_root, storage_name=storage_name)
        if image_result is not None:
            return image_result
        return analysis

    if media_kind == MediaKind.VIDEO:
        ffprobe_result = _probe_av(file_path)
        if ffprobe_result:
            analysis.width = ffprobe_result.get("width")
            analysis.height = ffprobe_result.get("height")
            analysis.duration_seconds = ffprobe_result.get("duration_seconds")
        analysis.thumbnail_storage_name = _generate_video_thumbnail(
            file_path=file_path,
            media_root=media_root,
            storage_name=storage_name,
        )
        return analysis

    if media_kind in {MediaKind.AUDIO, MediaKind.VOICE}:
        ffprobe_result = _probe_av(file_path)
        if ffprobe_result:
            analysis.duration_seconds = ffprobe_result.get("duration_seconds")
        return analysis

    return analysis


def _analyze_image(*, file_path: Path, media_root: Path, storage_name: str) -> MediaAnalysis | None:
    try:
        with Image.open(file_path) as image:
            width, height = image.size
            thumbnail_storage_name = _save_image_thumbnail(
                image=image,
                media_root=media_root,
                storage_name=storage_name,
            )
            return MediaAnalysis(
                media_kind=MediaKind.IMAGE,
                width=width,
                height=height,
                thumbnail_storage_name=thumbnail_storage_name,
            )
    except (UnidentifiedImageError, OSError):
        return None


def _save_image_thumbnail(*, image: Image.Image, media_root: Path, storage_name: str) -> str | None:
    thumb_name = f"{Path(storage_name).stem}_thumb.jpg"
    thumb_path = media_root / thumb_name
    try:
        image_copy = image.copy()
        image_copy.thumbnail((960, 960))
        if image_copy.mode not in {"RGB", "L"}:
            image_copy = image_copy.convert("RGB")
        image_copy.save(thumb_path, format="JPEG", quality=82, optimize=True)
        return thumb_name
    except OSError:
        thumb_path.unlink(missing_ok=True)
        return None


def _probe_av(file_path: Path) -> dict[str, int] | None:
    try:
        completed = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-print_format",
                "json",
                "-show_entries",
                "format=duration",
                "-show_streams",
                str(file_path),
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except (FileNotFoundError, subprocess.SubprocessError):
        return None

    if completed.returncode != 0 or not completed.stdout.strip():
        return None

    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return None

    streams = payload.get("streams") or []
    video_stream = next((item for item in streams if item.get("codec_type") == "video"), None)
    audio_stream = next((item for item in streams if item.get("codec_type") == "audio"), None)
    target_stream = video_stream or audio_stream or {}

    duration_raw = None
    for candidate in [target_stream.get("duration"), (payload.get("format") or {}).get("duration")]:
        if candidate not in {None, "", "N/A"}:
            duration_raw = candidate
            break

    duration_seconds = None
    if duration_raw is not None:
        try:
            duration_seconds = max(1, int(round(float(duration_raw))))
        except (TypeError, ValueError):
            duration_seconds = None

    width = _coerce_int(video_stream.get("width") if video_stream else None)
    height = _coerce_int(video_stream.get("height") if video_stream else None)
    return {
        "width": width,
        "height": height,
        "duration_seconds": duration_seconds,
    }


def _generate_video_thumbnail(*, file_path: Path, media_root: Path, storage_name: str) -> str | None:
    thumb_name = f"{Path(storage_name).stem}_thumb.jpg"
    thumb_path = media_root / thumb_name
    for seek_point in ("00:00:01", "00:00:00"):
        try:
            completed = subprocess.run(
                [
                    "ffmpeg",
                    "-y",
                    "-ss",
                    seek_point,
                    "-i",
                    str(file_path),
                    "-frames:v",
                    "1",
                    "-q:v",
                    "3",
                    str(thumb_path),
                ],
                check=False,
                capture_output=True,
                timeout=25,
            )
        except (FileNotFoundError, subprocess.SubprocessError):
            thumb_path.unlink(missing_ok=True)
            return None
        if completed.returncode == 0 and thumb_path.exists() and thumb_path.stat().st_size > 0:
            return thumb_name
    thumb_path.unlink(missing_ok=True)
    return None


def _coerce_int(value: object) -> int | None:
    try:
        if value in {None, "", "N/A"}:
            return None
        return int(value)
    except (TypeError, ValueError):
        return None
