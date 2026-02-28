import { useState, useEffect, useCallback, useMemo } from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  Alert,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  ActivityIndicator,
} from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
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
import {
  useTheme,
  type ThemeMode,
  type ThemeColors,
  spacing,
  fontSize,
  fontFamily,
  borderRadius,
  gradients,
  glow,
  palette,
} from '../ui/theme';
import { NeonText, NeonButton, HudCard, NeonDivider, Chip } from '../ui/components';
import * as Haptics from 'expo-haptics';

interface HomeScreenProps {
  onSessionReady: () => void;
  initialJoinCode?: string | null;
}

export default function HomeScreen({ onSessionReady, initialJoinCode }: HomeScreenProps) {
  const { colors, mode, isDark, setMode } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
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
      <ScrollView
        contentContainerStyle={styles.inner}
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
      >
        {/* Theme toggle */}
        <View style={styles.themeToggleRow}>
          {(['system', 'light', 'dark'] as ThemeMode[]).map((m) => (
            <TouchableOpacity
              key={m}
              style={[styles.themeChip, mode === m && styles.themeChipActive]}
              onPress={() => {
                Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                setMode(m);
              }}
            >
              <Text style={[styles.themeChipText, mode === m && styles.themeChipTextActive]}>
                {m === 'system' ? '⚙ AUTO' : m === 'light' ? '☀ LIGHT' : '🌙 DARK'}
              </Text>
            </TouchableOpacity>
          ))}
        </View>

        {/* Logo area */}
        <View style={styles.logoArea}>
          <NeonText variant="hero" accent glow center>
            W
          </NeonText>
          <NeonText variant="h1" accent center style={styles.logoTitle}>
            WAYPOINTS
          </NeonText>
          <NeonText variant="body" color={colors.textSecondary} center>
            Real-time location sharing
          </NeonText>
        </View>

        {/* Form Card */}
        <HudCard>
          <NeonText variant="caption" color={colors.textTertiary} style={styles.label}>
            YOUR NAME
          </NeonText>
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

          <NeonButton
            title="CREATE SESSION"
            onPress={handleCreate}
            variant="primary"
            disabled={loading}
            loading={loading}
            fullWidth
          />

          <NeonDivider intensity={0.15} style={styles.dividerSpacing} />

          <NeonText variant="caption" color={colors.textTertiary} style={styles.label}>
            JOIN CODE
          </NeonText>
          <TextInput
            style={[styles.input, styles.codeInput]}
            placeholder="ABC123"
            placeholderTextColor={colors.textTertiary}
            value={joinCode}
            onChangeText={(t) => setJoinCode(t.toUpperCase())}
            autoCapitalize="characters"
            maxLength={6}
          />

          <NeonButton
            title="JOIN SESSION"
            onPress={handleJoin}
            variant="secondary"
            disabled={loading}
            loading={loading}
            fullWidth
          />
        </HudCard>

        {/* Session history */}
        {!loadingHistory && (
          <SessionHistory
            sessions={sessionHistory}
            onRejoin={handleRejoin}
            onRefresh={refreshHistory}
          />
        )}

        <NeonText variant="caption" color={colors.textTertiary} center style={styles.footer}>
          Share location with your group in real time
        </NeonText>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const createStyles = (colors: ThemeColors) =>
  StyleSheet.create({
    container: {
      flex: 1,
    },
    inner: {
      flexGrow: 1,
      padding: spacing.xl,
      justifyContent: 'center',
    },
    // ─── Theme toggle ───
    themeToggleRow: {
      flexDirection: 'row',
      justifyContent: 'center',
      gap: spacing.sm,
      marginBottom: spacing.xl,
    },
    themeChip: {
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.xs + 2,
      borderRadius: borderRadius.full,
      backgroundColor: colors.surfaceAlt,
      borderWidth: 1,
      borderColor: colors.border,
    },
    themeChipActive: {
      backgroundColor: colors.accentSoft,
      borderColor: colors.accent,
    },
    themeChipText: {
      fontSize: fontSize.xs,
      color: colors.textSecondary,
      fontWeight: '600',
      letterSpacing: 1,
    },
    themeChipTextActive: {
      color: colors.accent,
    },
    // ─── Logo ───
    logoArea: {
      alignItems: 'center',
      marginBottom: spacing.xxl,
    },
    logoTitle: {
      marginTop: -spacing.sm,
      marginBottom: spacing.xs,
    },
    // ─── Form ───
    label: {
      marginBottom: spacing.xs,
    },
    input: {
      borderWidth: 1,
      borderColor: colors.border,
      borderRadius: borderRadius.md,
      padding: spacing.md,
      fontSize: fontSize.md,
      color: colors.text,
      backgroundColor: colors.surfaceAlt,
      marginBottom: spacing.md,
    },
    codeInput: {
      letterSpacing: 6,
      fontSize: fontSize.xl,
      fontWeight: '700',
      textAlign: 'center',
      color: colors.accent,
    },
    dividerSpacing: {
      marginVertical: spacing.md,
    },
    footer: {
      marginTop: spacing.xl,
    },
  });
