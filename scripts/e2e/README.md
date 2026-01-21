# E2E curl scripts (native API)

These scripts assume SAAR is already running and that the profiles are loaded.

## Setup

```bash
export SAAR_API_KEY="<your-key>"
export SAAR_BASE_URL="http://127.0.0.1:8080"
```

## Lightrag (native HTTP profile)

Create and wait:

```bash
scripts/e2e/run.sh create-agent --profile-id lightrag --instance-id lightrag-1
scripts/e2e/run.sh wait-ready --instance-id lightrag-1 --phase ready_continuous
```

Chat interaction:

```bash
scripts/e2e/run.sh interact --instance-id lightrag-1 --capability chat --mode sync --input "hola"
```

Files upload:

```bash
scripts/e2e/run.sh interact --instance-id lightrag-1 --capability files --mode sync \
  --file-url "http://127.0.0.1:8080/health" --file-name doc.txt --file-mime text/plain
```

Clean up:

```bash
scripts/e2e/run.sh delete-agent --instance-id lightrag-1
```

## Aider (runner profile)

Create and wait:

```bash
scripts/e2e/run.sh create-agent --profile-id aider --instance-id aider-1
scripts/e2e/run.sh wait-ready --instance-id aider-1 --phase ready_transient
```

Sync interaction:

```bash
scripts/e2e/run.sh interact --instance-id aider-1 --capability chat --mode sync --input "hola"
```

Deferred interaction (if the profile capability sets response_mode=deferred):

```bash
scripts/e2e/run.sh interact --instance-id aider-1 --capability chat --mode deferred \
  --input "hola" --wait
```

Clean up:

```bash
scripts/e2e/run.sh delete-agent --instance-id aider-1
```

## Notes

- For deferred mode, the server decides the response based on the profile's
  `response_mode`. The script only controls how to handle the response.
- Use `--trace-id` to control idempotency testing in deferred flows.
