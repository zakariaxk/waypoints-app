// Bottom sheet shown when tapping a participant in the list.
// Options: "Focus on map" and (optionally) "Set as destination".

import { useEffect, useRef, useMemo } from 'react';
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  Animated,
  Dimensions,
  Pressable,
  Platform,
} from 'react-native';
import * as Haptics from 'expo-haptics';
import type { Participant, Destination } from '../state/session-store';
import { formatDuration, type ParticipantETA } from '../hooks/useParticipantETAs';
import { formatDistance } from '../utils/geo';
import { spacing, fontSize, borderRadius, shadow, getParticipantColor, type ThemeColors } from '../utils/theme';
import { useTheme } from '../contexts/ThemeContext';

const SCREEN_HEIGHT = Dimensions.get('window').height;
const SHEET_HEIGHT = 280;

interface FriendSheetProps {
  participant: Participant | null;
  eta?: ParticipantETA | null;
  isHost: boolean;
  allParticipantIds: string[];
  currentParticipantId: string | null;
  onFocusOnMap: (participant: Participant) => void;
  onFollowOnMap: (participant: Participant) => void;
  onSetAsDestination: (participant: Participant) => void;
  onClose: () => void;
}

export default function FriendSheet({
  participant,
  eta,
  isHost,
  allParticipantIds,
  currentParticipantId,
  onFocusOnMap,
  onFollowOnMap,
  onSetAsDestination,
  onClose,
}: FriendSheetProps) {
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const translateY = useRef(new Animated.Value(SHEET_HEIGHT)).current;
  const backdropOpacity = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (participant) {
      // Slide in
      Animated.parallel([
        Animated.spring(translateY, {
          toValue: 0,
          useNativeDriver: true,
          damping: 20,
          stiffness: 200,
        }),
        Animated.timing(backdropOpacity, {
          toValue: 1,
          duration: 200,
          useNativeDriver: true,
        }),
      ]).start();
    } else {
      // Slide out
      Animated.parallel([
        Animated.timing(translateY, {
          toValue: SHEET_HEIGHT,
          duration: 200,
          useNativeDriver: true,
        }),
        Animated.timing(backdropOpacity, {
          toValue: 0,
          duration: 200,
          useNativeDriver: true,
        }),
      ]).start();
    }
  }, [participant, translateY, backdropOpacity]);

  if (!participant) return null;

  const hasLocation = !!participant.lastLocation;
  const pColor = getParticipantColor(participant.participantId, allParticipantIds, currentParticipantId);

  return (
    <View style={StyleSheet.absoluteFill} pointerEvents="box-none">
      {/* Backdrop */}
      <Pressable style={StyleSheet.absoluteFill} onPress={onClose}>
        <Animated.View style={[styles.backdrop, { opacity: backdropOpacity }]} />
      </Pressable>

      {/* Sheet */}
      <Animated.View style={[styles.sheet, { transform: [{ translateY }] }]}>
        {/* Handle */}
        <View style={styles.handleRow}>
          <View style={styles.handle} />
        </View>

        {/* Participant info */}
        <View style={styles.header}>
          <View style={[styles.avatar, { backgroundColor: hasLocation ? pColor : colors.markerOffline }]}>
            <Text style={styles.avatarText}>
              {(participant.displayName || '?')[0].toUpperCase()}
            </Text>
          </View>
          <View style={styles.headerInfo}>
            <Text style={styles.name} numberOfLines={1}>
              {participant.displayName || participant.participantId.slice(0, 8)}
            </Text>
            <Text style={styles.status}>
              {participant.status === 'online' ? '● Online' : participant.status}
              {eta ? ` · ETA ${formatDuration(eta.durationSec)} · ${formatDistance(eta.distanceM / 1000)}` : ''}
            </Text>
          </View>
        </View>

        {/* Actions */}
        <View style={styles.actions}>
          <TouchableOpacity
            style={[styles.actionButton, !hasLocation && styles.actionDisabled]}
            activeOpacity={0.7}
            disabled={!hasLocation}
            onPress={() => {
              Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
              onFocusOnMap(participant);
              onClose();
            }}
          >
            <Text style={styles.actionIcon}>🗺</Text>
            <Text style={[styles.actionLabel, !hasLocation && styles.actionLabelDisabled]}>
              Focus on map
            </Text>
          </TouchableOpacity>

          <TouchableOpacity
            style={[styles.actionButton, !hasLocation && styles.actionDisabled]}
            activeOpacity={0.7}
            disabled={!hasLocation}
            onPress={() => {
              Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
              onFollowOnMap(participant);
              onClose();
            }}
          >
            <Text style={styles.actionIcon}>👁</Text>
            <Text style={[styles.actionLabel, !hasLocation && styles.actionLabelDisabled]}>
              Follow on map
            </Text>
          </TouchableOpacity>

          <TouchableOpacity
            style={[styles.actionButton, (!hasLocation || !isHost) && styles.actionDisabled]}
            activeOpacity={0.7}
            disabled={!hasLocation || !isHost}
            onPress={() => {
              Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
              onSetAsDestination(participant);
              onClose();
            }}
          >
            <Text style={styles.actionIcon}>📍</Text>
            <View>
              <Text style={[styles.actionLabel, (!hasLocation || !isHost) && styles.actionLabelDisabled]}>
                Set as destination
              </Text>
              {!isHost && (
                <Text style={styles.actionHint}>Host only</Text>
              )}
            </View>
          </TouchableOpacity>
        </View>
      </Animated.View>
    </View>
  );
}

const createStyles = (colors: ThemeColors) =>
  StyleSheet.create({
    backdrop: {
      ...StyleSheet.absoluteFillObject,
      backgroundColor: colors.overlay,
    },
    sheet: {
      position: 'absolute',
      bottom: 0,
      left: 0,
      right: 0,
      height: SHEET_HEIGHT,
      backgroundColor: colors.card,
      borderTopLeftRadius: borderRadius.xl,
      borderTopRightRadius: borderRadius.xl,
      borderWidth: 1,
      borderBottomWidth: 0,
      borderColor: colors.borderAccent,
      ...Platform.select({
        ios: {
          shadowColor: '#000',
          shadowOffset: { width: 0, height: -4 },
          shadowOpacity: 0.15,
          shadowRadius: 12,
        },
        android: {
          elevation: 8,
        },
      }),
    },
    handleRow: {
      alignItems: 'center',
      paddingTop: spacing.sm,
      paddingBottom: spacing.xs,
    },
    handle: {
      width: 36,
      height: 4,
      borderRadius: 2,
      backgroundColor: colors.border,
    },
    header: {
      flexDirection: 'row',
      alignItems: 'center',
      paddingHorizontal: spacing.lg,
      paddingBottom: spacing.md,
    },
    avatar: {
      width: 44,
      height: 44,
      borderRadius: 22,
      alignItems: 'center',
      justifyContent: 'center',
      marginRight: spacing.md,
    },
    avatarText: {
      color: colors.white,
      fontSize: fontSize.lg,
      fontWeight: '700',
    },
    headerInfo: {
      flex: 1,
    },
    name: {
      fontSize: fontSize.lg,
      fontWeight: '700',
      color: colors.text,
    },
    status: {
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginTop: 2,
    },
    actions: {
      paddingHorizontal: spacing.lg,
      gap: spacing.sm,
    },
    actionButton: {
      flexDirection: 'row',
      alignItems: 'center',
      paddingVertical: spacing.md,
      paddingHorizontal: spacing.lg,
      backgroundColor: colors.surfaceAlt,
      borderRadius: borderRadius.md,
      borderWidth: 1,
      borderColor: colors.border,
    },
    actionDisabled: {
      opacity: 0.45,
    },
    actionIcon: {
      fontSize: 20,
      marginRight: spacing.md,
    },
    actionLabel: {
      fontSize: fontSize.md,
      fontWeight: '600',
      color: colors.text,
    },
    actionLabelDisabled: {
      color: colors.textTertiary,
    },
    actionHint: {
      fontSize: fontSize.xs,
      color: colors.textTertiary,
      marginTop: 1,
    },
  });
