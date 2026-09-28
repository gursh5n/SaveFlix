# SaveFlix setup

## Connect Supabase

1. Create a Supabase project.
2. Open the Supabase SQL Editor and run [`supabase/schema.sql`](supabase/schema.sql) once. It creates profiles, username history, friend requests, recommendations, row-level security policies, and the public `avatars` storage bucket.
3. In [`index.html`](index.html), replace `YOUR_SUPABASE_URL` and `YOUR_SUPABASE_ANON_KEY` with the project's **Project URL** and **publishable/anon key**. Never put a `service_role` key in this page.
4. In Supabase Auth, configure the site's URL and email confirmation settings. The app uses email/password authentication.
5. Serve this folder over HTTP while developing. From PowerShell in the project folder, run `python -m http.server 8000`, then open `http://localhost:8000`.

Usernames are unique, separate from display names, and can be changed at most twice during any rolling 14-day period. That limit is checked transactionally in the database. Friend requests and recommendations require authenticated accounts; only accepted friends can exchange recommendations.

## Streaming service logos

The page uses local SVG logos in `assets/streaming-services/` for Netflix, Hulu, Disney+, and Prime Video. Text marks appear if a logo file is missing. Service selections are saved on the current device; provider sign-in is not available in this demo.

## Profile pictures

PNG, JPEG, and WebP uploads are accepted. GIFs and other formats are rejected. The browser center-crops the image, converts it to WebP, and uploads a 256 × 256 image to the authenticated user's folder in the `avatars` bucket.
