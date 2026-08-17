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

## Deploy to Azure (no CI/CD)

Deploy straight to **Azure App Service** from your machine with the Azure CLI.

1. Log in and create the app (Linux, Python 3.12):

   ```bash
   az login

   az group create --name devops-agent-rg --location eastus

   az appservice plan create \
     --name devops-agent-plan \
     --resource-group devops-agent-rg \
     --sku B1 --is-linux

   az webapp create \
     --resource-group devops-agent-rg \
     --plan devops-agent-plan \
     --name <your-unique-app-name> \
     --runtime "PYTHON:3.12"
   ```

2. Set the Azure OpenAI settings and startup command:

   ```bash
   az webapp config appsettings set \
     --resource-group devops-agent-rg \
     --name <your-unique-app-name> \
     --settings \
       AZURE_OPENAI_ENDPOINT="https://your-resource.openai.azure.com/" \
       AZURE_OPENAI_API_KEY="your-azure-openai-key" \
       AZURE_OPENAI_DEPLOYMENT="your-gpt-deployment-name"

   az webapp config set \
     --resource-group devops-agent-rg \
     --name <your-unique-app-name> \
     --startup-file "python -m uvicorn main:app --host 0.0.0.0 --port 8000"
   ```

3. Deploy the code from this folder:

   ```bash
   az webapp up \
     --resource-group devops-agent-rg \
     --name <your-unique-app-name> \
     --runtime "PYTHON:3.12"
   ```

   > `az webapp up` zips the current directory and deploys it — no pipeline
   > required. Re-run it any time you change the code.

4. Your API is live at `https://<your-unique-app-name>.azurewebsites.net`
   (check `/health` and `/docs`).

## Notes

- The model is a GPT model served by **Azure OpenAI** via the `AzureOpenAI`
  client — it uses your Azure OpenAI key, not an Anthropic key.
  `AZURE_OPENAI_DEPLOYMENT` must be the **deployment name** you gave the model
  in Azure OpenAI. `gpt-4o-mini` is a good low-cost default.
- CORS is open (`*`) so a browser frontend or slide demo can call it directly.
  Restrict `allow_origins` in `main.py` before any real production use.
