// ListenAlongPanel — Shows current music broadcast and allows joining/leaving.
// Displays the broadcaster, platform, track info, and listener count.

import { useMemo } from 'react';
import { View, Text, StyleSheet, Image, TouchableOpacity } from 'react-native';
import { useListenAlong } from '../hooks/useListenAlong';
import { useSessionStore, type MusicPlatform } from '../state/session-store';
import { spacing, fontSize, borderRadius, useTheme, type ThemeColors } from '../ui/theme';

interface ListenAlongPanelProps {
  sessionId: string | null;
  onStartBroadcast?: () => void;
}

const PLATFORM_LABELS: Record<MusicPlatform, string> = {
  spotify: 'Spotify',
  apple_music: 'Apple Music',
  soundcloud: 'SoundCloud',
};

const PLATFORM_COLORS: Record<MusicPlatform, string> = {
  spotify: '#1DB954',
  apple_music: '#FA2D48',
  soundcloud: '#FF5500',
};

function formatTime(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${seconds.toString().padStart(2, '0')}`;
}

export default function ListenAlongPanel({ sessionId, onStartBroadcast }: ListenAlongPanelProps) {
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  
  const {
    broadcast,
    listeners,
    isBroadcaster,
    isListening,
    canJoin,
    join,
    leave,
  } = useListenAlong(sessionId);

  const participants = useSessionStore((s) => s.participants);
  const participantId = useSessionStore((s) => s.participantId);

  // Get broadcaster's display name
  const broadcasterName = useMemo(() => {
    if (!broadcast) return null;
    const p = participants.get(broadcast.broadcasterId);
    if (!p) return 'Unknown';
    if (broadcast.broadcasterId === participantId) return 'You';
    return p.displayName || p.participantId.slice(0, 8);
  }, [broadcast, participants, participantId]);

  // No active broadcast — show start button
  if (!broadcast) {
    return (
      <View style={styles.container}>
        <View style={styles.emptyState}>
          <Text style={styles.emptyIcon}>🎵</Text>
          <Text style={styles.emptyTitle}>No music playing</Text>
          <Text style={styles.emptySubtitle}>Start a listen-along session for your party</Text>
          {onStartBroadcast && (
            <TouchableOpacity style={styles.startButton} onPress={onStartBroadcast} activeOpacity={0.7}>
              <Text style={styles.startButtonText}>Start Broadcasting</Text>
            </TouchableOpacity>
          )}
        </View>
      </View>
    );
  }

  const platformColor = PLATFORM_COLORS[broadcast.platform];
  const platformLabel = PLATFORM_LABELS[broadcast.platform];

  return (
    <View style={styles.container}>
      {/* Header with platform badge */}
      <View style={styles.header}>
        <View style={[styles.platformBadge, { backgroundColor: platformColor }]}>
          <Text style={styles.platformText}>{platformLabel}</Text>
        </View>
        <Text style={styles.listenerCount}>
          {listeners.length} {listeners.length === 1 ? 'listener' : 'listeners'}
        </Text>
      </View>

      {/* Track info */}
      <View style={styles.trackInfo}>
        {broadcast.track.albumArt && (
          <Image source={{ uri: broadcast.track.albumArt }} style={styles.albumArt} />
        )}
        <View style={styles.trackDetails}>
          <Text style={styles.trackTitle} numberOfLines={1}>
            {broadcast.track.title}
          </Text>
          <Text style={styles.trackArtist} numberOfLines={1}>
            {broadcast.track.artist}
          </Text>
          <Text style={styles.trackBroadcaster}>
            DJ: {broadcasterName}
          </Text>
        </View>
      </View>

      {/* Playback state */}
      <View style={styles.playbackRow}>
        <Text style={styles.playbackIcon}>{broadcast.isPlaying ? '▶️' : '⏸️'}</Text>
        <Text style={styles.playbackTime}>
          {formatTime(broadcast.positionMs)} / {formatTime(broadcast.track.durationMs)}
        </Text>
      </View>

      {/* Action buttons */}
      <View style={styles.actions}>
        {isBroadcaster ? (
          <TouchableOpacity style={styles.leaveButton} onPress={leave} activeOpacity={0.7}>
            <Text style={styles.leaveButtonText}>Stop Broadcasting</Text>
          </TouchableOpacity>
        ) : isListening ? (
          <TouchableOpacity style={styles.leaveButton} onPress={leave} activeOpacity={0.7}>
            <Text style={styles.leaveButtonText}>Leave Session</Text>
          </TouchableOpacity>
        ) : canJoin ? (
          <TouchableOpacity style={[styles.joinButton, { backgroundColor: platformColor }]} onPress={join} activeOpacity={0.7}>
            <Text style={styles.joinButtonText}>Join Listen-Along</Text>
          </TouchableOpacity>
        ) : null}
      </View>

      {/* Compatibility notice for non-listeners */}
      {!isListening && canJoin && (
        <Text style={styles.compatibilityNotice}>
          Requires {platformLabel} app installed
        </Text>
      )}
    </View>
  );
}

function createStyles(colors: ThemeColors) {
  return StyleSheet.create({
    container: {
      backgroundColor: colors.panel,
      borderRadius: borderRadius.lg,
      borderWidth: 1,
      borderColor: colors.panelBorder,
      padding: spacing.md,
      marginBottom: spacing.md,
    },
    emptyState: {
      alignItems: 'center',
      paddingVertical: spacing.lg,
    },
    emptyIcon: {
      fontSize: 32,
      marginBottom: spacing.sm,
    },
    emptyTitle: {
      color: colors.text,
      fontSize: fontSize.lg,
      fontWeight: '600',
      marginBottom: spacing.xs,
    },
    emptySubtitle: {
      color: colors.textSecondary,
      fontSize: fontSize.sm,
      textAlign: 'center',
      marginBottom: spacing.md,
    },
    startButton: {
      backgroundColor: colors.accent,
      paddingHorizontal: spacing.lg,
      paddingVertical: spacing.sm,
      borderRadius: borderRadius.md,
    },
    startButtonText: {
      color: colors.background,
      fontSize: fontSize.md,
      fontWeight: '600',
    },
    header: {
      flexDirection: 'row',
      justifyContent: 'space-between',
      alignItems: 'center',
      marginBottom: spacing.sm,
    },
    platformBadge: {
      paddingHorizontal: spacing.sm,
      paddingVertical: spacing.xs,
      borderRadius: borderRadius.sm,
    },
    platformText: {
      color: '#FFFFFF',
      fontSize: fontSize.xs,
      fontWeight: '700',
      textTransform: 'uppercase',
      letterSpacing: 0.5,
    },
    listenerCount: {
      color: colors.textSecondary,
      fontSize: fontSize.sm,
    },
    trackInfo: {
      flexDirection: 'row',
      alignItems: 'center',
      marginBottom: spacing.sm,
    },
    albumArt: {
      width: 56,
      height: 56,
      borderRadius: borderRadius.sm,
      marginRight: spacing.md,
      backgroundColor: colors.surface,
    },
    trackDetails: {
      flex: 1,
    },
    trackTitle: {
      color: colors.text,
      fontSize: fontSize.md,
      fontWeight: '600',
      marginBottom: 2,
    },
    trackArtist: {
      color: colors.textSecondary,
      fontSize: fontSize.sm,
      marginBottom: 2,
    },
    trackBroadcaster: {
      color: colors.textTertiary,
      fontSize: fontSize.xs,
    },
    playbackRow: {
      flexDirection: 'row',
      alignItems: 'center',
      marginBottom: spacing.md,
    },
    playbackIcon: {
      fontSize: 16,
      marginRight: spacing.sm,
    },
    playbackTime: {
      color: colors.textSecondary,
      fontSize: fontSize.sm,
      fontFamily: 'monospace',
    },
    actions: {
      flexDirection: 'row',
      justifyContent: 'center',
    },
    joinButton: {
      flex: 1,
      paddingVertical: spacing.sm,
      borderRadius: borderRadius.md,
      alignItems: 'center',
    },
    joinButtonText: {
      color: '#FFFFFF',
      fontSize: fontSize.md,
      fontWeight: '600',
    },
    leaveButton: {
      flex: 1,
      paddingVertical: spacing.sm,
      borderRadius: borderRadius.md,
      alignItems: 'center',
      backgroundColor: 'rgba(255, 42, 109, 0.2)',
      borderWidth: 1,
      borderColor: 'rgba(255, 42, 109, 0.5)',
    },
    leaveButtonText: {
      color: '#FF2A6D',
      fontSize: fontSize.md,
      fontWeight: '600',
    },
    compatibilityNotice: {
      color: colors.textTertiary,
      fontSize: fontSize.xs,
      textAlign: 'center',
      marginTop: spacing.sm,
    },
  });
}
