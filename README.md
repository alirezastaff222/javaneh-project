# javaneh-project

## Application and deployment configuration

The application uses Next.js defaults on Vercel (`npm run build`); no custom
Vercel build configuration or production URL is checked in.

Configure these values in `.env.local` for development and in the matching
Vercel environment scopes for deployment:

| Variable | Scope | Requirement |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Public | Required for authentication and database access |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Public | Required for authentication and database access |
| `NEXT_PUBLIC_SITE_URL` | Public | Set to the canonical site origin for email confirmation; if omitted, the current browser origin is used |
| `SUPABASE_SERVICE_ROLE_KEY` | Server only | Required for mentor circuit-breaker and classification operations; never expose to browser code |
| `GOOGLE_GENERATIVE_AI_API_KEY` | Server only | Required to enable AI mentor and classification provider calls |
| `AI_MENTOR_MODEL` | Server only | Optional; defaults to `gemini-3.8-flash` |

`NEXT_PUBLIC_SITE_URL` must be an HTTPS origin without a path, query, or
fragment. For local development, use `http://localhost:3000`. Set the
corresponding origin as the Supabase Auth Site URL and allow the exact callback
URL `<site-origin>/auth/callback` in Supabase Auth redirect URLs. Add preview
origins only when they are needed; do not use broad production wildcards.

Copy the variable names (not secret values) from [`.env.example`](./.env.example).
Keep service-role and AI-provider credentials server-only and out of client
bundles, source control, build logs, and support reports.

The production database is not verified from this checkout. Before applying
any production migration, follow the inventory and recovery procedure in
[`supabase/README.md`](./supabase/README.md) and run
[`supabase/operations/production-inventory.sql`](./supabase/operations/production-inventory.sql)
in the Supabase SQL Editor. Do not claim the app is database-ready until the
real project has been inventoried, migrated safely, and exercised end-to-end.

## Group participation

An authenticated account can continue creating individual ideas and may also
create or join multiple groups. Group ideas have a shared three-idea quota,
are editable by accepted members, and can only be finally submitted or
permanently deleted by the current group owner. Ownership transfer is
restricted to an accepted member; the owner cannot leave without transferring
ownership. Dissolved groups remain available to their members for history
viewing but cannot accept new ideas or edits.

Email invitations are bound to a normalized email address, require the
recipient to sign in with that address, and expire after seven days. The
current deployment has no configured transactional email provider for group
invitations, so the owner sends the generated invitation link using the
provided email action. A group idea's development points are attributed to the
group, not copied to each member; the existing validation and scoring ledger
remain authoritative.

Apply
[`20261108000000_javaneh_group_participation.sql`](./supabase/migrations/20261108000000_javaneh_group_participation.sql)
only after comparing the production inventory with the complete migration
history and confirming its prerequisites. Group-owned ideas retain an internal
account anchor for the existing dossier and scoring procedures; an account
referenced by a group idea cannot be deleted until those ideas have been
permanently deleted. Production installation and RLS behavior remain
unverified from this checkout.