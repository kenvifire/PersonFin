from fastapi import FastAPI

from app.routers import accounts, auth

app = FastAPI(title="PersonFin")

app.include_router(auth.router)
app.include_router(accounts.router)


@app.get("/health")
def health_check() -> dict[str, str]:
    return {"status": "ok"}
