import { NativeModule, registerWebModule } from 'expo';

import { ExpoOneBoxModuleEvents, VPN_STATUS } from './ExpoOneBox.types';

// 模拟代理节点数据
const MOCK_PROXY_NODES = [
  { tag: 'auto', delay: 0 },
  { tag: 'hk-01', delay: Math.floor(Math.random() * 50) + 10 },
  { tag: 'hk-02', delay: Math.floor(Math.random() * 50) + 10 },
  { tag: 'sg-01', delay: Math.floor(Math.random() * 80) + 20 },
  { tag: 'jp-01', delay: Math.floor(Math.random() * 60) + 15 },
  { tag: 'us-01', delay: Math.floor(Math.random() * 200) + 100 },
];

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
    // 刷新随机延迟
    const nodes = MOCK_PROXY_NODES.map(node => ({
      tag: node.tag,
      delay: node.tag === 'auto' ? 0 : Math.floor(Math.random() * 150) + 10,
    }));
    return { all: nodes, now: this._currentNode };
  }

  async selectProxyNode(node: string): Promise<boolean> {
    console.log('[Web Mock] selectProxyNode:', node);
    const exists = MOCK_PROXY_NODES.some(n => n.tag === node);
    if (exists) {
      this._currentNode = node;
    }
    return exists;
  }

  async getBestDns(): Promise<string> {
    const idx = Math.floor(Math.random() * MOCK_DNS_LIST.length);
    return MOCK_DNS_LIST[idx];
  }
}

export default registerWebModule(ExpoOneBoxModule, 'ExpoOneBox');
