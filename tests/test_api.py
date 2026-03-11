from datetime import UTC, datetime, timedelta
from io import BytesIO
import time

from urllib.parse import quote_plus

from sqlalchemy import inspect

from app.core.database import SessionLocal, engine
from app.models.chat import MediaFile
from app.services.chat_service import dispatch_due_scheduled_messages

TEST_AUTH_CODE = "12345"


def _auth_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _client_headers(platform: str, device_name: str) -> dict[str, str]:
    return {
        "X-oMsg-Client-Platform": platform,
        "X-oMsg-Device-Name": device_name,
    }


def _recv_by_type(websocket, expected_type: str, max_events: int = 10):
    for _ in range(max_events):
        payload = websocket.receive_json()
        if payload.get("type") == expected_type:
            return payload
    raise AssertionError(f"Event '{expected_type}' was not received in {max_events} frames")


def _auth_by_phone(
    client,
    phone: str,
    first_name: str,
    last_name: str,
    *,
    platform: str = "android",
    device_name: str | None = None,
):
    request_code = client.post("/api/auth/request-code", json={"phone": phone})
    assert request_code.status_code == 200, request_code.text
    request_payload = request_code.json()
    assert request_payload["phone"].startswith("+")
    assert request_payload["code_token"]
    assert "dev_code" not in request_payload

    auth_headers = _client_headers(platform, device_name or f"{first_name} Phone")

    verify_code = client.post(
        "/api/auth/verify-code",
        headers=auth_headers,
        json={
            "phone": request_payload["phone"],
            "code_token": request_payload["code_token"],
            "code": TEST_AUTH_CODE,
        },
    )
    assert verify_code.status_code == 200, verify_code.text
    payload = verify_code.json()
    assert payload["access_token"]
    assert payload["refresh_token"]
    assert payload["user"]["phone"] == request_payload["phone"]
    assert payload["needs_profile_setup"] is True
    return payload


def test_phone_auth_follow_up_login_does_not_require_profile_setup(client):
    phone = "+7 900 100 10 10"
    first = _auth_by_phone(client, phone, "Setup", "Needed")
    headers = _auth_headers(first["access_token"])

    complete_profile = client.patch(
        "/api/users/me",
        headers=headers,
        json={"first_name": "Setup", "last_name": "Needed", "username": "setup_needed"},
    )
    assert complete_profile.status_code == 200, complete_profile.text

    request_code = client.post("/api/auth/request-code", json={"phone": phone})
    assert request_code.status_code == 200, request_code.text
    request_payload = request_code.json()
    assert request_payload["is_registered"] is True

    verify_code = client.post(
        "/api/auth/verify-code",
        json={
            "phone": request_payload["phone"],
            "code_token": request_payload["code_token"],
            "code": TEST_AUTH_CODE,
        },
    )
    assert verify_code.status_code == 200, verify_code.text
    payload = verify_code.json()
    assert payload["user"]["id"] == first["user"]["id"]
    assert payload["needs_profile_setup"] is False


def test_phone_auth_profile_and_lookup_flow(client):
    alice = _auth_by_phone(client, "+7 900 111 22 33", "Alice", "Stone")
    bob = _auth_by_phone(client, "+7 900 111 22 44", "Bob", "Miller")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    me = client.get("/api/users/me", headers=alice_headers)
    assert me.status_code == 200, me.text
    assert me.json()["first_name"] == ""
    assert me.json()["phone"] == "+79001112233"
    assert me.json()["username"] is None

    patched = client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"username": "@alice_stone", "first_name": "Alice", "last_name": "Stone", "bio": "hello"},
    )
    assert patched.status_code == 200, patched.text
    assert patched.json()["username"] == "alice_stone"
    assert patched.json()["first_name"] == "Alice"
    assert patched.json()["bio"] == "hello"

    lookup = client.get("/api/users/lookup", headers=bob_headers, params={"q": "alice_stone"})
    assert lookup.status_code == 200, lookup.text
    assert lookup.json()["id"] == alice["user"]["id"]

    by_id = client.get(f"/api/users/{alice['user']['id']}", headers=bob_headers)
    assert by_id.status_code == 200, by_id.text
    assert by_id.json()["username"] == "alice_stone"


def test_private_chat_and_messages_flow(client):
    alice = _auth_by_phone(client, "+7 900 222 22 33", "Alice", "Two")
    bob = _auth_by_phone(client, "+7 900 222 22 44", "Bob", "Two")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    alice_profile = client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"first_name": "Alice", "last_name": "Two"},
    )
    assert alice_profile.status_code == 200, alice_profile.text
    bob_profile = client.patch(
        "/api/users/me",
        headers=bob_headers,
        json={"first_name": "Bob", "last_name": "Two", "username": "bob_two"},
    )
    assert bob_profile.status_code == 200, bob_profile.text

    open_chat = client.post(
        "/api/chats/private?query=%2B79002222244",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]
    assert open_chat.json()["type"] == "private"

    send_message = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "Hello Bob"},
    )
    assert send_message.status_code == 201, send_message.text
    message_id = send_message.json()["id"]
    assert send_message.json()["content"] == "Hello Bob"

    bob_messages = client.get(f"/api/chats/{chat_id}/messages", headers=bob_headers)
    assert bob_messages.status_code == 200, bob_messages.text
    assert any(message["id"] == message_id for message in bob_messages.json())

    send_reply = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=bob_headers,
        json={"content": "Hello Alice"},
    )
    assert send_reply.status_code == 201, send_reply.text

    alice_chats = client.get("/api/chats", headers=alice_headers)
    assert alice_chats.status_code == 200, alice_chats.text
    chat_row = next((row for row in alice_chats.json() if row["id"] == chat_id), None)
    assert chat_row is not None
    assert chat_row["title"] == "Bob Two"
    assert chat_row["last_message_preview"] in {"Hello Bob", "Hello Alice"}
    assert chat_row["unread_count"] == 1


def test_search_users_by_phone_and_username(client):
    alice = _auth_by_phone(client, "+7 900 333 22 33", "Alice", "Search")
    bob = _auth_by_phone(client, "+7 900 333 22 44", "Bob", "Search")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    set_username = client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"first_name": "Alice", "last_name": "Search", "username": "alice_search"},
    )
    assert set_username.status_code == 200, set_username.text

    search_username = client.get("/api/users/search", headers=bob_headers, params={"q": "alice"})
    assert search_username.status_code == 200, search_username.text
    assert any(user["username"] == "alice_search" for user in search_username.json())

    search_username_with_at = client.get("/api/users/search", headers=bob_headers, params={"q": "@alice"})
    assert search_username_with_at.status_code == 200, search_username_with_at.text

    search_username_with_link = client.get(
        "/api/users/search",
        headers=bob_headers,
        params={"q": "https://volds.ru/u/alice_search"},
    )
    assert search_username_with_link.status_code == 200, search_username_with_link.text
    assert any(user["username"] == "alice_search" for user in search_username_with_link.json())

    search_phone = client.get("/api/users/search", headers=bob_headers, params={"q": "9003332233"})
    assert search_phone.status_code == 200, search_phone.text
    assert any(user["phone"] == "+79003332233" for user in search_phone.json())


def test_username_check_and_clear_flow(client):
    user = _auth_by_phone(client, "+7 900 350 22 33", "Name", "User")
    headers = _auth_headers(user["access_token"])

    available = client.get("/api/users/username-check", headers=headers, params={"username": "@telegram_like"})
    assert available.status_code == 200, available.text
    assert available.json() == {"username": "telegram_like", "available": True}

    updated = client.patch(
        "/api/users/me",
        headers=headers,
        json={"username": "telegram_like", "first_name": "Name"},
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["username"] == "telegram_like"

    taken = client.get("/api/users/username-check", headers=headers, params={"username": "telegram_like"})
    assert taken.status_code == 200, taken.text
    assert taken.json()["available"] is True

    second = _auth_by_phone(client, "+7 900 350 22 44", "Second", "User")
    second_headers = _auth_headers(second["access_token"])
    unavailable = client.get("/api/users/username-check", headers=second_headers, params={"username": "telegram_like"})
    assert unavailable.status_code == 200, unavailable.text
    assert unavailable.json()["available"] is False

    cleared = client.patch(
        "/api/users/me",
        headers=headers,
        json={"username": "", "first_name": "Name"},
    )
    assert cleared.status_code == 200, cleared.text
    assert cleared.json()["username"] is None


def test_public_profile_endpoint_and_link_lookup(client):
    owner = _auth_by_phone(client, "+7 900 351 22 33", "Public", "User")
    viewer = _auth_by_phone(client, "+7 900 351 22 44", "Viewer", "User")

    owner_headers = _auth_headers(owner["access_token"])
    viewer_headers = _auth_headers(viewer["access_token"])

    updated = client.patch(
        "/api/users/me",
        headers=owner_headers,
        json={"first_name": "Public", "last_name": "User", "username": "public_user", "bio": "Visible bio"},
    )
    assert updated.status_code == 200, updated.text

    public_profile = client.get("/api/public/users/public_user")
    assert public_profile.status_code == 200, public_profile.text
    payload = public_profile.json()
    assert payload["username"] == "public_user"
    assert payload["bio"] == "Visible bio"
    assert "phone" not in payload

    public_page = client.get("/u/public_user")
    assert public_page.status_code == 200, public_page.text
    assert "@public_user" in public_page.text

    open_by_link = client.post(
        "/api/chats/private?query=https%3A%2F%2Fvolds.ru%2Fu%2Fpublic_user",
        headers=viewer_headers,
    )
    assert open_by_link.status_code == 200, open_by_link.text


def test_realtime_message_status_flow(client):
    alice = _auth_by_phone(client, "+7 900 444 22 33", "Alice", "Ws")
    bob = _auth_by_phone(client, "+7 900 444 22 44", "Bob", "Ws")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch("/api/users/me", headers=alice_headers, json={"first_name": "Alice", "last_name": "Ws"})
    client.patch("/api/users/me", headers=bob_headers, json={"first_name": "Bob", "last_name": "Ws", "username": "bob_ws"})

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_ws')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    sent = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "Status check"},
    )
    assert sent.status_code == 201, sent.text
    message_id = sent.json()["id"]

    with (
        client.websocket_connect(f"/api/realtime/me/ws?token={alice['access_token']}") as alice_ws,
        client.websocket_connect(f"/api/realtime/me/ws?token={bob['access_token']}") as bob_ws,
    ):
        assert alice_ws.receive_json()["type"] == "ready"
        assert bob_ws.receive_json()["type"] == "ready"

        bob_ws.send_json(
            {
                "type": "ack",
                "chat_id": chat_id,
                "message_id": message_id,
                "status": "read",
            }
        )

        status_event = _recv_by_type(alice_ws, "message_status")
        assert status_event["chat_id"] == chat_id
        assert status_event["message_id"] == message_id
        assert status_event["status"] == "read"


def test_chat_state_and_message_search_flow(client):
    alice = _auth_by_phone(client, "+7 900 666 22 33", "Alice", "State")
    bob = _auth_by_phone(client, "+7 900 666 22 44", "Bob", "State")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch("/api/users/me", headers=alice_headers, json={"first_name": "Alice", "last_name": "State"})
    client.patch("/api/users/me", headers=bob_headers, json={"first_name": "Bob", "last_name": "State", "username": "bob_state"})

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_state')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    sent = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "Phase two searchable text"},
    )
    assert sent.status_code == 201, sent.text

    mark_pinned = client.patch(
        f"/api/chats/{chat_id}/state",
        headers=alice_headers,
        json={"is_pinned": True},
    )
    assert mark_pinned.status_code == 200, mark_pinned.text
    assert mark_pinned.json()["is_pinned"] is True

    pinned = client.get("/api/chats", headers=alice_headers, params={"pinned_only": "true"})
    assert pinned.status_code == 200, pinned.text
    assert any(row["id"] == chat_id and row["is_pinned"] is True for row in pinned.json())

    archive = client.patch(
        f"/api/chats/{chat_id}/state",
        headers=alice_headers,
        json={"is_archived": True},
    )
    assert archive.status_code == 200, archive.text
    assert archive.json()["is_archived"] is True

    archived = client.get("/api/chats", headers=alice_headers, params={"archived_only": "true"})
    assert archived.status_code == 200, archived.text
    assert any(row["id"] == chat_id and row["is_archived"] is True for row in archived.json())

    search = client.get(
        "/api/chats/messages/search",
        headers=alice_headers,
        params={"q": "searchable", "limit": 20},
    )
    assert search.status_code == 200, search.text
    assert any(row["chat_id"] == chat_id for row in search.json())






def test_chat_message_search_and_context_endpoint(client):
    alice = _auth_by_phone(client, "+7 900 225 22 33", "Alice", "SearchCtx")
    bob = _auth_by_phone(client, "+7 900 225 22 44", "Bob", "SearchCtx")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"first_name": "Alice", "last_name": "SearchCtx", "username": "alice_ctx"},
    )
    client.patch(
        "/api/users/me",
        headers=bob_headers,
        json={"first_name": "Bob", "last_name": "SearchCtx", "username": "bob_ctx"},
    )

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_ctx')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    contents = [
        "Older one",
        "Older two",
        "needle target message",
        "Newer after target",
    ]
    target_message_id = None
    for content in contents:
        sent = client.post(
            f"/api/chats/{chat_id}/messages",
            headers=alice_headers,
            json={"content": content},
        )
        assert sent.status_code == 201, sent.text
        if content == "needle target message":
            target_message_id = sent.json()["id"]
    assert target_message_id is not None

    search = client.get(
        f"/api/chats/{chat_id}/messages/search",
        headers=bob_headers,
        params={"q": "needle", "limit": 20},
    )
    assert search.status_code == 200, search.text
    assert any(row["message_id"] == target_message_id for row in search.json())

    context = client.get(
        f"/api/chats/{chat_id}/messages/context/{target_message_id}",
        headers=bob_headers,
        params={"before_limit": 1, "after_limit": 1},
    )
    assert context.status_code == 200, context.text
    payload = context.json()
    assert payload["anchor_message_id"] == target_message_id
    assert len(payload["items"]) == 3
    assert payload["items"][1]["id"] == target_message_id
    assert payload["items"][1]["content"] == "needle target message"
    assert payload["next_before_id"] is not None


def test_delete_message_for_me_hides_only_for_requester(client):
    alice = _auth_by_phone(client, "+7 900 226 22 33", "Alice", "DeleteMe")
    bob = _auth_by_phone(client, "+7 900 226 22 44", "Bob", "DeleteMe")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"first_name": "Alice", "last_name": "DeleteMe", "username": "alice_delete_me"},
    )
    client.patch(
        "/api/users/me",
        headers=bob_headers,
        json={"first_name": "Bob", "last_name": "DeleteMe", "username": "bob_delete_me"},
    )

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_delete_me')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    sent = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "Visible only for Alice after delete-for-me"},
    )
    assert sent.status_code == 201, sent.text
    message_id = sent.json()["id"]

    removed = client.delete(
        f"/api/chats/messages/{message_id}",
        headers=bob_headers,
        params={"scope": "me"},
    )
    assert removed.status_code == 200, removed.text
    assert removed.json()["scope"] == "me"

    bob_history = client.get(f"/api/chats/{chat_id}/messages", headers=bob_headers)
    assert bob_history.status_code == 200, bob_history.text
    assert all(item["id"] != message_id for item in bob_history.json())

    alice_history = client.get(f"/api/chats/{chat_id}/messages", headers=alice_headers)
    assert alice_history.status_code == 200, alice_history.text
    assert any(item["id"] == message_id for item in alice_history.json())


def test_clear_history_for_me_hides_chat_history_and_preview(client):
    alice = _auth_by_phone(client, "+7 900 227 22 33", "Alice", "ClearHistory")
    bob = _auth_by_phone(client, "+7 900 227 22 44", "Bob", "ClearHistory")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"first_name": "Alice", "last_name": "ClearHistory", "username": "alice_clear_history"},
    )
    client.patch(
        "/api/users/me",
        headers=bob_headers,
        json={"first_name": "Bob", "last_name": "ClearHistory", "username": "bob_clear_history"},
    )

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_clear_history')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "History line one"},
    )
    client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "History line two"},
    )

    cleared = client.post(f"/api/chats/{chat_id}/history/clear", headers=bob_headers)
    assert cleared.status_code == 200, cleared.text
    assert cleared.json()["removed_count"] == 2

    bob_history = client.get(f"/api/chats/{chat_id}/messages", headers=bob_headers)
    assert bob_history.status_code == 200, bob_history.text
    assert bob_history.json() == []

    bob_chats = client.get("/api/chats", headers=bob_headers)
    assert bob_chats.status_code == 200, bob_chats.text
    bob_row = next(row for row in bob_chats.json() if row["id"] == chat_id)
    assert bob_row["last_message_preview"] is None
    assert bob_row["unread_count"] == 0

    alice_history = client.get(f"/api/chats/{chat_id}/messages", headers=alice_headers)
    assert alice_history.status_code == 200, alice_history.text
    assert len(alice_history.json()) == 2

def test_scheduled_message_dispatch_flow(client):
    alice = _auth_by_phone(client, '+7 900 779 22 33', 'Alice', 'Schedule')
    bob = _auth_by_phone(client, '+7 900 779 22 44', 'Bob', 'Schedule')

    alice_headers = _auth_headers(alice['access_token'])
    bob_headers = _auth_headers(bob['access_token'])

    client.patch('/api/users/me', headers=alice_headers, json={'first_name': 'Alice', 'last_name': 'Schedule'})
    client.patch('/api/users/me', headers=bob_headers, json={'first_name': 'Bob', 'last_name': 'Schedule', 'username': 'bob_schedule'})

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_schedule')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()['id']

    scheduled_for = (datetime.now(UTC) + timedelta(seconds=0.5)).isoformat()
    created = client.post(
        f'/api/chats/{chat_id}/scheduled-messages',
        headers=alice_headers,
        json={'content': 'Send later', 'scheduled_for': scheduled_for},
    )
    assert created.status_code == 201, created.text
    scheduled_payload = created.json()
    assert scheduled_payload['status'] == 'pending'
    assert scheduled_payload['content'] == 'Send later'

    pending = client.get(f'/api/chats/{chat_id}/scheduled-messages', headers=alice_headers)
    assert pending.status_code == 200, pending.text
    assert any(item['id'] == scheduled_payload['id'] for item in pending.json())

    time.sleep(1.1)

    pending_after = client.get(f'/api/chats/{chat_id}/scheduled-messages', headers=alice_headers)
    assert pending_after.status_code == 200, pending_after.text
    assert all(item['id'] != scheduled_payload['id'] for item in pending_after.json())

    history = client.get(f'/api/chats/{chat_id}/messages', headers=bob_headers)
    assert history.status_code == 200, history.text
    delivered = next((item for item in history.json() if item['content'] == 'Send later'), None)
    assert delivered is not None
    assert delivered['sender_id'] == alice['user']['id']


def test_cancel_scheduled_message_flow(client):
    alice = _auth_by_phone(client, '+7 900 779 33 33', 'Alice', 'CancelSchedule')
    bob = _auth_by_phone(client, '+7 900 779 33 44', 'Bob', 'CancelSchedule')

    alice_headers = _auth_headers(alice['access_token'])
    bob_headers = _auth_headers(bob['access_token'])

    client.patch('/api/users/me', headers=alice_headers, json={'first_name': 'Alice', 'last_name': 'CancelSchedule'})
    client.patch('/api/users/me', headers=bob_headers, json={'first_name': 'Bob', 'last_name': 'CancelSchedule', 'username': 'bob_cancel_schedule'})

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_cancel_schedule')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()['id']

    scheduled_for = (datetime.now(UTC) + timedelta(seconds=1.5)).isoformat()
    created = client.post(
        f'/api/chats/{chat_id}/scheduled-messages',
        headers=alice_headers,
        json={'content': 'This should be canceled', 'scheduled_for': scheduled_for},
    )
    assert created.status_code == 201, created.text
    scheduled_id = created.json()['id']

    removed = client.delete(f'/api/chats/scheduled-messages/{scheduled_id}', headers=alice_headers)
    assert removed.status_code == 200, removed.text
    assert removed.json()['removed'] is True

    pending_after = client.get(f'/api/chats/{chat_id}/scheduled-messages', headers=alice_headers)
    assert pending_after.status_code == 200, pending_after.text
    assert all(item['id'] != scheduled_id for item in pending_after.json())

    time.sleep(1.7)

    history = client.get(f'/api/chats/{chat_id}/messages', headers=bob_headers)
    assert history.status_code == 200, history.text
    assert all(item['content'] != 'This should be canceled' for item in history.json())

def test_media_upload_and_send_attachment_flow(client):
    alice = _auth_by_phone(client, "+7 900 778 22 33", "Alice", "Media")
    bob = _auth_by_phone(client, "+7 900 778 22 44", "Bob", "Media")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch("/api/users/me", headers=alice_headers, json={"first_name": "Alice", "last_name": "Media"})
    client.patch("/api/users/me", headers=bob_headers, json={"first_name": "Bob", "last_name": "Media", "username": "bob_media"})

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_media')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    upload = client.post(
        f"/api/media/upload?chat_id={chat_id}",
        headers=alice_headers,
        files={"file": ("cover.png", b"fake-image-bytes", "image/png")},
    )
    assert upload.status_code == 201, upload.text
    upload_payload = upload.json()
    assert upload_payload["id"] > 0
    assert upload_payload["is_image"] is True
    assert upload_payload["url"].startswith("/media/")

    sent = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "", "attachment_ids": [upload_payload["id"]]},
    )
    assert sent.status_code == 201, sent.text
    message = sent.json()
    assert message["content"] == ""
    assert len(message["attachments"]) == 1
    assert message["attachments"][0]["id"] == upload_payload["id"]
    assert message["attachments"][0]["is_image"] is True

    history = client.get(f"/api/chats/{chat_id}/messages", headers=bob_headers)
    assert history.status_code == 200, history.text
    assert any(item["id"] == message["id"] and item["attachments"] for item in history.json())


def test_media_upload_can_force_send_as_file(client):
    alice = _auth_by_phone(client, "+7 900 778 55 11", "Alice", "Docs")
    bob = _auth_by_phone(client, "+7 900 778 55 22", "Bob", "Docs")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"first_name": "Alice", "last_name": "Docs"},
    )
    client.patch(
        "/api/users/me",
        headers=bob_headers,
        json={"first_name": "Bob", "last_name": "Docs", "username": "bob_docs"},
    )

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_docs')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    upload = client.post(
        f"/api/media/upload?chat_id={chat_id}&kind_hint=file",
        headers=alice_headers,
        files={"file": ("holiday.jpg", b"pretend-jpeg-binary", "image/jpeg")},
    )
    assert upload.status_code == 201, upload.text
    payload = upload.json()
    assert payload["media_kind"] == "file"
    assert payload["is_image"] is False
    assert payload["is_video"] is False

    sent = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"attachment_ids": [payload["id"]]},
    )
    assert sent.status_code == 201, sent.text
    message = sent.json()
    assert message["attachments"][0]["media_kind"] == "file"
    assert message["attachments"][0]["is_image"] is False



def test_message_create_is_idempotent_by_client_message_id(client):
    alice = _auth_by_phone(client, "+7 900 777 30 11", "Alice", "Retry")
    bob = _auth_by_phone(client, "+7 900 777 30 22", "Bob", "Retry")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch("/api/users/me", headers=alice_headers, json={"first_name": "Alice", "last_name": "Retry"})
    client.patch(
        "/api/users/me",
        headers=bob_headers,
        json={"first_name": "Bob", "last_name": "Retry", "username": "bob_retry"},
    )

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_retry')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    payload = {
        "content": "Retry-safe message",
        "client_message_id": "android-1741599900-001",
        "is_silent": True,
    }
    first = client.post(f"/api/chats/{chat_id}/messages", headers=alice_headers, json=payload)
    assert first.status_code == 201, first.text
    second = client.post(f"/api/chats/{chat_id}/messages", headers=alice_headers, json=payload)
    assert second.status_code == 201, second.text

    first_payload = first.json()
    second_payload = second.json()
    assert first_payload["id"] == second_payload["id"]
    assert first_payload["client_message_id"] == payload["client_message_id"]
    assert first_payload["is_silent"] is True

    history = client.get(f"/api/chats/{chat_id}/messages", headers=alice_headers)
    assert history.status_code == 200, history.text
    matching = [item for item in history.json() if item["client_message_id"] == payload["client_message_id"]]
    assert len(matching) == 1


def test_shared_media_listing_by_kind(client):
    alice = _auth_by_phone(client, "+7 900 777 40 11", "Alice", "Gallery")
    bob = _auth_by_phone(client, "+7 900 777 40 22", "Bob", "Gallery")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch("/api/users/me", headers=alice_headers, json={"first_name": "Alice", "last_name": "Gallery"})
    client.patch(
        "/api/users/me",
        headers=bob_headers,
        json={"first_name": "Bob", "last_name": "Gallery", "username": "bob_gallery"},
    )

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_gallery')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    image_upload = client.post(
        f"/api/media/upload?chat_id={chat_id}",
        headers=alice_headers,
        files={"file": ("photo.jpg", b"fake-image-bytes", "image/jpeg")},
    )
    assert image_upload.status_code == 201, image_upload.text

    audio_upload = client.post(
        f"/api/media/upload?chat_id={chat_id}",
        headers=alice_headers,
        files={"file": ("track.mp3", b"fake-audio-bytes", "audio/mpeg")},
    )
    assert audio_upload.status_code == 201, audio_upload.text

    send_image = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "Photo", "attachment_ids": [image_upload.json()["id"]]},
    )
    assert send_image.status_code == 201, send_image.text

    send_audio = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "Track", "attachment_ids": [audio_upload.json()["id"]]},
    )
    assert send_audio.status_code == 201, send_audio.text

    gallery = client.get(f"/api/chats/{chat_id}/media", headers=bob_headers)
    assert gallery.status_code == 200, gallery.text
    assert len(gallery.json()) >= 2

    images_only = client.get(
        f"/api/chats/{chat_id}/media",
        headers=bob_headers,
        params={"kind": "image"},
    )
    assert images_only.status_code == 200, images_only.text
    assert images_only.json()
    assert all(item["attachment"]["media_kind"] == "image" for item in images_only.json())

    audio_only = client.get(
        f"/api/chats/{chat_id}/media",
        headers=bob_headers,
        params={"kind": "audio"},
    )
    assert audio_only.status_code == 200, audio_only.text
    assert audio_only.json()
    assert all(item["attachment"]["media_kind"] == "audio" for item in audio_only.json())


def test_realtime_replay_after_disconnect(client):
    alice = _auth_by_phone(client, "+7 900 781 22 33", "Alice", "Replay")
    bob = _auth_by_phone(client, "+7 900 781 22 44", "Bob", "Replay")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch("/api/users/me", headers=alice_headers, json={"first_name": "Alice", "last_name": "Replay"})
    client.patch("/api/users/me", headers=bob_headers, json={"first_name": "Bob", "last_name": "Replay", "username": "bob_replay"})

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_replay')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    with client.websocket_connect(f"/api/realtime/me/ws?token={alice['access_token']}") as alice_ws:
        ready = alice_ws.receive_json()
        assert ready["type"] == "ready"
        resume_cursor = ready["latest_cursor"]

    sent = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=bob_headers,
        json={"content": "Missed while offline"},
    )
    assert sent.status_code == 201, sent.text

    with client.websocket_connect(
        f"/api/realtime/me/ws?token={alice['access_token']}&cursor={resume_cursor}"
    ) as alice_ws:
        ready = alice_ws.receive_json()
        assert ready["type"] == "ready"
        replay = _recv_by_type(alice_ws, "message")
        assert replay["chat_id"] == chat_id
        assert replay["message"]["content"] == "Missed while offline"
        assert replay["cursor"] > resume_cursor


def test_refresh_and_release_endpoint(client):
    user = _auth_by_phone(client, "+7 900 555 22 33", "Refresh", "Case")
    first_refresh = user["refresh_token"]

    rotated = client.post("/api/auth/refresh", json={"refresh_token": first_refresh})
    assert rotated.status_code == 200, rotated.text
    payload = rotated.json()
    assert payload["refresh_token"] != first_refresh

    stale = client.post("/api/auth/refresh", json={"refresh_token": first_refresh})
    assert stale.status_code == 401

    release = client.get("/api/releases/latest/windows")
    assert release.status_code == 200, release.text
    assert release.json()["platform"] == "windows"
    assert "volds.ru" in release.json()["download_url"]


def test_device_sessions_list_and_remote_termination(client):
    phone = "+7 900 556 22 33"
    first = _auth_by_phone(
        client,
        phone,
        "Phone",
        "Device",
        platform="android",
        device_name="Phone Device",
    )
    first_headers = _auth_headers(first["access_token"])

    listed_first = client.get("/api/auth/sessions", headers=first_headers)
    assert listed_first.status_code == 200, listed_first.text
    first_rows = listed_first.json()
    assert len(first_rows) == 1
    assert first_rows[0]["is_current"] is True
    assert first_rows[0]["device_name"] == "Phone Device"
    assert first_rows[0]["platform"] == "Android"

    request_second = client.post("/api/auth/request-code", json={"phone": phone})
    assert request_second.status_code == 200, request_second.text
    verify_second = client.post(
        "/api/auth/verify-code",
        headers=_client_headers("windows", "Desk App"),
        json={
            "phone": request_second.json()["phone"],
            "code_token": request_second.json()["code_token"],
            "code": TEST_AUTH_CODE,
        },
    )
    assert verify_second.status_code == 200, verify_second.text
    second = verify_second.json()
    second_headers = _auth_headers(second["access_token"])

    listed_second = client.get("/api/auth/sessions", headers=second_headers)
    assert listed_second.status_code == 200, listed_second.text
    second_rows = listed_second.json()
    assert len(second_rows) == 2
    current_second = next(row for row in second_rows if row["is_current"] is True)
    other_second = next(row for row in second_rows if row["is_current"] is False)
    assert current_second["device_name"] == "Desk App"
    assert current_second["platform"] == "Windows"
    assert other_second["device_name"] == "Phone Device"

    removed = client.delete(
        f"/api/auth/sessions/{other_second['session_id']}",
        headers=second_headers,
    )
    assert removed.status_code == 200, removed.text
    assert removed.json() == {"removed": True}

    first_after_remove = client.get("/api/users/me", headers=first_headers)
    assert first_after_remove.status_code == 401, first_after_remove.text

    request_third = client.post("/api/auth/request-code", json={"phone": phone})
    assert request_third.status_code == 200, request_third.text
    verify_third = client.post(
        "/api/auth/verify-code",
        headers=_client_headers("web", "Browser App"),
        json={
            "phone": request_third.json()["phone"],
            "code_token": request_third.json()["code_token"],
            "code": TEST_AUTH_CODE,
        },
    )
    assert verify_third.status_code == 200, verify_third.text
    third = verify_third.json()
    third_headers = _auth_headers(third["access_token"])

    revoke_others = client.post(
        "/api/auth/sessions/revoke-others",
        headers=third_headers,
    )
    assert revoke_others.status_code == 200, revoke_others.text
    assert revoke_others.json()["revoked"] == 1

    second_after_revoke = client.get("/api/users/me", headers=second_headers)
    assert second_after_revoke.status_code == 401, second_after_revoke.text

    listed_third = client.get("/api/auth/sessions", headers=third_headers)
    assert listed_third.status_code == 200, listed_third.text
    third_rows = listed_third.json()
    assert len(third_rows) == 1
    assert third_rows[0]["is_current"] is True
    assert third_rows[0]["device_name"] == "Browser App"


def test_database_is_versioned_after_startup(client):
    _ = client.get("/health")
    assert "alembic_version" in set(inspect(engine).get_table_names())


def test_release_manifest_exposes_update_contract(client):
    windows_release = client.get('/api/releases/latest/windows')
    assert windows_release.status_code == 200, windows_release.text
    payload = windows_release.json()
    assert payload['platform'] == 'windows'
    assert payload['channel'] == 'stable'
    assert payload['package_kind'] == 'zip'
    assert payload['install_strategy'] == 'replace_and_restart'
    assert payload['in_app_download_supported'] is True
    assert payload['restart_required'] is True
    assert 'generated_at' in payload

    web_release = client.get('/api/releases/latest/web')
    assert web_release.status_code == 200, web_release.text
    web_payload = web_release.json()
    assert web_payload['package_kind'] == 'bundle'
    assert web_payload['in_app_download_supported'] is False
    assert web_payload['restart_required'] is False



def test_privacy_settings_control_phone_lookup_and_data_storage(client):
    alice = _auth_by_phone(client, '+7 900 889 22 33', 'Alice', 'Privacy')
    bob = _auth_by_phone(client, '+7 900 889 22 44', 'Bob', 'Privacy')

    alice_headers = _auth_headers(alice['access_token'])
    bob_headers = _auth_headers(bob['access_token'])

    current = client.get('/api/users/me/settings', headers=alice_headers)
    assert current.status_code == 200, current.text
    current_payload = current.json()
    assert current_payload['privacy']['phone_visibility'] == 'everyone'
    assert current_payload['privacy']['phone_search_visibility'] == 'everyone'
    assert current_payload['data_storage']['keep_media_days'] == 30
    assert current_payload['blocked_users_count'] == 0

    privacy = client.patch(
        '/api/users/me/settings/privacy',
        headers=alice_headers,
        json={
            'phone_visibility': 'nobody',
            'phone_search_visibility': 'nobody',
            'last_seen_visibility': 'contacts',
            'show_approximate_last_seen': True,
            'allow_group_invites': 'contacts',
        },
    )
    assert privacy.status_code == 200, privacy.text
    privacy_payload = privacy.json()
    assert privacy_payload['phone_visibility'] == 'nobody'
    assert privacy_payload['phone_search_visibility'] == 'nobody'
    assert privacy_payload['last_seen_visibility'] == 'contacts'
    assert privacy_payload['allow_group_invites'] == 'contacts'

    storage = client.patch(
        '/api/users/me/settings/data-storage',
        headers=alice_headers,
        json={
            'keep_media_days': 90,
            'storage_limit_mb': 4096,
            'auto_download_photos': True,
            'auto_download_videos': False,
            'auto_download_music': True,
            'auto_download_files': True,
            'default_auto_delete_seconds': 604800,
        },
    )
    assert storage.status_code == 200, storage.text
    storage_payload = storage.json()
    assert storage_payload['keep_media_days'] == 90
    assert storage_payload['storage_limit_mb'] == 4096
    assert storage_payload['auto_download_videos'] is False
    assert storage_payload['auto_download_files'] is True
    assert storage_payload['default_auto_delete_seconds'] == 604800

    by_phone = client.get('/api/users/lookup', headers=bob_headers, params={'q': '+79008892233'})
    assert by_phone.status_code == 404, by_phone.text

    by_id = client.get(f"/api/users/{alice['user']['id']}", headers=bob_headers)
    assert by_id.status_code == 200, by_id.text
    assert by_id.json()['phone'] is None

    updated_bundle = client.get('/api/users/me/settings', headers=alice_headers)
    assert updated_bundle.status_code == 200, updated_bundle.text
    updated_payload = updated_bundle.json()
    assert updated_payload['privacy']['phone_visibility'] == 'nobody'
    assert updated_payload['data_storage']['keep_media_days'] == 90
    assert updated_payload['data_storage']['default_auto_delete_seconds'] == 604800


def test_privacy_exceptions_override_visibility_rules(client):
    alice = _auth_by_phone(client, '+7 900 887 22 33', 'Alice', 'Privacy')
    bob = _auth_by_phone(client, '+7 900 887 22 44', 'Bob', 'Privacy')
    carol = _auth_by_phone(client, '+7 900 887 22 55', 'Carol', 'Privacy')

    alice_headers = _auth_headers(alice['access_token'])
    bob_headers = _auth_headers(bob['access_token'])
    carol_headers = _auth_headers(carol['access_token'])

    privacy = client.patch(
        '/api/users/me/settings/privacy',
        headers=alice_headers,
        json={
            'phone_visibility': 'nobody',
            'phone_search_visibility': 'nobody',
        },
    )
    assert privacy.status_code == 200, privacy.text

    allow_search = client.post(
        '/api/users/me/settings/privacy-exceptions',
        headers=alice_headers,
        json={
            'setting_key': 'phone_search_visibility',
            'mode': 'allow',
            'target_user_id': bob['user']['id'],
        },
    )
    assert allow_search.status_code == 201, allow_search.text
    assert allow_search.json()['mode'] == 'allow'
    assert allow_search.json()['user']['id'] == bob['user']['id']

    allow_visibility = client.post(
        '/api/users/me/settings/privacy-exceptions',
        headers=alice_headers,
        json={
            'setting_key': 'phone_visibility',
            'mode': 'allow',
            'target_user_id': bob['user']['id'],
        },
    )
    assert allow_visibility.status_code == 201, allow_visibility.text

    listed = client.get('/api/users/me/settings/privacy-exceptions', headers=alice_headers)
    assert listed.status_code == 200, listed.text
    assert len(listed.json()) >= 2

    bob_lookup = client.get('/api/users/lookup', headers=bob_headers, params={'q': '+79008872233'})
    assert bob_lookup.status_code == 200, bob_lookup.text
    assert bob_lookup.json()['id'] == alice['user']['id']

    carol_lookup = client.get('/api/users/lookup', headers=carol_headers, params={'q': '+79008872233'})
    assert carol_lookup.status_code == 404, carol_lookup.text

    bob_view = client.get(f"/api/users/{alice['user']['id']}", headers=bob_headers)
    assert bob_view.status_code == 200, bob_view.text
    assert bob_view.json()['phone'] == '+79008872233'

    carol_view = client.get(f"/api/users/{alice['user']['id']}", headers=carol_headers)
    assert carol_view.status_code == 200, carol_view.text
    assert carol_view.json()['phone'] is None

    disallow_bob = client.post(
        '/api/users/me/settings/privacy-exceptions',
        headers=alice_headers,
        json={
            'setting_key': 'phone_visibility',
            'mode': 'disallow',
            'target_user_id': bob['user']['id'],
        },
    )
    assert disallow_bob.status_code == 201, disallow_bob.text
    assert disallow_bob.json()['mode'] == 'disallow'

    privacy_everyone = client.patch(
        '/api/users/me/settings/privacy',
        headers=alice_headers,
        json={
            'phone_visibility': 'everyone',
            'phone_search_visibility': 'everyone',
        },
    )
    assert privacy_everyone.status_code == 200, privacy_everyone.text

    bob_view_after_disallow = client.get(f"/api/users/{alice['user']['id']}", headers=bob_headers)
    assert bob_view_after_disallow.status_code == 200, bob_view_after_disallow.text
    assert bob_view_after_disallow.json()['phone'] is None

    carol_view_after_open = client.get(f"/api/users/{alice['user']['id']}", headers=carol_headers)
    assert carol_view_after_open.status_code == 200, carol_view_after_open.text
    assert carol_view_after_open.json()['phone'] == '+79008872233'

    removed = client.delete(
        '/api/users/me/settings/privacy-exceptions',
        headers=alice_headers,
        params={
            'setting_key': 'phone_search_visibility',
            'target_user_id': bob['user']['id'],
        },
    )
    assert removed.status_code == 200, removed.text
    assert removed.json() == {'removed': True}


def test_send_when_online_dispatch_waits_for_presence(client):
    alice = _auth_by_phone(client, '+7 900 886 22 33', 'Alice', 'Schedule')
    bob = _auth_by_phone(client, '+7 900 886 22 44', 'Bob', 'Schedule')

    alice_headers = _auth_headers(alice['access_token'])
    bob_headers = _auth_headers(bob['access_token'])

    open_chat = client.post('/api/chats/private?query=%2B79008862244', headers=alice_headers)
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()['id']

    created = client.post(
        f'/api/chats/{chat_id}/scheduled-messages',
        headers=alice_headers,
        json={
            'content': 'Send when online',
            'send_when_user_online': True,
        },
    )
    assert created.status_code == 201, created.text
    scheduled_payload = created.json()
    assert scheduled_payload['send_when_user_online'] is True
    assert scheduled_payload['status'] == 'pending'

    with SessionLocal() as db:
        delivered_while_offline = dispatch_due_scheduled_messages(
            db,
            is_user_online=lambda user_id: False,
        )
    assert delivered_while_offline == []

    pending_offline = client.get(f'/api/chats/{chat_id}/scheduled-messages', headers=alice_headers)
    assert pending_offline.status_code == 200, pending_offline.text
    assert any(item['id'] == scheduled_payload['id'] for item in pending_offline.json())

    with SessionLocal() as db:
        delivered_online = dispatch_due_scheduled_messages(
            db,
            is_user_online=lambda user_id: user_id == bob['user']['id'],
        )
        assert len(delivered_online) == 1
        assert delivered_online[0].content == 'Send when online'

    pending_after = client.get(f'/api/chats/{chat_id}/scheduled-messages', headers=alice_headers)
    assert pending_after.status_code == 200, pending_after.text
    assert all(item['id'] != scheduled_payload['id'] for item in pending_after.json())

    delivered_messages = client.get(f'/api/chats/{chat_id}/messages', headers=bob_headers)
    assert delivered_messages.status_code == 200, delivered_messages.text
    assert any(item['content'] == 'Send when online' for item in delivered_messages.json())


def test_send_when_online_is_restricted_to_private_chats(client):
    alice = _auth_by_phone(client, '+7 900 885 22 33', 'Alice', 'Group')
    bob = _auth_by_phone(client, '+7 900 885 22 44', 'Bob', 'Group')

    alice_headers = _auth_headers(alice['access_token'])

    created_chat = client.post(
        '/api/chats',
        headers=alice_headers,
        json={
            'title': 'Team',
            'description': 'Group chat',
            'type': 'group',
            'member_ids': [bob['user']['id']],
        },
    )
    assert created_chat.status_code == 201, created_chat.text
    chat_id = created_chat.json()['id']

    created = client.post(
        f'/api/chats/{chat_id}/scheduled-messages',
        headers=alice_headers,
        json={
            'content': 'This should fail',
            'send_when_user_online': True,
        },
    )
    assert created.status_code == 400, created.text
    assert 'private chats' in created.json()['detail'].lower()



def test_blocking_prevents_private_chat_open_and_message_send(client):
    alice = _auth_by_phone(client, '+7 900 888 22 33', 'Alice', 'Block')
    bob = _auth_by_phone(client, '+7 900 888 22 44', 'Bob', 'Block')

    alice_headers = _auth_headers(alice['access_token'])
    bob_headers = _auth_headers(bob['access_token'])

    client.patch(
        '/api/users/me',
        headers=alice_headers,
        json={'first_name': 'Alice', 'last_name': 'Block', 'username': 'alice_block'},
    )
    client.patch(
        '/api/users/me',
        headers=bob_headers,
        json={'first_name': 'Bob', 'last_name': 'Block', 'username': 'bob_block'},
    )

    open_chat = client.post('/api/chats/private?query=alice_block', headers=bob_headers)
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()['id']

    blocked = client.post(f"/api/users/blocks/{bob['user']['id']}", headers=alice_headers)
    assert blocked.status_code == 201, blocked.text
    assert blocked.json()['user']['id'] == bob['user']['id']

    blocked_users = client.get('/api/users/blocks', headers=alice_headers)
    assert blocked_users.status_code == 200, blocked_users.text
    assert any(row['user']['id'] == bob['user']['id'] for row in blocked_users.json())

    retry_open = client.post('/api/chats/private?query=alice_block', headers=bob_headers)
    assert retry_open.status_code == 400, retry_open.text
    assert 'blocked' in retry_open.json()['detail'].lower()

    send_message = client.post(
        f'/api/chats/{chat_id}/messages',
        headers=bob_headers,
        json={'content': 'Can you see this?'},
    )
    assert send_message.status_code == 400, send_message.text
    assert 'blocked' in send_message.json()['detail'].lower()

    remove_block = client.delete(f"/api/users/blocks/{bob['user']['id']}", headers=alice_headers)
    assert remove_block.status_code == 200, remove_block.text
    assert remove_block.json() == {'removed': True}


def test_media_upload_is_idempotent_by_client_upload_id(client):
    alice = _auth_by_phone(client, "+7 900 782 22 33", "Alice", "Upload")
    bob = _auth_by_phone(client, "+7 900 782 22 44", "Bob", "Upload")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"first_name": "Alice", "last_name": "Upload"},
    )
    client.patch(
        "/api/users/me",
        headers=bob_headers,
        json={"first_name": "Bob", "last_name": "Upload", "username": "bob_upload"},
    )

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_upload')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    chat_id = open_chat.json()["id"]

    upload_headers = {**alice_headers, **_client_headers("android", "Alice Upload") }
    files = {
        "file": (
            "hello.txt",
            BytesIO(b"hello from oMsg"),
            "text/plain",
        )
    }
    first = client.post(
        f"/api/media/upload?chat_id={chat_id}&client_upload_id=upload_001",
        headers=upload_headers,
        files=files,
    )
    assert first.status_code == 201, first.text

    second = client.post(
        f"/api/media/upload?chat_id={chat_id}&client_upload_id=upload_001",
        headers=upload_headers,
        files={
            "file": (
                "hello.txt",
                BytesIO(b"hello from oMsg"),
                "text/plain",
            )
        },
    )
    assert second.status_code == 201, second.text
    assert second.json()["id"] == first.json()["id"]

    with SessionLocal() as db:
        rows = (
            db.query(MediaFile)
            .filter(
                MediaFile.chat_id == chat_id,
                MediaFile.client_upload_id == "upload_001",
            )
            .count()
        )
        assert rows == 1


def test_saved_messages_chat_flow(client):
    alice = _auth_by_phone(client, "+7 900 990 22 33", "Alice", "Saved")
    alice_headers = _auth_headers(alice["access_token"])

    client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"first_name": "Alice", "last_name": "Saved", "username": "alice_saved"},
    )

    saved_chat = client.get("/api/chats/saved", headers=alice_headers)
    assert saved_chat.status_code == 200, saved_chat.text
    payload = saved_chat.json()
    assert payload["title"] == "Saved Messages"
    assert payload["is_saved_messages"] is True
    chat_id = payload["id"]

    sent = client.post(
        f"/api/chats/{chat_id}/messages",
        headers=alice_headers,
        json={"content": "Personal note"},
    )
    assert sent.status_code == 201, sent.text

    chats = client.get("/api/chats", headers=alice_headers)
    assert chats.status_code == 200, chats.text
    row = next(item for item in chats.json() if item["id"] == chat_id)
    assert row["title"] == "Saved Messages"
    assert row["is_saved_messages"] is True
    assert row["folder"] == "personal"


def test_forward_message_to_saved_messages_preserves_source_metadata(client):
    alice = _auth_by_phone(client, "+7 900 991 22 33", "Alice", "Forward")
    bob = _auth_by_phone(client, "+7 900 991 22 44", "Bob", "Forward")

    alice_headers = _auth_headers(alice["access_token"])
    bob_headers = _auth_headers(bob["access_token"])

    client.patch(
        "/api/users/me",
        headers=alice_headers,
        json={"first_name": "Alice", "last_name": "Forward", "username": "alice_forward"},
    )
    client.patch(
        "/api/users/me",
        headers=bob_headers,
        json={"first_name": "Bob", "last_name": "Forward", "username": "bob_forward"},
    )

    open_chat = client.post(
        f"/api/chats/private?query={quote_plus('bob_forward')}",
        headers=alice_headers,
    )
    assert open_chat.status_code == 200, open_chat.text
    private_chat_id = open_chat.json()["id"]

    sent = client.post(
        f"/api/chats/{private_chat_id}/messages",
        headers=bob_headers,
        json={"content": "Forward me"},
    )
    assert sent.status_code == 201, sent.text
    source_message_id = sent.json()["id"]

    saved_chat = client.get("/api/chats/saved", headers=alice_headers)
    assert saved_chat.status_code == 200, saved_chat.text
    saved_chat_id = saved_chat.json()["id"]

    forwarded = client.post(
        f"/api/chats/{saved_chat_id}/messages",
        headers=alice_headers,
        json={"content": "", "forward_from_message_id": source_message_id},
    )
    assert forwarded.status_code == 201, forwarded.text
    assert forwarded.json()["content"] == "Forward me"
    assert forwarded.json()["forwarded_from_message_id"] == source_message_id
    assert forwarded.json()["forwarded_from_sender_name"] == "Bob Forward"
    assert forwarded.json()["forwarded_from_chat_title"] == "Bob Forward"

    saved_messages = client.get(f"/api/chats/{saved_chat_id}/messages", headers=alice_headers)
    assert saved_messages.status_code == 200, saved_messages.text
    row = next(item for item in saved_messages.json() if item["id"] == forwarded.json()["id"])
    assert row["forwarded_from_sender_name"] == "Bob Forward"
    assert row["content"] == "Forward me"
