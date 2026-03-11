import httpx

from app.core.config import get_settings


def send_login_code(phone: str, code: str) -> None:
    settings = get_settings()
    provider = settings.sms_provider.strip().lower()

    if provider in {"test", "mock"}:
        return
    if provider in {"disabled", "none", "off"}:
        raise ValueError("SMS provider is disabled. Configure SMS_PROVIDER and provider credentials.")

    if provider in {"android_gateway", "gateway"}:
        try:
            _send_with_android_gateway(phone=phone, code=code)
        except Exception as exc:  # pragma: no cover - external provider failures
            raise ValueError("Failed to send SMS code") from exc
        return

    if provider == "twilio":
        try:
            _send_with_twilio(phone=phone, code=code)
        except Exception as exc:  # pragma: no cover - external provider failures
            raise ValueError("Failed to send SMS code") from exc
        return

    raise ValueError(f"Unsupported SMS provider '{settings.sms_provider}'")


def _send_with_twilio(*, phone: str, code: str) -> None:
    settings = get_settings()
    account_sid = (settings.twilio_account_sid or "").strip()
    auth_token = (settings.twilio_auth_token or "").strip()
    if not account_sid or not auth_token:
        raise ValueError("Twilio credentials are not configured")

    body = settings.sms_code_template.format(app_name=settings.app_name, code=code)
    payload = {
        "To": phone,
        "Body": body,
    }
    messaging_service_sid = (settings.twilio_messaging_service_sid or "").strip()
    twilio_from = (settings.twilio_from or "").strip()
    if messaging_service_sid:
        payload["MessagingServiceSid"] = messaging_service_sid
    elif twilio_from:
        payload["From"] = twilio_from
    else:
        raise ValueError("Set TWILIO_FROM or TWILIO_MESSAGING_SERVICE_SID")

    endpoint = f"https://api.twilio.com/2010-04-01/Accounts/{account_sid}/Messages.json"
    with httpx.Client(timeout=12.0) as client:
        response = client.post(
            endpoint,
            data=payload,
            auth=(account_sid, auth_token),
        )
    if response.status_code < 200 or response.status_code >= 300:
        raise ValueError("Failed to send SMS code")


def _send_with_android_gateway(*, phone: str, code: str) -> None:
    settings = get_settings()
    endpoint = (settings.sms_gateway_url or "").strip()
    if not endpoint:
        raise ValueError("Set SMS_GATEWAY_URL for android_gateway provider")

    body = settings.sms_code_template.format(app_name=settings.app_name, code=code)
    payload = {
        settings.sms_gateway_to_field: phone,
        settings.sms_gateway_message_field: body,
    }

    headers: dict[str, str] = {
        "Accept": "application/json",
        "Content-Type": "application/json",
    }
    api_key = (settings.sms_gateway_api_key or "").strip()
    if api_key:
        auth_header = settings.sms_gateway_auth_header.strip() or "Authorization"
        auth_prefix = settings.sms_gateway_auth_prefix.strip()
        headers[auth_header] = f"{auth_prefix} {api_key}".strip()

    timeout_seconds = max(3, settings.sms_gateway_timeout_seconds)
    with httpx.Client(timeout=timeout_seconds) as client:
        response = client.post(endpoint, json=payload, headers=headers)

    if response.status_code < 200 or response.status_code >= 300:
        raise ValueError("Gateway rejected SMS request")
