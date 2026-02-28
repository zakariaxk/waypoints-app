import { useState, useRef, useEffect } from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  FlatList,
  KeyboardAvoidingView,
  Platform,
  StyleSheet,
  Keyboard,
} from 'react-native';
import { useSessionStore, type ChatMessage } from '../state/session-store';
import { sendChatMessage } from '../services/ws-client';
import { colors, spacing, fontSize, borderRadius } from '../utils/theme';

interface ChatPanelProps {
  currentParticipantId: string | null;
}

export default function ChatPanel({ currentParticipantId }: ChatPanelProps) {
  const [text, setText] = useState('');
  const flatListRef = useRef<FlatList>(null);
  const chatMessages = useSessionStore((s) => s.chatMessages);

  // Auto-scroll to bottom on new messages
  useEffect(() => {
    if (chatMessages.length > 0) {
      setTimeout(() => {
        flatListRef.current?.scrollToEnd({ animated: true });
      }, 100);
    }
  }, [chatMessages.length]);

  // Scroll to bottom when keyboard opens
  useEffect(() => {
    const sub = Keyboard.addListener(
      Platform.OS === 'ios' ? 'keyboardWillShow' : 'keyboardDidShow',
      () => {
        setTimeout(() => {
          flatListRef.current?.scrollToEnd({ animated: true });
        }, 150);
      },
    );
    return () => sub.remove();
  }, []);

  const handleSend = () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    sendChatMessage(trimmed);
    setText('');
    // Scroll after sending
    setTimeout(() => {
      flatListRef.current?.scrollToEnd({ animated: true });
    }, 100);
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
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
      keyboardVerticalOffset={Platform.OS === 'ios' ? 120 : 0}
    >
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
          onContentSizeChange={() => {
            flatListRef.current?.scrollToEnd({ animated: false });
          }}
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
          onFocus={() => {
            setTimeout(() => {
              flatListRef.current?.scrollToEnd({ animated: true });
            }, 300);
          }}
        />
        <TouchableOpacity
          style={[styles.sendButton, !text.trim() && styles.sendButtonDisabled]}
          onPress={handleSend}
          disabled={!text.trim()}
        >
          <Text style={styles.sendButtonText}>↑</Text>
        </TouchableOpacity>
      </View>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
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
    borderRadius: borderRadius.lg,
    marginBottom: spacing.sm,
  },
  myMessage: {
    alignSelf: 'flex-end',
    backgroundColor: colors.primary,
    borderBottomRightRadius: borderRadius.sm,
  },
  otherMessage: {
    alignSelf: 'flex-start',
    backgroundColor: colors.surfaceAlt,
    borderBottomLeftRadius: borderRadius.sm,
  },
  senderName: {
    fontSize: fontSize.xs,
    fontWeight: '600',
    color: colors.primary,
    marginBottom: 2,
  },
  messageText: {
    fontSize: fontSize.md,
    color: colors.text,
    lineHeight: 20,
  },
  myMessageText: {
    color: colors.textInverse,
  },
  messageTime: {
    fontSize: fontSize.xs - 1,
    color: colors.textTertiary,
    marginTop: 2,
    alignSelf: 'flex-end',
  },
  myMessageTime: {
    color: 'rgba(255,255,255,0.7)',
  },
  inputRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderTopWidth: 1,
    borderTopColor: colors.border,
    backgroundColor: colors.white,
  },
  input: {
    flex: 1,
    backgroundColor: colors.surfaceAlt,
    borderRadius: borderRadius.xl,
    paddingHorizontal: spacing.lg,
    paddingVertical: Platform.OS === 'ios' ? spacing.sm : spacing.xs,
    fontSize: fontSize.md,
    color: colors.text,
    maxHeight: 80,
  },
  sendButton: {
    width: 34,
    height: 34,
    borderRadius: 17,
    backgroundColor: colors.primary,
    alignItems: 'center',
    justifyContent: 'center',
    marginLeft: spacing.sm,
  },
  sendButtonDisabled: {
    backgroundColor: colors.border,
  },
  sendButtonText: {
    color: colors.white,
    fontSize: fontSize.lg,
    fontWeight: '700',
  },
});
