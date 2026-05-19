# OpenClaw + AlphaClaw + GBrain on Render

One-click Render deploy for [OpenClaw](https://github.com/openclaw/openclaw) wrapped in [AlphaClaw](https://github.com/chrysb/alphaclaw), with [GBrain](https://github.com/garrytan/gbrain) pre-installed as a skill pack so your agent has a persistent, hybrid-searchable knowledge brain from the moment it boots.

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/renderinc/openclaw-render-template-gbrain)

## What you get

- **AlphaClaw + OpenClaw**, same setup as the [base Render template](https://github.com/chrysb/openclaw-render-template): browser-based setup wizard, watchdog, in-app updates handled by Render.
- **GBrain**, a Postgres + pgvector knowledge brain with hybrid search (vector + keyword + RRF fusion + multi-query expansion).
- **All seven GBrain skills** pre-seeded into `$ALPHACLAW_ROOT_DIR/skills`: `ingest`, `query`, `maintain`, `enrich`, `briefing`, `migrate`, `install`. OpenClaw discovers them automatically on first boot.
- **Render Postgres** with `pgvector` and `pg_trgm` enabled. Single-vendor: no external Supabase account, one billing line, one dashboard.

## What this template provisions

| Resource | Plan | Notes |
| --- | --- | --- |
| Web service (Docker) | Standard (2 GB) | AlphaClaw + OpenClaw + GBrain CLI. Standard is the minimum that fits the gateway without OOM. |
| Postgres | Basic-256mb | 256 MB RAM, 1 GB storage. Fine for a few thousand pages. Upgrade if your brain is large. |
| Persistent disk | 10 GB at `/data` | AlphaClaw state, OpenClaw memory index, GBrain local config. |

Estimated cost: about $32/mo for Standard web + Basic-256mb Postgres at current Render pricing. Compare to AlphaClaw on Railway + Supabase Pro at ~$85/mo + $25/mo. Check [render.com/pricing](https://render.com/pricing) for current rates.

## Before you deploy

You need two API keys:

| Key | Used by | Where to get it |
| --- | --- | --- |
| `OPENAI_API_KEY` | GBrain embeddings (`text-embedding-3-large`) | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| `ANTHROPIC_API_KEY` | GBrain multi-query expansion + LLM chunking (Haiku) | [console.anthropic.com](https://console.anthropic.com) |

Both are required by this template's entrypoint. If you want to run GBrain in degraded mode (keyword search only, no embeddings), remove the `require_env` checks in `entrypoint.sh` before deploying.

Initial embedding cost is roughly $4-5 per 7,500 pages.

## Deploy

1. Click the **Deploy to Render** button above.
2. Render provisions the Postgres database and the web service from `render.yaml`.
3. On the web service config screen, fill in `OPENAI_API_KEY` and `ANTHROPIC_API_KEY`. `SETUP_PASSWORD` and `OPENCLAW_GATEWAY_TOKEN` are generated automatically.
4. Wait for the first deploy. The entrypoint will:
   1. Enable `vector` and `pg_trgm` on Postgres.
   2. Run `gbrain init` to apply the schema migration.
   3. Seed the seven GBrain skills into `/data/skills`.
   4. Start AlphaClaw.
5. Visit your Render URL, enter `SETUP_PASSWORD`, and complete the AlphaClaw welcome wizard.

## First conversation with your brain

Once the welcome wizard finishes, your agent already knows how to use GBrain. Try:

```
You: How many pages are in the brain right now?
You: Import the markdown files at <some path on the disk or a git repo>
You: Search the brain for everything we know about <topic>
You: Give me a briefing for tomorrow
```

OpenClaw reads the skill files in `/data/skills`, picks the right `gbrain` command, and runs it. You do not need to touch the CLI.

## Importing your existing knowledge base

GBrain is designed to ingest your existing markdown. Two patterns work well on Render:

**Option A: paste in chat.** Drop markdown into AlphaClaw's chat; the `ingest` skill writes it to the brain.

**Option B: git pull on the persistent disk.** SSH into the service (`render ssh`) and clone your knowledge repo into `/data/repos/<name>`, then in chat: "Import the markdown at `/data/repos/<name>`." The `install` skill handles `gbrain sync --watch` setup if you want incremental sync.

Binary attachments (images, PDFs, audio) are not supported on this template. GBrain's `files` commands assume Supabase Storage; we would need to add Render Object Storage support upstream to wire those up. Text-only is the v1 scope.

## What is in the box

```
.
├── render.yaml         # Render Blueprint: web service + Postgres + disk
├── Dockerfile          # AlphaClaw (Node) + GBrain (Bun) + psql
├── entrypoint.sh       # pgvector setup, gbrain init, skills seed, exec alphaclaw
├── package.json        # Pins @chrysb/alphaclaw
└── README.md
```

The skills themselves are not committed here. They are extracted from the `gbrain` npm package at Docker build time and staged into `/app/skills-seed`, then copied to `/data/skills` on first boot. This way the skills always match the GBrain version you are running.

## Updating

- **AlphaClaw / OpenClaw**: In-app updates are disabled for Render-managed deploys as of AlphaClaw 0.9.0. Bump `@chrysb/alphaclaw` in `package.json` and redeploy.
- **GBrain**: The image installs `gbrain` globally at build time. To upgrade, redeploy from main (which pulls the latest `gbrain` from npm) or pin a version with `bun add -g gbrain@<version>` in the Dockerfile.
- **Schema migrations**: `gbrain init` is idempotent. The entrypoint runs it only on first boot, but you can re-run it manually via `render ssh` if a GBrain upgrade ships a migration.

## Troubleshooting

**Container OOMs on startup.** The Standard plan (2 GB) is the floor for OpenClaw's gateway. Do not downgrade to Starter.

**`gbrain init` fails with `permission denied for extension`.** Render Postgres permits `CREATE EXTENSION` for `vector` and `pg_trgm` on user databases, but only against the database owner. Confirm `DATABASE_URL` is pointing at the `gbrain` database, not `postgres`.

**Embeddings stuck at 0.** Check the service logs for OpenAI rate limit errors. GBrain backs off automatically. If `OPENAI_API_KEY` is missing or invalid, search still works in keyword-only mode.

**Skills not appearing in OpenClaw.** Confirm `/data/skills` is populated after first boot (`render ssh` into the service and `ls /data/skills`). The entrypoint uses `cp -rn` so it will never overwrite user edits, but it also will not re-seed if the directory exists.

## Limitations

- **Binary attachments**: not supported. GBrain's `files` subsystem expects Supabase Storage.
- **Multi-region**: this template deploys to `oregon`. Change `region` in `render.yaml` if you need a different region; the disk and Postgres must match the service.
- **Backup**: AlphaClaw handles disk backups via cron; Render Postgres backups are managed by Render. Verify both are working before you put real knowledge into the brain.

## License

MIT for the template itself. AlphaClaw, OpenClaw, and GBrain each ship under their own licenses (MIT at last check). See upstream repos.
