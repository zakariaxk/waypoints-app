// Destination Voting Panel — allows participants to propose and vote on destinations.
// Uses a local voting model visible to all via implicit polling of participant actions.
// The host makes the final decision by accepting a proposal (sets it as destination).

import { useState, useMemo } from 'react';
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  FlatList,
  Alert,
  Platform,
} from 'react-native';
import { spacing, fontSize, borderRadius, getParticipantColor, glow, type ThemeColors, useTheme } from '../ui/theme';

export interface DestinationProposal {
  id: string;
  lat: number;
  lng: number;
  label: string;
  proposedBy: string;
  proposedByName: string;
  votes: Set<string>; // participantIds who voted for this
  timestamp: number;
}

interface DestinationVotingProps {
  proposals: DestinationProposal[];
  currentParticipantId: string | null;
  isHost: boolean;
  allParticipantIds: string[];
  onPropose: (lat: number, lng: number, label: string) => void;
  onVote: (proposalId: string) => void;
  onAccept: (proposal: DestinationProposal) => void;
  onDismiss: () => void;
}

export default function DestinationVoting({
  proposals,
  currentParticipantId,
  isHost,
  allParticipantIds,
  onVote,
  onAccept,
  onDismiss,
}: DestinationVotingProps) {
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);

  // Sort by votes (descending), then by time (newest first)
  const sorted = useMemo(
    () =>
      [...proposals].sort((a, b) => {
        const vDiff = b.votes.size - a.votes.size;
        if (vDiff !== 0) return vDiff;
        return b.timestamp - a.timestamp;
      }),
    [proposals],
  );

  if (proposals.length === 0) {
    return (
      <View style={styles.emptyContainer}>
        <Text style={styles.emptyText}>No destination proposals yet</Text>
        <Text style={styles.emptyHint}>Long-press the map to propose a destination</Text>
        <TouchableOpacity style={styles.closeButton} onPress={onDismiss}>
          <Text style={styles.closeText}>Close</Text>
        </TouchableOpacity>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.title}>📍 Destination Proposals</Text>
        <TouchableOpacity onPress={onDismiss}>
          <Text style={styles.closeIcon}>✕</Text>
        </TouchableOpacity>
      </View>
      <FlatList
        data={sorted}
        keyExtractor={(item) => item.id}
        contentContainerStyle={styles.listContent}
        renderItem={({ item }) => {
          const hasVoted = currentParticipantId ? item.votes.has(currentParticipantId) : false;
          const pColor = getParticipantColor(item.proposedBy, allParticipantIds, currentParticipantId);

          return (
            <View style={styles.proposalRow}>
              <View style={[styles.proposalColor, { backgroundColor: pColor }]} />
              <View style={styles.proposalInfo}>
                <Text style={styles.proposalLabel} numberOfLines={1}>
                  {item.label || `${item.lat.toFixed(4)}, ${item.lng.toFixed(4)}`}
                </Text>
                <Text style={styles.proposalMeta}>
                  by {item.proposedByName} · {item.votes.size} vote{item.votes.size !== 1 ? 's' : ''}
                </Text>
              </View>
              <View style={styles.proposalActions}>
                <TouchableOpacity
                  style={[styles.voteButton, hasVoted && styles.votedButton]}
                  onPress={() => onVote(item.id)}
                  activeOpacity={0.7}
                >
                  <Text style={[styles.voteText, hasVoted && styles.votedText]}>
                    {hasVoted ? '✓' : '👍'}
                  </Text>
                </TouchableOpacity>
                {isHost && (
                  <TouchableOpacity
                    style={styles.acceptButton}
                    onPress={() => onAccept(item)}
                    activeOpacity={0.7}
                  >
                    <Text style={styles.acceptText}>Set</Text>
                  </TouchableOpacity>
                )}
              </View>
            </View>
          );
        }}
      />
      {!isHost && (
        <Text style={styles.hostNote}>The host will choose the final destination</Text>
      )}
    </View>
  );
}

const createStyles = (colors: ThemeColors) =>
  StyleSheet.create({
    container: {
      backgroundColor: colors.panel,
      borderRadius: borderRadius.lg,
      maxHeight: 300,
      overflow: 'hidden',
      borderWidth: 1,
      borderColor: colors.panelBorder,
    },
    emptyContainer: {
      backgroundColor: colors.panel,
      borderRadius: borderRadius.lg,
      padding: spacing.xl,
      alignItems: 'center',
      borderWidth: 1,
      borderColor: colors.panelBorder,
    },
    emptyText: {
      fontSize: fontSize.md,
      fontWeight: '600',
      color: colors.text,
      marginBottom: spacing.xs,
    },
    emptyHint: {
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      textAlign: 'center',
      marginBottom: spacing.md,
    },
    header: {
      flexDirection: 'row',
      justifyContent: 'space-between',
      alignItems: 'center',
      padding: spacing.md,
      borderBottomWidth: 1,
      borderBottomColor: colors.panelBorder,
    },
    title: {
      fontSize: fontSize.md,
      fontWeight: '700',
      color: colors.text,
    },
    closeIcon: {
      fontSize: fontSize.lg,
      color: colors.textSecondary,
      fontWeight: '700',
      padding: spacing.xs,
    },
    listContent: {
      padding: spacing.sm,
    },
    proposalRow: {
      flexDirection: 'row',
      alignItems: 'center',
      paddingVertical: spacing.sm,
      paddingHorizontal: spacing.sm,
      marginBottom: spacing.xs,
      backgroundColor: colors.surface,
      borderRadius: borderRadius.sm,
      borderWidth: 1,
      borderColor: colors.panelBorder,
    },
    proposalColor: {
      width: 4,
      height: 32,
      borderRadius: 2,
      marginRight: spacing.sm,
    },
    proposalInfo: {
      flex: 1,
    },
    proposalLabel: {
      fontSize: fontSize.sm,
      fontWeight: '600',
      color: colors.text,
    },
    proposalMeta: {
      fontSize: fontSize.xs,
      color: colors.textSecondary,
      marginTop: 1,
    },
    proposalActions: {
      flexDirection: 'row',
      gap: spacing.xs,
      marginLeft: spacing.sm,
    },
    voteButton: {
      width: 36,
      height: 36,
      borderRadius: borderRadius.sm,
      backgroundColor: colors.surface,
      alignItems: 'center',
      justifyContent: 'center',
      borderWidth: 1,
      borderColor: colors.panelBorder,
    },
    votedButton: {
      backgroundColor: 'rgba(45,226,230,0.15)',
      borderColor: colors.accent,
    },
    voteText: {
      fontSize: fontSize.sm,
    },
    votedText: {
      color: colors.accent,
      fontWeight: '700',
    },
    acceptButton: {
      paddingHorizontal: spacing.sm,
      height: 36,
      borderRadius: borderRadius.sm,
      backgroundColor: colors.accent,
      alignItems: 'center',
      justifyContent: 'center',
      ...glow.cyan.sm,
    },
    acceptText: {
      color: colors.textInverse,
      fontSize: fontSize.xs,
      fontWeight: '700',
    },
    closeButton: {
      paddingVertical: spacing.sm,
      paddingHorizontal: spacing.lg,
      backgroundColor: colors.surface,
      borderRadius: borderRadius.md,
      borderWidth: 1,
      borderColor: colors.panelBorder,
    },
    closeText: {
      fontSize: fontSize.sm,
      fontWeight: '600',
      color: colors.textSecondary,
    },
    hostNote: {
      fontSize: fontSize.xs,
      color: colors.textTertiary,
      textAlign: 'center',
      paddingVertical: spacing.sm,
    },
  });
