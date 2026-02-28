import { useMemo } from 'react';
import { View, Text, TouchableOpacity, StyleSheet } from 'react-native';
import type { Destination, Participant } from '../state/session-store';
import { haversineDistance, formatDistance } from '../utils/geo';
import { formatDuration, type ParticipantETA } from '../hooks/useParticipantETAs';
import { spacing, fontSize, borderRadius, type ThemeColors, useTheme } from '../ui/theme';

interface DestinationPanelProps {
  destination: Destination | null;
  myLocation?: { lat: number; lng: number; speed?: number | null } | null;
  myETA?: ParticipantETA | null;
  isHost?: boolean;
  onClear?: () => void;
}

export default function DestinationPanel({
  destination,
  myLocation,
  myETA,
  isHost,
  onClear,
}: DestinationPanelProps) {
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);

  if (!destination) return null;

  let distanceText: string | null = null;
  let etaText: string | null = null;

  if (myETA) {
    // Prefer OSRM-based ETA (driving distance/time)
    distanceText = formatDistance(myETA.distanceM / 1000);
    etaText = formatDuration(myETA.durationSec);
  } else if (myLocation) {
    const dist = haversineDistance(
      myLocation.lat,
      myLocation.lng,
      destination.lat,
      destination.lng,
    );
    distanceText = formatDistance(dist);
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

const createStyles = (colors: ThemeColors) =>
  StyleSheet.create({
    container: {
      flexDirection: 'row',
      alignItems: 'center',
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.sm,
      backgroundColor: colors.panel,
      borderTopWidth: 1,
      borderTopColor: colors.panelBorder,
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
      letterSpacing: 0.3,
    },
    statsRow: {
      flexDirection: 'row',
      alignItems: 'center',
      marginTop: 1,
    },
    stat: {
      fontSize: fontSize.xs,
      fontWeight: '600',
      color: colors.accent,
      letterSpacing: 0.3,
    },
    coords: {
      fontSize: fontSize.xs,
      color: colors.textSecondary,
      marginTop: 1,
    },
    clearButton: {
      width: 28,
      height: 28,
      borderRadius: borderRadius.sm,
      backgroundColor: colors.surface,
      alignItems: 'center',
      justifyContent: 'center',
      marginLeft: spacing.sm,
      borderWidth: 1,
      borderColor: colors.panelBorder,
    },
    clearText: {
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      fontWeight: '700',
    },
  });
