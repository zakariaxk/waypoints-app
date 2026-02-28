/**
 * Cyberpunk Theme System
 *
 * Provides dark/light/system mode with full color token resolution.
 * The dark mode is the flagship "cyberpunk" look; light mode is a clean
 * high-contrast counterpart.
 */

import { createContext, useContext, useState, useEffect, useCallback, useMemo, type ReactNode } from 'react';
import { useColorScheme } from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { palette } from './tokens';

const THEME_KEY = '@waypoints/theme-mode';

// ─── Theme Mode ──────────────────────────────────────────────────────────────

export type ThemeMode = 'system' | 'light' | 'dark';

// ─── ThemeColors Interface ───────────────────────────────────────────────────

export interface ThemeColors {
  // Accent system
  accent: string;
  accentMuted: string;
  accentSoft: string;
  accentGlow: string;
  secondary: string;         // neonMagenta / magentaDeep
  secondarySoft: string;
  tertiary: string;          // neonViolet / violetDeep

  // Surfaces
  background: string;
  surface: string;
  surfaceAlt: string;
  surfaceHover: string;
  card: string;
  panel: string;
  panelBorder: string;

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

  // Destination
  destinationBg: string;
  destinationBorder: string;
  destinationText: string;

  // Semantic
  danger: string;
  dangerLight: string;
  success: string;
  successLight: string;
  warn: string;
  warnLight: string;
  info: string;

  // Route
  route: string;

  // Map controls
  mapControlBg: string;
  mapControlText: string;
}

// ─── Dark Colors (Cyberpunk flagship) ────────────────────────────────────────

export const darkColors: ThemeColors = {
  accent: palette.neonCyan,
  accentMuted: '#1ABAC0',
  accentSoft: 'rgba(45, 226, 230, 0.12)',
  accentGlow: 'rgba(45, 226, 230, 0.30)',
  secondary: palette.neonMagenta,
  secondarySoft: 'rgba(255, 42, 109, 0.12)',
  tertiary: palette.neonViolet,

  background: palette.bg0,
  surface: palette.bg1,
  surfaceAlt: palette.panelSolid,
  surfaceHover: '#1E2340',
  card: palette.panelSolid,
  panel: palette.panel,
  panelBorder: palette.panelBorder,

  text: palette.text0,
  textSecondary: palette.text1,
  textTertiary: palette.text2,
  textInverse: palette.bg0,

  border: 'rgba(120, 140, 255, 0.12)',
  borderLight: 'rgba(120, 140, 255, 0.08)',
  borderAccent: 'rgba(45, 226, 230, 0.35)',

  online: palette.neonLime,
  stale: palette.neonAmber,
  offline: palette.neonMagenta,

  markerSelf: palette.neonCyan,
  markerOther: palette.neonLime,
  markerOffline: palette.text2,
  markerDestination: palette.neonMagenta,

  white: palette.white,
  black: palette.black,
  overlay: 'rgba(5, 6, 10, 0.80)',

  destinationBg: 'rgba(255, 42, 109, 0.10)',
  destinationBorder: 'rgba(255, 42, 109, 0.25)',
  destinationText: palette.neonMagenta,

  danger: palette.neonMagenta,
  dangerLight: 'rgba(255, 42, 109, 0.15)',
  success: palette.neonLime,
  successLight: 'rgba(182, 255, 106, 0.12)',
  warn: palette.neonAmber,
  warnLight: 'rgba(255, 176, 0, 0.12)',
  info: palette.neonCyan,

  route: palette.neonCyan,

  mapControlBg: 'rgba(20, 24, 40, 0.85)',
  mapControlText: palette.neonCyan,
};

// ─── Light Colors ────────────────────────────────────────────────────────────

export const lightColors: ThemeColors = {
  accent: palette.cyanDeep,
  accentMuted: '#0E7490',
  accentSoft: 'rgba(8, 145, 178, 0.08)',
  accentGlow: 'rgba(8, 145, 178, 0.15)',
  secondary: palette.magentaDeep,
  secondarySoft: 'rgba(190, 24, 93, 0.08)',
  tertiary: palette.violetDeep,

  background: palette.lightBg,
  surface: palette.lightSurface,
  surfaceAlt: palette.lightSurfaceAlt,
  surfaceHover: '#D4D8E8',
  card: palette.lightSurface,
  panel: 'rgba(255, 255, 255, 0.85)',
  panelBorder: 'rgba(100, 110, 160, 0.15)',

  text: palette.lightText,
  textSecondary: palette.lightTextSecondary,
  textTertiary: palette.lightTextTertiary,
  textInverse: palette.white,

  border: palette.lightBorder,
  borderLight: '#E8EBF2',
  borderAccent: 'rgba(8, 145, 178, 0.25)',

  online: palette.limeDeep,
  stale: palette.amberDeep,
  offline: palette.magentaDeep,

  markerSelf: palette.cyanDeep,
  markerOther: palette.limeDeep,
  markerOffline: palette.lightTextTertiary,
  markerDestination: palette.magentaDeep,

  white: palette.white,
  black: palette.black,
  overlay: 'rgba(0, 0, 0, 0.35)',

  destinationBg: 'rgba(190, 24, 93, 0.06)',
  destinationBorder: 'rgba(190, 24, 93, 0.15)',
  destinationText: palette.magentaDeep,

  danger: palette.magentaDeep,
  dangerLight: 'rgba(190, 24, 93, 0.08)',
  success: palette.limeDeep,
  successLight: 'rgba(101, 163, 13, 0.08)',
  warn: palette.amberDeep,
  warnLight: 'rgba(217, 119, 6, 0.08)',
  info: palette.cyanDeep,

  route: palette.cyanDeep,

  mapControlBg: 'rgba(255, 255, 255, 0.92)',
  mapControlText: palette.cyanDeep,
};

// ─── Status Colors ───────────────────────────────────────────────────────────

export function getStatusColors(c: ThemeColors): Record<string, string> {
  return { online: c.online, stale: c.stale, offline: c.offline };
}

// ─── Theme Context ───────────────────────────────────────────────────────────

interface ThemeContextValue {
  colors: ThemeColors;
  mode: ThemeMode;
  isDark: boolean;
  setMode: (m: ThemeMode) => void;
  fontsLoaded: boolean;
}

const ThemeContext = createContext<ThemeContextValue>({
  colors: darkColors,
  mode: 'system',
  isDark: true,
  setMode: () => {},
  fontsLoaded: false,
});

interface ThemeProviderProps {
  children: ReactNode;
  fontsLoaded: boolean;
}

export function ThemeProvider({ children, fontsLoaded }: ThemeProviderProps) {
  const systemScheme = useColorScheme();
  const [mode, setModeState] = useState<ThemeMode>('system');
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    AsyncStorage.getItem(THEME_KEY).then((v) => {
      if (v === 'light' || v === 'dark' || v === 'system') {
        setModeState(v);
      }
      setLoaded(true);
    });
  }, []);

  const setMode = useCallback((m: ThemeMode) => {
    setModeState(m);
    AsyncStorage.setItem(THEME_KEY, m);
  }, []);

  const isDark = mode === 'dark' || (mode === 'system' && systemScheme !== 'light');
  const colors = isDark ? darkColors : lightColors;

  const value = useMemo<ThemeContextValue>(
    () => ({ colors, mode, isDark, setMode, fontsLoaded }),
    [colors, mode, isDark, setMode, fontsLoaded],
  );

  if (!loaded) return null;

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme(): ThemeContextValue {
  return useContext(ThemeContext);
}

export { ThemeContext };
