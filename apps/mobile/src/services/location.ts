// Location service: polls GPS and sends updates via WS.

import * as ExpoLocation from 'expo-location';
import { sendLocUpdate, sendArrivalPing } from './ws-client';
import { LOCATION_INTERVAL_MS, ARRIVAL_RADIUS_M } from '../utils/constants';
import { readBattery, resetBattery } from './battery';
import { useSessionStore } from '../state/session-store';
import { haversineDistance } from '../utils/geo';

let watchSubscription: ExpoLocation.LocationSubscription | null = null;
let seq = 0;
/**
 * Destination we have already auto-pinged arrival for, as "lat,lng". Guards
 * the auto-fire so a jittery fix hovering on the 50m boundary cannot spam the
 * server, while still re-arming when the host picks a new destination.
 */
let autoPingedDestination: string | null = null;

export async function requestLocationPermission(): Promise<boolean> {
  const { status } = await ExpoLocation.requestForegroundPermissionsAsync();
  return status === 'granted';
}

function destinationKey(lat: number, lng: number): string {
  return `${lat.toFixed(5)},${lng.toFixed(5)}`;
}

/** Fire ARRIVAL_PING once per destination when we cross the radius. */
function maybeAutoPingArrival(lat: number, lng: number): void {
  const state = useSessionStore.getState();
  const destination = state.destination;
  if (!destination) {
    autoPingedDestination = null;
    return;
  }

  const key = destinationKey(destination.lat, destination.lng);
  if (autoPingedDestination === key) return;

  const me = state.participantId ? state.participants.get(state.participantId) : undefined;
  if (me?.arrived) {
    autoPingedDestination = key;
    return;
  }

  // haversineDistance returns KILOMETRES; the arrival radius is in metres.
  const distanceM = haversineDistance(lat, lng, destination.lat, destination.lng) * 1000;
  if (distanceM <= ARRIVAL_RADIUS_M) {
    autoPingedDestination = key;
    sendArrivalPing();
  }
}

export async function startLocationUpdates(): Promise<void> {
  if (watchSubscription) return;

  seq = 0;
  autoPingedDestination = null;
  watchSubscription = await ExpoLocation.watchPositionAsync(
    {
      accuracy: ExpoLocation.Accuracy.High,
      timeInterval: LOCATION_INTERVAL_MS,
      distanceInterval: 0,
    },
    (location) => {
      seq += 1;
      const { battery, charging } = readBattery();
      sendLocUpdate({
        seq,
        lat: location.coords.latitude,
        lng: location.coords.longitude,
        speed: location.coords.speed,
        heading: location.coords.heading,
        accuracy: location.coords.accuracy,
        ts: location.timestamp,
        battery,
        charging,
      });
      maybeAutoPingArrival(location.coords.latitude, location.coords.longitude);
    },
  );
}

export function stopLocationUpdates(): void {
  if (watchSubscription) {
    watchSubscription.remove();
    watchSubscription = null;
  }
  autoPingedDestination = null;
  resetBattery();
}
