import { useRef, useEffect, useMemo, useState, useCallback } from 'react';
import { View, Text, StyleSheet, Platform, TouchableOpacity } from 'react-native';
import MapView, { Marker, Polyline, Callout, Region, PROVIDER_DEFAULT } from 'react-native-maps';
import { useSessionStore, type Participant, type Destination } from '../state/session-store';
import { fetchRoute, type RouteCoord } from '../utils/routing';
import { haversineDistance } from '../utils/geo';
import { colors, fontSize, spacing, borderRadius } from '../utils/theme';

const STATUS_MARKER_COLORS: Record<string, string> = {
  online: colors.markerOther,
  stale: colors.stale,
  offline: colors.markerOffline,
};

interface MapSectionProps {
  currentParticipantId: string | null;
  onLongPress?: (lat: number, lng: number) => void;
  focusLocation?: { lat: number; lng: number } | null;
  onMapRef?: (ref: MapView | null) => void;
}

/** Distance threshold (km) before re-fetching route */
const ROUTE_RETHRESH_KM = 0.05; // 50 meters
/** Time-based route refresh interval */
const ROUTE_REFRESH_MS = 10_000; // 10 seconds

export default function MapSection({ currentParticipantId, onLongPress, focusLocation, onMapRef }: MapSectionProps) {
  const mapRef = useRef<MapView>(null);
  const participants = useSessionStore((s) => s.participants);
  const destination = useSessionStore((s) => s.destination);

  // Route polyline state
  const [routeCoords, setRouteCoords] = useState<RouteCoord[]>([]);
  const lastRouteFetchRef = useRef<{ lat: number; lng: number; destLat: number; destLng: number; time: number } | null>(null);

  // Expose map ref to parent
  useEffect(() => {
    onMapRef?.(mapRef.current);
    return () => onMapRef?.(null);
  }, [onMapRef]);

  const participantsWithLocation = useMemo(() => {
    const result: Participant[] = [];
    for (const p of participants.values()) {
      if (p.lastLocation) {
        result.push(p);
      }
    }
    return result;
  }, [participants]);

  // Fit map to show all participants + destination
  useEffect(() => {
    if (!mapRef.current) return;
    const coords: { latitude: number; longitude: number }[] = [];

    for (const p of participantsWithLocation) {
      if (p.lastLocation) {
        coords.push({ latitude: p.lastLocation.lat, longitude: p.lastLocation.lng });
      }
    }
    if (destination) {
      coords.push({ latitude: destination.lat, longitude: destination.lng });
    }

    if (coords.length >= 2) {
      mapRef.current.fitToCoordinates(coords, {
        edgePadding: { top: 80, right: 40, bottom: 40, left: 40 },
        animated: true,
      });
    } else if (coords.length === 1) {
      mapRef.current.animateToRegion(
        {
          latitude: coords[0].latitude,
          longitude: coords[0].longitude,
          latitudeDelta: 0.01,
          longitudeDelta: 0.01,
        },
        500,
      );
    }
  }, [participantsWithLocation.length, destination?.lat, destination?.lng]);

  // ─── Route polyline fetching ───
  const myLoc = useMemo(() => {
    if (!currentParticipantId) return null;
    const me = participants.get(currentParticipantId);
    return me?.lastLocation ?? null;
  }, [participants, currentParticipantId]);

  const fetchRouteIfNeeded = useCallback(async () => {
    if (!myLoc || !destination) {
      setRouteCoords([]);
      lastRouteFetchRef.current = null;
      return;
    }

    const last = lastRouteFetchRef.current;
    const now = Date.now();

    if (last) {
      const movedKm = haversineDistance(myLoc.lat, myLoc.lng, last.lat, last.lng);
      const destChanged = last.destLat !== destination.lat || last.destLng !== destination.lng;
      const timeElapsed = now - last.time;

      // Only re-fetch if moved >50m OR destination changed OR 10s elapsed
      if (!destChanged && movedKm < ROUTE_RETHRESH_KM && timeElapsed < ROUTE_REFRESH_MS) {
        return;
      }
    }

    lastRouteFetchRef.current = {
      lat: myLoc.lat,
      lng: myLoc.lng,
      destLat: destination.lat,
      destLng: destination.lng,
      time: now,
    };

    const coords = await fetchRoute(myLoc, destination);
    if (coords) {
      setRouteCoords(coords);
    }
    // On failure, keep existing route (or empty) — destination marker still shows
  }, [myLoc, destination]);

  // Fetch route on location/destination change
  useEffect(() => {
    fetchRouteIfNeeded();
  }, [fetchRouteIfNeeded]);

  // Timer-based route refresh every 10s
  useEffect(() => {
    if (!myLoc || !destination) return;
    const timer = setInterval(fetchRouteIfNeeded, ROUTE_REFRESH_MS);
    return () => clearInterval(timer);
  }, [myLoc, destination, fetchRouteIfNeeded]);

  // Clear route when destination is removed
  useEffect(() => {
    if (!destination) {
      setRouteCoords([]);
      lastRouteFetchRef.current = null;
    }
  }, [destination]);

  // ─── Participant focus: animate to target ───
  useEffect(() => {
    if (!focusLocation || !mapRef.current) return;
    mapRef.current.animateToRegion(
      {
        latitude: focusLocation.lat,
        longitude: focusLocation.lng,
        latitudeDelta: 0.005,
        longitudeDelta: 0.005,
      },
      600,
    );
  }, [focusLocation]);

  // Use current user's location or a sensible default
  const initialRegion: Region = useMemo(() => {
    if (currentParticipantId) {
      const me = participants.get(currentParticipantId);
      if (me?.lastLocation) {
        return {
          latitude: me.lastLocation.lat,
          longitude: me.lastLocation.lng,
          latitudeDelta: 0.02,
          longitudeDelta: 0.02,
        };
      }
    }
    for (const p of participants.values()) {
      if (p.lastLocation) {
        return {
          latitude: p.lastLocation.lat,
          longitude: p.lastLocation.lng,
          latitudeDelta: 0.02,
          longitudeDelta: 0.02,
        };
      }
    }
    return {
      latitude: 39.8283,
      longitude: -98.5795,
      latitudeDelta: 40,
      longitudeDelta: 40,
    };
  }, []);

  return (
    <View style={styles.container}>
      <MapView
        ref={mapRef}
        style={styles.map}
        provider={PROVIDER_DEFAULT}
        initialRegion={initialRegion}
        showsUserLocation={false}
        showsMyLocationButton={false}
        showsCompass={true}
        rotateEnabled={true}
        onLongPress={(e) => {
          if (onLongPress) {
            const { latitude, longitude } = e.nativeEvent.coordinate;
            onLongPress(latitude, longitude);
          }
        }}
      >
        {/* Participant markers */}
        {participantsWithLocation.map((p) => {
          const isMe = p.participantId === currentParticipantId;
          const markerColor = isMe ? colors.markerSelf : (STATUS_MARKER_COLORS[p.status] || colors.markerOffline);
          const loc = p.lastLocation!;

          return (
            <Marker
              key={p.participantId}
              coordinate={{ latitude: loc.lat, longitude: loc.lng }}
              pinColor={markerColor}
              title={p.displayName || p.participantId.slice(0, 8)}
              description={isMe ? 'You' : p.status}
            >
              {/* Custom marker view */}
              <View style={[styles.markerContainer, { borderColor: markerColor }]}>
                <View style={[styles.markerDot, { backgroundColor: markerColor }]} />
                <Text style={[styles.markerLabel, isMe && styles.markerLabelBold]} numberOfLines={1}>
                  {isMe ? 'You' : (p.displayName || p.participantId.slice(0, 6))}
                </Text>
              </View>
              <View style={[styles.markerArrow, { borderTopColor: markerColor }]} />
            </Marker>
          );
        })}

        {/* Destination marker */}
        {destination && (
          <Marker
            coordinate={{ latitude: destination.lat, longitude: destination.lng }}
            pinColor={colors.markerDestination}
          >
            <View style={styles.destMarkerContainer}>
              <Text style={styles.destMarkerText}>📍</Text>
              <Text style={styles.destMarkerLabel} numberOfLines={1}>
                {destination.label || 'Destination'}
              </Text>
            </View>
          </Marker>
        )}

        {/* Route polyline from user to destination */}
        {routeCoords.length > 1 && (
          <Polyline
            coordinates={routeCoords}
            strokeColor={colors.route}
            strokeWidth={4}
            lineDashPattern={[0]}
          />
        )}
      </MapView>

      {/* Center on me button */}
      <TouchableOpacity
        style={styles.centerButton}
        onPress={() => {
          if (!mapRef.current || !currentParticipantId) return;
          const me = participants.get(currentParticipantId);
          if (me?.lastLocation) {
            mapRef.current.animateToRegion(
              {
                latitude: me.lastLocation.lat,
                longitude: me.lastLocation.lng,
                latitudeDelta: 0.01,
                longitudeDelta: 0.01,
              },
              500,
            );
          }
        }}
        activeOpacity={0.7}
      >
        <Text style={styles.centerButtonText}>◎</Text>
      </TouchableOpacity>

      {/* Participant count overlay */}
      <View style={styles.overlay}>
        <Text style={styles.overlayText}>
          {participantsWithLocation.length} on map
        </Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    position: 'relative',
  },
  map: {
    flex: 1,
  },
  markerContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: colors.white,
    paddingHorizontal: 6,
    paddingVertical: 3,
    borderRadius: borderRadius.lg,
    borderWidth: 2,
    ...Platform.select({
      ios: {
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 2 },
        shadowOpacity: 0.2,
        shadowRadius: 3,
      },
      android: {
        elevation: 4,
      },
    }),
  },
  markerDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    marginRight: 4,
  },
  markerLabel: {
    fontSize: fontSize.xs,
    color: colors.text,
    maxWidth: 60,
  },
  markerLabelBold: {
    fontWeight: '700',
    color: colors.primary,
  },
  markerArrow: {
    width: 0,
    height: 0,
    borderLeftWidth: 5,
    borderRightWidth: 5,
    borderTopWidth: 6,
    borderLeftColor: 'transparent',
    borderRightColor: 'transparent',
    alignSelf: 'center',
  },
  destMarkerContainer: {
    alignItems: 'center',
  },
  destMarkerText: {
    fontSize: 28,
  },
  destMarkerLabel: {
    fontSize: fontSize.xs,
    color: colors.markerDestination,
    fontWeight: '600',
    backgroundColor: 'rgba(255,255,255,0.85)',
    paddingHorizontal: 4,
    paddingVertical: 1,
    borderRadius: 4,
    overflow: 'hidden',
    maxWidth: 80,
  },
  centerButton: {
    position: 'absolute',
    bottom: spacing.sm,
    left: spacing.sm,
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: colors.white,
    alignItems: 'center',
    justifyContent: 'center',
    ...Platform.select({
      ios: {
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 2 },
        shadowOpacity: 0.2,
        shadowRadius: 3,
      },
      android: {
        elevation: 4,
      },
    }),
  },
  centerButtonText: {
    fontSize: 22,
    color: colors.primary,
    fontWeight: '700',
  },
  overlay: {
    position: 'absolute',
    bottom: spacing.sm,
    right: spacing.sm,
    backgroundColor: 'rgba(0,0,0,0.6)',
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.xs,
    borderRadius: borderRadius.full,
  },
  overlayText: {
    color: colors.white,
    fontSize: fontSize.xs,
    fontWeight: '600',
  },
});
