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
  /** iOS: fire a lightweight network request to trigger the system network-access permission prompt. */
  triggerNetworkPermission(): Promise<boolean>;
  /**
   * Copies the asset at sourceUri to the native working directory as tun.db.
   * Skips if the destination file already exists.
   * Android: <externalFilesDir>/tun.db
   * iOS:     <AppGroup>/Library/Caches/tun.db
   * @param sourceUri A file:// URI pointing to the bundled asset (from expo-asset localUri).
   */
  copy2CacheDbPath(sourceUri: string): Promise<boolean>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoOneBoxModule>('ExpoOneBox');
