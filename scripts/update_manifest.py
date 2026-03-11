import argparse
import json
from datetime import UTC, datetime
from pathlib import Path


def _default_package_kind(platform: str) -> str:
    return {
        "windows": "zip",
        "android": "apk",
        "web": "bundle",
    }.get(platform, "package")


def _default_install_strategy(platform: str, package_kind: str) -> str:
    if platform == "android":
        return "open_package"
    if platform == "windows" and package_kind in {"exe", "msix", "zip"}:
        return "replace_and_restart"
    if platform == "web":
        return "deploy_hosting"
    return "external"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Update oMsg releases manifest.")
    parser.add_argument("--manifest", default="releases/manifest.json", help="Manifest file path")
    parser.add_argument("--platform", choices=["windows", "android", "web"], required=True)
    parser.add_argument("--version", required=True, help="Version in format 1.2.3+4")
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--channel", default="stable")
    parser.add_argument("--minimum-supported-version", default=None)
    parser.add_argument("--notes", default="")
    parser.add_argument("--package-kind", default=None)
    parser.add_argument("--install-strategy", default=None)
    parser.add_argument("--file-size-bytes", type=int, default=None)
    parser.add_argument("--sha256", default=None)
    parser.add_argument("--mandatory", action="store_true")
    parser.add_argument("--no-in-app-download", action="store_true")
    parser.add_argument("--no-restart-required", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    path = Path(args.manifest)
    path.parent.mkdir(parents=True, exist_ok=True)

    if path.exists():
        manifest = json.loads(path.read_text(encoding="utf-8"))
    else:
        manifest = {"channels": {}}

    package_kind = args.package_kind or _default_package_kind(args.platform)
    install_strategy = args.install_strategy or _default_install_strategy(args.platform, package_kind)

    channels = manifest.setdefault("channels", {})
    channel_data = channels.setdefault(args.channel, {})
    channel_data[args.platform] = {
        "latest_version": args.version,
        "minimum_supported_version": args.minimum_supported_version or args.version,
        "mandatory": bool(args.mandatory),
        "download_url": args.download_url,
        "notes": args.notes,
        "package_kind": package_kind,
        "install_strategy": install_strategy,
        "in_app_download_supported": not args.no_in_app_download and args.platform in {"windows", "android"},
        "restart_required": not args.no_restart_required and args.platform in {"windows", "android"},
        "file_size_bytes": args.file_size_bytes,
        "sha256": args.sha256,
    }
    manifest["generated_at"] = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Updated {path} for {args.platform} {args.version} ({args.channel})")


if __name__ == "__main__":
    main()
