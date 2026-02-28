// Recent sessions list — allows rejoining previous sessions.

import { useMemo } from 'react';
import { View, Text, TouchableOpacity, FlatList, StyleSheet, Alert } from 'react-native';
import type { SessionHistoryEntry } from '../utils/storage';
import { removeSessionFromHistory } from '../utils/storage';
import { spacing, fontSize, borderRadius, shadow, type ThemeColors } from '../utils/theme';
import { useTheme } from '../contexts/ThemeContext';

interface SessionHistoryProps {
  sessions: SessionHistoryEntry[];
  onRejoin: (entry: SessionHistoryEntry) => void;
  onRefresh: () => void;
}

function timeAgo(ms: number): string {
  const seconds = Math.floor((Date.now() - ms) / 1000);
  if (seconds < 60) return 'just now';
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

export default function SessionHistory({ sessions, onRejoin, onRefresh }: SessionHistoryProps) {
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);

  if (sessions.length === 0) return null;

  const handleLongPress = (entry: SessionHistoryEntry) => {
    Alert.alert('Remove Session', `Remove "${entry.joinCode}" from history?`, [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Remove',
        style: 'destructive',
        onPress: async () => {
          await removeSessionFromHistory(entry.sessionId);
          onRefresh();
        },
      },
    ]);
  };

  return (
    <View style={styles.container}>
      <Text style={styles.heading}>Recent Sessions</Text>
      <FlatList
        data={sessions}
        keyExtractor={(item) => item.sessionId}
        scrollEnabled={false}
        renderItem={({ item }) => (
          <TouchableOpacity
            style={styles.row}
            onPress={() => onRejoin(item)}
            onLongPress={() => handleLongPress(item)}
            activeOpacity={0.7}
          >
            <View style={styles.codeBox}>
              <Text style={styles.code}>{item.joinCode}</Text>
            </View>
            <View style={styles.meta}>
              <Text style={styles.name} numberOfLines={1}>
                {item.displayName || 'Anonymous'}
              </Text>
              <Text style={styles.time}>{timeAgo(item.lastActiveAt)}</Text>
            </View>
            <Text style={styles.arrow}>→</Text>
          </TouchableOpacity>
        )}
      />
    </View>
  );
}

const createStyles = (colors: ThemeColors) =>
  StyleSheet.create({
    container: {
      marginTop: spacing.lg,
    },
    heading: {
      fontSize: fontSize.sm,
      fontWeight: '600',
      color: colors.textSecondary,
      textTransform: 'uppercase',
      letterSpacing: 0.5,
      marginBottom: spacing.sm,
    },
    row: {
      flexDirection: 'row',
      alignItems: 'center',
      backgroundColor: colors.card,
      paddingVertical: spacing.md,
      paddingHorizontal: spacing.md,
      borderRadius: borderRadius.md,
      marginBottom: spacing.xs,
      borderWidth: 1,
      borderColor: colors.border,
      ...shadow.sm,
    },
    codeBox: {
      backgroundColor: colors.surfaceAlt,
      paddingHorizontal: spacing.sm,
      paddingVertical: spacing.xs,
      borderRadius: borderRadius.sm,
      marginRight: spacing.md,
    },
    code: {
      fontSize: fontSize.sm,
      fontWeight: '700',
      color: colors.accent,
      letterSpacing: 2,
    },
    meta: {
      flex: 1,
    },
    name: {
      fontSize: fontSize.md,
      fontWeight: '500',
      color: colors.text,
    },
    time: {
      fontSize: fontSize.xs,
      color: colors.textTertiary,
      marginTop: 1,
    },
    arrow: {
      fontSize: fontSize.lg,
      color: colors.textTertiary,
      marginLeft: spacing.sm,
    },
  });
