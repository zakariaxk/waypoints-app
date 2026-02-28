/**
 * HudCard — Translucent panel with neon border, HUD-style aesthetic.
 *
 * Features:
 *  - Panel background (semi-transparent on dark, frosted on light)
 *  - Neon accent border (configurable color)
 *  - Optional header slot
 *  - Optional angled corner accent (top-right SVG cut)
 */

import React, { type ReactNode } from 'react';
import { View, StyleSheet, type ViewStyle } from 'react-native';
import { useTheme, borderRadius, spacing, glow } from '../theme';

interface HudCardProps {
  children: ReactNode;
  header?: ReactNode;
  /** Override border glow color ('cyan' | 'magenta' | 'violet') */
  glowColor?: 'cyan' | 'magenta' | 'violet';
  /** Additional style */
  style?: ViewStyle;
  /** Remove padding */
  noPadding?: boolean;
}

export default function HudCard({
  children,
  header,
  glowColor = 'cyan',
  style,
  noPadding = false,
}: HudCardProps) {
  const { colors } = useTheme();

  const glowShadow = glow[glowColor].sm;
  const borderColor =
    glowColor === 'magenta'
      ? colors.secondary + '55'
      : glowColor === 'violet'
        ? colors.tertiary + '55'
        : colors.borderAccent;

  return (
    <View
      style={[
        styles.card,
        {
          backgroundColor: colors.panel,
          borderColor,
        },
        glowShadow,
        style,
      ]}
    >
      {/* Top accent line */}
      <View style={[styles.accentLine, { backgroundColor: borderColor }]} />

      {header && <View style={styles.header}>{header}</View>}

      <View style={!noPadding && styles.body}>{children}</View>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    borderRadius: borderRadius.lg,
    borderWidth: 1,
    overflow: 'hidden',
  },
  accentLine: {
    height: 1,
    width: '100%',
  },
  header: {
    paddingHorizontal: spacing.lg,
    paddingTop: spacing.md,
    paddingBottom: spacing.sm,
  },
  body: {
    paddingHorizontal: spacing.lg,
    paddingVertical: spacing.md,
  },
});
