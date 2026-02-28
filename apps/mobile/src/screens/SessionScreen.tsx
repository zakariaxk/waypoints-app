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
} from 'react-native';
import { useSessionStore } from '../state/session-store';
import {
  connectWs,
  disconnectWs,
  sendSetDestination,
  sendClearDestination,
  sendLeaveSession,
} from '../services/ws-client';
import {
  requestLocationPermission,
  startLocationUpdates,
  stopLocationUpdates,
} from '../services/location';
import { updateSessionActivity } from '../utils/storage';
import { makeJoinLink } from '../utils/deeplink';
import MapSection from '../components/MapSection';
import PresenceList from '../components/PresenceList';
import ChatPanel from '../components/ChatPanel';
import DestinationPanel from '../components/DestinationPanel';
import { colors, spacing, fontSize, borderRadius, shadow } from '../utils/theme';

type Tab = 'people' | 'chat';

interface SessionScreenProps {
  onLeave: () => void;
}

export default function SessionScreen({ onLeave }: SessionScreenProps) {
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

  // My location for distance calculation
  const myLocation = useMemo(() => {
    if (!participantId) return null;
    const me = participants.get(participantId);
    return me?.lastLocation ?? null;
  }, [participants, participantId]);

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
          sendLeaveSession();
          stopLocationUpdates();
          reset();
          onLeave();
        },
      },
    ]);
  }, [onLeave, reset]);

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

  const handleMapLongPress = useCallback(
    (lat: number, lng: number) => {
      if (!isHost) {
        Alert.alert('Host Only', 'Only the session host can set the destination.');
        return;
      }

      // @ts-expect-error — Alert.prompt exists on iOS but not in types
      if (Platform.OS === 'ios' && Alert.prompt) {
        // @ts-expect-error
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
    },
    [isHost],
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

  const participantList = Array.from(participants.values());
  const onlineCount = participantList.filter((p) => p.status === 'online').length;

  return (
    <View style={styles.container}>
      <StatusBar barStyle="dark-content" />

      {/* Header */}
      <View style={styles.header}>
        <TouchableOpacity onPress={handleLeave} style={styles.headerButton}>
          <Text style={styles.leaveText}>← Leave</Text>
        </TouchableOpacity>

        <View style={styles.headerCenter}>
          <TouchableOpacity onPress={handleShare} style={styles.codeContainer}>
            <Text style={styles.codeText}>{joinCode || '------'}</Text>
            <Text style={styles.shareHint}>tap to share</Text>
          </TouchableOpacity>
        </View>

        <View style={styles.headerRight}>
          <View
            style={[
              styles.connectionDot,
              connected ? styles.dotConnected : styles.dotDisconnected,
            ]}
          />
          <Text style={styles.connectionText}>
            {connected
              ? `${onlineCount} online`
              : reconnectCount > 0
                ? `Retry #${reconnectCount}...`
                : 'Connecting...'}
          </Text>
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
        </View>
      )}

      {/* Map Section */}
      <View style={styles.mapContainer}>
        {locationGranted ? (
          <MapSection
            currentParticipantId={participantId}
            onLongPress={handleMapLongPress}
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

      {/* Destination bar (if set) */}
      <DestinationPanel
        destination={destination}
        myLocation={myLocation}
        isHost={isHost}
        onClear={handleClearDestination}
      />

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

      {/* Tab Content */}
      <View style={styles.tabContent}>
        {activeTab === 'people' ? (
          <PresenceList
            participants={participantList}
            currentParticipantId={participantId}
            hostParticipantId={useSessionStore.getState().hostParticipantId}
            myLocation={myLocation}
          />
        ) : (
          <ChatPanel currentParticipantId={participantId} />
        )}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
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
    backgroundColor: colors.white,
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
  },
  codeText: {
    fontSize: fontSize.lg,
    fontWeight: '700',
    color: colors.primary,
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
  offlineBanner: {
    backgroundColor: colors.dangerLight,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderBottomWidth: 1,
    borderBottomColor: '#FECACA',
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
    backgroundColor: colors.white,
  },
  tab: {
    flex: 1,
    paddingVertical: spacing.sm,
    alignItems: 'center',
    borderBottomWidth: 2,
    borderBottomColor: 'transparent',
  },
  activeTab: {
    borderBottomColor: colors.primary,
  },
  tabText: {
    fontSize: fontSize.sm,
    fontWeight: '500',
    color: colors.textSecondary,
  },
  activeTabText: {
    color: colors.primary,
    fontWeight: '600',
  },
  badge: {
    color: colors.offline,
    fontWeight: '700',
  },
  tabContent: {
    flex: 2,
    minHeight: 120,
    backgroundColor: colors.white,
  },
});
