import { View, Text, TouchableOpacity, StyleSheet } from 'react-native';
import type { Destination, Participant } from '../state/session-store';
import { haversineDistance, formatDistance, estimateETA } from '../utils/geo';
import { colors, spacing, fontSize } from '../utils/theme';

interface DestinationPanelProps {
  destination: Destination | null;
  myLocation?: { lat: number; lng: number; speed?: number | null } | null;
  isHost?: boolean;
  onClear?: () => void;
}

export default function DestinationPanel({
  destination,
  myLocation,
  isHost,
  onClear,
}: DestinationPanelProps) {
  if (!destination) return null;

  let distanceText: string | null = null;
  let etaText: string | null = null;

  if (myLocation) {
    const dist = haversineDistance(
      myLocation.lat,
      myLocation.lng,
      destination.lat,
      destination.lng,
    );
    distanceText = formatDistance(dist);
    etaText = estimateETA(dist, myLocation.speed ?? null);
  }

  return (
    <View style={styles.container}>
      <Text style={styles.icon}>📍</Text>
      <View style={styles.info}>
        <Text style={styles.name} numberOfLines={1}>
          {destination.label || 'Destination'}
        </Text>
        <View style={styles.statsRow}>
          {distanceText && <Text style={styles.stat}>{distanceText}</Text>}
          {etaText && <Text style={styles.stat}> · ETA {etaText}</Text>}
          {!distanceText && (
            <Text style={styles.coords}>
              {destination.lat.toFixed(5)}, {destination.lng.toFixed(5)}
            </Text>
          )}
        </View>
      </View>
      {isHost && onClear && (
        <TouchableOpacity style={styles.clearButton} onPress={onClear}>
          <Text style={styles.clearText}>✕</Text>
        </TouchableOpacity>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    backgroundColor: '#FEF3C7',
    borderTopWidth: 1,
    borderTopColor: '#FDE68A',
  },
  icon: {
    fontSize: 18,
    marginRight: spacing.sm,
  },
  info: {
    flex: 1,
  },
  name: {
    fontSize: fontSize.sm,
    fontWeight: '600',
    color: colors.text,
  },
  statsRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginTop: 1,
  },
  stat: {
    fontSize: fontSize.xs,
    fontWeight: '600',
    color: '#92400E',
  },
  coords: {
    fontSize: fontSize.xs,
    color: colors.textSecondary,
    marginTop: 1,
  },
  clearButton: {
    width: 28,
    height: 28,
    borderRadius: 14,
    backgroundColor: 'rgba(0,0,0,0.1)',
    alignItems: 'center',
    justifyContent: 'center',
    marginLeft: spacing.sm,
  },
  clearText: {
    fontSize: fontSize.sm,
    color: colors.textSecondary,
    fontWeight: '700',
  },
});
