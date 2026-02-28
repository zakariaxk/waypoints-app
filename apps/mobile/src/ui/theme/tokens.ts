/**
 * Cyberpunk Design Tokens
 *
 * Single source of truth for all colors, gradients, spacing, typography, and
 * shape language. Dark-first neon-tech aesthetic.
 *
 * Rules:
 *  - Background is always dark in flagship mode.
 *  - Accents are neon, used in controlled amounts: outlines, highlights, CTAs.
 *  - NEVER large blocks of solid neon. Use gradients + thin strokes.
 */

// ─── Raw Palette ─────────────────────────────────────────────────────────────

export const palette = {
  // Backgrounds
  bg0: '#05060A',
  bg1: '#0A0C14',
  bg2: '#120A1B',

  // Panels
  panel: 'rgba(20, 24, 40, 0.72)',
  panelSolid: '#141828',
  panelBorder: 'rgba(120, 140, 255, 0.18)',

  // Text
  text0: '#F2F6FF',
  text1: 'rgba(242, 246, 255, 0.72)',
  text2: 'rgba(242, 246, 255, 0.40)',

  // Neon accents
  neonCyan: '#2DE2E6',
  neonMagenta: '#FF2A6D',
  neonViolet: '#7A5CFF',
  neonLime: '#B6FF6A',
  neonAmber: '#FFB000',

  // Light-mode counterparts (deeper tones for readability on white)
  cyanDeep: '#0891B2',
  magentaDeep: '#BE185D',
  violetDeep: '#6D28D9',
  limeDeep: '#65A30D',
  amberDeep: '#D97706',

  // Pure
  white: '#FFFFFF',
  black: '#000000',

  // Light-mode surfaces
  lightBg: '#F0F2F8',
  lightSurface: '#FFFFFF',
  lightSurfaceAlt: '#E8EBF2',
  lightText: '#0F1120',
  lightTextSecondary: '#4A4E69',
  lightTextTertiary: '#8B8FAA',
  lightBorder: '#D4D8E8',
} as const;

// ─── Semantic Colors ─────────────────────────────────────────────────────────

export const semantic = {
  success: palette.neonLime,
  warn: palette.neonAmber,
  danger: palette.neonMagenta,
  info: palette.neonCyan,
} as const;

// ─── Gradients ───────────────────────────────────────────────────────────────

export const gradients = {
  /** Cinematic background gradient (top → bottom) */
  background: [palette.bg0, palette.bg1, palette.bg2] as readonly string[],
  /** Primary accent strip */
  accentCyanViolet: [palette.neonCyan, palette.neonViolet] as readonly string[],
  /** Secondary accent */
  accentMagentaViolet: [palette.neonMagenta, palette.neonViolet] as readonly string[],
  /** Danger/action gradient */
  danger: [palette.neonMagenta, '#FF4D4D'] as readonly string[],
  /** Success gradient */
  success: [palette.neonLime, '#22C55E'] as readonly string[],
  /** Button primary */
  buttonPrimary: [palette.neonCyan, '#1BA8C4'] as readonly string[],
  /** Button secondary */
  buttonSecondary: [palette.neonViolet, '#5A3FCC'] as readonly string[],
  /** Light mode background */
  backgroundLight: [palette.lightBg, '#E2E6F0', '#D8DCE8'] as readonly string[],
} as const;

// ─── Spacing ─────────────────────────────────────────────────────────────────

export const spacing = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
  xxxl: 48,
} as const;

// ─── Typography ──────────────────────────────────────────────────────────────

/** Font families loaded via expo-font. */
export const fontFamily = {
  heading: 'Orbitron_700Bold',
  headingMedium: 'Orbitron_500Medium',
  body: 'Rajdhani_400Regular',
  bodyMedium: 'Rajdhani_500Medium',
  bodySemiBold: 'Rajdhani_600SemiBold',
  bodyBold: 'Rajdhani_700Bold',
} as const;

export const fontSize = {
  xs: 11,
  sm: 13,
  md: 15,
  lg: 18,
  xl: 22,
  xxl: 28,
  title: 36,
  hero: 48,
} as const;

export const letterSpacing = {
  tight: -0.5,
  normal: 0,
  wide: 1,
  wider: 2,
  widest: 4,
} as const;

export const lineHeight = {
  tight: 1.1,
  normal: 1.4,
  relaxed: 1.6,
} as const;

// ─── Border Radius ───────────────────────────────────────────────────────────

export const borderRadius = {
  xs: 4,
  sm: 6,
  md: 12,
  lg: 16,
  xl: 24,
  full: 999,
} as const;

// ─── Shadows ─────────────────────────────────────────────────────────────────

export const shadow = {
  sm: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.2,
    shadowRadius: 2,
    elevation: 2,
  },
  md: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 3 },
    shadowOpacity: 0.35,
    shadowRadius: 6,
    elevation: 4,
  },
  lg: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 6 },
    shadowOpacity: 0.45,
    shadowRadius: 12,
    elevation: 8,
  },
} as const;

// ─── Participant Route Colors ────────────────────────────────────────────────

export const PARTICIPANT_COLORS = [
  palette.neonCyan,    // self / primary
  palette.neonLime,    // lime
  palette.neonAmber,   // amber
  palette.neonMagenta, // magenta
  palette.neonViolet,  // violet
  '#06B6D4',           // teal
  '#FF8F3F',           // orange
  '#14B8A6',           // seafoam
  '#F472B6',           // pink
  '#60A5FA',           // sky
  '#84CC16',           // chartreuse
  '#C084FC',           // lavender
] as const;

export function getParticipantColor(
  participantId: string,
  allParticipantIds: string[],
  currentParticipantId: string | null,
): string {
  if (participantId === currentParticipantId) return PARTICIPANT_COLORS[0];
  const others = allParticipantIds
    .filter((id) => id !== currentParticipantId)
    .sort();
  const idx = others.indexOf(participantId);
  return PARTICIPANT_COLORS[(idx + 1) % PARTICIPANT_COLORS.length];
}
