import { View, Text, FlatList, StyleSheet, TouchableOpacity } from 'react-native';
import type { Participant, Destination } from '../state/session-store';
import { haversineDistance, formatDistance } from '../utils/geo';
import { formatDuration, type ParticipantETA } from '../hooks/useParticipantETAs';
import { colors, spacing, fontSize, borderRadius, getParticipantColor } from '../utils/theme';

interface PresenceListProps {
  participants: Participant[];
  currentParticipantId: string | null;
  hostParticipantId?: string | null;
  myLocation?: { lat: number; lng: number } | null;
  destination?: Destination | null;
  etas?: Map<string, ParticipantETA>;
  onParticipantPress?: (participant: Participant) => void;
}

const ARRIVAL_THRESHOLD_KM = 0.05; // 50 meters

const STATUS_LABELS: Record<string, string> = {
  online: 'Online',
  stale: 'Stale',
  offline: 'Offline',
};

function timeAgo(ts: number): string {
  const seconds = Math.floor((Date.now() - ts) / 1000);
  if (seconds < 10) return 'just now';
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  return `${Math.floor(minutes / 60)}h ago`;
}

export default function PresenceList({ participants, currentParticipantId, hostParticipantId, myLocation, destination, etas, onParticipantPress }: PresenceListProps) {
  const allIds = participants.map((p) => p.participantId);

  // Sort: arrived first, then online, then stale, then offline
  const sorted = [...participants].sort((a, b) => {
    const aArrived = destination && a.lastLocation
      ? haversineDistance(a.lastLocation.lat, a.lastLocation.lng, destination.lat, destination.lng) < ARRIVAL_THRESHOLD_KM
      : false;
    const bArrived = destination && b.lastLocation
      ? haversineDistance(b.lastLocation.lat, b.lastLocation.lng, destination.lat, destination.lng) < ARRIVAL_THRESHOLD_KM
      : false;
    if (aArrived !== bArrived) return aArrived ? -1 : 1;
    const order: Record<string, number> = { online: 0, stale: 1, offline: 2 };
    return (order[a.status] ?? 3) - (order[b.status] ?? 3);
  });

  return (
    <FlatList
      data={sorted}
      keyExtractor={(item) => item.participantId}
      contentContainerStyle={styles.list}
      renderItem={({ item }) => {
        const isMe = item.participantId === currentParticipantId;
        const isHost = item.participantId === hostParticipantId;
        const pColor = getParticipantColor(item.participantId, allIds, currentParticipantId);
        const eta = etas?.get(item.participantId);

        // Arrival detection
        const isArrived = destination && item.lastLocation
          ? haversineDistance(item.lastLocation.lat, item.lastLocation.lng, destination.lat, destination.lng) < ARRIVAL_THRESHOLD_KM
          : false;

        // Movement status from speed
        const speed = item.lastLocation?.speed ?? 0;
        const movementIcon = speed > 5 ? '🚗' : speed > 1 ? '🚶' : '📍';
        const movementLabel = speed > 5 ? 'Driving' : speed > 1 ? 'Walking' : 'Stationary';

        const avatarBg = item.status === 'offline' ? colors.markerOffline : isArrived ? '#22C55E' : pColor;
        const rowOpacity = item.status === 'offline' ? 0.5 : 1;

        return (
          <TouchableOpacity
            style={[styles.row, { opacity: rowOpacity }]}
            activeOpacity={0.6}
            onPress={() => onParticipantPress?.(item)}
          >
            <View style={[styles.avatar, { backgroundColor: avatarBg }]}>
              <Text style={styles.avatarText}>
                {isArrived ? '✓' : (item.displayName || '?')[0].toUpperCase()}
              </Text>
            </View>
            <View style={styles.info}>
              <View style={styles.nameRow}>
                <Text style={styles.name} numberOfLines={1}>
                  {item.displayName || item.participantId.slice(0, 8)}
                  {isMe ? ' (you)' : ''}
                </Text>
                {isHost && <Text style={styles.hostTag}> 👑</Text>}
              </View>
              <Text style={styles.detail}>
                {isArrived ? (
                  '✓ Arrived'
                ) : (
                  <>
                    {item.status === 'online' && item.lastLocation
                      ? `${movementIcon} ${movementLabel}`
                      : STATUS_LABELS[item.status] || item.status}
                    {item.lastLocation && myLocation && !isMe
                      ? ` · ${formatDistance(haversineDistance(myLocation.lat, myLocation.lng, item.lastLocation.lat, item.lastLocation.lng))} away`
                      : item.lastLocation && isMe
                        ? ' · Your location'
                        : ' · No location'}
                  </>
                )}
              </Text>
              {eta && !isArrived && (
                <Text style={styles.etaText}>
                  🕐 ETA {formatDuration(eta.durationSec)} · {formatDistance(eta.distanceM / 1000)}
                </Text>
              )}
            </View>
            <Text style={styles.time}>{timeAgo(item.lastSeenTs)}</Text>
          </TouchableOpacity>
        );
      }}
      ListEmptyComponent={
        <View style={styles.empty}>
          <Text style={styles.emptyText}>No participants yet</Text>
        </View>
      }
    />
  );
}

const styles = StyleSheet.create({
  list: {
    padding: spacing.md,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.sm,
    marginBottom: spacing.xs,
    backgroundColor: colors.surface,
    borderRadius: borderRadius.md,
  },
  avatar: {
    width: 36,
    height: 36,
    borderRadius: 18,
    alignItems: 'center',
    justifyContent: 'center',
    marginRight: spacing.md,
  },
  avatarText: {
    color: colors.white,
    fontSize: fontSize.md,
    fontWeight: '700',
  },
  info: {
    flex: 1,
  },
  nameRow: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  name: {
    fontSize: fontSize.md,
    fontWeight: '600',
    color: colors.text,
    flexShrink: 1,
  },
  hostTag: {
    fontSize: fontSize.md,
    marginLeft: 2,
  },
  detail: {
    fontSize: fontSize.xs,
    color: colors.textSecondary,
    marginTop: 1,
  },
  etaText: {
    fontSize: fontSize.xs,
    color: colors.primary,
    fontWeight: '600',
    marginTop: 1,
  },
  time: {
    fontSize: fontSize.xs,
    color: colors.textTertiary,
    marginLeft: spacing.sm,
  },
  empty: {
    alignItems: 'center',
    paddingVertical: spacing.xl,
  },
  emptyText: {
    fontSize: fontSize.sm,
    color: colors.textTertiary,
  },
});
