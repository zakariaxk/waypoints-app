import { useRef, useEffect, useMemo } from 'react';
import { View, Text, StyleSheet, Platform } from 'react-native';
import MapView, { Marker, Callout, Region, PROVIDER_DEFAULT } from 'react-native-maps';
import { useSessionStore, type Participant, type Destination } from '../state/session-store';
import { colors, fontSize, spacing, borderRadius } from '../utils/theme';

const STATUS_MARKER_COLORS: Record<string, string> = {
  online: colors.markerOther,
  stale: colors.stale,
  offline: colors.markerOffline,
};

interface MapSectionProps {
  currentParticipantId: string | null;
  onLongPress?: (lat: number, lng: number) => void;
}

export default function MapSection({ currentParticipantId, onLongPress }: MapSectionProps) {
  const mapRef = useRef<MapView>(null);
  const participants = useSessionStore((s) => s.participants);
  const destination = useSessionStore((s) => s.destination);

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

  const initialRegion: Region = {
    latitude: 37.78,
    longitude: -122.42,
    latitudeDelta: 0.05,
    longitudeDelta: 0.05,
  };

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
      </MapView>

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
