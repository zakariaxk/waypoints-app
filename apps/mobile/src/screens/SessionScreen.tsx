import { useEffect, useState } from 'react';
import { View, Text, StyleSheet, Alert } from 'react-native';
import { useSessionStore } from '../state/session-store';
import { connectWs, disconnectWs } from '../services/ws-client';
import { requestLocationPermission, startLocationUpdates, stopLocationUpdates } from '../services/location';
import PresenceList from '../components/PresenceList';
import DestinationPanel from '../components/DestinationPanel';

export default function SessionScreen() {
  const { sessionId, participantId, token, joinCode, connected, lastEventId } = useSessionStore();
  const participants = useSessionStore((s) => s.participants);
  const destination = useSessionStore((s) => s.destination);
  const [locationGranted, setLocationGranted] = useState(false);

  useEffect(() => {
    if (sessionId && participantId && token) {
      connectWs(sessionId, participantId, token, null);
    }
    return () => {
      disconnectWs();
    };
  }, [sessionId, participantId, token]);

  useEffect(() => {
    (async () => {
      const granted = await requestLocationPermission();
      setLocationGranted(granted);
      if (granted) {
        await startLocationUpdates();
      } else {
        Alert.alert(
          'Location Required',
          'Waypoints needs location access to share your position with your group.',
        );
      }
    })();
    return () => {
      stopLocationUpdates();
    };
  }, []);

  const participantList = Array.from(participants.values());

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.title}>Session</Text>
        {joinCode && <Text style={styles.code}>Code: {joinCode}</Text>}
        <Text style={styles.status}>
          {connected ? '● Connected' : '○ Disconnected'} · Event #{lastEventId}
        </Text>
      </View>

      <View style={styles.mapPlaceholder}>
        <Text style={styles.mapText}>
          {locationGranted ? `Map view — ${participantList.length} participant(s)` : 'Location permission not granted'}
        </Text>
        {/* react-native-maps MapView will replace this placeholder */}
      </View>

      <PresenceList participants={participantList} currentParticipantId={participantId} />
      <DestinationPanel destination={destination} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
  },
  header: {
    padding: 16,
    paddingTop: 48,
    backgroundColor: '#f8f8f8',
    borderBottomWidth: 1,
    borderBottomColor: '#eee',
  },
  title: {
    fontSize: 20,
    fontWeight: 'bold',
  },
  code: {
    fontSize: 14,
    color: '#007AFF',
    marginTop: 2,
  },
  status: {
    fontSize: 12,
    color: '#999',
    marginTop: 4,
  },
  mapPlaceholder: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#f0f0f0',
  },
  mapText: {
    color: '#666',
    fontSize: 14,
  },
});
