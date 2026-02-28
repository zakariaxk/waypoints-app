// Learn more https://docs.expo.io/guides/customizing-metro
const { getDefaultConfig } = require('expo/metro-config');
const path = require('path');

// Find the project and workspace directories
const projectRoot = __dirname;
const monorepoRoot = path.resolve(projectRoot, '../..');

const config = getDefaultConfig(projectRoot);

// 1. Watch all files within the monorepo
config.watchFolders = [monorepoRoot];

// 2. Let Metro know where to resolve packages and in what order
config.resolver.nodeModulesPaths = [
  path.resolve(projectRoot, 'node_modules'),
  path.resolve(monorepoRoot, 'node_modules'),
];

// 3. Force Metro to resolve (sub)dependencies only from the root node_modules
config.resolver.disableHierarchicalLookup = true;

// 4. Fix monorepo entry point: expo/AppEntry.js does `import App from '../../App'`
//    which breaks when expo is hoisted to root node_modules. Intercept and redirect.
const defaultResolveRequest = config.resolver.resolveRequest;
config.resolver.resolveRequest = (context, moduleName, platform) => {
  // When AppEntry.js tries to import '../../App', redirect to our App.tsx.
  // This happens because expo is hoisted to the monorepo root node_modules.
  if (moduleName === '../../App') {
    return {
      filePath: path.resolve(projectRoot, 'App.tsx'),
      type: 'sourceFile',
    };
  }

  // react-native-webrtc imports 'event-target-shim/index' but the package's
  // "exports" map only exposes ".".  Rewrite to the bare specifier so Metro
  // can resolve it through the normal "." export.
  if (moduleName === 'event-target-shim/index') {
    return context.resolveRequest(context, 'event-target-shim', platform);
  }

  // Stub react-native-webrtc ONLY when the real package isn't installed.
  // When installed (dev client / EAS build), Metro uses the real module.
  // The getWebRTC() guard in useVoiceChat.ts prevents runtime evaluation
  // in Expo Go even though the module is in the bundle.
  if (moduleName === 'react-native-webrtc') {
    try {
      // Check if the real module resolves; if so, let Metro use it.
      require.resolve('react-native-webrtc');
    } catch {
      return {
        filePath: path.resolve(projectRoot, 'src/stubs/react-native-webrtc.js'),
        type: 'sourceFile',
      };
    }
  }

  if (defaultResolveRequest) {
    return defaultResolveRequest(context, moduleName, platform);
  }
  return context.resolveRequest(context, moduleName, platform);
};

module.exports = config;
