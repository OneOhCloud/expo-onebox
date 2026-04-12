import { NativeModule, registerWebModule } from 'expo';

import { ExpoOneBoxModuleEvents, VerificationData, VPN_STATUS } from './ExpoOneBox.types';

// 模拟代理节点数据
const MOCK_PROXY_NODE_TAGS = ['auto', 'hk-01', 'hk-02', 'sg-01', 'jp-01', 'us-01', 'tw-01', 'de-01'];

function randomDelay(tag: string): number {
  if (tag === 'auto') return 0;
  return Math.floor(Math.random() * 180) + 10;
}

function buildMockNodes() {
  return MOCK_PROXY_NODE_TAGS.map(tag => ({ tag, delay: randomDelay(tag) }));
}

// Mock sing-box config body returned by fetchSubscription. Content is not
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

const MOCK_DNS_LIST = ['8.8.8.8', '1.1.1.1', '9.9.9.9', '223.5.5.5'];

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
  private _currentNode: string = 'auto';
  private _trafficTimer: ReturnType<typeof setInterval> | null = null;
  private _uplinkTotal: number = 0;
  private _downlinkTotal: number = 0;

  hello(): string {
    return 'Hello world! 👋';
  }

  getLibBoxVersion(): string {
    return '1.12.0-web-mock';
  }

  async start(config: string): Promise<void> {
    console.log('[Web Mock] VPN start called with config:', config);

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

  setCoreLogEnabled(enabled: boolean): void {
    this._coreLogEnabled = enabled;
    console.log('[Web Mock] setCoreLogEnabled:', enabled);
  }

  getCoreLogEnabled(): boolean {
    return this._coreLogEnabled;
  }

  async getProxyNodes(): Promise<{ all: { tag: string; delay: number }[]; now: string }> {
    return { all: buildMockNodes(), now: this._currentNode };
  }

  async triggerURLTest(_tag: string): Promise<boolean> {
    setTimeout(() => {
      this.emit('onGroupUpdate', { all: buildMockNodes(), now: this._currentNode });
    }, 200);
    return true;
  }

  async selectProxyNode(node: string): Promise<boolean> {
    console.log('[Web Mock] selectProxyNode:', node);
    const exists = MOCK_PROXY_NODE_TAGS.includes(node);
    if (exists) {
      this._currentNode = node;
      this.emit('onGroupUpdate', { all: buildMockNodes(), now: this._currentNode });
    }
    return exists;
  }

  async getBestDns(): Promise<string> {
    const idx = Math.floor(Math.random() * MOCK_DNS_LIST.length);
    return MOCK_DNS_LIST[idx];
  }

  async triggerNetworkPermission(): Promise<boolean> {
    return true;
  }

  checkBatteryOptimizationExemption(): boolean {
    return true;
  }

  async requestBatteryOptimizationExemption(): Promise<boolean> {
    return true;
  }

  async copy2CacheDbPath(_sourceUri: string): Promise<boolean> {
    return true;
  }

  async fetchSubscription(url: string, _userAgent: string) {
    console.log('[Web Mock] fetchSubscription:', url);
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

  async registerBackgroundConfigRefresh(_url: string, _userAgent: string, _intervalSeconds: number, _accelerateUrl: string | null): Promise<void> {
    console.log('[Web Mock] registerBackgroundConfigRefresh');
  }

  async unregisterBackgroundConfigRefresh(): Promise<void> {}

  async executeConfigRefreshNow(url: string, _userAgent: string, _accelerateUrl: string | null, _testPrimaryUrlUnavailable?: boolean) {
    const body = buildMockConfigBody(url);
    const header = buildMockUserinfoHeader();
    const info = {
      upload: parseInt(header.match(/upload=(\d+)/)?.[1] ?? '0', 10),
      download: parseInt(header.match(/download=(\d+)/)?.[1] ?? '0', 10),
      total: parseInt(header.match(/total=(\d+)/)?.[1] ?? '0', 10),
      expire: parseInt(header.match(/expire=(\d+)/)?.[1] ?? '0', 10),
    };
    return {
      status: 'success' as const,
      content: body,
      subscriptionUpload: info.upload,
      subscriptionDownload: info.download,
      subscriptionTotal: info.total,
      subscriptionExpire: info.expire,
      timestamp: new Date().toISOString(),
      durationMs: 120,
      subscriptionUserinfoHeader: header,
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

export default registerWebModule(ExpoOneBoxModule, 'ExpoOneBox');
