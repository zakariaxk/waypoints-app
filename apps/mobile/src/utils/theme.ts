// Futuristic design system — dark-first aesthetic with electric teal accent.
// Avoids generic purple. Uses cyan/teal primary with coral secondary.

// ─── Color Type ───

export interface ThemeColors {
  // Accent system
  accent: string;
  accentMuted: string;
  accentSoft: string;
  accentGlow: string;
  secondary: string;
  secondarySoft: string;

  // Surfaces
  background: string;
  surface: string;
  surfaceAlt: string;
  surfaceHover: string;
  card: string;

  // Text
  text: string;
  textSecondary: string;
  textTertiary: string;
  textInverse: string;

  // Borders
  border: string;
  borderLight: string;
  borderAccent: string;

  // Status
  online: string;
  stale: string;
  offline: string;

  // Map markers
  markerSelf: string;
  markerOther: string;
  markerOffline: string;
  markerDestination: string;

  // Core
  white: string;
  black: string;
  overlay: string;

  // Destination badge
  destinationBg: string;
  destinationBorder: string;
  destinationText: string;

  // Danger
  danger: string;
  dangerLight: string;

  // Route polyline
  route: string;

  // Gradient endpoints
  gradientStart: string;
  gradientEnd: string;

  // Map controls
  mapControlBg: string;
  mapControlText: string;
}

/** Dark palette — primary default. Deep navy base, electric cyan accent. */
export const darkColors: ThemeColors = {
  accent: '#22D1EE',
  accentMuted: '#0EA5C7',
  accentSoft: 'rgba(34,209,238,0.12)',
  accentGlow: 'rgba(34,209,238,0.25)',
  secondary: '#FF6B6B',
  secondarySoft: 'rgba(255,107,107,0.12)',

  background: '#0B0F19',
  surface: '#141B2D',
  surfaceAlt: '#1C2541',
  surfaceHover: '#243051',
  card: '#141B2D',

  text: '#E8ECF1',
  textSecondary: '#8B95A5',
  textTertiary: '#5A6578',
  textInverse: '#0B0F19',

  border: '#1C2541',
  borderLight: '#243051',
  borderAccent: 'rgba(34,209,238,0.30)',

  online: '#00E68A',
  stale: '#FFB800',
  offline: '#FF4D6A',

  markerSelf: '#22D1EE',
  markerOther: '#00E68A',
  markerOffline: '#5A6578',
  markerDestination: '#FF6B6B',

  white: '#FFFFFF',
  black: '#000000',
  overlay: 'rgba(0,0,0,0.65)',

  destinationBg: 'rgba(255,107,107,0.12)',
  destinationBorder: 'rgba(255,107,107,0.30)',
  destinationText: '#FF8A8A',

  danger: '#FF4D6A',
  dangerLight: 'rgba(255,77,106,0.15)',

  route: '#22D1EE',
  gradientStart: '#22D1EE',
  gradientEnd: '#6366F1',

  mapControlBg: '#141B2D',
  mapControlText: '#22D1EE',
};

/** Light palette — clean modern with deeper teal accents for readability. */
export const lightColors: ThemeColors = {
  accent: '#0891B2',
  accentMuted: '#06B6D4',
  accentSoft: 'rgba(8,145,178,0.08)',
  accentGlow: 'rgba(8,145,178,0.15)',
  secondary: '#E11D48',
  secondarySoft: 'rgba(225,29,72,0.08)',

  background: '#F5F7FA',
  surface: '#FFFFFF',
  surfaceAlt: '#EDF0F5',
  surfaceHover: '#DEE3EB',
  card: '#FFFFFF',

  text: '#1A2038',
  textSecondary: '#4A556B',
  textTertiary: '#8B95A5',
  textInverse: '#FFFFFF',

  border: '#DEE3EB',
  borderLight: '#EDF0F5',
  borderAccent: 'rgba(8,145,178,0.20)',

  online: '#059669',
  stale: '#D97706',
  offline: '#DC2626',

  markerSelf: '#0891B2',
  markerOther: '#059669',
  markerOffline: '#8B95A5',
  markerDestination: '#E11D48',

  white: '#FFFFFF',
  black: '#000000',
  overlay: 'rgba(0,0,0,0.35)',

  destinationBg: '#FFF0F1',
  destinationBorder: '#FECDD3',
  destinationText: '#9F1239',

  danger: '#DC2626',
  dangerLight: '#FEE2E2',

  route: '#0891B2',
  gradientStart: '#0891B2',
  gradientEnd: '#6D28D9',

  mapControlBg: '#FFFFFF',
  mapControlText: '#0891B2',
};

// ─── Static Tokens (shared across themes) ───

export const spacing = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
} as const;

export const fontSize = {
  xs: 11,
  sm: 13,
  md: 15,
  lg: 17,
  xl: 20,
  xxl: 28,
  title: 32,
} as const;

export const borderRadius = {
  sm: 6,
  md: 10,
  lg: 16,
  xl: 24,
  full: 999,
} as const;

export const shadow = {
  sm: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.05,
    shadowRadius: 2,
    elevation: 1,
  },
  md: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.1,
    shadowRadius: 4,
    elevation: 3,
  },
  lg: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.15,
    shadowRadius: 8,
    elevation: 5,
  },
} as const;

// ─── Status Colors ───

export function getStatusColors(c: ThemeColors): Record<string, string> {
  return { online: c.online, stale: c.stale, offline: c.offline };
}

// ─── Participant Colors ───

/** Distinct palette for per-user route/marker coloring (high saturation). */
export const PARTICIPANT_COLORS = [
  '#22D1EE', // cyan (self / primary)
  '#00E68A', // emerald
  '#FFB800', // amber
  '#FF6B6B', // coral
  '#A78BFA', // violet
  '#06B6D4', // teal
  '#FF8F3F', // orange
  '#14B8A6', // seafoam
  '#F472B6', // pink
  '#60A5FA', // sky blue
  '#84CC16', // lime
  '#C084FC', // purple
] as const;

/**
 * Get a deterministic color for a participant based on a sorted index.
 * The current user always gets PARTICIPANT_COLORS[0] (primary cyan).
 */
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
