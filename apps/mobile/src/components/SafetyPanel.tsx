// SOS + arrival controls and the incoming-SOS banner (Phase 3).
//
// SOS is deliberately two-tap: it alerts everyone in the session and pins the
// sender's location, so a mis-tap has a real social cost. Clearing is one tap,
// because the failure mode there is someone staying alarmed longer than needed.

import { useMemo } from 'react';
import { View, Text, StyleSheet, TouchableOpacity, Alert } from 'react-native';
import * as Haptics from 'expo-haptics';
import type { ActiveSos, Participant } from '../state/session-store';
import { spacing, fontSize, borderRadius, type ThemeColors, useTheme } from '../ui/theme';

interface SafetyPanelProps {
  activeSos: Map<string, ActiveSos>;
  participants: Map<string, Participant>;
  currentParticipantId: string | null;
  /** True when a destination is set and we are inside the arrival radius. */
  canPingArrival: boolean;
  /** True once the server has confirmed our arrival. */
  hasArrived: boolean;
  onRaiseSos: (note?: string) => void;
  onClearSos: () => void;
  onPingArrival: () => void;
  onFocusParticipant?: (participantId: string) => void;
}

function displayNameFor(
  participants: Map<string, Participant>,
  participantId: string,
): string {
  const p = participants.get(participantId);
  return p?.displayName || participantId.slice(0, 8);
}

export default function SafetyPanel({
  activeSos,
  participants,
  currentParticipantId,
  canPingArrival,
  hasArrived,
  onRaiseSos,
  onClearSos,
  onPingArrival,
  onFocusParticipant,
}: SafetyPanelProps) {
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);

  const myServerSos = currentParticipantId ? activeSos.get(currentParticipantId) : undefined;
  const othersSos = [...activeSos.values()].filter(
    (s) => s.participantId !== currentParticipantId,
  );

  function confirmRaiseSos() {
    Alert.alert(
      'Send SOS?',
      'Everyone in this session is alerted and your location is shared with them.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Send SOS',
          style: 'destructive',
          onPress: () => {
            void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning);
            onRaiseSos();
          },
        },
      ],
    );
  }

  return (
    <View style={styles.container}>
      {othersSos.map((sos) => (
        <TouchableOpacity
          key={sos.participantId}
          style={styles.banner}
          activeOpacity={0.8}
          onPress={() => onFocusParticipant?.(sos.participantId)}
        >
          <Text style={styles.bannerTitle}>
            🆘 {displayNameFor(participants, sos.participantId)} needs help
          </Text>
          {sos.note ? <Text style={styles.bannerNote}>{sos.note}</Text> : null}
          <Text style={styles.bannerHint}>
            {sos.lat !== null && sos.lng !== null
              ? 'Tap to show on map'
              : 'No location reported yet'}
          </Text>
        </TouchableOpacity>
      ))}

      <View style={styles.actions}>
        {myServerSos ? (
          <TouchableOpacity style={[styles.button, styles.clearButton]} onPress={onClearSos}>
            <Text style={styles.clearButtonText}>Clear my SOS</Text>
          </TouchableOpacity>
        ) : (
          <TouchableOpacity style={[styles.button, styles.sosButton]} onPress={confirmRaiseSos}>
            <Text style={styles.sosButtonText}>🆘 SOS</Text>
          </TouchableOpacity>
        )}

        {hasArrived ? (
          <View style={[styles.button, styles.arrivedButton]}>
            <Text style={styles.arrivedText}>✓ Arrived</Text>
          </View>
        ) : (
          <TouchableOpacity
            style={[styles.button, styles.arriveButton, !canPingArrival && styles.buttonDisabled]}
            disabled={!canPingArrival}
            onPress={() => {
              void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
              onPingArrival();
            }}
          >
            <Text style={[styles.arriveText, !canPingArrival && styles.textDisabled]}>
              I&apos;m here
            </Text>
          </TouchableOpacity>
        )}
      </View>
    </View>
  );
}

function createStyles(colors: ThemeColors) {
  return StyleSheet.create({
    container: {
      gap: spacing.sm,
    },
    banner: {
      backgroundColor: '#7F1D1D',
      borderColor: '#EF4444',
      borderWidth: 1,
      borderRadius: borderRadius.md,
      padding: spacing.md,
    },
    bannerTitle: {
      color: '#FEE2E2',
      fontSize: fontSize.md,
      fontWeight: '700',
    },
    bannerNote: {
      color: '#FECACA',
      fontSize: fontSize.sm,
      marginTop: spacing.xs,
    },
    bannerHint: {
      color: '#FCA5A5',
      fontSize: fontSize.xs,
      marginTop: spacing.xs,
    },
    actions: {
      flexDirection: 'row',
      gap: spacing.sm,
    },
    button: {
      flex: 1,
      paddingVertical: spacing.md,
      borderRadius: borderRadius.md,
      alignItems: 'center',
      justifyContent: 'center',
    },
    sosButton: {
      backgroundColor: '#DC2626',
    },
    sosButtonText: {
      color: '#FFFFFF',
      fontWeight: '800',
      fontSize: fontSize.md,
      letterSpacing: 1,
    },
    clearButton: {
      backgroundColor: 'transparent',
      borderWidth: 1,
      borderColor: '#EF4444',
    },
    clearButtonText: {
      color: '#EF4444',
      fontWeight: '700',
      fontSize: fontSize.sm,
    },
    arriveButton: {
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
    },
    arriveText: {
      color: colors.text,
      fontWeight: '700',
      fontSize: fontSize.sm,
    },
    arrivedButton: {
      backgroundColor: '#166534',
    },
    arrivedText: {
      color: '#DCFCE7',
      fontWeight: '700',
      fontSize: fontSize.sm,
    },
    buttonDisabled: {
      opacity: 0.4,
    },
    textDisabled: {
      color: colors.textSecondary,
    },
  });
}
