// Reexport the native module. On web, it will be resolved to ExpoOneBoxModule.web.ts
// and on native platforms to ExpoOneBoxModule.ts
import { EventSubscription } from 'expo-modules-core';
import { TrafficUpdateEventPayload } from './src/ExpoOneBox.types';
import ExpoOneBoxModule from './src/ExpoOneBoxModule';
export * from './src/ExpoOneBox.types';
export { default } from './src/ExpoOneBoxModule';
export { default as ExpoOneBoxView } from './src/ExpoOneBoxView';

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

export function SetCoreLogEnabled(enabled: boolean): void {
    ExpoOneBoxModule.setCoreLogEnabled(enabled);
}

export function GetCoreLogEnabled(): boolean {
    return ExpoOneBoxModule.getCoreLogEnabled();
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

/**
 * iOS: 通过 libbox CommandClient + LibboxCommandGroup 从 Network Extension 进程
 * 查询 ExitGateway 代理组的节点列表和当前选中节点。
 * @returns { all: string[], now: string }
 */
export function GetProxyNodes(): Promise<{ all: string[]; now: string }> {
    return ExpoOneBoxModule.getProxyNodes();
}

/**
 * iOS: 通过 LibboxNewStandaloneCommandClient().selectOutbound 切换节点。
 * @param node  节点 tag 名称
 */
export function SelectProxyNode(node: string): Promise<boolean> {
    return ExpoOneBoxModule.selectProxyNode(node);
}