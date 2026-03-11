from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy.orm import Session

from app.api.deps import get_current_session, get_current_user, get_db
from app.models.user import RefreshToken, User
from app.schemas.auth import (
    AuthSessionOut,
    LoginRequest,
    PhoneCodeRequest,
    PhoneCodeResponse,
    PhoneCodeVerifyRequest,
    RefreshRequest,
    RegisterRequest,
    RevokeSessionsOut,
    TokenResponse,
)
from app.services.auth_service import (
    authenticate_user,
    build_client_context,
    build_token_response,
    list_active_sessions,
    request_phone_login_code,
    register_user,
    revoke_other_sessions,
    revoke_refresh_token,
    revoke_session_by_key,
    rotate_refresh_token,
    verify_phone_login_code,
)

router = APIRouter(prefix="/auth", tags=["Auth"])


def _request_ip(request: Request) -> str | None:
    forwarded_for = request.headers.get("x-forwarded-for", "").strip()
    if forwarded_for:
        return forwarded_for.split(",", 1)[0].strip() or None
    if request.client is None:
        return None
    return request.client.host


def _client_context_from_request(request: Request):
    return build_client_context(
        user_agent=request.headers.get("user-agent"),
        ip_address=_request_ip(request),
        platform=request.headers.get("x-omsg-client-platform"),
        device_name=request.headers.get("x-omsg-device-name"),
    )


@router.post("/request-code", response_model=PhoneCodeResponse)
def request_code(payload: PhoneCodeRequest, db: Session = Depends(get_db)) -> PhoneCodeResponse:
    try:
        return request_phone_login_code(db, payload.phone)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc


@router.post("/verify-code", response_model=TokenResponse)
def verify_code(
    payload: PhoneCodeVerifyRequest,
    request: Request,
    db: Session = Depends(get_db),
) -> TokenResponse:
    try:
        user, needs_profile_setup = verify_phone_login_code(db, payload)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    if not user.first_name.strip():
        needs_profile_setup = True
    return build_token_response(
        db,
        user,
        needs_profile_setup=needs_profile_setup,
        client_context=_client_context_from_request(request),
    )


@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
def register(
    payload: RegisterRequest,
    request: Request,
    db: Session = Depends(get_db),
) -> TokenResponse:
    try:
        user = register_user(db, payload)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    return build_token_response(db, user, client_context=_client_context_from_request(request))


@router.post("/login", response_model=TokenResponse)
def login(
    payload: LoginRequest,
    request: Request,
    db: Session = Depends(get_db),
) -> TokenResponse:
    user = authenticate_user(db, login=payload.login, password=payload.password)
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid login or password")
    return build_token_response(db, user, client_context=_client_context_from_request(request))


@router.post("/refresh", response_model=TokenResponse)
def refresh(
    payload: RefreshRequest,
    request: Request,
    db: Session = Depends(get_db),
) -> TokenResponse:
    try:
        return rotate_refresh_token(
            db,
            payload.refresh_token,
            client_context=_client_context_from_request(request),
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc


@router.post("/logout")
def logout(payload: RefreshRequest, db: Session = Depends(get_db)) -> dict[str, bool]:
    revoked = revoke_refresh_token(db, payload.refresh_token)
    return {"revoked": revoked}


@router.get("/sessions", response_model=list[AuthSessionOut])
def sessions(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    current_session: RefreshToken | None = Depends(get_current_session),
) -> list[AuthSessionOut]:
    return list_active_sessions(
        db,
        user_id=current_user.id,
        current_session_id=current_session.id if current_session is not None else None,
    )


@router.delete("/sessions/{session_id}")
def delete_session(
    session_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    current_session: RefreshToken | None = Depends(get_current_session),
) -> dict[str, bool]:
    try:
        removed = revoke_session_by_key(
            db,
            user_id=current_user.id,
            session_key=session_id,
            current_session_key=current_session.session_key if current_session is not None else None,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    return {"removed": removed}


@router.post("/sessions/revoke-others", response_model=RevokeSessionsOut)
def delete_other_sessions(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    current_session: RefreshToken | None = Depends(get_current_session),
) -> RevokeSessionsOut:
    revoked = revoke_other_sessions(
        db,
        user_id=current_user.id,
        current_session_key=current_session.session_key if current_session is not None else None,
    )
    return RevokeSessionsOut(revoked=revoked)
