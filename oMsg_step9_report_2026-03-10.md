# oMsg step 9 — chats & history

## Что сделано

### 1) История “для меня”
- добавлена серверная модель `message_hidden` для скрытия сообщений только для конкретного пользователя;
- `DELETE /api/chats/messages/{message_id}?scope=me` теперь скрывает сообщение только у текущего пользователя;
- обычное удаление `scope=all` осталось удалением для всех и всё ещё требует прав отправителя/админа;
- список сообщений, чат-лист, поиск и shared media теперь не показывают скрытые для пользователя сообщения.

### 2) Очистка истории чата у себя
- добавлен endpoint `POST /api/chats/{chat_id}/history/clear`;
- очистка истории не ломает историю у собеседника и не удаляет сообщения глобально;
- после очистки у пользователя обнуляется видимый history и превью последнего сообщения в chat list.

### 3) Поиск внутри текущего чата
- добавлен endpoint `GET /api/chats/{chat_id}/messages/search?q=...`;
- на клиенте появился поиск по сообщениям внутри открытого чата.

### 4) Переход к найденному сообщению с контекстом
- добавлен endpoint `GET /api/chats/{chat_id}/messages/context/{message_id}`;
- клиент теперь умеет открыть контекст вокруг найденного сообщения, подсветить его и прокрутить к нему;
- тап по preview ответа теперь тоже прыгает к исходному сообщению.

### 5) UI-улучшения в ChatScreen
- добавлена кнопка `Search in chat`;
- добавлен action `Clear history for me`;
- для удаления сообщения появился выбор:
  - `Delete for me`
  - `Delete for everyone` (для своих сообщений)
- сообщение, к которому произошёл jump, временно подсвечивается.

## Изменённые файлы
- `alembic/versions/20260310_000010_message_hidden_history.py`
- `app/models/chat.py`
- `app/schemas/chat.py`
- `app/services/chat_service.py`
- `app/api/routers/chats.py`
- `tests/test_api.py`
- `omsg_app/lib/src/models.dart`
- `omsg_app/lib/src/api.dart`
- `omsg_app/lib/src/features/chats/application/chat_view_models.dart`
- `omsg_app/lib/src/features/chats/presentation/chats_tab.dart`

## Что проверено
- `python -m compileall app tests`
- `pytest -q` → `27 passed`
- `DATABASE_URL=sqlite:////tmp/omsg_migrate.db alembic upgrade head`

## Что важно честно отметить
- Flutter/Dart SDK в этой среде отсутствует, поэтому полноценную сборку Flutter-клиента здесь не запускал;
- backend проверен реально тестами и миграцией;
- клиентская часть доведена по коду, API-контракту и UI-логике, но финальную сборку нужно проверить локально у тебя через `flutter pub get` и `flutter run`.
