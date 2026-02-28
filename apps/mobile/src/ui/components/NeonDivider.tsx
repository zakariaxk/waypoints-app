/**
 * NeonDivider — Thin gradient separator line.
 *
 * Renders a subtle cyan→violet gradient at low opacity for HUD-style separators.
 */

import React from 'react';
import { StyleSheet, type ViewStyle } from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { useTheme, spacing } from '../theme';

interface NeonDividerProps {
  style?: ViewStyle;
  /** Opacity multiplier (0–1), default 0.2 */
  intensity?: number;
  vertical?: boolean;
}

export default function NeonDivider({ style, intensity = 0.2, vertical = false }: NeonDividerProps) {
  const { colors } = useTheme();

  return (
    <LinearGradient
      colors={[colors.accent + '00', colors.accent, colors.tertiary ?? colors.accent, colors.accent + '00'] as [string, string, ...string[]]}
      start={vertical ? { x: 0.5, y: 0 } : { x: 0, y: 0.5 }}
      end={vertical ? { x: 0.5, y: 1 } : { x: 1, y: 0.5 }}
      style={[
        vertical ? styles.vertical : styles.horizontal,
        { opacity: intensity },
        style,
      ]}
    />
  );
}

const styles = StyleSheet.create({
  horizontal: {
    height: 1,
    width: '100%',
    marginVertical: spacing.sm,
  },
  vertical: {
    width: 1,
    height: '100%',
    marginHorizontal: spacing.sm,
  },
});
