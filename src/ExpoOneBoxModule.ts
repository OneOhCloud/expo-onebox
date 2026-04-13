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
  setCoreLogEnabled(enabled: boolean): void;
  getCoreLogEnabled(): boolean;
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

  /** Set verification data (known SHA256 + verified list) for domain validation during fallback. */
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

  /**
   * Append-only diagnostic log of background worker invocations.
   * Unlike `getLastConfigRefreshResult`, reading this does NOT clear it,
   * so it can be used to verify whether `doWork()` was actually invoked.
   * Android: entries include `event` (scheduled | doWork), `time`, `status`,
   * `method`, `durationMs`, `error`, `runAttempt`, `workId`, `intervalSeconds`.
   * iOS / Web: always returns `[]` (not yet implemented).
   */
  getBackgroundWorkerRunLog(): WorkerRunLogEntry[];

  /** Clears the append-only worker run log (Android only). */
  clearBackgroundWorkerRunLog(): void;
}

export interface WorkerRunLogEntry {
  event: 'scheduled' | 'doWork';
  time: string;
  status?: 'success' | 'failed' | 'skipped';
  reason?: string;
  method?: 'primary' | 'fallback';
  durationMs?: number;
  error?: string | null;
  runAttempt?: number;
  workId?: string;
  intervalSeconds?: number;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoOneBoxModule>('ExpoOneBox');
