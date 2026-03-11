# oMsg step13 report — 2026-03-11

## Что сделано

Этот этап добивает более Telegram-подобный **media composer** перед отправкой:

- добавлен отдельный **preview-режим вложений до отправки**;
- вложения в composer теперь можно **переставлять drag-and-drop** прямо в горизонтальной ленте;
- по тапу на вложение открывается отдельный **media editor / preview page**;
- внутри preview page можно:
  - листать выбранные вложения;
  - видеть текущий порядок в альбоме;
  - **перемещать текущее вложение влево/вправо**;
  - **удалять** вложение из альбома до отправки;
- composer показывает более явный album-oriented UX:
  - `Album • N items` для медиа-пачек;
  - отдельную подсказку про reorder / preview;
  - отдельную кнопку `Preview`.

## Какие файлы изменены

- `omsg_app/lib/src/features/chats/presentation/chats_tab.dart`

## Что проверено

- `python -m compileall app scripts tests`
- `pytest -q` → `29 passed`

## Что важно отметить

- Это в основном **клиентский UX-этап**: backend API не ломался.
- В этой среде не было Flutter/Dart SDK, поэтому полноценная Flutter-сборка не запускалась.
- Архитектурно шаг безопасный: порядок отправки вложений теперь следует текущему порядку `_pendingAttachments`, а preview/editor меняет именно этот порядок.

## Логичный следующий шаг

- сделать **общую caption composer page для альбома** с более телеграмным pre-send flow;
- добавить **mixed photo/video album layout** ещё ближе к Telegram;
- добить **upload jobs manager** с pause/cancel/resume и видимым прогрессом пачки.
