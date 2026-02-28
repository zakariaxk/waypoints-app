// Group ETA Summary component — shows fastest, longest, and average ETA at a glance.

import { View, Text, StyleSheet } from 'react-native';
import { formatDuration, type ParticipantETA } from '../hooks/useParticipantETAs';
import { colors, spacing, fontSize, borderRadius } from '../utils/theme';

interface GroupETASummaryProps {
  etas: Map<string, ParticipantETA>;
  participantNames: Map<string, string>;
}

export default function GroupETASummary({ etas, participantNames }: GroupETASummaryProps) {
  if (etas.size === 0) return null;

  const entries = Array.from(etas.entries());
  const durations = entries.map(([, e]) => e.durationSec);

  const minDuration = Math.min(...durations);
  const maxDuration = Math.max(...durations);
  const avgDuration = Math.round(durations.reduce((a, b) => a + b, 0) / durations.length);

  const fastest = entries.find(([, e]) => e.durationSec === minDuration);
  const slowest = entries.find(([, e]) => e.durationSec === maxDuration);

  const fastestName = fastest ? (participantNames.get(fastest[0]) || fastest[0].slice(0, 6)) : '';
  const slowestName = slowest ? (participantNames.get(slowest[0]) || slowest[0].slice(0, 6)) : '';

  // Don't show if only one person
  if (entries.length < 2) {
    return (
      <View style={styles.container}>
        <View style={styles.pill}>
          <Text style={styles.label}>ETA</Text>
          <Text style={styles.value}>{formatDuration(minDuration)}</Text>
        </View>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.pill}>
        <Text style={styles.label}>🏁 First</Text>
        <Text style={styles.value} numberOfLines={1}>
          {fastestName} · {formatDuration(minDuration)}
        </Text>
      </View>
      <View style={[styles.pill, styles.pillAvg]}>
        <Text style={styles.label}>⌀ Avg</Text>
        <Text style={styles.value}>{formatDuration(avgDuration)}</Text>
      </View>
      <View style={styles.pill}>
        <Text style={styles.label}>🐢 Last</Text>
        <Text style={styles.value} numberOfLines={1}>
          {slowestName} · {formatDuration(maxDuration)}
        </Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.xs,
    backgroundColor: colors.surface,
    borderTopWidth: 1,
    borderTopColor: colors.borderLight,
    gap: spacing.xs,
  },
  pill: {
    flex: 1,
    alignItems: 'center',
    paddingVertical: spacing.xs,
    paddingHorizontal: spacing.xs,
    backgroundColor: colors.white,
    borderRadius: borderRadius.sm,
    borderWidth: 1,
    borderColor: colors.borderLight,
  },
  pillAvg: {
    backgroundColor: colors.primaryLight + '15',
    borderColor: colors.primaryLight + '40',
  },
  label: {
    fontSize: fontSize.xs - 1,
    color: colors.textTertiary,
    fontWeight: '600',
    marginBottom: 1,
  },
  value: {
    fontSize: fontSize.xs,
    fontWeight: '700',
    color: colors.text,
    maxWidth: 90,
  },
});
