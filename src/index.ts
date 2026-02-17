// Reexport the native module. On web, it will be resolved to ExpoOneBoxModule.web.ts
// and on native platforms to ExpoOneBoxModule.ts
export * from './ExpoOneBox.types';
export { default } from './ExpoOneBoxModule';
export { default as ExpoOneBoxView } from './ExpoOneBoxView';
import { EventSubscription } from 'expo-modules-core';
import { TrafficUpdateEventPayload } from './ExpoOneBox.types';
import ExpoOneBoxModule from './ExpoOneBoxModule';

export function GetVersion(): string {
    return ExpoOneBoxModule.getLibBoxVersion();
}

export function Start(config: string): Promise<void> {
    return ExpoOneBoxModule.start(config);
}

export function Stop(): Promise<void> {
    return ExpoOneBoxModule.stop();
}

export function CheckVpnPermission(): Promise<boolean> {
    return ExpoOneBoxModule.checkVpnPermission();
}

export function RequestVpnPermission(): Promise<boolean> {
    return ExpoOneBoxModule.requestVpnPermission();
}

export function GetStatus(): number {
    return ExpoOneBoxModule.getStatus();
}

// 添加事件监听器的便捷方法
export function addStatusChangeListener(callback: (event: { status: number; statusName: string; message: string }) => void)
    : EventSubscription {
    return ExpoOneBoxModule.addListener('onStatusChange', callback);
}

export function addErrorListener(callback: (event: { type: string; message: string; status?: number }) => void): EventSubscription {
    return ExpoOneBoxModule.addListener('onError', callback);
}

export function addLogListener(callback: (event: { message: string }) => void): EventSubscription {
    return ExpoOneBoxModule.addListener('onLog', callback);
}

/**
 * 监听流量和运行状态更新（网速、内存、协程数、连接数）。
 * 仅在 VPN 服务启动后有数据推送，约每秒一次。
 */
export function addTrafficUpdateListener(callback: (event: TrafficUpdateEventPayload) => void): EventSubscription {
    return ExpoOneBoxModule.addListener('onTrafficUpdate', callback);
}