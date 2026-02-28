# Waypoints UI Style Guide — Cyberpunk / Neon-Tech

> Aesthetic: dark-first, neon-lit HUD with translucent panels, colored glow, and cinematic gradients.

---

## 1. Color Palette

### Backgrounds
| Token | Hex | Usage |
|-------|-----|-------|
| `bg0` | `#05060A` | Deep-space base |
| `bg1` | `#0A0C14` | Primary dark surface |
| `bg2` | `#10142A` | Elevated surface |
| `panel` | `rgba(20,24,40,0.72)` | Translucent card/panel fill |
| `panelSolid` | `#141828` | Opaque panel fallback |
| `panelBorder` | `rgba(45,226,230,0.12)` | Subtle neon border |

### Neon Accents
| Token | Hex | Role |
|-------|-----|------|
| `neonCyan` | `#2DE2E6` | Primary accent, CTAs, links |
| `neonMagenta` | `#FF2A6D` | Danger, destructive actions |
| `neonViolet` | `#7A5CFF` | Secondary accent |
| `neonLime` | `#B6FF6A` | Success, online status |
| `neonAmber` | `#FFB000` | Warnings, stale states |

### Text
| Token | Value | Usage |
|-------|-------|-------|
| `text0` | `#E8EAED` | Primary text |
| `text1` | `#9CA3AF` | Secondary / labels |
| `text2` | `#4B5563` | Tertiary / timestamps |

### Light Mode
The system also supports a light counterpart with deeper neon tones (`cyanDeep`, `magentaDeep`, etc.) for readability on white backgrounds.

---

## 2. Typography

### Font Families
- **Headings:** Orbitron (500 Medium, 700 Bold) — tech/geometric sans
- **Body:** Rajdhani (400 Regular, 500 Medium, 600 SemiBold, 700 Bold) — futuristic utility sans
- **Fallback:** System default when fonts haven't loaded

### Font Scale
| Variant | Size | Weight | Family | Letter Spacing |
|---------|------|--------|--------|---------------|
| `hero` | 48 | 700 | Orbitron Bold | 4 |
| `h1` | 28 | 700 | Orbitron Bold | 2 |
| `h2` | 22 | 500 | Orbitron Medium | 1 |
| `h3` | 18 | 500 | Orbitron Medium | 0.5 |
| `body` | 15 | 400 | Rajdhani Regular | 0.3 |
| `bodyMedium` | 15 | 500 | Rajdhani Medium | 0.3 |
| `bodySemiBold` | 15 | 600 | Rajdhani SemiBold | 0.3 |
| `bodyBold` | 15 | 700 | Rajdhani Bold | 0.3 |
| `caption` | 11 | 500 | Rajdhani Medium | 0.5 |

### Glow Text
Apply `textShadowColor` + `textShadowRadius` for neon glow on headings:
```ts
{ textShadowColor: palette.neonCyan, textShadowOffset: { width: 0, height: 0 }, textShadowRadius: 12 }
```

---

## 3. Spacing Scale

| Token | Value |
|-------|-------|
| `xs` | 4 |
| `sm` | 8 |
| `md` | 16 |
| `lg` | 24 |
| `xl` | 32 |
| `xxl` | 48 |

---

## 4. Border Radius

| Token | Value |
|-------|-------|
| `xs` | 4 |
| `sm` | 6 |
| `md` | 12 |
| `lg` | 16 |
| `xl` | 24 |
| `full` | 999 |

---

## 5. Glow System

Glow effects are created with `makeGlow(color, level)`.

| Level | Shadow Radius (iOS) | Opacity (iOS) | Elevation (Android) |
|-------|-------------------|--------------|-------------------|
| `sm` | 6 | 0.4 | 3 |
| `md` | 14 | 0.5 | 6 |
| `lg` | 24 | 0.6 | 10 |

Pre-built exports: `glow.cyan.sm`, `glow.cyan.md`, `glow.cyan.lg`, and same for `magenta`, `violet`, `lime`, `amber`.

---

## 6. Gradients

| Token | Colors | Usage |
|-------|--------|-------|
| `background` | bg0 → bg1 → bg2 | Dark app background |
| `backgroundLight` | lightBg → white | Light app background |
| `buttonPrimary` | neonCyan → #1AC8DB → #0891B2 | Primary CTA |
| `buttonSecondary` | neonViolet → #6347E0 → #4C30C9 | Secondary CTA |
| `danger` | neonMagenta → #E01560 → #B50E4D | Destructive actions |
| `accent` | neonCyan → neonViolet | Accent decorations |
| `warmGlow` | neonAmber → neonMagenta | Warning indicators |
| `divider` | transparent → neonCyan → transparent | Separator lines |

---

## 7. Reusable Components

### NeonText
Typography component with variant system and optional glow.
```tsx
<NeonText variant="h1" glow>WAYPOINTS</NeonText>
<NeonText variant="body" secondary>Subtitle text</NeonText>
```

### NeonButton
Gradient-filled button with glow, scale animation, and haptic feedback.
```tsx
<NeonButton title="Create Session" onPress={fn} variant="primary" />
<NeonButton title="Cancel" variant="ghost" onPress={fn} />
```
Variants: `primary` (cyan), `secondary` (violet), `danger` (magenta), `ghost` (outline).
Sizes: `sm`, `md`, `lg`.

### HudCard
Translucent panel with neon accent line and glow shadow.
```tsx
<HudCard header="Settings" glowColor="cyan">
  {/* content */}
</HudCard>
```

### Chip
Neon pill for status indicators.
```tsx
<Chip label="Online" variant="success" />
<Chip label="5 min" variant="info" active />
```
Variants: `info`, `success`, `warn`, `danger`, `accent`, `default`.

### NeonDivider
Gradient horizontal line with configurable intensity.
```tsx
<NeonDivider intensity={0.5} />
```

### BottomSheetPanel
Animated bottom sheet with translucent panel and neon accent.
```tsx
<BottomSheetPanel visible={open} onClose={close} snapHeight={300}>
  {/* content */}
</BottomSheetPanel>
```

---

## 8. Design Principles

1. **Dark-first**: bg0 `#05060A` is the default canvas. Light mode is an alternate.
2. **Glow, not flat**: Use colored shadows/glow instead of plain borders where possible.
3. **Translucent panels**: `rgba(20,24,40,0.72)` for overlays — depth through transparency.
4. **Neon accent sparingly**: Full neon on interactive elements and key data. Body text stays neutral.
5. **Consistent radius**: `borderRadius.md` (12) for most elements. No random rounded values.
6. **Letter spacing**: Add subtle tracking (0.3–1) to labels and values for a tech feel.
7. **Haptic feedback**: All interactive buttons provide tactile response via `expo-haptics`.
8. **Font hierarchy**: Orbitron for headings (geometric/techy), Rajdhani for body (readable/futuristic).

---

## 9. Participant Colors

8-color rotating palette for individual user markers and avatars:
```
#2DE2E6, #FF2A6D, #7A5CFF, #B6FF6A, #FFB000, #E94ECF, #00D9FF, #FF6B35
```
The current user always gets index 0 (neonCyan).

---

## 10. Map Styling

- **Controls**: Panel background + `glow.cyan.sm` + `borderRadius.md`
- **Satellite toggle**: Cycles `standard` → `satellite` → `hybrid` → `standard`
- **Route polylines**: Colored per-participant using `getParticipantColor()`
- **Markers**: Panel bg, `borderRadius.md`, 1.5px colored border
