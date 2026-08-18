/**
 * Chip — Small neon pill with outline and optional glow.
 *
 * Variants: info (cyan), success (lime), warn (amber), danger (magenta), default
 */

import React from 'react';
import { View, StyleSheet, type ViewStyle } from 'react-native';
import { useTheme, borderRadius, spacing, fontSize } from '../theme';
import NeonText from './NeonText';

type ChipVariant = 'info' | 'success' | 'warn' | 'danger' | 'default' | 'accent';

interface ChipProps {
  label: string;
  variant?: ChipVariant;
  /** Show as active/highlighted */
  active?: boolean;
  style?: ViewStyle;
  small?: boolean;
}

export default function Chip({
  label,
  variant = 'default',
  active = false,
  style,
  small = false,
}: ChipProps) {
  const { colors } = useTheme();

  const colorMap: Record<ChipVariant, { bg: string; border: string; text: string }> = {
    info: { bg: colors.info + '18', border: colors.info + '50', text: colors.info },
    success: { bg: colors.success + '18', border: colors.success + '50', text: colors.success },
    warn: { bg: colors.warn + '18', border: colors.warn + '50', text: colors.warn },
    danger: { bg: colors.danger + '18', border: colors.danger + '50', text: colors.danger },
    accent: { bg: colors.accentSoft, border: colors.borderAccent, text: colors.accent },
    default: { bg: colors.surfaceAlt, border: colors.border, text: colors.textSecondary },
  };

  const c = colorMap[variant];

  return (
    <View
      style={[
        styles.chip,
        small && styles.chipSmall,
        {
          backgroundColor: active ? c.border : c.bg,
          borderColor: c.border,
        },
        style,
      ]}
    >
      <NeonText
        variant="caption"
        color={active ? colors.textInverse : c.text}
        style={[styles.text, small && styles.textSmall]}
      >
        {label}
      </NeonText>
    </View>
  );
}

const styles = StyleSheet.create({
  chip: {
    paddingHorizontal: spacing.sm + 2,
    paddingVertical: spacing.xs,
    borderRadius: borderRadius.full,
    borderWidth: 1,
    alignSelf: 'flex-start',
  },
  chipSmall: {
    paddingHorizontal: spacing.sm,
    paddingVertical: 2,
  },
  text: {
    fontSize: fontSize.xs,
    letterSpacing: 0.5,
  },
  textSmall: {
    fontSize: fontSize.xs - 1,
  },
});
