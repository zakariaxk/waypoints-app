import { useState, useEffect, useCallback } from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  Alert,
  KeyboardAvoidingView,
  Platform,
  StatusBar,
  ScrollView,
  ActivityIndicator,
} from 'react-native';
import { createSession, joinSession } from '../services/api';
import { useSessionStore } from '../state/session-store';
import {
  getStoredDisplayName,
  setStoredDisplayName,
  getSessionHistory,
  addSessionToHistory,
  type SessionHistoryEntry,
} from '../utils/storage';
import SessionHistory from '../components/SessionHistory';
import { colors, spacing, fontSize, borderRadius, shadow } from '../utils/theme';

interface HomeScreenProps {
  onSessionReady: () => void;
  initialJoinCode?: string | null;
}

export default function HomeScreen({ onSessionReady, initialJoinCode }: HomeScreenProps) {
  const [displayName, setDisplayName] = useState('');
  const [joinCode, setJoinCode] = useState('');
  const [loading, setLoading] = useState(false);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [sessionHistory, setSessionHistory] = useState<SessionHistoryEntry[]>([]);
  const setSession = useSessionStore((s) => s.setSession);

  // Load persisted display name and session history on mount
  useEffect(() => {
    (async () => {
      const [storedName, history] = await Promise.all([
        getStoredDisplayName(),
        getSessionHistory(),
      ]);
      if (storedName) setDisplayName(storedName);
      setSessionHistory(history);
      setLoadingHistory(false);
    })();
  }, []);

  // Handle deep link join code
  useEffect(() => {
    if (initialJoinCode) {
      setJoinCode(initialJoinCode);
    }
  }, [initialJoinCode]);

  const refreshHistory = useCallback(async () => {
    const history = await getSessionHistory();
    setSessionHistory(history);
  }, []);

  const persistAndSetSession = useCallback(
    async (params: {
      sessionId: string;
      participantId: string;
      token: string;
      joinCode: string;
      displayName: string;
      hostParticipantId?: string;
    }) => {
      // Persist display name
      await setStoredDisplayName(params.displayName);

      // Add to session history
      await addSessionToHistory({
        sessionId: params.sessionId,
        joinCode: params.joinCode,
        participantId: params.participantId,
        token: params.token,
        displayName: params.displayName,
        hostParticipantId: params.hostParticipantId ?? null,
        joinedAt: Date.now(),
        lastActiveAt: Date.now(),
      });

      setSession(params);
      onSessionReady();
    },
    [setSession, onSessionReady],
  );

  const handleCreate = async () => {
    if (!displayName.trim()) {
      Alert.alert('Name Required', 'Enter a display name to continue.');
      return;
    }
    setLoading(true);
    try {
      const result = await createSession(displayName.trim());
      await persistAndSetSession({
        sessionId: result.sessionId,
        participantId: result.participantId,
        token: result.token,
        joinCode: result.joinCode,
        displayName: displayName.trim(),
      });
    } catch (err) {
      Alert.alert('Error', err instanceof Error ? err.message : 'Failed to create session');
    } finally {
      setLoading(false);
    }
  };

  const handleJoin = async () => {
    if (!displayName.trim()) {
      Alert.alert('Name Required', 'Enter a display name to continue.');
      return;
    }
    if (!joinCode.trim()) {
      Alert.alert('Code Required', 'Enter a 6-character join code.');
      return;
    }
    setLoading(true);
    try {
      const result = await joinSession(joinCode.trim(), displayName.trim());
      await persistAndSetSession({
        sessionId: result.sessionId,
        participantId: result.participantId,
        token: result.token,
        joinCode: joinCode.trim().toUpperCase(),
        displayName: displayName.trim(),
      });
    } catch (err) {
      Alert.alert('Error', err instanceof Error ? err.message : 'Failed to join session');
    } finally {
      setLoading(false);
    }
  };

  const handleRejoin = useCallback(
    (entry: SessionHistoryEntry) => {
      // Rejoin using stored credentials — server will accept the token
      setSession({
        sessionId: entry.sessionId,
        participantId: entry.participantId,
        token: entry.token,
        joinCode: entry.joinCode,
        displayName: entry.displayName ?? (displayName.trim() || undefined),
        hostParticipantId: entry.hostParticipantId ?? undefined,
      });
      onSessionReady();
    },
    [setSession, onSessionReady, displayName],
  );

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <StatusBar barStyle="dark-content" />
      <ScrollView
        contentContainerStyle={styles.inner}
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
      >
        {/* Logo area */}
        <View style={styles.logoArea}>
          <Text style={styles.logoEmoji}>📍</Text>
          <Text style={styles.title}>Waypoints</Text>
          <Text style={styles.subtitle}>Real-time location sharing</Text>
        </View>

        {/* Form */}
        <View style={styles.formCard}>
          <Text style={styles.label}>Your Name</Text>
          <TextInput
            style={styles.input}
            placeholder="Enter your display name"
            placeholderTextColor={colors.textTertiary}
            value={displayName}
            onChangeText={setDisplayName}
            autoCapitalize="words"
            autoComplete="name"
            maxLength={30}
          />

          <TouchableOpacity
            style={[styles.button, styles.createButton, loading && styles.buttonDisabled]}
            onPress={handleCreate}
            disabled={loading}
          >
            {loading ? (
              <ActivityIndicator color={colors.textInverse} size="small" />
            ) : (
              <Text style={styles.buttonText}>Create Session</Text>
            )}
          </TouchableOpacity>

          <View style={styles.divider}>
            <View style={styles.dividerLine} />
            <Text style={styles.dividerText}>or join existing</Text>
            <View style={styles.dividerLine} />
          </View>

          <Text style={styles.label}>Join Code</Text>
          <TextInput
            style={[styles.input, styles.codeInput]}
            placeholder="ABC123"
            placeholderTextColor={colors.textTertiary}
            value={joinCode}
            onChangeText={(t) => setJoinCode(t.toUpperCase())}
            autoCapitalize="characters"
            maxLength={6}
          />

          <TouchableOpacity
            style={[styles.button, styles.joinButton, loading && styles.buttonDisabled]}
            onPress={handleJoin}
            disabled={loading}
          >
            {loading ? (
              <ActivityIndicator color={colors.textInverse} size="small" />
            ) : (
              <Text style={styles.buttonText}>Join Session</Text>
            )}
          </TouchableOpacity>
        </View>

        {/* Session history */}
        {!loadingHistory && (
          <SessionHistory
            sessions={sessionHistory}
            onRejoin={handleRejoin}
            onRefresh={refreshHistory}
          />
        )}

        <Text style={styles.footer}>Share location with your group in real time</Text>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.surface,
  },
  inner: {
    flexGrow: 1,
    padding: spacing.xl,
    justifyContent: 'center',
  },
  // ─── Logo ───
  logoArea: {
    alignItems: 'center',
    marginBottom: spacing.xxl,
  },
  logoEmoji: {
    fontSize: 56,
    marginBottom: spacing.sm,
  },
  title: {
    fontSize: fontSize.title,
    fontWeight: '800',
    color: colors.text,
    letterSpacing: -1,
  },
  subtitle: {
    fontSize: fontSize.md,
    color: colors.textSecondary,
    marginTop: spacing.xs,
  },
  // ─── Form ───
  formCard: {
    backgroundColor: colors.white,
    borderRadius: borderRadius.lg,
    padding: spacing.xl,
    ...shadow.md,
  },
  label: {
    fontSize: fontSize.sm,
    fontWeight: '600',
    color: colors.textSecondary,
    marginBottom: spacing.xs,
    textTransform: 'uppercase',
    letterSpacing: 0.5,
  },
  input: {
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: borderRadius.md,
    padding: spacing.md,
    fontSize: fontSize.md,
    color: colors.text,
    backgroundColor: colors.surface,
    marginBottom: spacing.md,
  },
  codeInput: {
    letterSpacing: 6,
    fontSize: fontSize.xl,
    fontWeight: '700',
    textAlign: 'center',
    color: colors.primary,
  },
  button: {
    paddingVertical: 14,
    borderRadius: borderRadius.md,
    alignItems: 'center',
    marginBottom: spacing.sm,
  },
  createButton: {
    backgroundColor: colors.primary,
  },
  joinButton: {
    backgroundColor: colors.online,
  },
  buttonDisabled: {
    opacity: 0.6,
  },
  buttonText: {
    color: colors.textInverse,
    fontSize: fontSize.md,
    fontWeight: '700',
  },
  divider: {
    flexDirection: 'row',
    alignItems: 'center',
    marginVertical: spacing.lg,
  },
  dividerLine: {
    flex: 1,
    height: 1,
    backgroundColor: colors.border,
  },
  dividerText: {
    marginHorizontal: spacing.md,
    color: colors.textTertiary,
    fontSize: fontSize.sm,
  },
  footer: {
    textAlign: 'center',
    color: colors.textTertiary,
    fontSize: fontSize.sm,
    marginTop: spacing.xl,
  },
});
