import { useState, useRef, useEffect, useMemo, useCallback } from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  FlatList,
  Platform,
  StyleSheet,
  Keyboard,
} from 'react-native';
import { useSessionStore, type ChatMessage } from '../state/session-store';
import { sendChatMessage } from '../services/ws-client';
import { spacing, fontSize, borderRadius, glow, type ThemeColors, useTheme } from '../ui/theme';

interface ChatPanelProps {
  currentParticipantId: string | null;
}

export default function ChatPanel({ currentParticipantId }: ChatPanelProps) {
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const [text, setText] = useState('');
  const flatListRef = useRef<FlatList>(null);
  const chatMessages = useSessionStore((s) => s.chatMessages);

  // Stable scroll-to-end callback
  const scrollToEnd = useCallback((animated = true) => {
    flatListRef.current?.scrollToEnd({ animated });
  }, []);

  // Auto-scroll to bottom on new messages
  useEffect(() => {
    if (chatMessages.length > 0) {
      setTimeout(() => scrollToEnd(), 100);
    }
  }, [chatMessages.length, scrollToEnd]);

  // Scroll to bottom when keyboard opens
  useEffect(() => {
    const showEvent = Platform.OS === 'ios' ? 'keyboardWillShow' : 'keyboardDidShow';
    const sub = Keyboard.addListener(showEvent, () => {
      setTimeout(() => scrollToEnd(), 150);
    });
    return () => sub.remove();
  }, [scrollToEnd]);

  const handleSend = () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    sendChatMessage(trimmed);
    setText('');
    // Scroll after sending
    setTimeout(() => scrollToEnd(), 100);
  };

  const formatTime = (ts: number) => {
    const d = new Date(ts);
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  };

  const renderMessage = ({ item }: { item: ChatMessage }) => {
    const isMe = item.participantId === currentParticipantId;
    return (
      <View style={[styles.messageBubble, isMe ? styles.myMessage : styles.otherMessage]}>
        {!isMe && (
          <Text style={styles.senderName}>
            {item.displayName || item.participantId.slice(0, 8)}
          </Text>
        )}
        <Text style={[styles.messageText, isMe && styles.myMessageText]}>{item.text}</Text>
        <Text style={[styles.messageTime, isMe && styles.myMessageTime]}>
          {formatTime(item.ts)}
        </Text>
      </View>
    );
  };

  return (
    <View style={styles.container}>
      {chatMessages.length === 0 ? (
        <View style={styles.emptyContainer}>
          <Text style={styles.emptyText}>No messages yet</Text>
          <Text style={styles.emptySubtext}>Start the conversation!</Text>
        </View>
      ) : (
        <FlatList
          ref={flatListRef}
          data={chatMessages}
          keyExtractor={(item) => String(item.eventId)}
          renderItem={renderMessage}
          contentContainerStyle={styles.messageList}
          showsVerticalScrollIndicator={false}
          keyboardShouldPersistTaps="handled"
          keyboardDismissMode="interactive"
          automaticallyAdjustKeyboardInsets={false}
          onContentSizeChange={() => scrollToEnd(false)}
        />
      )}

      <View style={styles.inputRow}>
        <TextInput
          style={styles.input}
          placeholder="Type a message..."
          placeholderTextColor={colors.textTertiary}
          value={text}
          onChangeText={setText}
          onSubmitEditing={handleSend}
          returnKeyType="send"
          maxLength={500}
          multiline={false}
          onFocus={() => setTimeout(() => scrollToEnd(), 300)}
        />
        <TouchableOpacity
          style={[styles.sendButton, !text.trim() && styles.sendButtonDisabled]}
          onPress={handleSend}
          disabled={!text.trim()}
        >
          <Text style={styles.sendButtonText}>↑</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const createStyles = (colors: ThemeColors) =>
  StyleSheet.create({
    container: {
      flex: 1,
    },
    emptyContainer: {
      flex: 1,
      alignItems: 'center',
      justifyContent: 'center',
      paddingVertical: spacing.xl,
    },
    emptyText: {
      fontSize: fontSize.md,
      color: colors.textSecondary,
      fontWeight: '500',
      letterSpacing: 0.3,
    },
    emptySubtext: {
      fontSize: fontSize.sm,
      color: colors.textTertiary,
      marginTop: spacing.xs,
    },
    messageList: {
      padding: spacing.md,
      paddingBottom: spacing.xs,
    },
    messageBubble: {
      maxWidth: '80%',
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.sm,
      borderRadius: borderRadius.md,
      marginBottom: spacing.sm,
      borderWidth: 1,
    },
    myMessage: {
      alignSelf: 'flex-end',
      backgroundColor: 'rgba(45,226,230,0.15)',
      borderColor: 'rgba(45,226,230,0.3)',
      borderBottomRightRadius: borderRadius.xs,
    },
    otherMessage: {
      alignSelf: 'flex-start',
      backgroundColor: colors.panel,
      borderColor: colors.panelBorder,
      borderBottomLeftRadius: borderRadius.xs,
    },
    senderName: {
      fontSize: fontSize.xs,
      fontWeight: '600',
      color: colors.accent,
      marginBottom: 2,
      letterSpacing: 0.5,
    },
    messageText: {
      fontSize: fontSize.md,
      color: colors.text,
      lineHeight: 20,
    },
    myMessageText: {
      color: colors.text,
    },
    messageTime: {
      fontSize: fontSize.xs - 1,
      color: colors.textTertiary,
      marginTop: 2,
      alignSelf: 'flex-end',
    },
    myMessageTime: {
      color: 'rgba(45,226,230,0.6)',
    },
    inputRow: {
      flexDirection: 'row',
      alignItems: 'center',
      paddingHorizontal: spacing.md,
      paddingVertical: spacing.sm,
      borderTopWidth: 1,
      borderTopColor: colors.panelBorder,
      backgroundColor: colors.panel,
    },
    input: {
      flex: 1,
      backgroundColor: colors.surface,
      borderRadius: borderRadius.md,
      borderWidth: 1,
      borderColor: colors.panelBorder,
      paddingHorizontal: spacing.lg,
      paddingVertical: Platform.OS === 'ios' ? spacing.sm : spacing.xs,
      fontSize: fontSize.md,
      color: colors.text,
      maxHeight: 80,
    },
    sendButton: {
      width: 34,
      height: 34,
      borderRadius: borderRadius.md,
      backgroundColor: colors.accent,
      alignItems: 'center',
      justifyContent: 'center',
      marginLeft: spacing.sm,
      ...glow.cyan.sm,
    },
    sendButtonDisabled: {
      backgroundColor: colors.panelBorder,
      shadowOpacity: 0,
      elevation: 0,
    },
    sendButtonText: {
      color: colors.textInverse,
      fontSize: fontSize.lg,
      fontWeight: '700',
    },
  });
