import { View, Text, StyleSheet } from 'react-native';
import type { Destination } from '../state/session-store';
import { colors, spacing, fontSize } from '../utils/theme';

interface DestinationPanelProps {
  destination: Destination | null;
}

export default function DestinationPanel({ destination }: DestinationPanelProps) {
  if (!destination) return null;

  return (
    <View style={styles.container}>
      <Text style={styles.icon}>📍</Text>
      <View style={styles.info}>
        <Text style={styles.name} numberOfLines={1}>
          {destination.label || 'Destination'}
        </Text>
        <Text style={styles.coords}>
          {destination.lat.toFixed(5)}, {destination.lng.toFixed(5)}
        </Text>
      </View>
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
  coords: {
    fontSize: fontSize.xs,
    color: colors.textSecondary,
    marginTop: 1,
  },
});
