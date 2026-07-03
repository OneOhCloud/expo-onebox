import { NativeModule, registerWebModule } from 'expo';

import type { ExpoOneBoxModuleType } from './ExpoOneBoxModule';
import { BackgroundRefreshOptions, ExpoOneBoxModuleEvents, VerificationData, VPN_STATUS } from './ExpoOneBox.types';

// 模拟代理节点数据
const MOCK_PROXY_NODE_TAGS = ['auto', 'hk-01', 'hk-02', 'sg-01', 'jp-01', 'us-01', 'tw-01', 'de-01'];

function randomDelay(tag: string): number {
  if (tag === 'auto') return 0;
  return Math.floor(Math.random() * 180) + 10;
}

function buildMockNodes() {
  return MOCK_PROXY_NODE_TAGS.map(tag => ({ tag, delay: randomDelay(tag) }));
}

// Mock sing-box config body returned by fetchProfileConfig. Content is not
// validated on web since start() is also mocked.
export function buildMockConfigBody(url: string): string {
  return JSON.stringify(
    {
      log: { level: 'info' },
      outbounds: [
        { type: 'selector', tag: 'ExitGateway', outbounds: MOCK_PROXY_NODE_TAGS },
        { type: 'urltest', tag: 'auto', outbounds: MOCK_PROXY_NODE_TAGS.slice(1) },
      ],
      _mock: { source: url, generatedAt: new Date().toISOString() },
    },
    null,
    2,
  );
}

export function buildMockUserinfoHeader(): string {
  const gb = 1024 * 1024 * 1024;
  const total = (Math.floor(Math.random() * 200) + 50) * gb;
  const used = Math.floor(total * (0.1 + Math.random() * 0.6));
  const upload = Math.floor(used * 0.2);
  const download = used - upload;
  const expire = Math.floor(Date.now() / 1000) + (Math.floor(Math.random() * 300) + 30) * 86400;
  return `upload=${upload}; download=${download}; total=${total}; expire=${expire}`;
}

// Submodule-local mirror of parseProfileUserinfo (src/utils/profile-info.ts). The
// web stub ships inside the native submodule and must stay self-contained, so it
// cannot import the parent helper. All copies (this one, the JS reference, the
// Kotlin parseUserinfo, the Swift parseUserinfo) are locked to one language-agnostic
// contract: src/modules/expo-onebox/golden/userinfo.json — order-independent,
// missing field = 0, null header = all zeros. Keep this body equivalent to that
// contract; changes go through the golden JSON, never inline.
function parseProfileUserinfo(header: string | null) {
  return {
    upload: parseInt(header?.match(/upload=(\d+)/)?.[1] ?? '0', 10),
    download: parseInt(header?.match(/download=(\d+)/)?.[1] ?? '0', 10),
    total: parseInt(header?.match(/total=(\d+)/)?.[1] ?? '0', 10),
    expire: parseInt(header?.match(/expire=(\d+)/)?.[1] ?? '0', 10),
  };
}

const MOCK_DNS_LIST = ['8.8.8.8', '1.1.1.1', '9.9.9.9', '223.5.5.5'];

// Bare MAJOR.MINOR.PATCH mirror of the native LibboxVersion(). Single source of
// truth is SING_BOX_TAG in modules/expo-onebox/helper/Makefile — this constant
// must equal it (minus the leading `v`). Drift is caught by
// src/utils/sing-box-version-sync.test.ts, so this is a scripted obligation,
// not a silent hand-sync.
const WEB_STUB_SING_BOX_VERSION = '1.13.14';

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B/s`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB/s`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB/s`;
}

function formatBytesTotal(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

class ExpoOneBoxModule extends NativeModule<ExpoOneBoxModuleEvents> {
  private _status: number = VPN_STATUS.STOPPED;
  private _coreLogEnabled: boolean = false;
  private _lastStartConfig: string = '';
  private _currentNode: string = 'auto';
  private _trafficTimer: ReturnType<typeof setInterval> | null = null;
  private _uplinkTotal: number = 0;
  private _downlinkTotal: number = 0;

  getLibBoxVersion(): string {
    // Native returns bare MAJOR.MINOR.PATCH (no v-prefix) via LibboxVersion()
    // / Libbox.version(). Mirror the shape so getSingBox*Version helpers split
    // cleanly across platforms. See WEB_STUB_SING_BOX_VERSION above.
    return WEB_STUB_SING_BOX_VERSION;
  }

  async start(config: string): Promise<void> {
    this._lastStartConfig = config;
    console.log('[Web Mock] VPN start called with config:', config);

    // Mirror the native "Tunnel" lifecycle line so the web log viewer isn't
    // perpetually empty. onLog (libbox core output) and onError (startup
    // failure) stay unmocked — no core runs on web and a synthetic failure is
    // a product decision, not a mock concern.
    this.emit('onNativeLog', { level: 'info', tag: 'Tunnel', message: `start() requested, config bytes=${config.length}` });

    this._status = VPN_STATUS.STARTING;
    this.emit('onStatusChange', {
      status: VPN_STATUS.STARTING,
      statusName: 'connecting',
      message: 'VPN connecting (mock)',
    });

    await new Promise(resolve => setTimeout(resolve, 800));

    this._status = VPN_STATUS.STARTED;
    this._uplinkTotal = 0;
    this._downlinkTotal = 0;
    this.emit('onStatusChange', {
      status: VPN_STATUS.STARTED,
      statusName: 'connected',
      message: 'VPN connected (mock)',
    });

    // 启动模拟流量更新定时器
    this._trafficTimer = setInterval(() => {
      const uplink = Math.floor(Math.random() * 512 * 1024);
      const downlink = Math.floor(Math.random() * 2 * 1024 * 1024);
      this._uplinkTotal += uplink;
      this._downlinkTotal += downlink;
      const memory = Math.floor(Math.random() * 20 * 1024 * 1024) + 8 * 1024 * 1024;

      this.emit('onTrafficUpdate', {
        uplink,
        downlink,
        uplinkTotal: this._uplinkTotal,
        downlinkTotal: this._downlinkTotal,
        uplinkDisplay: formatBytes(uplink),
        downlinkDisplay: formatBytes(downlink),
        uplinkTotalDisplay: formatBytesTotal(this._uplinkTotal),
        downlinkTotalDisplay: formatBytesTotal(this._downlinkTotal),
        memory,
        memoryDisplay: `${(memory / 1024 / 1024).toFixed(1)} MB`,
        goroutines: Math.floor(Math.random() * 30) + 20,
        connectionsIn: Math.floor(Math.random() * 10),
        connectionsOut: Math.floor(Math.random() * 20),
      });
    }, 1000);
  }

  async stop(): Promise<void> {
    console.log('[Web Mock] VPN stop called');
    this.emit('onNativeLog', { level: 'info', tag: 'Tunnel', message: 'stop() requested' });

    this._status = VPN_STATUS.STOPPING;
    this.emit('onStatusChange', {
      status: VPN_STATUS.STOPPING,
      statusName: 'disconnecting',
      message: 'VPN disconnecting (mock)',
    });

    if (this._trafficTimer) {
      clearInterval(this._trafficTimer);
      this._trafficTimer = null;
    }

    await new Promise(resolve => setTimeout(resolve, 400));

    this._status = VPN_STATUS.STOPPED;
    this.emit('onStatusChange', {
      status: VPN_STATUS.STOPPED,
      statusName: 'stopped',
      message: 'VPN stopped (mock)',
    });
  }

  async checkVpnPermission(): Promise<boolean> {
    return true;
  }

  async requestVpnPermission(): Promise<boolean> {
    return true;
  }

  getStatus(): number {
    return this._status;
  }

  getStartError(): string {
    return '';
  }

  getStartConfig(): string {
    return this._lastStartConfig;
  }

  setCoreLogEnabled(enabled: boolean): void {
    this._coreLogEnabled = enabled;
    console.log('[Web Mock] setCoreLogEnabled:', enabled);
  }

  // No sing-box core runs on web; the log-level filter is a native concern.
  // Present as a no-op so the shared mount effect in vpn-context.tsx does not
  // throw on web (see the bridge-signature four-layer rule).
  setCoreLogLevel(level: string): void {
    console.log('[Web Mock] setCoreLogLevel:', level);
  }

  async triggerURLTest(_tag: string): Promise<boolean> {
    setTimeout(() => {
      this.emit('onGroupUpdate', {
        all: buildMockNodes(),
        now: this._currentNode,
        autoNow: this._currentNode === 'auto' ? 'hk-01' : this._currentNode,
      });
    }, 200);
    return true;
  }

  async selectProxyNode(node: string): Promise<boolean> {
    console.log('[Web Mock] selectProxyNode:', node);
    const exists = MOCK_PROXY_NODE_TAGS.includes(node);
    if (exists) {
      this._currentNode = node;
      this.emit('onGroupUpdate', {
        all: buildMockNodes(),
        now: this._currentNode,
        autoNow: this._currentNode === 'auto' ? 'hk-01' : this._currentNode,
      });
    }
    return exists;
  }

  async getBestDns(): Promise<string> {
    const idx = Math.floor(Math.random() * MOCK_DNS_LIST.length);
    return MOCK_DNS_LIST[idx];
  }

  checkBatteryOptimizationExemption(): boolean {
    return true;
  }

  async requestBatteryOptimizationExemption(): Promise<boolean> {
    return true;
  }

  crashForBugsnagTest(): boolean {
    throw new Error('Bugsnag native crash test is Android-only.');
  }

  repairSQLiteDirectory(): boolean {
    return true;
  }

  async copy2CacheDbPath(_sourceUri: string): Promise<boolean> {
    // No native working directory on web, so nothing is copied. Mirror the
    // native "already exists / skipped" branch (false) rather than reporting a
    // copy that never happened — otherwise _layout.tsx mis-logs "copied".
    return false;
  }

  async fetchProfileConfig(url: string, _userAgent: string) {
    console.log('[Web Mock] fetchProfileConfig:', url);
    return {
      statusCode: 200,
      headers: {
        'content-type': 'application/json',
        'subscription-userinfo': buildMockUserinfoHeader(),
      } as Record<string, string>,
      body: buildMockConfigBody(url),
    };
  }

  async setVerificationData(_data: VerificationData): Promise<void> {
    console.log('[Web Mock] setVerificationData');
  }

  async setBackgroundConfigRefreshOptions(_options: BackgroundRefreshOptions): Promise<void> {
    console.log('[Web Mock] setBackgroundConfigRefreshOptions');
  }

  async registerBackgroundConfigRefresh(_url: string, _userAgent: string, _intervalSeconds: number): Promise<void> {
    console.log('[Web Mock] registerBackgroundConfigRefresh');
  }

  async executeConfigRefreshNow(url: string, _userAgent: string) {
    const body = buildMockConfigBody(url);
    const header = buildMockUserinfoHeader();
    const info = parseProfileUserinfo(header);
    return {
      status: 'success' as const,
      content: body,
      profileUpload: info.upload,
      profileDownload: info.download,
      profileTotal: info.total,
      profileExpire: info.expire,
      timestamp: new Date().toISOString(),
      durationMs: 120,
      profileUserinfoHeader: header,
      method: 'primary' as const,
      actualUrl: url,
    };
  }

  getLastConfigRefreshResult() {
    return null;
  }

  async isBackgroundConfigRefreshRegistered(): Promise<boolean> {
    return false;
  }

}

// Conformance gate (D8-05): the web stub must expose every method the native
// module declares. If a method is added to ExpoOneBoxModule.ts but not mirrored
// here, this line fails tsc — instead of the app crashing at runtime on web
// (as it did when setCoreLogLevel was missing). Type-only; erased at build.
const _webStubConformsToNative = (m: InstanceType<typeof ExpoOneBoxModule>): ExpoOneBoxModuleType => m;
void _webStubConformsToNative;

export default registerWebModule(ExpoOneBoxModule, 'ExpoOneBox');
