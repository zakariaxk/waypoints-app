import { useEffect, useState, useCallback, useMemo, useRef } from 'react';
import {
  View,
  Text,
  StyleSheet,
  Alert,
  TouchableOpacity,
  Share,
  Platform,
  StatusBar,
  ToastAndroid,
  KeyboardAvoidingView,
} from 'react-native';
import { useSessionStore, type Participant } from '../state/session-store';
import {
  connectWs,
  disconnectWs,
  sendSetDestination,
  sendClearDestination,
  sendLeaveSession,
  isSessionInvalidated,
  onMessage,
} from '../services/ws-client';
import {
  requestLocationPermission,
  startLocationUpdates,
  stopLocationUpdates,
} from '../services/location';
import * as Haptics from 'expo-haptics';
import * as Clipboard from 'expo-clipboard';
import { updateSessionActivity, removeSessionFromHistory } from '../utils/storage';
import { makeJoinLink } from '../utils/deeplink';
import { useParticipantETAs } from '../hooks/useParticipantETAs';
import { useArrivalAlert } from '../hooks/useArrivalAlert';
import { useSessionTimer } from '../hooks/useSessionTimer';
import MapSection from '../components/MapSection';
import PresenceList from '../components/PresenceList';
import ChatPanel from '../components/ChatPanel';
import DestinationPanel from '../components/DestinationPanel';
import FriendSheet from '../components/FriendSheet';
import GroupETASummary from '../components/GroupETASummary';
import SessionSummaryScreen, { type SessionSummaryData, type ParticipantSummary } from '../components/SessionSummaryScreen';
import DestinationVoting, { type DestinationProposal } from '../components/DestinationVoting';
import { spacing, fontSize, borderRadius, shadow, type ThemeColors } from '../utils/theme';
import { useTheme } from '../contexts/ThemeContext';
import { haversineDistance, formatDistance } from '../utils/geo';

type Tab = 'people' | 'chat';

interface SessionScreenProps {
  onLeave: () => void;
}

export default function SessionScreen({ onLeave }: SessionScreenProps) {
  const { colors, isDark } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const {
    sessionId,
    participantId,
    token,
    joinCode,
    connected,
    reconnectCount,
    chatMessages,
    isHost,
  } = useSessionStore();
  const participants = useSessionStore((s) => s.participants);
  const destination = useSessionStore((s) => s.destination);
  const reset = useSessionStore((s) => s.reset);
  const [locationGranted, setLocationGranted] = useState(false);
  const [activeTab, setActiveTab] = useState<Tab>('people');
  const [unreadChat, setUnreadChat] = useState(0);
  const [focusLocation, setFocusLocation] = useState<{ lat: number; lng: number; _key: number } | null>(null);
  const [toastMessage, setToastMessage] = useState<string | null>(null);
  const focusKeyRef = useRef(0);

  // Friend bottom sheet
  const [selectedFriend, setSelectedFriend] = useState<Participant | null>(null);

  // Follow mode
  const [followTargetId, setFollowTargetId] = useState<string | null>(null);

  // Arrival tracking: Map<participantId, arrivalTimestamp>
  const arrivalsRef = useRef<Map<string, number>>(new Map());

  // Session summary
  const [summaryData, setSummaryData] = useState<SessionSummaryData | null>(null);

  const ARRIVAL_THRESHOLD_KM = 0.05; // 50 meters

  // Destination voting
  const [proposals, setProposals] = useState<DestinationProposal[]>([]);
  const [showVoting, setShowVoting] = useState(false);

  // Per-participant ETAs
  const participantETAs = useParticipantETAs(participants, destination);

  // Session duration timer
  const sessionTimer = useSessionTimer();

  // My location for distance calculation
  const myLocation = useMemo(() => {
    if (!participantId) return null;
    const me = participants.get(participantId);
    return me?.lastLocation ?? null;
  }, [participants, participantId]);

  // Arrival proximity alert
  const handleArrival = useCallback(() => {
    if (Platform.OS === 'android') {
      ToastAndroid.show('🎉 You arrived at the destination!', ToastAndroid.LONG);
    } else {
      setToastMessage('🎉 You arrived at the destination!');
      setTimeout(() => setToastMessage(null), 3000);
    }
  }, []);
  useArrivalAlert(myLocation, destination, handleArrival);

  // Track arrivals for all participants (for session summary)
  useEffect(() => {
    if (!destination) return;
    for (const p of participants.values()) {
      if (!p.lastLocation) continue;
      const dist = haversineDistance(p.lastLocation.lat, p.lastLocation.lng, destination.lat, destination.lng);
      if (dist < ARRIVAL_THRESHOLD_KM && !arrivalsRef.current.has(p.participantId)) {
        arrivalsRef.current.set(p.participantId, Date.now());
      }
    }
  }, [participants, destination]);

  // Track unread chat when on people tab
  const prevChatLenRef = useRef(chatMessages.length);
  useEffect(() => {
    if (activeTab === 'chat') {
      setUnreadChat(0);
      prevChatLenRef.current = chatMessages.length;
    }
  }, [activeTab, chatMessages.length]);

  useEffect(() => {
    if (activeTab !== 'chat') {
      const newCount = chatMessages.length - prevChatLenRef.current;
      if (newCount > 0) {
        // Only count messages from others
        const newMessages = chatMessages.slice(prevChatLenRef.current);
        const othersCount = newMessages.filter((m) => m.participantId !== participantId).length;
        if (othersCount > 0) {
          setUnreadChat((prev) => prev + othersCount);
        }
        prevChatLenRef.current = chatMessages.length;
      }
    }
  }, [chatMessages.length, activeTab, participantId]);

  // Connect WebSocket
  useEffect(() => {
    if (sessionId && participantId && token) {
      connectWs(sessionId, participantId, token, null);
    }
    return () => {
      disconnectWs();
    };
  }, [sessionId, participantId, token]);

  // Detect dead/expired session — server lost it (free tier restart, etc.)
  useEffect(() => {
    const unsub = onMessage((msg: unknown) => {
      const m = msg as { type?: string; payload?: { code?: string } };
      if (m.type === 'ERROR') {
        const code = m.payload?.code;
        if (code === 'NOT_IN_SESSION' || code === 'SESSION_NOT_FOUND' || code === 'INVALID_TOKEN') {
          // Remove stale entry from history and go home
          if (sessionId) {
            removeSessionFromHistory(sessionId);
          }
          stopLocationUpdates();
          reset();
          Alert.alert(
            'Session Expired',
            'This session no longer exists on the server. It may have been cleared when the server restarted.',
            [{ text: 'OK', onPress: onLeave }],
          );
        }
      }
    });
    return unsub;
  }, [sessionId, reset, onLeave]);

  // Update session activity timestamp periodically
  useEffect(() => {
    if (!sessionId) return;
    updateSessionActivity(sessionId);
    const timer = setInterval(() => updateSessionActivity(sessionId), 30_000);
    return () => clearInterval(timer);
  }, [sessionId]);

  // Request location permission and start updates
  useEffect(() => {
    (async () => {
      const granted = await requestLocationPermission();
      setLocationGranted(granted);
      if (granted) {
        await startLocationUpdates();
      } else {
        Alert.alert(
          'Location Required',
          'Waypoints needs location access to share your position with your group. Please enable it in Settings.',
          [{ text: 'OK' }],
        );
      }
    })();
    return () => {
      stopLocationUpdates();
    };
  }, []);

  const handleLeave = useCallback(() => {
    Alert.alert('Leave Session', 'Are you sure you want to leave?', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Leave',
        style: 'destructive',
        onPress: () => {
          // Build session summary before resetting state
          const arrivals = arrivalsRef.current;
          const arrivalOrder = Array.from(arrivals.entries())
            .sort((a, b) => a[1] - b[1]);

          const summaries: ParticipantSummary[] = Array.from(participants.values()).map((p) => {
            const arrIdx = arrivalOrder.findIndex(([pid]) => pid === p.participantId);
            const arrivalTs = arrivals.get(p.participantId);
            let distToDest: number | undefined;
            if (destination && p.lastLocation) {
              distToDest = haversineDistance(p.lastLocation.lat, p.lastLocation.lng, destination.lat, destination.lng) * 1000;
            }
            return {
              participantId: p.participantId,
              displayName: p.displayName || p.participantId.slice(0, 8),
              isMe: p.participantId === participantId,
              arrived: arrivals.has(p.participantId),
              arrivalOrder: arrIdx >= 0 ? arrIdx + 1 : undefined,
              arrivalTime: arrivalTs ? new Date(arrivalTs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : undefined,
              distanceToDestinationM: distToDest,
            };
          });

          const summary: SessionSummaryData = {
            sessionDuration: sessionTimer,
            participantSummaries: summaries,
            destinationLabel: destination?.label ?? null,
          };

          sendLeaveSession();
          stopLocationUpdates();

          // Show summary if there was a destination
          if (destination) {
            setSummaryData(summary);
          } else {
            reset();
            onLeave();
          }
        },
      },
    ]);
  }, [onLeave, reset, participants, destination, participantId, sessionTimer]);

  const handleShare = useCallback(async () => {
    if (!joinCode) return;
    try {
      const link = makeJoinLink(joinCode);
      await Share.share({
        message: `Join my Waypoints session!\n\nCode: ${joinCode}\n${link}`,
      });
    } catch {
      // User cancelled share
    }
  }, [joinCode]);

  const handleCopyCode = useCallback(async () => {
    if (!joinCode) return;
    await Clipboard.setStringAsync(joinCode);
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
    if (Platform.OS === 'android') {
      ToastAndroid.show('Code copied!', ToastAndroid.SHORT);
    } else {
      setToastMessage('Code copied!');
      setTimeout(() => setToastMessage(null), 1500);
    }
  }, [joinCode]);

  const handleMapLongPress = useCallback(
    (lat: number, lng: number) => {
      if (isHost) {
        // Host can set destination directly
        // @ts-ignore — Alert.prompt exists on iOS but not in types
        if (Platform.OS === 'ios' && Alert.prompt) {
          // @ts-ignore
          Alert.prompt(
            'Set Destination',
            'Enter a label for the destination (optional)',
            [
              { text: 'Cancel', style: 'cancel' },
              {
                text: 'Set',
                onPress: (label?: string) => {
                  sendSetDestination(lat, lng, label || null);
                },
              },
            ],
            'plain-text',
          );
        } else {
          Alert.alert('Set Destination', `Set destination at this location?`, [
            { text: 'Cancel', style: 'cancel' },
            {
              text: 'Set',
              onPress: () => {
                sendSetDestination(lat, lng, null);
              },
            },
          ]);
        }
      } else {
        // Non-host: propose destination
        const proposal: DestinationProposal = {
          id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
          lat,
          lng,
          label: `Proposal ${proposals.length + 1}`,
          proposedBy: participantId || 'unknown',
          proposedByName: useSessionStore.getState().displayName || 'Anonymous',
          votes: new Set([participantId || '']),
          timestamp: Date.now(),
        };
        setProposals((prev) => [...prev, proposal]);
        setShowVoting(true);
        if (Platform.OS === 'android') {
          ToastAndroid.show('📍 Destination proposed!', ToastAndroid.SHORT);
        } else {
          setToastMessage('📍 Destination proposed!');
          setTimeout(() => setToastMessage(null), 2000);
        }
      }
    },
    [isHost, participantId, proposals.length],
  );

  const handleClearDestination = useCallback(() => {
    Alert.alert('Clear Destination', 'Remove the current destination?', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Clear',
        style: 'destructive',
        onPress: () => sendClearDestination(),
      },
    ]);
  }, []);

  // Voting handlers
  const handleVote = useCallback((proposalId: string) => {
    if (!participantId) return;
    setProposals((prev) =>
      prev.map((p) => {
        if (p.id !== proposalId) return p;
        const newVotes = new Set(p.votes);
        if (newVotes.has(participantId)) {
          newVotes.delete(participantId);
        } else {
          newVotes.add(participantId);
        }
        return { ...p, votes: newVotes };
      }),
    );
  }, [participantId]);

  const handleAcceptProposal = useCallback((proposal: DestinationProposal) => {
    sendSetDestination(proposal.lat, proposal.lng, proposal.label || null);
    setShowVoting(false);
    setProposals([]);
  }, []);

  // ─── Participant focus ───
  const handleParticipantPress = useCallback((p: Participant) => {
    setSelectedFriend(p);
  }, []);

  const handleFocusOnMap = useCallback((p: Participant) => {
    if (!p.lastLocation) {
      if (Platform.OS === 'android') {
        ToastAndroid.show('No location yet', ToastAndroid.SHORT);
      } else {
        setToastMessage('No location yet');
        setTimeout(() => setToastMessage(null), 2000);
      }
      return;
    }
    focusKeyRef.current += 1;
    setFocusLocation({ lat: p.lastLocation.lat, lng: p.lastLocation.lng, _key: focusKeyRef.current });
  }, []);

  const handleFollowOnMap = useCallback((p: Participant) => {
    if (!p.lastLocation) return;
    setFollowTargetId(p.participantId);
    if (Platform.OS === 'android') {
      ToastAndroid.show(`Following ${p.displayName || 'participant'}`, ToastAndroid.SHORT);
    } else {
      setToastMessage(`Following ${p.displayName || 'participant'}`);
      setTimeout(() => setToastMessage(null), 2000);
    }
  }, []);

  const handleSetFriendAsDestination = useCallback((p: Participant) => {
    if (!p.lastLocation) return;
    if (!isHost) {
      Alert.alert('Host Only', 'Only the session host can set the destination.');
      return;
    }
    sendSetDestination(
      p.lastLocation.lat,
      p.lastLocation.lng,
      p.displayName ? `${p.displayName}'s location` : null,
    );
  }, [isHost]);

  const participantList = Array.from(participants.values());
  const onlineCount = participantList.filter((p) => p.status === 'online').length;

  return (
    <View style={styles.container}>
      <StatusBar barStyle={isDark ? 'light-content' : 'dark-content'} />

      {/* Header */}
      <View style={styles.header}>
        <TouchableOpacity onPress={handleLeave} style={styles.headerButton}>
          <Text style={styles.leaveText}>← Leave</Text>
        </TouchableOpacity>

        <View style={styles.headerCenter}>
          <TouchableOpacity
            onPress={handleShare}
            onLongPress={handleCopyCode}
            style={styles.codeContainer}
          >
            <Text style={styles.codeText}>{joinCode || '------'}</Text>
            <Text style={styles.shareHint}>tap share · hold copy</Text>
          </TouchableOpacity>
        </View>

        <View style={styles.headerRight}>
          <View
            style={[
              styles.connectionDot,
              connected ? styles.dotConnected : styles.dotDisconnected,
            ]}
          />
          <View>
            <Text style={styles.connectionText}>
              {connected
                ? `${onlineCount} online`
                : reconnectCount > 0
                  ? `Retry #${reconnectCount}...`
                  : 'Connecting...'}
            </Text>
            <Text style={styles.timerText}>⏱ {sessionTimer}</Text>
          </View>
        </View>
      </View>

      {/* Offline / Connecting Banner */}
      {!connected && (
        <View style={styles.offlineBanner}>
          <Text style={styles.offlineBannerText}>
            {reconnectCount > 0
              ? `⚠ Connection lost — reconnecting (attempt ${reconnectCount})...`
              : '⚠ Connecting to server...'}
          </Text>
        </View>
      )}

      {/* Host badge */}
      {isHost && (
        <View style={styles.hostBadge}>
          <Text style={styles.hostBadgeText}>
            👑 You are the host — long-press map to set destination
          </Text>
          {proposals.length > 0 && (
            <TouchableOpacity onPress={() => setShowVoting(!showVoting)}>
              <Text style={styles.votingToggle}>
                📋 {proposals.length} proposal{proposals.length > 1 ? 's' : ''}
              </Text>
            </TouchableOpacity>
          )}
        </View>
      )}

      {/* Non-host hint */}
      {!isHost && (
        <View style={styles.hostBadge}>
          <Text style={styles.hostBadgeText}>
            Long-press map to propose a destination
          </Text>
          {proposals.length > 0 && (
            <TouchableOpacity onPress={() => setShowVoting(!showVoting)}>
              <Text style={styles.votingToggle}>
                📋 {proposals.length} proposal{proposals.length > 1 ? 's' : ''}
              </Text>
            </TouchableOpacity>
          )}
        </View>
      )}

      {/* Map Section */}
      <View style={styles.mapContainer}>
        {locationGranted ? (
          <MapSection
            currentParticipantId={participantId}
            onLongPress={handleMapLongPress}
            focusLocation={focusLocation}
            followTargetId={followTargetId}
            onFollowEnd={() => setFollowTargetId(null)}
          />
        ) : (
          <View style={styles.noLocationContainer}>
            <Text style={styles.noLocationEmoji}>📍</Text>
            <Text style={styles.noLocationTitle}>Location Access Needed</Text>
            <Text style={styles.noLocationText}>
              Enable location permissions in your device settings to see everyone on the map.
            </Text>
          </View>
        )}
      </View>

      {/* Voting panel (when open) */}
      {showVoting && (
        <DestinationVoting
          proposals={proposals}
          currentParticipantId={participantId}
          isHost={isHost}
          allParticipantIds={participantList.map((p) => p.participantId)}
          onPropose={() => {}}
          onVote={handleVote}
          onAccept={handleAcceptProposal}
          onDismiss={() => setShowVoting(false)}
        />
      )}

      {/* Destination bar (if set) */}
      <DestinationPanel
        destination={destination}
        myLocation={myLocation}
        myETA={participantId ? participantETAs.get(participantId) ?? null : null}
        isHost={isHost}
        onClear={handleClearDestination}
      />

      {/* Group ETA Summary (when destination is set and ETAs available) */}
      {destination && participantETAs.size > 0 && (
        <GroupETASummary
          etas={participantETAs}
          participantNames={new Map(participantList.map((p) => [p.participantId, p.displayName || p.participantId.slice(0, 6)]))}
        />
      )}

      {/* Tab Bar */}
      <View style={styles.tabBar}>
        <TouchableOpacity
          style={[styles.tab, activeTab === 'people' && styles.activeTab]}
          onPress={() => setActiveTab('people')}
        >
          <Text style={[styles.tabText, activeTab === 'people' && styles.activeTabText]}>
            People ({participantList.length})
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.tab, activeTab === 'chat' && styles.activeTab]}
          onPress={() => {
            setActiveTab('chat');
            setUnreadChat(0);
          }}
        >
          <Text style={[styles.tabText, activeTab === 'chat' && styles.activeTabText]}>
            Chat
            {unreadChat > 0 && (
              <Text style={styles.badge}> ({unreadChat})</Text>
            )}
          </Text>
        </TouchableOpacity>
      </View>

      {/* Tab Content — wrapped in KeyboardAvoidingView for chat input */}
      <KeyboardAvoidingView
        style={styles.tabContent}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        keyboardVerticalOffset={Platform.OS === 'ios' ? 0 : 0}
      >
        {activeTab === 'people' ? (
          <PresenceList
            participants={participantList}
            currentParticipantId={participantId}
            hostParticipantId={useSessionStore.getState().hostParticipantId}
            myLocation={myLocation}
            destination={destination}
            etas={participantETAs}
            onParticipantPress={handleParticipantPress}
          />
        ) : (
          <ChatPanel currentParticipantId={participantId} />
        )}
      </KeyboardAvoidingView>

      {/* iOS toast banner */}
      {toastMessage && (
        <View style={styles.toast}>
          <Text style={styles.toastText}>{toastMessage}</Text>
        </View>
      )}

      {/* Friend bottom sheet */}
      <FriendSheet
        participant={selectedFriend}
        eta={selectedFriend ? participantETAs.get(selectedFriend.participantId) ?? null : null}
        isHost={isHost}
        allParticipantIds={participantList.map((p) => p.participantId)}
        currentParticipantId={participantId}
        onFocusOnMap={handleFocusOnMap}
        onFollowOnMap={handleFollowOnMap}
        onSetAsDestination={handleSetFriendAsDestination}
        onClose={() => setSelectedFriend(null)}
      />

      {/* Session summary overlay */}
      {summaryData && (
        <View style={StyleSheet.absoluteFill}>
          <SessionSummaryScreen
            data={summaryData}
            onDismiss={() => {
              setSummaryData(null);
              reset();
              onLeave();
            }}
          />
        </View>
      )}
    </View>
  );
}

const createStyles = (colors: ThemeColors) =>
  StyleSheet.create({
    container: {
      flex: 1,
      backgroundColor: colors.background,
    },
    header: {
      flexDirection: 'row',
      alignItems: 'center',
      paddingHorizontal: spacing.md,
      paddingTop: Platform.OS === 'ios' ? 50 : spacing.lg,
      paddingBottom: spacing.sm,
      backgroundColor: colors.surface,
      borderBottomWidth: 1,
      borderBottomColor: colors.border,
      ...shadow.sm,
    },
    headerButton: {
      paddingVertical: spacing.xs,
      paddingRight: spacing.sm,
    },
    leaveText: {
      fontSize: fontSize.md,
      color: colors.offline,
      fontWeight: '600',
    },
    headerCenter: {
      flex: 1,
      alignItems: 'center',
    },
    codeContainer: {
      alignItems: 'center',
      paddingVertical: spacing.xs,
      paddingHorizontal: spacing.md,
      backgroundColor: colors.surfaceAlt,
      borderRadius: borderRadius.md,
      borderWidth: 1,
      borderColor: colors.borderAccent,
    },
    codeText: {
      fontSize: fontSize.lg,
      fontWeight: '700',
      color: colors.accent,
      letterSpacing: 3,
    },
    shareHint: {
      fontSize: fontSize.xs - 1,
      color: colors.textTertiary,
      marginTop: 1,
    },
    headerRight: {
      flexDirection: 'row',
      alignItems: 'center',
      paddingLeft: spacing.sm,
    },
    connectionDot: {
      width: 8,
      height: 8,
      borderRadius: 4,
      marginRight: spacing.xs,
    },
    dotConnected: {
      backgroundColor: colors.online,
    },
    dotDisconnected: {
      backgroundColor: colors.offline,
    },
    connectionText: {
      fontSize: fontSize.xs,
      color: colors.textSecondary,
    },
    timerText: {
      fontSize: fontSize.xs - 1,
      color: colors.textTertiary,
      marginTop: 1,
    },
    hostBadge: {
      backgroundColor: colors.destinationBg,
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.xs,
      borderBottomWidth: 1,
      borderBottomColor: colors.destinationBorder,
    },
    hostBadgeText: {
      fontSize: fontSize.xs,
      color: colors.destinationText,
      textAlign: 'center',
      fontWeight: '500',
    },
    votingToggle: {
      fontSize: fontSize.xs,
      color: colors.accent,
      fontWeight: '700',
      textAlign: 'center',
      marginTop: spacing.xs,
    },
    offlineBanner: {
      backgroundColor: colors.dangerLight,
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.sm,
      borderBottomWidth: 1,
      borderBottomColor: colors.danger + '40',
    },
    offlineBannerText: {
      fontSize: fontSize.xs,
      color: colors.danger,
      textAlign: 'center',
      fontWeight: '600',
    },
    mapContainer: {
      flex: 3,
      minHeight: 200,
    },
    noLocationContainer: {
      flex: 1,
      alignItems: 'center',
      justifyContent: 'center',
      backgroundColor: colors.surfaceAlt,
      padding: spacing.xl,
    },
    noLocationEmoji: {
      fontSize: 48,
      marginBottom: spacing.md,
    },
    noLocationTitle: {
      fontSize: fontSize.lg,
      fontWeight: '600',
      color: colors.text,
      marginBottom: spacing.sm,
    },
    noLocationText: {
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      textAlign: 'center',
      lineHeight: 20,
    },
    tabBar: {
      flexDirection: 'row',
      borderTopWidth: 1,
      borderTopColor: colors.border,
      backgroundColor: colors.surface,
    },
    tab: {
      flex: 1,
      paddingVertical: spacing.sm,
      alignItems: 'center',
      borderBottomWidth: 2,
      borderBottomColor: 'transparent',
    },
    activeTab: {
      borderBottomColor: colors.accent,
    },
    tabText: {
      fontSize: fontSize.sm,
      fontWeight: '500',
      color: colors.textSecondary,
    },
    activeTabText: {
      color: colors.accent,
      fontWeight: '600',
    },
    badge: {
      color: colors.secondary,
      fontWeight: '700',
    },
    tabContent: {
      flex: 2,
      minHeight: 120,
      backgroundColor: colors.surface,
    },
    toast: {
      position: 'absolute',
      bottom: 100,
      alignSelf: 'center',
      backgroundColor: colors.surface,
      paddingHorizontal: spacing.lg,
      paddingVertical: spacing.sm,
      borderRadius: borderRadius.full,
      borderWidth: 1,
      borderColor: colors.borderAccent,
    },
    toastText: {
      color: colors.text,
      fontSize: fontSize.sm,
      fontWeight: '600',
    },
  });
