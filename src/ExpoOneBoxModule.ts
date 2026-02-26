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
  setCoreLogEnabled(enabled: boolean): void;
  getCoreLogEnabled(): boolean
  getProxyNodes(): Promise<{ all: string[]; now: string }>;
  selectProxyNode(node: string): Promise<boolean>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoOneBoxModule>('ExpoOneBox');
