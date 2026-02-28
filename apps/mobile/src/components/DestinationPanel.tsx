import { View, Text, StyleSheet } from 'react-native';
import type { Destination } from '../state/session-store';

interface DestinationPanelProps {
  destination: Destination | null;
}

export default function DestinationPanel({ destination }: DestinationPanelProps) {
  if (!destination) {
    return (
      <View style={styles.container}>
        <Text style={styles.empty}>No destination set</Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <Text style={styles.label}>Destination</Text>
      <Text style={styles.name}>{destination.label || 'Unnamed'}</Text>
      <Text style={styles.coords}>
        {destination.lat.toFixed(4)}, {destination.lng.toFixed(4)}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    padding: 12,
    borderTopWidth: 1,
    borderTopColor: '#eee',
    backgroundColor: '#fafafa',
  },
  empty: {
    color: '#999',
    fontSize: 13,
    textAlign: 'center',
  },
  label: {
    fontSize: 11,
    color: '#999',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
  },
  name: {
    fontSize: 16,
    fontWeight: '600',
    marginTop: 2,
  },
  coords: {
    fontSize: 12,
    color: '#666',
    marginTop: 2,
  },
});
