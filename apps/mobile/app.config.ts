import { ExpoConfig, ConfigContext } from 'expo/config';

const IS_DEV = process.env.APP_VARIANT === 'development';
const IS_PREVIEW = process.env.APP_VARIANT === 'preview';

const getUniqueIdentifier = () => {
  if (IS_DEV) return 'com.waypoints.app.dev';
  if (IS_PREVIEW) return 'com.waypoints.app.preview';
  return 'com.waypoints.app';
};

const getAppName = () => {
  if (IS_DEV) return 'Waypoints (Dev)';
  if (IS_PREVIEW) return 'Waypoints (Preview)';
  return 'Waypoints';
};

export default ({ config }: ConfigContext): ExpoConfig => ({
  ...config,
  name: getAppName(),
  slug: 'waypoints',
  version: '1.0.0',
  orientation: 'portrait',
  scheme: 'waypoints',
  platforms: ['ios', 'android'],
  icon: './assets/icon.png',
  userInterfaceStyle: 'light',
  splash: {
    image: './assets/splash.png',
    resizeMode: 'contain',
    backgroundColor: '#4F46E5',
  },
  assetBundlePatterns: ['**/*'],
  ios: {
    supportsTablet: false,
    bundleIdentifier: getUniqueIdentifier(),
    buildNumber: '1',
    infoPlist: {
      NSLocationWhenInUseUsageDescription:
        'Waypoints needs your location to share it with your session group in real time.',
      CFBundleAllowMixedLocalizations: true,
    },
    config: {
      usesNonExemptEncryption: false,
    },
  },
  android: {
    adaptiveIcon: {
      foregroundImage: './assets/adaptive-icon.png',
      backgroundColor: '#4F46E5',
    },
    package: getUniqueIdentifier(),
    versionCode: 1,
    permissions: ['ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION'],
  },
  plugins: ['expo-location'],
  extra: {
    eas: {
      projectId: process.env.EAS_PROJECT_ID || '',
    },
  },
  updates: {
    url: `https://u.expo.dev/${process.env.EAS_PROJECT_ID || ''}`,
  },
  runtimeVersion: {
    policy: 'appVersion',
  },
});
