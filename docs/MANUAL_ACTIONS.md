# Manual Actions Required

This file is used when the coding agent requires:
- API keys
- Environment variables
- Account setup
- UI-based configuration steps
- External service setup

The agent must NOT assume these are completed.
The agent must append requests here and pause execution if required.

---

## Pending Actions

### 1. Apple Developer Account
- **Service**: Apple Developer Program
- **Why**: Required to build for iOS devices and submit to App Store
- **Steps**:
  1. Go to https://developer.apple.com/programs/
  2. Enroll in Apple Developer Program ($99/year)
  3. Once activated, note your **Apple Team ID**
- **Where result goes**: `apps/mobile/eas.json` → `submit.production.ios.appleTeamId`

### 2. EAS Project Setup
- **Service**: Expo Application Services (EAS)
- **Why**: Required for cloud builds (iOS requires macOS + Xcode which EAS provides)
- **Steps**:
  1. Install EAS CLI: `npm install -g eas-cli`
  2. Login: `eas login`
  3. From `apps/mobile/`, run: `eas init` (creates project on Expo servers)
  4. Copy the **Project ID** from the output
- **Where result goes**: 
  - `apps/mobile/app.config.ts` → `extra.eas.projectId` and `updates.url`
  - Set env var `EAS_PROJECT_ID` or hardcode in app.config.ts

### 3. Deploy Backend to Render (chosen — no card, free)
- **Service**: Render free web service (Docker), no credit card required
- **Why**: Fly requires a card on file even for its free allowance; Render's
  free tier needs no card. Trade-off: idle-sleeps after ~15min (wakes cold,
  ~30-60s) and sleep wipes in-memory sessions — acceptable under the in-memory
  constraint (ARCHITECTURE.md §4). Active-session heartbeat traffic keeps it awake.
- **Steps**:
  1. `render.yaml` blueprint is committed at repo root.
  2. https://render.com → sign in with GitHub (`zakariaxk`).
  3. New + → Blueprint → select repo `waypoints-app` → pick the deploy branch.
  4. Render reads `render.yaml`, shows service `waypoints-api` (free) → Apply.
  5. Note the URL: `https://waypoints-api.onrender.com`
  6. Verify: `curl https://waypoints-api.onrender.com/health`
- **Where result goes**:
  - `apps/mobile/eas.json` → `EXPO_PUBLIC_API_URL` / `EXPO_PUBLIC_WS_URL`
    (update from the `waypoints-api.fly.dev` placeholders to the Render host,
    `wss://` for WS).

### 3b. Deploy Backend to Fly.io (alternative — needs a card)
- **Service**: Fly.io (free tier: 3 shared VMs, 256MB RAM)
- **Why**: Mobile app needs a reachable backend (not localhost)
- **Steps**:
  1. Install Fly CLI: `brew install flyctl`
  2. Sign up: `fly auth signup` (or `fly auth login`)
  3. From repo root: `fly launch` (uses existing fly.toml)
  4. Deploy: `fly deploy`
  5. Note the URL: `https://waypoints-api.fly.dev`
  6. Verify: `curl https://waypoints-api.fly.dev/health`
- **Where result goes**: 
  - `apps/mobile/eas.json` → `preview.env.EXPO_PUBLIC_API_URL` and `EXPO_PUBLIC_WS_URL`
  - Already pre-configured as `https://waypoints-api.fly.dev` / `wss://waypoints-api.fly.dev`

### 4. Host Privacy Policy
- **Service**: Any static hosting (GitHub Pages, Vercel, etc.)
- **Why**: App Store requires a publicly accessible privacy policy URL
- **Steps**:
  1. Content is ready at `docs/PRIVACY_POLICY.md`
  2. Host as a static page (e.g., GitHub Pages from the repo)
  3. Note the URL (e.g., `https://zakariaxk.github.io/waypoints-app/PRIVACY_POLICY`)
- **Where result goes**: App Store Connect → App Privacy Policy URL

### 5. App Store Connect Setup
- **Service**: App Store Connect
- **Why**: Required to submit the app for review
- **Steps**:
  1. Go to https://appstoreconnect.apple.com
  2. Create a new app:
     - Platform: iOS
     - Name: "Waypoints — Live Location Sharing"
     - Primary Language: English (US)
     - Bundle ID: `com.waypoints.app` (register in Certificates, Identifiers & Profiles first)
     - SKU: `waypoints-ios-001`
  3. Fill in metadata from `docs/APP_STORE_METADATA.md`
  4. Set Privacy Policy URL
  5. Upload screenshots (see metadata doc for required shots)
  6. Note the **ASC App ID** (numeric)
- **Where result goes**:
  - `apps/mobile/eas.json` → `submit.production.ios.ascAppId`
  - `apps/mobile/eas.json` → `submit.production.ios.appleId` (your Apple ID email)

### 6. Build and Submit
- **Steps** (after all above are complete):
  1. `cd apps/mobile`
  2. Preview build: `eas build --platform ios --profile preview`
  3. Test via TestFlight
  4. Production build: `eas build --platform ios --profile production`
  5. Submit: `eas submit --platform ios --profile production`
  6. Fill in App Review information in App Store Connect
  7. Submit for review

---

## Completed Actions

_None_

---

## Pending Actions — Voice Chat (Phase 2)

### 7. react-native-webrtc Native Module Setup (EAS Dev Client)
- **Service**: EAS Build / Expo Dev Client
- **Why**: `react-native-webrtc` is a native module that cannot run in Expo Go. It requires a custom dev client built via EAS Build or local prebuild.
- **Dependency justification**: `react-native-webrtc` is the only mature, maintained WebRTC library for React Native. It provides `RTCPeerConnection`, `mediaDevices.getUserMedia`, and ICE/SDP handling — all required for peer-to-peer audio.
- **Steps**:
  1. Install the dependency:
     ```bash
     cd apps/mobile
     npm install react-native-webrtc@^124.0.4
     ```
  2. The Expo config plugin is already added to `app.config.ts` → `plugins: ['react-native-webrtc']`
  3. Microphone permissions are already configured:
     - iOS: `NSMicrophoneUsageDescription` in `infoPlist`
     - Android: `RECORD_AUDIO` in `permissions`
  4. Build a development client:
     ```bash
     cd apps/mobile
     eas build --platform ios --profile development
     # or for Android:
     eas build --platform android --profile development
     ```
  5. Install the dev client on your device/simulator
  6. Start the app with `npx expo start --dev-client`
- **Where result goes**: The dev client build enables `react-native-webrtc` native module at runtime.
- **Note**: Voice chat UI will render in Expo Go but WebRTC calls will fail at runtime. A dev client is required for actual audio functionality.

### 8. TURN Server (Optional, for NAT Traversal)
- **Service**: Any TURN server provider (Twilio, Xirsys, coturn self-hosted)
- **Why**: The current implementation uses STUN-only (Google's free STUN servers). This works for ~80% of connections but may fail for users behind symmetric NATs or restrictive firewalls. A TURN server provides relay fallback.
- **Steps** (if needed):
  1. Set up a TURN server (e.g., coturn on a VPS, or use Twilio Network Traversal)
  2. Get the TURN server URL, username, and credential
  3. Update `ICE_SERVERS` in `apps/mobile/src/hooks/useVoiceChat.ts` to include TURN:
     ```typescript
     const ICE_SERVERS = [
       { urls: 'stun:stun.l.google.com:19302' },
       { urls: 'turn:your-turn-server.com:3478', username: 'user', credential: 'pass' },
     ];
     ```
  4. Consider using environment variables for TURN credentials
- **Where result goes**: `apps/mobile/src/hooks/useVoiceChat.ts` → `ICE_SERVERS` array
- **Note**: Not required for initial testing on the same network. Only needed if users report connection failures.

---

## Pending Actions — Supabase Architecture Upgrade (Phase 3)

### 9. Create Supabase Project
- **Service**: Supabase (https://supabase.com)
- **Why**: Required for user authentication, Postgres database, and RLS-secured data persistence.
- **Steps**:
  1. Go to https://supabase.com/dashboard and sign in (or create an account)
  2. Click "New Project"
  3. Choose an organization (or create one)
  4. Project name: `waypoints` (or similar)
  5. Database password: generate a strong password and save it securely
  6. Region: choose the closest to your Fly.io deployment (e.g., US East if using IAD)
  7. Click "Create new project" — wait for provisioning (~2 minutes)
  8. Once created, go to **Settings → API**:
     - Copy **Project URL** (e.g., `https://xxxxx.supabase.co`)
     - Copy **anon/public key** (starts with `eyJ...`)
     - Copy **service_role key** (starts with `eyJ...` — keep this SECRET)
  9. Go to **Settings → API → JWT Settings**:
     - Copy the **JWT Secret** (used to verify JWTs locally on the backend)
- **Where results go**:
  - Backend `.env` file (create if it doesn't exist):
    ```
    SUPABASE_URL=https://xxxxx.supabase.co
    SUPABASE_ANON_KEY=eyJ...
    SUPABASE_SERVICE_ROLE_KEY=eyJ...
    SUPABASE_JWT_SECRET=your-jwt-secret-here
    ```
  - Mobile environment / app config:
    ```
    EXPO_PUBLIC_SUPABASE_URL=https://xxxxx.supabase.co
    EXPO_PUBLIC_SUPABASE_ANON_KEY=eyJ...
    ```
  - **NEVER** expose the service_role key or JWT secret in mobile/client code

### 10. Run Database Migrations
- **Service**: Supabase SQL Editor (or Supabase CLI)
- **Why**: Creates the required tables (profiles, friendships, sessions, session_participants, session_events) with RLS policies.
- **Steps**:
  1. After creating the Supabase project, go to **SQL Editor** in the dashboard
  2. Run the migration SQL from `services/api/src/db/migrations/001_initial_schema.sql` (will be created during implementation)
  3. Verify tables were created: go to **Table Editor** and confirm `profiles`, `friendships`, `sessions`, `session_participants`, `session_events` all exist
  4. Verify RLS is enabled: each table should show "RLS enabled" in the Table Editor
  5. Verify the `on_auth_user_created` trigger exists: go to **Database → Triggers**
- **Alternative**: Use Supabase CLI for automated migrations:
  ```bash
  npx supabase init
  npx supabase db push
  ```
- **Where result goes**: Database is ready for the backend to connect

### 11. Configure Supabase Auth Settings
- **Service**: Supabase Dashboard → Authentication
- **Why**: Configure authentication providers and settings.
- **Steps**:
  1. Go to **Authentication → Providers**
  2. Ensure **Email** provider is enabled (it's enabled by default)
  3. Optionally disable "Confirm email" for development (Authentication → Settings → toggle off "Enable email confirmations")
  4. Set **Site URL** to your mobile app's deep link scheme (e.g., `waypoints://`) or a redirect URL
  5. Optionally configure rate limits under Authentication → Rate Limits
  6. Under **Authentication → URL Configuration**, add any redirect URLs needed for OAuth (future)
- **Where result goes**: Supabase Auth is configured and ready for signup/login

### 12. Update Fly.io Environment Variables
- **Service**: Fly.io
- **Why**: The deployed backend needs Supabase credentials.
- **Steps**:
  1. Set secrets on Fly.io:
     ```bash
     fly secrets set SUPABASE_URL=https://xxxxx.supabase.co
     fly secrets set SUPABASE_ANON_KEY=eyJ...
     fly secrets set SUPABASE_SERVICE_ROLE_KEY=eyJ...
     fly secrets set SUPABASE_JWT_SECRET=your-jwt-secret-here
     ```
  2. Redeploy: `fly deploy`
  3. Verify health: `curl https://waypoints-api.fly.dev/health`
- **Where result goes**: Backend running on Fly.io can now connect to Supabase

---

## Pending Actions — Engineering Foundation (Epic A)

### 13. Configure branch protection on `main` (WP-102)
- **Service**: GitHub → repository **Settings → Branches → Branch protection rules**
- **Why**: The CI workflow (`.github/workflows/ci.yml`, WP-101) only guards merges if
  GitHub is configured to require it. Branch protection makes a green CI run and a review
  mandatory, and forbids direct/force pushes to `main`. This cannot be set from code — it
  is a repository setting.
- **Steps**:
  1. Go to **Settings → Branches → Add branch protection rule**.
  2. Branch name pattern: `main`.
  3. Enable **Require a pull request before merging** (with **Require approvals: 1** — for
     solo development, a self-review against the PR checklist satisfies this).
  4. Enable **Require status checks to pass before merging**, then select the CI check
     **`build · typecheck · lint · test`** (it appears in the list after CI has run once).
  5. Enable **Require branches to be up to date before merging**.
  6. Enable **Do not allow bypassing the above settings** and leave **Allow force pushes**
     and **Allow deletions** **off**.
  7. Save.
- **Where result goes**: Direct and force pushes to `main` are rejected by GitHub; every
  change lands via a CI-green PR. See `CONTRIBUTING.md` for the day-to-day flow.
