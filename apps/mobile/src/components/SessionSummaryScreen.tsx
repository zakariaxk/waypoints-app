// Session Summary Screen — shown after leaving a session.
// Displays stats: duration, arrival order, distances.

import { useMemo } from 'react';
import { View, Text, StyleSheet, TouchableOpacity, Platform, ScrollView } from 'react-native';
import { spacing, fontSize, borderRadius, shadow, type ThemeColors } from '../utils/theme';
import { useTheme } from '../contexts/ThemeContext';
import { formatDistance } from '../utils/geo';
import { formatDuration } from '../hooks/useParticipantETAs';

export interface SessionSummaryData {
  sessionDuration: string; // formatted time string
  participantSummaries: ParticipantSummary[];
  destinationLabel: string | null;
}

export interface ParticipantSummary {
  participantId: string;
  displayName: string;
  isMe: boolean;
  arrived: boolean;
  arrivalOrder?: number; // 1-based
  arrivalTime?: string; // formatted time
  distanceToDestinationM?: number;
}

interface SessionSummaryScreenProps {
  data: SessionSummaryData;
  onDismiss: () => void;
}

export default function SessionSummaryScreen({ data, onDismiss }: SessionSummaryScreenProps) {
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const arrived = data.participantSummaries.filter((p) => p.arrived);
  const notArrived = data.participantSummaries.filter((p) => !p.arrived);

  return (
    <View style={styles.container}>
      <View style={styles.card}>
        <Text style={styles.title}>Session Summary</Text>

        <View style={styles.statRow}>
          <View style={styles.stat}>
            <Text style={styles.statValue}>{data.sessionDuration}</Text>
            <Text style={styles.statLabel}>Duration</Text>
          </View>
          <View style={styles.stat}>
            <Text style={styles.statValue}>{data.participantSummaries.length}</Text>
            <Text style={styles.statLabel}>Participants</Text>
          </View>
          <View style={styles.stat}>
            <Text style={styles.statValue}>{arrived.length}</Text>
            <Text style={styles.statLabel}>Arrived</Text>
          </View>
        </View>

        {data.destinationLabel && (
          <Text style={styles.destLabel}>📍 {data.destinationLabel}</Text>
        )}

        <ScrollView style={styles.listContainer} contentContainerStyle={styles.listContent}>
          {arrived.length > 0 && (
            <>
              <Text style={styles.sectionHeader}>🏁 Arrivals</Text>
              {arrived
                .sort((a, b) => (a.arrivalOrder ?? 99) - (b.arrivalOrder ?? 99))
                .map((p) => (
                  <View key={p.participantId} style={styles.participantRow}>
                    <View style={[styles.badge, styles.arrivedBadge]}>
                      <Text style={styles.badgeText}>#{p.arrivalOrder}</Text>
                    </View>
                    <View style={styles.participantInfo}>
                      <Text style={styles.participantName}>
                        {p.displayName}{p.isMe ? ' (you)' : ''}
                      </Text>
                      {p.arrivalTime && (
                        <Text style={styles.participantDetail}>
                          Arrived at {p.arrivalTime}
                        </Text>
                      )}
                    </View>
                    <Text style={styles.arrivedIcon}>✓</Text>
                  </View>
                ))}
            </>
          )}

          {notArrived.length > 0 && (
            <>
              <Text style={styles.sectionHeader}>🚗 En Route</Text>
              {notArrived.map((p) => (
                <View key={p.participantId} style={styles.participantRow}>
                  <View style={[styles.badge, styles.enRouteBadge]}>
                    <Text style={styles.badgeText}>—</Text>
                  </View>
                  <View style={styles.participantInfo}>
                    <Text style={styles.participantName}>
                      {p.displayName}{p.isMe ? ' (you)' : ''}
                    </Text>
                    {p.distanceToDestinationM != null && (
                      <Text style={styles.participantDetail}>
                        {formatDistance(p.distanceToDestinationM / 1000)} remaining
                      </Text>
                    )}
                  </View>
                </View>
              ))}
            </>
          )}
        </ScrollView>

        <TouchableOpacity style={styles.dismissButton} onPress={onDismiss} activeOpacity={0.7}>
          <Text style={styles.dismissText}>Done</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const createStyles = (colors: ThemeColors) =>
  StyleSheet.create({
    container: {
      flex: 1,
      backgroundColor: colors.overlay,
      justifyContent: 'center',
      alignItems: 'center',
      padding: spacing.lg,
    },
    card: {
      width: '100%',
      maxHeight: '85%',
      backgroundColor: colors.card,
      borderRadius: borderRadius.xl,
      padding: spacing.xl,
      borderWidth: 1,
      borderColor: colors.borderAccent,
      ...Platform.select({
        ios: shadow.lg,
        android: { elevation: 8 } as any,
      }),
    },
    title: {
      fontSize: fontSize.xl,
      fontWeight: '700',
      color: colors.text,
      textAlign: 'center',
      marginBottom: spacing.lg,
    },
    statRow: {
      flexDirection: 'row',
      justifyContent: 'space-around',
      marginBottom: spacing.lg,
      paddingVertical: spacing.md,
      backgroundColor: colors.surfaceAlt,
      borderRadius: borderRadius.md,
    },
    stat: {
      alignItems: 'center',
    },
    statValue: {
      fontSize: fontSize.lg,
      fontWeight: '700',
      color: colors.accent,
    },
    statLabel: {
      fontSize: fontSize.xs,
      color: colors.textSecondary,
      marginTop: 2,
    },
    destLabel: {
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      textAlign: 'center',
      marginBottom: spacing.md,
    },
    listContainer: {
      maxHeight: 300,
    },
    listContent: {
      paddingBottom: spacing.md,
    },
    sectionHeader: {
      fontSize: fontSize.sm,
      fontWeight: '700',
      color: colors.text,
      marginTop: spacing.md,
      marginBottom: spacing.sm,
    },
    participantRow: {
      flexDirection: 'row',
      alignItems: 'center',
      paddingVertical: spacing.sm,
      paddingHorizontal: spacing.sm,
      marginBottom: spacing.xs,
      backgroundColor: colors.surfaceAlt,
      borderRadius: borderRadius.sm,
    },
    badge: {
      width: 28,
      height: 28,
      borderRadius: 14,
      alignItems: 'center',
      justifyContent: 'center',
      marginRight: spacing.sm,
    },
    arrivedBadge: {
      backgroundColor: colors.online,
    },
    enRouteBadge: {
      backgroundColor: colors.stale,
    },
    badgeText: {
      color: colors.white,
      fontSize: fontSize.xs,
      fontWeight: '700',
    },
    participantInfo: {
      flex: 1,
    },
    participantName: {
      fontSize: fontSize.md,
      fontWeight: '600',
      color: colors.text,
    },
    participantDetail: {
      fontSize: fontSize.xs,
      color: colors.textSecondary,
      marginTop: 1,
    },
    arrivedIcon: {
      fontSize: fontSize.lg,
      color: colors.online,
      fontWeight: '700',
      marginLeft: spacing.sm,
    },
    dismissButton: {
      marginTop: spacing.lg,
      backgroundColor: colors.accent,
      paddingVertical: spacing.md,
      borderRadius: borderRadius.md,
      alignItems: 'center',
    },
    dismissText: {
      color: colors.textInverse,
      fontSize: fontSize.md,
      fontWeight: '700',
    },
  });
