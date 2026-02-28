/**
 * Generate app icon and splash screen PNGs using sharp.
 * Run: node scripts/generate-assets.js
 */

const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const ASSETS_DIR = path.join(__dirname, '..', 'apps', 'mobile', 'assets');

const BRAND_COLOR = '#4F46E5';

// 1024x1024 icon SVG
const iconSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:${BRAND_COLOR};stop-opacity:1" />
      <stop offset="100%" style="stop-color:#7C3AED;stop-opacity:1" />
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="220" fill="url(#bg)"/>
  <g transform="translate(512, 390) scale(1.6)" fill="none" stroke="white" stroke-width="30" stroke-linecap="round" stroke-linejoin="round">
    <path d="M0,-160 C-88.4,-160 -160,-88.4 -160,0 C-160,110 0,240 0,240 C0,240 160,110 160,0 C160,-88.4 88.4,-160 0,-160 Z"/>
    <circle cx="0" cy="-10" r="55" fill="white" fill-opacity="0.3"/>
  </g>
  <text x="512" y="800" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="160" font-weight="800" fill="white" fill-opacity="0.95">WAYPOINTS</text>
</svg>`;

// Splash screen SVG
const splashSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="1284" height="2778" viewBox="0 0 1284 2778">
  <rect width="1284" height="2778" fill="${BRAND_COLOR}"/>
  <g transform="translate(642, 1200) scale(2.2)" fill="none" stroke="white" stroke-width="26" stroke-linecap="round" stroke-linejoin="round">
    <path d="M0,-160 C-88.4,-160 -160,-88.4 -160,0 C-160,110 0,240 0,240 C0,240 160,110 160,0 C160,-88.4 88.4,-160 0,-160 Z"/>
    <circle cx="0" cy="-10" r="55" fill="white" fill-opacity="0.3"/>
  </g>
  <text x="642" y="1700" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="72" font-weight="700" letter-spacing="12" fill="white" fill-opacity="0.9">WAYPOINTS</text>
</svg>`;

// Adaptive icon foreground (transparent bg, white icon for Android)
const adaptiveSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect width="1024" height="1024" fill="${BRAND_COLOR}"/>
  <g transform="translate(512, 390) scale(1.6)" fill="none" stroke="white" stroke-width="30" stroke-linecap="round" stroke-linejoin="round">
    <path d="M0,-160 C-88.4,-160 -160,-88.4 -160,0 C-160,110 0,240 0,240 C0,240 160,110 160,0 C160,-88.4 88.4,-160 0,-160 Z"/>
    <circle cx="0" cy="-10" r="55" fill="white" fill-opacity="0.3"/>
  </g>
  <text x="512" y="800" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="160" font-weight="800" fill="white" fill-opacity="0.95">WAYPOINTS</text>
</svg>`;

// Favicon (48x48)
const faviconSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48">
  <rect width="48" height="48" rx="10" fill="${BRAND_COLOR}"/>
  <g transform="translate(24, 20) scale(0.08)" fill="none" stroke="white" stroke-width="30" stroke-linecap="round" stroke-linejoin="round">
    <path d="M0,-160 C-88.4,-160 -160,-88.4 -160,0 C-160,110 0,240 0,240 C0,240 160,110 160,0 C160,-88.4 88.4,-160 0,-160 Z"/>
  </g>
</svg>`;

async function generate() {
  fs.mkdirSync(ASSETS_DIR, { recursive: true });

  await sharp(Buffer.from(iconSvg))
    .resize(1024, 1024)
    .png()
    .toFile(path.join(ASSETS_DIR, 'icon.png'));
  console.log('✓ icon.png (1024x1024)');

  await sharp(Buffer.from(splashSvg))
    .resize(1284, 2778)
    .png()
    .toFile(path.join(ASSETS_DIR, 'splash.png'));
  console.log('✓ splash.png (1284x2778)');

  await sharp(Buffer.from(adaptiveSvg))
    .resize(1024, 1024)
    .png()
    .toFile(path.join(ASSETS_DIR, 'adaptive-icon.png'));
  console.log('✓ adaptive-icon.png (1024x1024)');

  await sharp(Buffer.from(faviconSvg))
    .resize(48, 48)
    .png()
    .toFile(path.join(ASSETS_DIR, 'favicon.png'));
  console.log('✓ favicon.png (48x48)');

  console.log('\nAll assets generated in', ASSETS_DIR);
}

generate().catch(console.error);
