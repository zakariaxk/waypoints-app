/**
 * NeonText — Cyberpunk typography wrapper.
 *
 * Variants: hero, h1, h2, h3, body, bodyBold, caption
 * Enforces consistent font family, letter spacing, and color usage.
 * Falls back to system font if custom fonts haven't loaded yet.
 */

import React from 'react';
import { Text, type TextProps, type TextStyle, StyleSheet } from 'react-native';
import { useTheme, fontFamily, fontSize, letterSpacing } from '../theme';

type NeonTextVariant = 'hero' | 'h1' | 'h2' | 'h3' | 'body' | 'bodyMedium' | 'bodySemiBold' | 'bodyBold' | 'caption';

interface NeonTextProps extends TextProps {
  variant?: NeonTextVariant;
  /** Override color (defaults to theme text color) */
  color?: string;
  /** Use accent color */
  accent?: boolean;
  /** Center text */
  center?: boolean;
  /** Use secondary (magenta) */
  secondary?: boolean;
  glow?: boolean;
}

const variantStyles: Record<NeonTextVariant, TextStyle> = {
  hero: {
    fontFamily: fontFamily.heading,
    fontSize: fontSize.hero,
    letterSpacing: letterSpacing.widest,
    lineHeight: fontSize.hero * 1.1,
  },
  h1: {
    fontFamily: fontFamily.heading,
    fontSize: fontSize.title,
    letterSpacing: letterSpacing.wider,
    lineHeight: fontSize.title * 1.1,
  },
  h2: {
    fontFamily: fontFamily.headingMedium,
    fontSize: fontSize.xxl,
    letterSpacing: letterSpacing.wide,
    lineHeight: fontSize.xxl * 1.2,
  },
  h3: {
    fontFamily: fontFamily.bodySemiBold,
    fontSize: fontSize.xl,
    letterSpacing: letterSpacing.wide,
    lineHeight: fontSize.xl * 1.2,
  },
  body: {
    fontFamily: fontFamily.body,
    fontSize: fontSize.md,
    letterSpacing: letterSpacing.normal,
    lineHeight: fontSize.md * 1.4,
  },
  bodyMedium: {
    fontFamily: fontFamily.bodyMedium,
    fontSize: fontSize.md,
    letterSpacing: letterSpacing.normal,
    lineHeight: fontSize.md * 1.4,
  },
  bodySemiBold: {
    fontFamily: fontFamily.bodySemiBold,
    fontSize: fontSize.md,
    letterSpacing: letterSpacing.normal,
    lineHeight: fontSize.md * 1.4,
  },
  bodyBold: {
    fontFamily: fontFamily.bodyBold,
    fontSize: fontSize.lg,
    letterSpacing: letterSpacing.normal,
    lineHeight: fontSize.lg * 1.3,
  },
  caption: {
    fontFamily: fontFamily.body,
    fontSize: fontSize.xs,
    letterSpacing: letterSpacing.wide,
    lineHeight: fontSize.xs * 1.4,
    textTransform: 'uppercase',
  },
};

export default function NeonText({
  variant = 'body',
  color,
  accent,
  secondary,
  center,
  glow,
  style,
  ...rest
}: NeonTextProps) {
  const { colors, fontsLoaded } = useTheme();

  const resolvedColor = color ?? (accent ? colors.accent : secondary ? colors.secondary : colors.text);

  const variantStyle = variantStyles[variant];
  // If fonts aren't loaded, strip custom fontFamily to avoid crash
  const fontStyle: TextStyle = fontsLoaded
    ? variantStyle
    : { ...variantStyle, fontFamily: undefined };

  const glowStyle: TextStyle | undefined = glow
    ? {
        textShadowColor: resolvedColor,
        textShadowOffset: { width: 0, height: 0 },
        textShadowRadius: 8,
      }
    : undefined;

  return (
    <Text
      {...rest}
      style={[
        fontStyle,
        { color: resolvedColor },
        center && styles.center,
        glowStyle,
        style,
      ]}
    />
  );
}

const styles = StyleSheet.create({
  center: { textAlign: 'center' },
});
