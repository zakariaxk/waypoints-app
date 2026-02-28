/**
 * BottomSheetPanel — Cyberpunk HUD-style bottom sheet.
 *
 * Uses react-native-reanimated for smooth slide animation.
 * Features: draggable handle, neon accent border, translucent panel background.
 */

import React, { useEffect, type ReactNode } from 'react';
import { View, StyleSheet, Dimensions, Pressable, type ViewStyle } from 'react-native';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withSpring,
  withTiming,
  runOnJS,
} from 'react-native-reanimated';
import { useTheme, borderRadius, spacing, glow } from '../theme';

const SCREEN_HEIGHT = Dimensions.get('window').height;

interface BottomSheetPanelProps {
  visible: boolean;
  onClose: () => void;
  children: ReactNode;
  /** Height of the sheet content area */
  height?: number;
  style?: ViewStyle;
}

export default function BottomSheetPanel({
  visible,
  onClose,
  children,
  height = 300,
  style,
}: BottomSheetPanelProps) {
  const { colors } = useTheme();
  const translateY = useSharedValue(height);
  const backdropOpacity = useSharedValue(0);

  useEffect(() => {
    if (visible) {
      translateY.value = withSpring(0, { damping: 22, stiffness: 220 });
      backdropOpacity.value = withTiming(1, { duration: 200 });
    } else {
      translateY.value = withTiming(height, { duration: 200 });
      backdropOpacity.value = withTiming(0, { duration: 200 });
    }
  }, [visible, height, translateY, backdropOpacity]);

  const sheetStyle = useAnimatedStyle(() => ({
    transform: [{ translateY: translateY.value }],
  }));

  const backdropStyle = useAnimatedStyle(() => ({
    opacity: backdropOpacity.value,
  }));

  if (!visible) return null;

  return (
    <View style={StyleSheet.absoluteFill} pointerEvents="box-none">
      {/* Backdrop */}
      <Pressable
        style={StyleSheet.absoluteFill}
        onPress={onClose}
      >
        <Animated.View
          style={[
            styles.backdrop,
            { backgroundColor: colors.overlay },
            backdropStyle,
          ]}
        />
      </Pressable>

      {/* Sheet */}
      <Animated.View
        style={[
          styles.sheet,
          {
            height,
            backgroundColor: colors.panel,
            borderColor: colors.borderAccent,
          },
          glow.cyan.sm,
          sheetStyle,
          style,
        ]}
      >
        {/* Neon accent top line */}
        <View style={[styles.accentLine, { backgroundColor: colors.accent + '60' }]} />

        {/* Handle */}
        <View style={styles.handleRow}>
          <View style={[styles.handle, { backgroundColor: colors.textTertiary }]} />
        </View>

        {/* Content */}
        {children}
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({
  backdrop: {
    ...StyleSheet.absoluteFillObject,
  },
  sheet: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    borderTopLeftRadius: borderRadius.xl,
    borderTopRightRadius: borderRadius.xl,
    borderWidth: 1,
    borderBottomWidth: 0,
    overflow: 'hidden',
  },
  accentLine: {
    height: 2,
    width: '100%',
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
  },
});
