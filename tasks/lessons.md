# Lessons

## Rules to avoid repeated mistakes
- Always read docs/PRD.md + docs/WS-PROTOCOL.md before implementing real-time logic.
- Never mark a task done without running tests or providing a manual verification checklist.
- Don’t add new libraries unless required; justify and document.
- When protocol changes, update docs/WS-PROTOCOL.md in the same PR.

### 2026-02-28 — react-native-reanimated babel plugin crash
- **Mistake**: Added `react-native-reanimated/plugin` to babel.config.js for simple scale/translate animations. Reanimated 4.x's Worklets babel plugin crashes with `WorkletsBabelPluginError: Cannot set properties of undefined (setting 'workletNumber')` on Expo SDK 54.
- **Rule**: Prefer React Native's built-in `Animated` API for simple animations (scale, translate, opacity). Only reach for reanimated when you need gesture-driven or layout-based animations. If you do use reanimated, verify the babel plugin actually works before committing.