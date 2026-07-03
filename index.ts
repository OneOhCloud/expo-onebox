// Reexport the native module. On web, it will be resolved to ExpoOneBoxModule.web.ts
// and on native platforms to ExpoOneBoxModule.ts
export * from './src/ExpoOneBox.types';
export { default, default as ExpoOneBox } from './src/ExpoOneBoxModule';
