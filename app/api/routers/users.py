from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_db
from app.models.user import PrivacySettingKey, User
from app.schemas.user import (
    BlockedUserOut,
    ProfileUpdate,
    UserDataSettingsOut,
    UserDataSettingsUpdate,
    UserPrivacyExceptionCreate,
    UserPrivacyExceptionOut,
    UserPrivacySettingsOut,
    UserPrivacySettingsUpdate,
    UserPublic,
    UserSettingsOut,
    UsernameCheckOut,
)
from app.services.user_service import (
    USERNAME_RULES_MESSAGE,
    block_user,
    ensure_username_available,
    find_user_by_phone_or_username,
    get_blocked_user_count,
    get_or_create_data_settings,
    get_or_create_privacy_settings,
    is_probable_phone,
    list_blocked_users,
    list_privacy_exceptions,
    normalize_phone,
    normalize_username,
    remove_privacy_exception,
    search_users,
    serialize_user_public,
    unblock_user,
    upsert_privacy_exception,
    validate_username,
)

router = APIRouter(prefix="/users", tags=["Users"])


def _serialize_privacy_exception_row(
    db: Session,
    row,
    *,
    viewer_user_id: int,
) -> UserPrivacyExceptionOut | None:
    target = db.scalar(select(User).where(User.id == row.target_user_id))
    if target is None:
        return None
    return UserPrivacyExceptionOut(
        id=row.id,
        setting_key=row.setting_key,
        mode=row.mode,
        target_user_id=row.target_user_id,
        user=serialize_user_public(
            db,
            target,
            viewer_user_id=viewer_user_id,
            include_private_fields=False,
        ),
        created_at=row.created_at,
    )


@router.get("/me", response_model=UserPublic)
def me(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserPublic:
    return serialize_user_public(
        db,
        current_user,
        viewer_user_id=current_user.id,
        include_private_fields=True,
    )


@router.patch("/me", response_model=UserPublic)
def update_me(
    payload: ProfileUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserPublic:
    if payload.bio is not None:
        current_user.bio = payload.bio
    if payload.avatar_url is not None:
        current_user.avatar_url = payload.avatar_url
    if payload.first_name is not None:
        current_user.first_name = payload.first_name.strip()
    if payload.last_name is not None:
        current_user.last_name = payload.last_name.strip()

    if "username" in payload.model_fields_set:
        requested_username = (payload.username or "").strip()
        if not requested_username:
            current_user.username = None
        else:
            normalized_username = normalize_username(requested_username)
            if not validate_username(normalized_username):
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=USERNAME_RULES_MESSAGE,
                )
            try:
                ensure_username_available(db, normalized_username, current_user_id=current_user.id)
            except ValueError as exc:
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
            current_user.username = normalized_username

    db.add(current_user)
    db.commit()
    db.refresh(current_user)
    return serialize_user_public(
        db,
        current_user,
        viewer_user_id=current_user.id,
        include_private_fields=True,
    )


@router.get("/me/settings", response_model=UserSettingsOut)
def get_my_settings(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserSettingsOut:
    privacy = get_or_create_privacy_settings(db, current_user.id)
    data_settings = get_or_create_data_settings(db, current_user.id)
    return UserSettingsOut(
        privacy=UserPrivacySettingsOut.model_validate(privacy),
        data_storage=UserDataSettingsOut.model_validate(data_settings),
        blocked_users_count=get_blocked_user_count(db, current_user.id),
    )


@router.patch("/me/settings/privacy", response_model=UserPrivacySettingsOut)
def update_my_privacy_settings(
    payload: UserPrivacySettingsUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserPrivacySettingsOut:
    settings = get_or_create_privacy_settings(db, current_user.id)
    for field in payload.model_fields_set:
        setattr(settings, field, getattr(payload, field))
    db.add(settings)
    db.commit()
    db.refresh(settings)
    return UserPrivacySettingsOut.model_validate(settings)


@router.patch("/me/settings/data-storage", response_model=UserDataSettingsOut)
def update_my_data_settings(
    payload: UserDataSettingsUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserDataSettingsOut:
    settings = get_or_create_data_settings(db, current_user.id)
    for field in payload.model_fields_set:
        value = getattr(payload, field)
        if field == "default_auto_delete_seconds" and value == 0:
            value = None
        setattr(settings, field, value)
    db.add(settings)
    db.commit()
    db.refresh(settings)
    return UserDataSettingsOut.model_validate(settings)


@router.get("/me/settings/privacy-exceptions", response_model=list[UserPrivacyExceptionOut])
def get_my_privacy_exceptions(
    setting_key: PrivacySettingKey | None = Query(default=None),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[UserPrivacyExceptionOut]:
    rows = list_privacy_exceptions(db, user_id=current_user.id, setting_key=setting_key)
    output: list[UserPrivacyExceptionOut] = []
    for row in rows:
        serialized = _serialize_privacy_exception_row(db, row, viewer_user_id=current_user.id)
        if serialized is not None:
            output.append(serialized)
    return output


@router.post(
    "/me/settings/privacy-exceptions",
    response_model=UserPrivacyExceptionOut,
    status_code=status.HTTP_201_CREATED,
)
def add_my_privacy_exception(
    payload: UserPrivacyExceptionCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserPrivacyExceptionOut:
    try:
        row = upsert_privacy_exception(
            db,
            user_id=current_user.id,
            setting_key=payload.setting_key,
            mode=payload.mode,
            target_user_id=payload.target_user_id,
        )
    except ValueError as exc:
        detail = str(exc)
        status_code = status.HTTP_404_NOT_FOUND if detail == "User not found" else status.HTTP_400_BAD_REQUEST
        raise HTTPException(status_code=status_code, detail=detail) from exc

    serialized = _serialize_privacy_exception_row(db, row, viewer_user_id=current_user.id)
    if serialized is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    return serialized


@router.delete("/me/settings/privacy-exceptions")
def delete_my_privacy_exception(
    setting_key: PrivacySettingKey = Query(...),
    target_user_id: int = Query(..., gt=0),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    removed = remove_privacy_exception(
        db,
        user_id=current_user.id,
        setting_key=setting_key,
        target_user_id=target_user_id,
    )
    return {"removed": removed}


@router.get("/blocks", response_model=list[BlockedUserOut])
def get_blocked_users(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[BlockedUserOut]:
    rows = list_blocked_users(db, current_user.id)
    output: list[BlockedUserOut] = []
    for row in rows:
        blocked = db.scalar(select(User).where(User.id == row.blocked_id))
        if blocked is None:
            continue
        output.append(
            BlockedUserOut(
                user=serialize_user_public(
                    db,
                    blocked,
                    viewer_user_id=current_user.id,
                    include_private_fields=False,
                ),
                blocked_at=row.created_at,
            )
        )
    return output


@router.post("/blocks/{user_id}", response_model=BlockedUserOut, status_code=status.HTTP_201_CREATED)
def add_blocked_user(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> BlockedUserOut:
    try:
        row = block_user(db, blocker_id=current_user.id, blocked_id=user_id)
    except ValueError as exc:
        detail = str(exc)
        status_code = status.HTTP_404_NOT_FOUND if detail == "User not found" else status.HTTP_400_BAD_REQUEST
        raise HTTPException(status_code=status_code, detail=detail) from exc

    blocked = db.scalar(select(User).where(User.id == row.blocked_id))
    if blocked is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    return BlockedUserOut(
        user=serialize_user_public(db, blocked, viewer_user_id=current_user.id),
        blocked_at=row.created_at,
    )


@router.delete("/blocks/{user_id}")
def remove_blocked_user(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict:
    removed = unblock_user(db, blocker_id=current_user.id, blocked_id=user_id)
    return {"removed": removed}


@router.get("/username-check", response_model=UsernameCheckOut)
def username_check(
    username: str = Query(..., min_length=1, max_length=40),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UsernameCheckOut:
    normalized_username = normalize_username(username)
    if not validate_username(normalized_username):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=USERNAME_RULES_MESSAGE,
        )
    try:
        ensure_username_available(db, normalized_username, current_user_id=current_user.id)
    except ValueError:
        return UsernameCheckOut(username=normalized_username, available=False)
    return UsernameCheckOut(username=normalized_username, available=True)


@router.get("/search", response_model=list[UserPublic])
def search(
    q: str = Query(..., min_length=1, max_length=120),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[UserPublic]:
    users = search_users(db, q, viewer_user_id=current_user.id)
    return [serialize_user_public(db, user, viewer_user_id=current_user.id) for user in users]


@router.get("/lookup", response_model=UserPublic)
def lookup_user(
    q: str = Query(..., min_length=3, max_length=120),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserPublic:
    user = find_user_by_phone_or_username(db, q, viewer_user_id=current_user.id)
    if user:
        return serialize_user_public(db, user, viewer_user_id=current_user.id)

    if is_probable_phone(q):
        try:
            normalized = normalize_phone(q)
        except ValueError:
            normalized = q
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"User with phone {normalized} not found")

    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")


@router.get("/{user_id}", response_model=UserPublic)
def get_user_by_id(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserPublic:
    user = db.scalar(select(User).where(User.id == user_id))
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    return serialize_user_public(db, user, viewer_user_id=current_user.id)
