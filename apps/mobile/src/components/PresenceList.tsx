import { View, Text, FlatList, StyleSheet } from 'react-native';
import type { Participant } from '../state/session-store';

interface PresenceListProps {
  participants: Participant[];
  currentParticipantId: string | null;
}

const STATUS_COLORS: Record<string, string> = {
  online: '#34C759',
  stale: '#FF9500',
  offline: '#FF3B30',
};

export default function PresenceList({ participants, currentParticipantId }: PresenceListProps) {
  return (
    <View style={styles.container}>
      <Text style={styles.header}>Participants ({participants.length})</Text>
      <FlatList
        data={participants}
        keyExtractor={(item) => item.participantId}
        renderItem={({ item }) => (
          <View style={styles.row}>
            <View style={[styles.dot, { backgroundColor: STATUS_COLORS[item.status] || '#ccc' }]} />
            <Text style={styles.name}>
              {item.displayName || item.participantId.slice(0, 8)}
              {item.participantId === currentParticipantId ? ' (you)' : ''}
            </Text>
            <Text style={styles.status}>{item.status}</Text>
          </View>
        )}
        scrollEnabled={false}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    padding: 12,
    borderTopWidth: 1,
    borderTopColor: '#eee',
  },
  header: {
    fontSize: 14,
    fontWeight: '600',
    marginBottom: 8,
    color: '#333',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 6,
  },
  dot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    marginRight: 8,
  },
  name: {
    flex: 1,
    fontSize: 14,
  },
  status: {
    fontSize: 12,
    color: '#999',
  },
});
