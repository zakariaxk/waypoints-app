import { useState } from 'react';
import { View, Text, TextInput, TouchableOpacity, StyleSheet, Alert } from 'react-native';
import { createSession, joinSession } from '../services/api';
import { useSessionStore } from '../state/session-store';

interface HomeScreenProps {
  onSessionReady: () => void;
}

export default function HomeScreen({ onSessionReady }: HomeScreenProps) {
  const [displayName, setDisplayName] = useState('');
  const [joinCode, setJoinCode] = useState('');
  const [loading, setLoading] = useState(false);
  const setSession = useSessionStore((s) => s.setSession);

  const handleCreate = async () => {
    if (!displayName.trim()) {
      Alert.alert('Enter a display name');
      return;
    }
    setLoading(true);
    try {
      const result = await createSession(displayName.trim());
      setSession({
        sessionId: result.sessionId,
        participantId: result.participantId,
        token: result.token,
        joinCode: result.joinCode,
      });
      onSessionReady();
    } catch (err) {
      Alert.alert('Error', err instanceof Error ? err.message : 'Failed to create session');
    } finally {
      setLoading(false);
    }
  };

  const handleJoin = async () => {
    if (!displayName.trim()) {
      Alert.alert('Enter a display name');
      return;
    }
    if (!joinCode.trim()) {
      Alert.alert('Enter a join code');
      return;
    }
    setLoading(true);
    try {
      const result = await joinSession(joinCode.trim(), displayName.trim());
      setSession({
        sessionId: result.sessionId,
        participantId: result.participantId,
        token: result.token,
      });
      onSessionReady();
    } catch (err) {
      Alert.alert('Error', err instanceof Error ? err.message : 'Failed to join session');
    } finally {
      setLoading(false);
    }
  };

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Waypoints</Text>
      <Text style={styles.subtitle}>Real-time location sharing</Text>

      <TextInput
        style={styles.input}
        placeholder="Your display name"
        value={displayName}
        onChangeText={setDisplayName}
        autoCapitalize="words"
      />

      <TouchableOpacity style={styles.button} onPress={handleCreate} disabled={loading}>
        <Text style={styles.buttonText}>Create Session</Text>
      </TouchableOpacity>

      <View style={styles.divider}>
        <View style={styles.dividerLine} />
        <Text style={styles.dividerText}>or join</Text>
        <View style={styles.dividerLine} />
      </View>

      <TextInput
        style={styles.input}
        placeholder="Enter join code"
        value={joinCode}
        onChangeText={(t) => setJoinCode(t.toUpperCase())}
        autoCapitalize="characters"
        maxLength={6}
      />

      <TouchableOpacity
        style={[styles.button, styles.joinButton]}
        onPress={handleJoin}
        disabled={loading}
      >
        <Text style={styles.buttonText}>Join Session</Text>
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 24,
    justifyContent: 'center',
    backgroundColor: '#fff',
  },
  title: {
    fontSize: 32,
    fontWeight: 'bold',
    textAlign: 'center',
    marginBottom: 4,
  },
  subtitle: {
    fontSize: 16,
    color: '#666',
    textAlign: 'center',
    marginBottom: 32,
  },
  input: {
    borderWidth: 1,
    borderColor: '#ddd',
    borderRadius: 8,
    padding: 12,
    fontSize: 16,
    marginBottom: 12,
  },
  button: {
    backgroundColor: '#007AFF',
    padding: 14,
    borderRadius: 8,
    alignItems: 'center',
    marginBottom: 12,
  },
  joinButton: {
    backgroundColor: '#34C759',
  },
  buttonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
  divider: {
    flexDirection: 'row',
    alignItems: 'center',
    marginVertical: 16,
  },
  dividerLine: {
    flex: 1,
    height: 1,
    backgroundColor: '#ddd',
  },
  dividerText: {
    marginHorizontal: 12,
    color: '#999',
    fontSize: 14,
  },
});
