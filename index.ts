// 重新导出原生模块。web 上会解析到 ExpoOneBoxModule.web.ts，
// 原生平台上会解析到 ExpoOneBoxModule.ts。
export * from './src/ExpoOneBox.types';
export { default, default as ExpoOneBox } from './src/ExpoOneBoxModule';
