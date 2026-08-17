# DevOps & Cloud Explainer Agent

A simple **agentic** FastAPI backend that explains cloud and DevOps concepts.
It uses a **GPT model hosted on Azure OpenAI** with a **web_search** tool
(free DuckDuckGo search, no API key) so answers are grounded in live web
results instead of a hand-written knowledge base. No Anthropic key, no AWS —
everything runs on Azure.

## How it works

```
POST /ask  ──▶  agent.ask()  ──▶  Azure OpenAI Chat Completions (manual tool loop)
                                        │
                                        └─ web_search(query)  ──▶ DuckDuckGo
                                        │
                                   grounded answer (with source links)
```

- `main.py` — FastAPI app and routes (`/`, `/health`, `/ready`, `/ask`)
- `agent.py` — the agentic loop (the model decides when to search)
- `websearch.py` — free DuckDuckGo web search

## Endpoints

- `GET /health` — liveness (process is up)
- `GET /ready` — readiness: checks env vars are set and Azure is reachable
  (returns 503 if not configured)
- `POST /ask` — ask the agent a question

## Run locally

1. Create a virtual environment and install dependencies:

   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   pip install -r requirements.txt
   ```

2. Deploy a GPT model in **Azure OpenAI** (once), then set its details locally:

   - In the [Azure AI Foundry / Azure OpenAI portal](https://ai.azure.com),
     create an Azure OpenAI resource and deploy a GPT model (e.g. `gpt-4o-mini`).
     Note the **endpoint**, the **API key**, and the **deployment name** you chose.

   ```bash
   cp .env.example .env
   # edit .env and fill in:
   #   AZURE_OPENAI_ENDPOINT     (https://<your-resource>.openai.azure.com/)
   #   AZURE_OPENAI_API_KEY      (your Azure OpenAI key)
   #   AZURE_OPENAI_DEPLOYMENT   (your GPT deployment name)
   ```

3. Start the server:

   ```bash
   uvicorn main:app --reload
   ```

4. Try it:

   ```bash
   curl -s http://127.0.0.1:8000/health

   curl -s -X POST http://127.0.0.1:8000/ask \
     -H "Content-Type: application/json" \
     -d '{"question": "What is CI/CD and why does it matter?"}'
   ```

   Interactive API docs: http://127.0.0.1:8000/docs

## Containerize the backend

The app ships as a container. The `Dockerfile` here uses a multi-stage build on
`python:3.12-alpine`: the builder installs the deps into a venv, and the runtime
stage copies just that venv + the app code and runs as a **non-root** user on
**port 8000**. `.dockerignore` keeps `.env`, `.venv`, and caches out of the image.

### Build the image locally (optional — for testing on your machine)

Requires Docker Desktop running.

```bash
# from this backend/ directory
docker build -t agentic-api:local .
```

### Test the container locally before deploying

Run the image with your Azure OpenAI settings injected at runtime (never baked
into the image):

```bash
docker run --rm -p 8000:8000 --env-file .env agentic-api:local
```

Then, in another terminal, hit the same endpoints as the local run:

```bash
curl -s http://127.0.0.1:8000/health          # {"status":"healthy"}
curl -s http://127.0.0.1:8000/ready           # env + Azure reachability check

curl -s -X POST http://127.0.0.1:8000/ask \
  -H "Content-Type: application/json" \
  -d '{"question": "What is CI/CD and why does it matter?"}'
```

Docs UI: http://127.0.0.1:8000/docs. If `/ready` returns 503, your `.env` is
missing a value or the Azure OpenAI endpoint isn't reachable.

## Deploy to Azure Container Apps

The actual cloud deploy is handled by the **Terraform in [`../terraform`](../terraform)**.
You do **not** need Docker locally for it — Terraform runs a **server-side build**
with `az acr build`, which builds this `Dockerfile` inside Azure Container
Registry and pushes it, then runs it on Azure Container Apps.

```bash
az login
cd ../terraform
cp terraform.tfvars.example terraform.tfvars   # fill in Azure OpenAI values
terraform init
terraform apply                                # builds the image + provisions everything
```

The image tag is a **content hash** of this backend's source (`Dockerfile`,
`requirements.txt`, `main.py`, `agent.py`, `websearch.py`), so changing any of
those files and re-running `terraform apply` automatically rebuilds, repushes,
and rolls out a new Container App revision.

See [`../terraform/README.md`](../terraform/README.md) for the full step-by-step,
variables, and cleanup.

## Notes

- The model is a GPT model served by **Azure OpenAI** via the `AzureOpenAI`
  client — it uses your Azure OpenAI key, not an Anthropic key.
  `AZURE_OPENAI_DEPLOYMENT` must be the **deployment name** you gave the model
  in Azure OpenAI. `gpt-4o-mini` is a good low-cost default.
- CORS is open (`*`) so a browser frontend or slide demo can call it directly.
  Restrict `allow_origins` in `main.py` before any real production use.
