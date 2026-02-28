/**
 * NeonButton — Gradient-filled button with neon glow and haptic feedback.
 *
 * Variants: primary (cyan), secondary (violet), danger (magenta)
 * Features: scale animation on press, glow intensity shift, haptic impact.
 */

import React, { useCallback, useRef } from 'react';
import {
  StyleSheet,
  Pressable,
  Animated,
  Text,
  type ViewStyle,
  type TextStyle,
  ActivityIndicator,
} from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import * as Haptics from 'expo-haptics';
import { useTheme, gradients, borderRadius, spacing, fontSize, fontFamily, glow } from '../theme';

type ButtonVariant = 'primary' | 'secondary' | 'danger' | 'ghost';
type ButtonSize = 'sm' | 'md' | 'lg';

interface NeonButtonProps {
  title: string;
  onPress: () => void;
  variant?: ButtonVariant;
  size?: ButtonSize;
  disabled?: boolean;
  loading?: boolean;
  icon?: string;
  style?: ViewStyle;
  fullWidth?: boolean;
}

const variantGradients: Record<Exclude<ButtonVariant, 'ghost'>, readonly string[]> = {
  primary: gradients.buttonPrimary,
  secondary: gradients.buttonSecondary,
  danger: gradients.danger,
};

const variantGlows = {
  primary: glow.cyan.md,
  secondary: glow.violet.md,
  danger: glow.magenta.md,
  ghost: {},
};

const sizeStyles: Record<ButtonSize, { paddingVertical: number; paddingHorizontal: number; fontSize: number }> = {
  sm: { paddingVertical: 8, paddingHorizontal: 16, fontSize: fontSize.sm },
  md: { paddingVertical: 14, paddingHorizontal: 24, fontSize: fontSize.md },
  lg: { paddingVertical: 18, paddingHorizontal: 32, fontSize: fontSize.lg },
};

export default function NeonButton({
  title,
  onPress,
  variant = 'primary',
  size = 'md',
  disabled = false,
  loading = false,
  icon,
  style,
  fullWidth = false,
}: NeonButtonProps) {
  const { colors, fontsLoaded } = useTheme();
  const scaleAnim = useRef(new Animated.Value(1)).current;

  const handlePressIn = useCallback(() => {
    Animated.spring(scaleAnim, {
      toValue: 0.97,
      friction: 8,
      tension: 400,
      useNativeDriver: true,
    }).start();
  }, [scaleAnim]);

  const handlePressOut = useCallback(() => {
    Animated.spring(scaleAnim, {
      toValue: 1,
      friction: 8,
      tension: 400,
      useNativeDriver: true,
    }).start();
  }, [scaleAnim]);

  const handlePress = useCallback(() => {
    if (disabled || loading) return;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    onPress();
  }, [disabled, loading, onPress]);

  const sizeConfig = sizeStyles[size];
  const isGhost = variant === 'ghost';
  const glowS = variantGlows[variant];

  const textFont: TextStyle = fontsLoaded
    ? { fontFamily: fontFamily.bodySemiBold }
    : { fontWeight: '600' };

  const buttonContent = (
    <>
      {loading ? (
        <ActivityIndicator color={isGhost ? colors.accent : colors.textInverse} size="small" />
      ) : (
        <Text
          style={[
            styles.text,
            textFont,
            { fontSize: sizeConfig.fontSize },
            isGhost
              ? { color: colors.accent }
              : { color: '#FFFFFF' },
          ]}
        >
          {icon ? `${icon}  ${title}` : title}
        </Text>
      )}
    </>
  );

  if (isGhost) {
    return (
      <Pressable
        onPress={handlePress}
        onPressIn={handlePressIn}
        onPressOut={handlePressOut}
        disabled={disabled || loading}
      >
        <Animated.View
          style={[
            { transform: [{ scale: scaleAnim }] },
            styles.base,
            {
              paddingVertical: sizeConfig.paddingVertical,
              paddingHorizontal: sizeConfig.paddingHorizontal,
              backgroundColor: 'transparent',
              borderWidth: 1,
              borderColor: colors.borderAccent,
              borderRadius: borderRadius.md,
            },
            disabled && styles.disabled,
            fullWidth && styles.fullWidth,
            style,
          ]}
        >
          {buttonContent}
        </Animated.View>
      </Pressable>
    );
  }

  return (
    <Pressable
      onPress={handlePress}
      onPressIn={handlePressIn}
      onPressOut={handlePressOut}
      disabled={disabled || loading}
    >
      <Animated.View
        style={[
          { transform: [{ scale: scaleAnim }] },
          styles.base,
          fullWidth && styles.fullWidth,
          !disabled && glowS,
          disabled && styles.disabled,
          style,
        ]}
      >
      <LinearGradient
        colors={[...variantGradients[variant]] as [string, string, ...string[]]}
        start={{ x: 0, y: 0 }}
        end={{ x: 1, y: 0 }}
        style={[
          styles.gradient,
          {
            paddingVertical: sizeConfig.paddingVertical,
            paddingHorizontal: sizeConfig.paddingHorizontal,
          },
        ]}
      >
        {buttonContent}
      </LinearGradient>
      </Animated.View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  base: {
    borderRadius: borderRadius.md,
    overflow: 'hidden',
    alignItems: 'center',
    justifyContent: 'center',
  },
  gradient: {
    borderRadius: borderRadius.md,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row',
    width: '100%',
  },
  text: {
    letterSpacing: 1,
    textAlign: 'center',
  },
  disabled: {
    opacity: 0.45,
  },
  fullWidth: {
    width: '100%',
  },
});
