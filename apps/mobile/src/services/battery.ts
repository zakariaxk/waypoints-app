// Battery reporting for presence enrichment (Phase 3).
//
// Battery rides the LOC_UPDATE stream rather than getting its own message
// kind: it is high-frequency and worthless on replay, exactly like location.
// See docs/DECISIONS.md (battery-not-an-event).
//
// Foreground-only by construction — this is only read when the location
// service fires, and location is foreground-only (background tracking is an
// explicit non-goal in docs/SPEC-PHASE3.md §4).

import * as Battery from 'expo-battery';

interface BatterySample {
  battery: number | null;
  charging: boolean | null;
}

let cached: BatterySample = { battery: null, charging: null };
let inFlight = false;

/**
 * Latest known battery state, refreshed in the background.
 *
 * Returns the cached value synchronously so it can be attached to a location
 * update without making the location hot path await a native call. On a
 * device that cannot report battery (simulator, permission-less platform)
 * this stays null forever, and null battery simply means "no badge".
 */
export function readBattery(): BatterySample {
  if (!inFlight) {
    inFlight = true;
    Promise.all([Battery.getBatteryLevelAsync(), Battery.getBatteryStateAsync()])
      .then(([level, state]) => {
        cached = {
          battery: level >= 0 ? level : null,
          charging:
            state === Battery.BatteryState.CHARGING || state === Battery.BatteryState.FULL,
        };
      })
      .catch(() => {
        // Unsupported platform — leave the last known value in place.
      })
      .finally(() => {
        inFlight = false;
      });
  }
  return cached;
}

/** Reset cached state, e.g. when leaving a session. */
export function resetBattery(): void {
  cached = { battery: null, charging: null };
}
