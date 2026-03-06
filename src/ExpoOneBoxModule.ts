import { NativeModule, requireNativeModule } from 'expo';

import { ExpoOneBoxModuleEvents } from './ExpoOneBox.types';

declare class ExpoOneBoxModule extends NativeModule<ExpoOneBoxModuleEvents> {
  hello(): string;
  getLibBoxVersion(): string;
  start(config: string): Promise<void>;
  stop(): Promise<void>;
  checkVpnPermission(): Promise<boolean>;
  requestVpnPermission(): Promise<boolean>;
  getStatus(): number;
  /** Sync read of the last startup error written by the Extension/Service. Empty = no error. */
  getStartError(): string;
  setCoreLogEnabled(enabled: boolean): void;
  getCoreLogEnabled(): boolean;
  getProxyNodes(): Promise<{ all: { tag: string; delay: number }[]; now: string }>;
  selectProxyNode(node: string): Promise<boolean>;
  getBestDns(): Promise<string>;
  /** Android: check if POST_NOTIFICATIONS permission is granted */
  checkNotificationPermission(): Promise<boolean>;
  /** Android: request POST_NOTIFICATIONS runtime permission (Android 13+). Returns true if granted. */
  requestNotificationPermission(): Promise<boolean>;
  /** iOS: fire a lightweight network request to trigger the system network-access permission prompt. */
  triggerNetworkPermission(): Promise<boolean>;
  /**
   * Returns the absolute path where JS should write cache.db.
   * Android: <externalFilesDir>/cache/tun.db
   * iOS:     <AppGroup>/Library/Caches/tun.db
   */
  getCacheDbPath(): string;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoOneBoxModule>('ExpoOneBox');
