import { NativeModule, requireNativeModule } from 'expo';

import { ConfigRefreshResult, ExpoOneBoxModuleEvents, ConfigFetchResult, VerificationData } from './ExpoOneBox.types';

declare class ExpoOneBoxModule extends NativeModule<ExpoOneBoxModuleEvents> {
  hello(): string;
  getLibBoxVersion(): string;
  start(config: string): Promise<void>;
  stop(): Promise<void>;
  checkVpnPermission(): Promise<boolean>;
  requestVpnPermission(): Promise<boolean>;
  /** Android only: returns true if the app is already exempt from battery optimizations. */
  checkBatteryOptimizationExemption(): boolean;
  /** Android only: shows the system dialog to request battery optimization exemption. Resolves with the final exemption state after the user dismisses the dialog. */
  requestBatteryOptimizationExemption(): Promise<boolean>;
  getStatus(): number;
  /** Sync read of the last startup error written by the Extension/Service. Empty = no error. */
  getStartError(): string;
  /** Returns the config JSON string last passed to start(), after native processing. Empty string if never started. */
  getStartConfig(): string;
  setCoreLogEnabled(enabled: boolean): void;
  getCoreLogEnabled(): boolean;
  /**
   * Filter entries from the sing-box CommandServer log stream at the
   * earliest native point (before they're serialised into JS events).
   *
   * Needed because sing-box's `log.level` in config only filters the
   * stdout / observable sinks — the platform writer (which feeds this
   * stream) receives every level unconditionally. See the block comment
   * in `vpn-context.tsx` for the source pointer.
   *
   * Accepts the sing-box level names: trace / debug / info / warn /
   * error / fatal / panic. Unknown values are coerced to `info`.
   */
  setCoreLogLevel(level: string): void;
  getProxyNodes(): Promise<{ all: { tag: string; delay: number }[]; now: string }>;
  selectProxyNode(node: string): Promise<boolean>;
  /** Trigger URLTest for a specific outbound tag or group tag (e.g. "ExitGateway"). */
  triggerURLTest(tag: string): Promise<boolean>;
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

  /** Fetch a config URL using DNS resolution + SNI-overriding HTTPS. */
  fetchSubscription(url: string, userAgent: string): Promise<ConfigFetchResult>;

  /**
   * Push the JS-managed domain allowlist into the native background worker's
   * shared store. Consumed by the iOS BGTaskScheduler / Android WorkManager
   * refresh task so it can verify hostnames without re-fetching the remote
   * list. Timestamp is captured on the native side; cache is honoured for
   * 24 h before falling back to the built-in list.
   */
  setVerificationData(data: VerificationData): Promise<void>;

  /** Register (or update) the native periodic background config refresh. */
  registerBackgroundConfigRefresh(url: string, userAgent: string, intervalSeconds: number, accelerateUrl: string | null): Promise<void>;

  /** Cancel the scheduled background config refresh. */
  unregisterBackgroundConfigRefresh(): Promise<void>;

  /** Execute a config refresh immediately (returns result synchronously to JS). */
  executeConfigRefreshNow(url: string, userAgent: string, accelerateUrl: string | null, testPrimaryUrlUnavailable?: boolean): Promise<ConfigRefreshResult>;

  /**
   * Return and clear the last result stored by the native background task.
   * Returns null if no result has been stored since the last read.
   */
  getLastConfigRefreshResult(): ConfigRefreshResult | null;

  /** Whether the native background refresh task is currently scheduled. */
  isBackgroundConfigRefreshRegistered(): Promise<boolean>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoOneBoxModule>('ExpoOneBox');
