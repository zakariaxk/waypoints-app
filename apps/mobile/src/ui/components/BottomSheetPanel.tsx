/**
 * BottomSheetPanel — Cyberpunk HUD-style bottom sheet.
 *
 * Uses React Native Animated API for smooth slide animation.
 * Features: draggable handle, neon accent border, translucent panel background.
 */

import React, { useEffect, useRef, type ReactNode } from 'react';
import { View, StyleSheet, Pressable, Animated, type ViewStyle } from 'react-native';
import { useTheme, borderRadius, spacing, glow } from '../theme';


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
  const translateY = useRef(new Animated.Value(height)).current;
  const backdropOpacity = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (visible) {
      Animated.parallel([
        Animated.spring(translateY, {
          toValue: 0,
          damping: 22,
          stiffness: 220,
          mass: 1,
          useNativeDriver: true,
        }),
        Animated.timing(backdropOpacity, {
          toValue: 1,
          duration: 200,
          useNativeDriver: true,
        }),
      ]).start();
    } else {
      Animated.parallel([
        Animated.timing(translateY, {
          toValue: height,
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
  }, [visible, height, translateY, backdropOpacity]);

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
            { backgroundColor: colors.overlay, opacity: backdropOpacity },
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
            transform: [{ translateY }],
          },
          glow.cyan.sm,
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
