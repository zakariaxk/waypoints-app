// Hook that triggers a haptic + toast when the user arrives near the destination.

import { useEffect, useRef } from 'react';
import * as Haptics from 'expo-haptics';
import type { Destination } from '../state/session-store';
import { haversineDistance } from '../utils/geo';

/** Distance threshold in km — alert when within this range */
const ARRIVAL_THRESHOLD_KM = 0.1; // 100 meters

/** Don't re-alert until user leaves this radius and returns */
const RESET_THRESHOLD_KM = 0.3; // 300 meters

export function useArrivalAlert(
  myLocation: { lat: number; lng: number } | null,
  destination: Destination | null,
  onArrival: () => void,
): void {
  const hasAlertedRef = useRef(false);

  useEffect(() => {
    // Reset alert state when destination changes
    hasAlertedRef.current = false;
  }, [destination?.lat, destination?.lng]);

  useEffect(() => {
    if (!myLocation || !destination) return;

    const dist = haversineDistance(
      myLocation.lat,
      myLocation.lng,
      destination.lat,
      destination.lng,
    );

    if (dist <= ARRIVAL_THRESHOLD_KM && !hasAlertedRef.current) {
      hasAlertedRef.current = true;
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      onArrival();
    } else if (dist > RESET_THRESHOLD_KM && hasAlertedRef.current) {
      // User moved away — allow re-alert if they come back
      hasAlertedRef.current = false;
    }
  }, [myLocation?.lat, myLocation?.lng, destination, onArrival]);
}
