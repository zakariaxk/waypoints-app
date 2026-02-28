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

### 3. Deploy Backend to Fly.io
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
