import { useRef, useEffect, useMemo, useState, useCallback } from 'react';
import { View, Text, StyleSheet, Platform, TouchableOpacity } from 'react-native';
import MapView, { Marker, Polyline, Callout, Region, PROVIDER_DEFAULT, MapType } from 'react-native-maps';
import { useSessionStore, type Participant, type Destination } from '../state/session-store';
import { fetchRoute, type RouteCoord } from '../utils/routing';
import { haversineDistance, formatSpeed } from '../utils/geo';
import { fontSize, spacing, borderRadius, getParticipantColor, glow, type ThemeColors, useTheme } from '../ui/theme';

const ARRIVAL_THRESHOLD_KM = 0.05; // 50 meters

interface MapSectionProps {
  currentParticipantId: string | null;
  onLongPress?: (lat: number, lng: number) => void;
  focusLocation?: { lat: number; lng: number } | null;
  followTargetId?: string | null;
  onFollowEnd?: () => void;
  onMapRef?: (ref: MapView | null) => void;
}

/** Distance threshold (km) before re-fetching route */
const ROUTE_RETHRESH_KM = 0.05; // 50 meters
/** Time-based route refresh interval */
const ROUTE_REFRESH_MS = 10_000; // 10 seconds

export default function MapSection({ currentParticipantId, onLongPress, focusLocation, followTargetId, onFollowEnd, onMapRef }: MapSectionProps) {
  const { colors, isDark } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const mapRef = useRef<MapView>(null);
  const participants = useSessionStore((s) => s.participants);
  const destination = useSessionStore((s) => s.destination);

  // Per-participant route polylines: Map<participantId, RouteCoord[]>
  const [participantRoutes, setParticipantRoutes] = useState<Map<string, RouteCoord[]>>(new Map());
  const [mapType, setMapType] = useState<MapType>('standard');
  const lastRouteFetchRef = useRef<Map<string, { lat: number; lng: number; destLat: number; destLng: number; time: number }>>(new Map());

  // Follow mode state
  const [followParticipantId, setFollowParticipantId] = useState<string | null>(null);
  const userPannedRef = useRef(false);

  // Sync follow mode from external prop (e.g. FriendSheet "Follow on map")
  useEffect(() => {
    if (followTargetId !== undefined && followTargetId !== null) {
      setFollowParticipantId(followTargetId);
      userPannedRef.current = false;
    }
  }, [followTargetId]);

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

  // ─── Route polyline fetching for ALL participants ───
  const myLoc = useMemo(() => {
    if (!currentParticipantId) return null;
    const me = participants.get(currentParticipantId);
    return me?.lastLocation ?? null;
  }, [participants, currentParticipantId]);

  const fetchAllRoutes = useCallback(async () => {
    if (!destination) {
      setParticipantRoutes(new Map());
      lastRouteFetchRef.current.clear();
      return;
    }

    const now = Date.now();
    const updates = new Map<string, RouteCoord[]>();
    const deletions: string[] = [];

    for (const p of participantsWithLocation) {
      if (p.status === 'offline') continue;
      const loc = p.lastLocation!;

      const last = lastRouteFetchRef.current.get(p.participantId);
      if (last) {
        const movedKm = haversineDistance(loc.lat, loc.lng, last.lat, last.lng);
        const destChanged = last.destLat !== destination.lat || last.destLng !== destination.lng;
        const timeElapsed = now - last.time;
        if (!destChanged && movedKm < ROUTE_RETHRESH_KM && timeElapsed < ROUTE_REFRESH_MS) {
          continue;
        }
      }

      // Check if participant is near destination (arrived) — skip route
      const distToDest = haversineDistance(loc.lat, loc.lng, destination.lat, destination.lng);
      if (distToDest < ARRIVAL_THRESHOLD_KM) {
        deletions.push(p.participantId);
        lastRouteFetchRef.current.delete(p.participantId);
        continue;
      }

      const result = await fetchRoute(loc, destination);
      if (result) {
        updates.set(p.participantId, result.coords);
        lastRouteFetchRef.current.set(p.participantId, {
          lat: loc.lat, lng: loc.lng,
          destLat: destination.lat, destLng: destination.lng,
          time: now,
        });
      }

      // Stagger to be polite to OSRM
      await new Promise((r) => setTimeout(r, 250));
    }

    if (updates.size > 0 || deletions.length > 0) {
      setParticipantRoutes((prev) => {
        const next = new Map(prev);
        for (const [pid, coords] of updates) next.set(pid, coords);
        for (const pid of deletions) next.delete(pid);
        // Remove routes for participants no longer present
        for (const pid of next.keys()) {
          if (!participants.has(pid)) next.delete(pid);
        }
        return next;
      });
    }
  }, [participantsWithLocation, destination, participants]);

  // Fetch routes on location/destination change
  useEffect(() => {
    fetchAllRoutes();
  }, [fetchAllRoutes]);

  // Timer-based route refresh every 10s
  useEffect(() => {
    if (!destination || participantsWithLocation.length === 0) return;
    const timer = setInterval(fetchAllRoutes, ROUTE_REFRESH_MS);
    return () => clearInterval(timer);
  }, [destination, participantsWithLocation.length, fetchAllRoutes]);

  // Clear routes when destination is removed
  useEffect(() => {
    if (!destination) {
      setParticipantRoutes(new Map());
      lastRouteFetchRef.current.clear();
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

  // ─── Follow mode: track a participant's location continuously ───
  useEffect(() => {
    if (!followParticipantId || !mapRef.current || userPannedRef.current) return;
    const target = participants.get(followParticipantId);
    if (target?.lastLocation) {
      mapRef.current.animateToRegion(
        {
          latitude: target.lastLocation.lat,
          longitude: target.lastLocation.lng,
          latitudeDelta: 0.01,
          longitudeDelta: 0.01,
        },
        400,
      );
    }
  }, [followParticipantId, participants]);

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

  // Sorted participant IDs for deterministic color assignment
  const allParticipantIds = useMemo(
    () => Array.from(participants.keys()),
    [participants],
  );

  return (
    <View style={styles.container}>
      <MapView
        ref={mapRef}
        style={styles.map}
        provider={PROVIDER_DEFAULT}
        initialRegion={initialRegion}
        mapType={mapType}
        showsUserLocation={false}
        showsMyLocationButton={false}
        showsCompass={true}
        rotateEnabled={true}
        onPanDrag={() => {
          // Disable follow mode when user manually pans
          if (followParticipantId) {
            userPannedRef.current = true;
            setFollowParticipantId(null);
            onFollowEnd?.();
          }
        }}
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
          const pColor = getParticipantColor(p.participantId, allParticipantIds, currentParticipantId);
          const loc = p.lastLocation!;
          const heading = loc.heading;
          const hasHeading = heading != null && heading >= 0 && (loc.speed ?? 0) > 0.5;

          // Arrival detection: within 50m of destination
          const isArrived = destination
            ? haversineDistance(loc.lat, loc.lng, destination.lat, destination.lng) < ARRIVAL_THRESHOLD_KM
            : false;

          // Movement status
          const speed = loc.speed ?? 0;
          const movementIcon = speed > 5 ? '🚗' : speed > 1 ? '🚶' : '';
          const speedLabel = speed > 1 ? ` ${formatSpeed(loc.speed)}` : '';

          // Grey out offline participants
          const markerColor = p.status === 'offline' ? colors.markerOffline : isArrived ? '#22C55E' : pColor;
          const markerOpacity = p.status === 'offline' ? 0.4 : 1;

          return (
            <Marker
              key={p.participantId}
              coordinate={{ latitude: loc.lat, longitude: loc.lng }}
              pinColor={markerColor}
              title={p.displayName || p.participantId.slice(0, 8)}
              description={isMe ? 'You' : isArrived ? '✓ Arrived' : p.status}
              anchor={{ x: 0.5, y: 1 }}
            >
              {/* Custom marker view */}
              <View style={[styles.markerWrapper, { opacity: markerOpacity }]}>
                {hasHeading && (
                  <View style={[styles.headingArrow, { transform: [{ rotate: `${heading}deg` }] }]}>
                    <View style={[styles.headingTriangle, { borderBottomColor: markerColor }]} />
                  </View>
                )}
                <View style={[styles.markerContainer, { borderColor: markerColor }]}>
                  <View style={[styles.markerDot, { backgroundColor: markerColor }]} />
                  <Text style={[styles.markerLabel, isMe && styles.markerLabelBold]} numberOfLines={1}>
                    {isArrived ? '✓ ' : movementIcon ? `${movementIcon} ` : ''}
                    {isMe ? 'You' : (p.displayName || p.participantId.slice(0, 6))}
                    {speedLabel}
                  </Text>
                </View>
                <View style={[styles.markerArrow, { borderTopColor: markerColor }]} />
              </View>
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

        {/* Per-participant route polylines */}
        {Array.from(participantRoutes.entries()).map(([pid, coords]) => {
          if (coords.length < 2) return null;
          const pColor = getParticipantColor(pid, allParticipantIds, currentParticipantId);
          const isMe = pid === currentParticipantId;
          return (
            <Polyline
              key={`route-${pid}`}
              coordinates={coords}
              strokeColor={pColor}
              strokeWidth={isMe ? 5 : 3}
              lineJoin="round"
              lineCap="round"
              geodesic={true}
              lineDashPattern={isMe ? undefined : [8, 4]}
            />
          );
        })}
      </MapView>

      {/* Center on me button */}
      <TouchableOpacity
        style={styles.centerButton}
        onPress={() => {
          if (!mapRef.current || !currentParticipantId) return;
          // Toggle follow mode on self
          if (followParticipantId === currentParticipantId) {
            setFollowParticipantId(null);
          } else {
            setFollowParticipantId(currentParticipantId);
            userPannedRef.current = false;
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
          }
        }}
        activeOpacity={0.7}
      >
        <Text style={[styles.centerButtonText, followParticipantId === currentParticipantId && styles.followActive]}>
          {followParticipantId === currentParticipantId ? '⊚' : '◎'}
        </Text>
      </TouchableOpacity>

      {/* Map type toggle */}
      <TouchableOpacity
        style={styles.mapTypeButton}
        onPress={() => {
          setMapType((prev) => {
            if (prev === 'standard') return 'satellite';
            if (prev === 'satellite') return 'hybrid';
            return 'standard';
          });
        }}
        activeOpacity={0.7}
      >
        <Text style={styles.mapTypeButtonText}>
          {mapType === 'standard' ? '🗺' : mapType === 'satellite' ? '🛰' : '🌐'}
        </Text>
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

const createStyles = (colors: ThemeColors) =>
  StyleSheet.create({
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
      backgroundColor: colors.panel,
      paddingHorizontal: 6,
      paddingVertical: 3,
      borderRadius: borderRadius.md,
      borderWidth: 1.5,
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
    markerWrapper: {
      alignItems: 'center',
    },
    headingArrow: {
      position: 'absolute',
      top: -14,
      alignSelf: 'center',
      zIndex: 10,
    },
    headingTriangle: {
      width: 0,
      height: 0,
      borderLeftWidth: 6,
      borderRightWidth: 6,
      borderBottomWidth: 10,
      borderLeftColor: 'transparent',
      borderRightColor: 'transparent',
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
      maxWidth: 80,
    },
    markerLabelBold: {
      fontWeight: '700',
      color: colors.accent,
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
      backgroundColor: colors.card + 'D9',
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
      borderRadius: borderRadius.md,
      backgroundColor: colors.mapControlBg,
      alignItems: 'center',
      justifyContent: 'center',
      borderWidth: 1,
      borderColor: colors.borderAccent,
      ...glow.cyan.sm,
    },
    centerButtonText: {
      fontSize: 22,
      color: colors.mapControlText,
      fontWeight: '700',
    },
    followActive: {
      color: colors.online,
    },
    mapTypeButton: {
      position: 'absolute',
      bottom: spacing.sm,
      left: spacing.sm + 48,
      width: 40,
      height: 40,
      borderRadius: borderRadius.md,
      backgroundColor: colors.mapControlBg,
      alignItems: 'center',
      justifyContent: 'center',
      borderWidth: 1,
      borderColor: colors.borderAccent,
      ...glow.cyan.sm,
    },
    mapTypeButtonText: {
      fontSize: 18,
    },
    overlay: {
      position: 'absolute',
      bottom: spacing.sm,
      right: spacing.sm,
      backgroundColor: colors.panel,
      paddingHorizontal: spacing.sm,
      paddingVertical: spacing.xs,
      borderRadius: borderRadius.md,
      borderWidth: 1,
      borderColor: colors.borderAccent,
    },
    overlayText: {
      color: colors.accent,
      fontSize: fontSize.xs,
      fontWeight: '600',
      letterSpacing: 0.5,
    },
  });
