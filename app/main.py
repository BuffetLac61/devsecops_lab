import os
from pathlib import Path

import psycopg
from fastapi import FastAPI, HTTPException

app = FastAPI(title="devsecops-lab")


def read_setting(name: str, default: str | None = None) -> str | None:
    """Lit la variable NAME, ou le fichier indiqué par NAME_FILE (secret monté)."""
    file_path = os.getenv(f"{name}_FILE")
    if file_path:
        return Path(file_path).read_text().strip()
    return os.getenv(name, default)


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/db")
def db() -> dict:
    try:
        with psycopg.connect(
            host=read_setting("DB_HOST", "postgres"),
            port=int(read_setting("DB_PORT", "5432")),
            dbname=read_setting("DB_NAME", "app"),
            user=read_setting("DB_USER"),
            password=read_setting("DB_PASSWORD"),
            connect_timeout=3,
        ) as conn:
            user = conn.execute("SELECT current_user").fetchone()[0]
    except psycopg.Error as exc:
        # On ne renvoie jamais le détail de l'erreur : il peut révéler l'hôte ou l'utilisateur.
        raise HTTPException(status_code=503, detail="database unavailable") from exc
    # connected_as sert en DJ2 : on y verra l'utilisateur éphémère créé par Vault.
    return {"database": "ok", "connected_as": user}
