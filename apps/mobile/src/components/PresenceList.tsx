import { View, Text, FlatList, StyleSheet } from 'react-native';
import type { Participant } from '../state/session-store';
import { colors, spacing, fontSize, borderRadius } from '../utils/theme';

interface PresenceListProps {
  participants: Participant[];
  currentParticipantId: string | null;
  hostParticipantId?: string | null;
}

const STATUS_COLORS: Record<string, string> = {
  online: colors.online,
  stale: colors.stale,
  offline: colors.offline,
};

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

export default function PresenceList({ participants, currentParticipantId, hostParticipantId }: PresenceListProps) {
  // Sort: online first, then stale, then offline
  const sorted = [...participants].sort((a, b) => {
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
        return (
          <View style={styles.row}>
            <View style={[styles.avatar, { backgroundColor: STATUS_COLORS[item.status] || colors.border }]}>
              <Text style={styles.avatarText}>
                {(item.displayName || '?')[0].toUpperCase()}
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
                {STATUS_LABELS[item.status] || item.status}
                {item.lastLocation
                  ? ` · ${item.lastLocation.lat.toFixed(4)}, ${item.lastLocation.lng.toFixed(4)}`
                  : ' · No location'}
              </Text>
            </View>
            <Text style={styles.time}>{timeAgo(item.lastSeenTs)}</Text>
          </View>
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
