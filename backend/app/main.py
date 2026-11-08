import math
from typing import Any

from fastapi import FastAPI, Request, status
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.routers import accounts, auth, dashboard, insights, snapshots, targets, todos, uploads
from app.services.fx import FXRateUnavailable
from app.services.image_storage import UnsupportedUploadError

FX_UNAVAILABLE_DETAIL = "Exchange rate temporarily unavailable, try again shortly"

app = FastAPI(title="PersonFin")

app.include_router(auth.router)
app.include_router(accounts.router)
app.include_router(snapshots.router)
app.include_router(dashboard.router)
app.include_router(targets.router)
app.include_router(insights.router)
app.include_router(todos.router)
app.include_router(uploads.router)


@app.exception_handler(FXRateUnavailable)
async def fx_rate_unavailable_handler(request: Request, exc: FXRateUnavailable) -> JSONResponse:
    """An upstream FX outage is a transient dependency failure, not a bug:
    surface it as 503 with a clear message instead of a bare 500."""
    return JSONResponse(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        content={"detail": FX_UNAVAILABLE_DETAIL},
    )


@app.exception_handler(UnsupportedUploadError)
async def unsupported_upload_handler(request: Request, exc: UnsupportedUploadError) -> JSONResponse:
    """A bad MIME type or oversized file is a client error, not a bug:
    surface it as 422 with a message explaining which check failed."""
    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        content={"detail": str(exc)},
    )


def _json_safe(value: Any) -> Any:
    """Replace non-finite floats (which strict JSON can't represent) with
    their string form, recursively."""
    if isinstance(value, float) and not math.isfinite(value):
        return str(value)
    if isinstance(value, dict):
        return {key: _json_safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_json_safe(item) for item in value]
    return value


@app.exception_handler(RequestValidationError)
async def request_validation_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    """Same 422 body as FastAPI's default handler, except that a rejected
    `Infinity`/`NaN` input echoed back in the error details is rendered
    as a string. Otherwise serializing the 422 itself fails (JSON has no
    inf/nan) and the client gets a 500 instead."""
    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        content={"detail": _json_safe(jsonable_encoder(exc.errors()))},
    )


@app.get("/health")
def health_check() -> dict[str, str]:
    return {"status": "ok"}
