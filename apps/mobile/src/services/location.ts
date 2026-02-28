// Location service: polls GPS and sends updates via WS.

import * as ExpoLocation from 'expo-location';
import { sendLocUpdate } from './ws-client';
import { LOCATION_INTERVAL_MS } from '../utils/constants';

let watchSubscription: ExpoLocation.LocationSubscription | null = null;
let seq = 0;

export async function requestLocationPermission(): Promise<boolean> {
  const { status } = await ExpoLocation.requestForegroundPermissionsAsync();
  return status === 'granted';
}

export async function startLocationUpdates(): Promise<void> {
  if (watchSubscription) return;

  seq = 0;
  watchSubscription = await ExpoLocation.watchPositionAsync(
    {
      accuracy: ExpoLocation.Accuracy.High,
      timeInterval: LOCATION_INTERVAL_MS,
      distanceInterval: 0,
    },
    (location) => {
      seq += 1;
      sendLocUpdate({
        seq,
        lat: location.coords.latitude,
        lng: location.coords.longitude,
        speed: location.coords.speed,
        heading: location.coords.heading,
        accuracy: location.coords.accuracy,
        ts: location.timestamp,
      });
    },
  );
}

export function stopLocationUpdates(): void {
  if (watchSubscription) {
    watchSubscription.remove();
    watchSubscription = null;
  }
}
