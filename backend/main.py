"""FastAPI backend for the DevOps & cloud explainer agent.

Run locally:
    uvicorn main:app --reload

Endpoints:
    GET  /            -> service info
    GET  /health      -> health check
    GET  /topics      -> list knowledge-base topics
    POST /ask         -> ask the agent a question
"""

from dotenv import load_dotenv

load_dotenv()  # load ANTHROPIC_API_KEY from a local .env if present

import os

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

import agent

REQUIRED_ENV = [
    "AZURE_OPENAI_ENDPOINT",
    "AZURE_OPENAI_API_KEY",
    "AZURE_OPENAI_DEPLOYMENT",
]

app = FastAPI(
    title="DevOps & Cloud Explainer Agent",
    description="A simple agentic API that explains cloud and DevOps concepts.",
    version="1.0.0",
)

# Open CORS so a browser frontend (or the PPT demo) can call the API directly.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class AskRequest(BaseModel):
    question: str = Field(..., min_length=1, max_length=2000)


class AskResponse(BaseModel):
    question: str
    answer: str


@app.get("/")
def root():
    return {
        "service": "DevOps & Cloud Explainer Agent",
        "status": "ok",
        "docs": "/docs",
        "ask": "POST /ask with {\"question\": \"...\"}",
    }


@app.get("/health")
def health():
    """Liveness — the process is up. Always 200 while the server runs."""
    return {"status": "healthy"}


@app.get("/ready")
def ready():
    """Readiness — verify required env vars are set and Azure is reachable."""
    missing = [v for v in REQUIRED_ENV if not os.environ.get(v)]
    endpoint = os.environ.get("AZURE_OPENAI_ENDPOINT")

    endpoint_reachable: bool | None = None
    reachable_error: str | None = None
    if endpoint:
        try:
            # Any HTTP response (even 401/404) proves the host is reachable.
            httpx.get(endpoint, timeout=5.0)
            endpoint_reachable = True
        except Exception as exc:
            endpoint_reachable = False
            reachable_error = str(exc)[:200]

    ok = not missing and endpoint_reachable is True
    body: dict = {
        "ready": ok,
        "env_set": {v: bool(os.environ.get(v)) for v in REQUIRED_ENV},
        "missing_env": missing,
        "deployment": os.environ.get("AZURE_OPENAI_DEPLOYMENT"),
        "endpoint_reachable": endpoint_reachable,
    }
    if reachable_error:
        body["reachable_error"] = reachable_error
    return JSONResponse(status_code=200 if ok else 503, content=body)


@app.post("/ask", response_model=AskResponse)
def ask(req: AskRequest):
    try:
        answer = agent.ask(req.question)
    except Exception as exc:  # surface a clean error to the caller
        raise HTTPException(status_code=502, detail=f"Agent error: {exc}") from exc
    return AskResponse(question=req.question, answer=answer)
