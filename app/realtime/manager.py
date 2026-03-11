from collections import defaultdict

from fastapi import WebSocket


class ChatConnectionManager:
    def __init__(self) -> None:
        self._connections: dict[int, dict[WebSocket, int]] = defaultdict(dict)

    async def connect(
        self,
        chat_id: int,
        websocket: WebSocket,
        user_id: int,
        *,
        accept_socket: bool = True,
    ) -> bool:
        sockets = self._connections[chat_id]
        had_user = user_id in sockets.values()
        if accept_socket:
            await websocket.accept()
        sockets[websocket] = user_id
        return not had_user

    def disconnect(self, chat_id: int, websocket: WebSocket) -> tuple[int | None, bool]:
        sockets = self._connections.get(chat_id)
        if not sockets:
            return None, False

        user_id = sockets.pop(websocket, None)
        if user_id is None:
            return None, False

        is_last_for_user = user_id not in sockets.values()
        if not sockets:
            del self._connections[chat_id]
        return user_id, is_last_for_user

    def has_user(self, user_id: int) -> bool:
        if user_id <= 0:
            return False
        return any(user_id in sockets.values() for sockets in self._connections.values())

    async def broadcast(
        self,
        chat_id: int,
        payload: dict,
        *,
        exclude: WebSocket | None = None,
    ) -> None:
        dead_connections: list[WebSocket] = []
        sockets = self._connections.get(chat_id, {})
        for socket in sockets:
            if exclude is not None and socket == exclude:
                continue
            try:
                await socket.send_json(payload)
            except Exception:
                dead_connections.append(socket)

        for socket in dead_connections:
            self.disconnect(chat_id, socket)


chat_manager = ChatConnectionManager()


class UserConnectionManager:
    def __init__(self) -> None:
        self._connections: dict[int, set[WebSocket]] = defaultdict(set)

    async def connect(
        self,
        user_id: int,
        websocket: WebSocket,
        *,
        accept_socket: bool = True,
    ) -> bool:
        sockets = self._connections[user_id]
        is_first_connection = not sockets
        if accept_socket:
            await websocket.accept()
        sockets.add(websocket)
        return is_first_connection

    def disconnect(self, user_id: int, websocket: WebSocket) -> tuple[bool, bool]:
        sockets = self._connections.get(user_id)
        if not sockets:
            return False, False

        was_connected = websocket in sockets
        sockets.discard(websocket)
        if not sockets:
            del self._connections[user_id]
            return was_connected, True
        return was_connected, False

    def is_online(self, user_id: int) -> bool:
        return bool(self._connections.get(user_id))

    async def broadcast(self, user_id: int, payload: dict) -> None:
        dead_connections: list[WebSocket] = []
        sockets = self._connections.get(user_id, set())
        for socket in sockets:
            try:
                await socket.send_json(payload)
            except Exception:
                dead_connections.append(socket)

        for socket in dead_connections:
            self.disconnect(user_id, socket)

    async def broadcast_many(self, user_ids: set[int], payload: dict) -> None:
        for user_id in user_ids:
            await self.broadcast(user_id, payload)


user_realtime_manager = UserConnectionManager()


def is_user_online(user_id: int) -> bool:
    return user_realtime_manager.is_online(user_id) or chat_manager.has_user(user_id)
