from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.api.deps import get_db
from app.schemas.user import PublicUserProfile
from app.services.user_service import find_user_by_username

router = APIRouter(prefix="/public", tags=["Public"])


@router.get("/users/{username}", response_model=PublicUserProfile)
def public_user_profile(
    username: str,
    db: Session = Depends(get_db),
) -> PublicUserProfile:
    user = find_user_by_username(db, username)
    if not user or not user.username:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Public profile not found",
        )
    return PublicUserProfile.model_validate(user)
