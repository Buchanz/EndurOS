# EndurOS Backend (MVP)

## Stack
- Node.js + TypeScript + Express
- Supabase (Postgres)

## 1) Environment
Create `.env` in this folder from `.env.example`.

Required keys:
- `SUPABASE_URL`: Supabase project URL
- `SUPABASE_SERVICE_ROLE_KEY`: Supabase service role key (server-only)
- `PORT`: API port (default `4000`)

Where to find Supabase keys:
- Supabase dashboard -> Project Settings -> API

## 2) Create DB schema
In Supabase SQL Editor, run:
- `supabase/schema.sql`

## 3) Install + run
```bash
npm install
npm run dev
```

Server health:
- `GET http://localhost:4000/api/health`

## 4) MVP endpoints
- `POST /api/sessions`
- `POST /api/sessions/:sessionId/samples`
- `GET /api/athletes/:athleteId/sessions`

## Notes
- Do not expose `SUPABASE_SERVICE_ROLE_KEY` in mobile/watch clients.
- Watch/iPhone should call your backend only, never direct service-role writes.
