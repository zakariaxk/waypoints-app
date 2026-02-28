/**
 * Glow Styles — reusable shadow helpers that simulate neon glow effects.
 *
 * A "glow" is 2–3 shadow layers:
 *  - Outer glow: same color at low opacity + bigger blur
 *  - Inner glow: smaller shadow + higher opacity
 *  - Core line: solid thin stroke (done via borderColor in the component)
 *
 * On Android, elevation is used since box-shadow colors are not supported.
 */

import { Platform, type ViewStyle } from 'react-native';
import { palette } from './tokens';

type GlowLevel = 'sm' | 'md' | 'lg';

function makeGlow(color: string, level: GlowLevel): ViewStyle {
  if (Platform.OS === 'android') {
    // Android doesn't support colored shadows, use elevation only
    return {
      elevation: level === 'sm' ? 3 : level === 'md' ? 6 : 10,
    };
  }

  const configs = {
    sm: { opacity: 0.35, radius: 4, offset: 0 },
    md: { opacity: 0.45, radius: 10, offset: 2 },
    lg: { opacity: 0.55, radius: 20, offset: 4 },
  };

  const cfg = configs[level];
  return {
    shadowColor: color,
    shadowOffset: { width: 0, height: cfg.offset },
    shadowOpacity: cfg.opacity,
    shadowRadius: cfg.radius,
  };
}

// Pre-built glow variants
export const glow = {
  cyan: {
    sm: makeGlow(palette.neonCyan, 'sm'),
    md: makeGlow(palette.neonCyan, 'md'),
    lg: makeGlow(palette.neonCyan, 'lg'),
  },
  magenta: {
    sm: makeGlow(palette.neonMagenta, 'sm'),
    md: makeGlow(palette.neonMagenta, 'md'),
    lg: makeGlow(palette.neonMagenta, 'lg'),
  },
  violet: {
    sm: makeGlow(palette.neonViolet, 'sm'),
    md: makeGlow(palette.neonViolet, 'md'),
    lg: makeGlow(palette.neonViolet, 'lg'),
  },
  lime: {
    sm: makeGlow(palette.neonLime, 'sm'),
    md: makeGlow(palette.neonLime, 'md'),
    lg: makeGlow(palette.neonLime, 'lg'),
  },
  amber: {
    sm: makeGlow(palette.neonAmber, 'sm'),
    md: makeGlow(palette.neonAmber, 'md'),
    lg: makeGlow(palette.neonAmber, 'lg'),
  },
} as const;

export { makeGlow };
