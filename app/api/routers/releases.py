import json
from pathlib import Path

from fastapi import APIRouter, HTTPException, Query, status

from app.core.config import get_settings

router = APIRouter(prefix="/releases", tags=["Releases"])

SUPPORTED_PLATFORMS = {"windows", "android", "web"}


def _load_manifest() -> dict:
    settings = get_settings()
    path = Path(settings.release_manifest_path)
    if not path.exists():
        return {"channels": {}}
    return json.loads(path.read_text(encoding="utf-8"))


def _infer_package_kind(platform: str, download_url: str) -> str:
    lowered = download_url.lower()
    if lowered.endswith(".apk"):
        return "apk"
    if lowered.endswith(".msix"):
        return "msix"
    if lowered.endswith(".exe"):
        return "exe"
    if lowered.endswith(".zip"):
        return "zip"
    if platform == "web":
        return "bundle"
    return "package"


def _default_install_strategy(platform: str, package_kind: str) -> str:
    if platform == "android":
        return "open_package"
    if platform == "windows" and package_kind in {"exe", "msix", "zip"}:
        return "replace_and_restart"
    if platform == "web":
        return "deploy_hosting"
    return "external"


def _enrich_release(platform: str, channel: str, manifest: dict, release: dict) -> dict:
    release = dict(release)
    download_url = str(release.get("download_url", ""))
    package_kind = str(release.get("package_kind") or _infer_package_kind(platform, download_url))
    release.setdefault("package_kind", package_kind)
    release.setdefault("install_strategy", _default_install_strategy(platform, package_kind))
    release.setdefault("in_app_download_supported", platform in {"windows", "android"})
    release.setdefault("restart_required", platform in {"windows", "android"})
    release.setdefault("file_size_bytes", None)
    release.setdefault("sha256", None)
    return {
        "platform": platform,
        "channel": channel,
        "generated_at": manifest.get("generated_at"),
        **release,
    }


@router.get("/latest/{platform}")
def latest_release(
    platform: str,
    channel: str = Query(default="stable", min_length=1, max_length=30),
) -> dict:
    platform = platform.lower()
    if platform not in SUPPORTED_PLATFORMS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported platform '{platform}'",
        )

    manifest = _load_manifest()
    platform_release = (
        manifest.get("channels", {})
        .get(channel, {})
        .get(platform)
    )
    if not platform_release:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Release for platform '{platform}' and channel '{channel}' not found",
        )

    return _enrich_release(platform, channel, manifest, platform_release)
