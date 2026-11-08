from fastapi import FastAPI

from app.routers import accounts, auth, dashboard, snapshots, targets

app = FastAPI(title="PersonFin")

app.include_router(auth.router)
app.include_router(accounts.router)
app.include_router(snapshots.router)
app.include_router(dashboard.router)
app.include_router(targets.router)


@app.get("/health")
def health_check() -> dict[str, str]:
    return {"status": "ok"}
