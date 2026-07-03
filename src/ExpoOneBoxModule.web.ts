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

// fetchProfileConfig 返回的 mock sing-box config 主体。web 上不校验内容，
// 因为 start() 同样是 mock 的。
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

// parseProfileUserinfo（src/utils/profile-info.ts）的 submodule 本地副本。web stub
// 随原生 submodule 一起发布，必须保持自包含，因此无法 import 上层 helper。所有副本
// （本副本、JS 参照实现、Kotlin parseUserinfo、Swift parseUserinfo）都锁定到同一份
// 与语言无关的契约：src/modules/expo-onebox/golden/userinfo.json——与顺序无关、
// 缺失字段 = 0、header 为 null 则全为零。保持此处实现与该契约等价；改动走 golden
// JSON，绝不 inline 直改。
function parseProfileUserinfo(header: string | null) {
  return {
    upload: parseInt(header?.match(/upload=(\d+)/)?.[1] ?? '0', 10),
    download: parseInt(header?.match(/download=(\d+)/)?.[1] ?? '0', 10),
    total: parseInt(header?.match(/total=(\d+)/)?.[1] ?? '0', 10),
    expire: parseInt(header?.match(/expire=(\d+)/)?.[1] ?? '0', 10),
  };
}

const MOCK_DNS_LIST = ['8.8.8.8', '1.1.1.1', '9.9.9.9', '223.5.5.5'];

// 原生 LibboxVersion() 的纯 MAJOR.MINOR.PATCH 镜像。单一来源是
// modules/expo-onebox/helper/Makefile 中的 SING_BOX_TAG——本常量必须与之相等
// （去掉开头的 `v`）。漂移由 src/utils/sing-box-version-sync.test.ts 捕获，
// 因此这是脚本化的强制约束，而非静默的手工同步。
const WEB_STUB_SING_BOX_VERSION = '1.13.14';

class ExpoOneBoxModule extends NativeModule<ExpoOneBoxModuleEvents> {
  private _status: number = VPN_STATUS.STOPPED;
  private _coreLogEnabled: boolean = false;
  private _lastStartConfig: string = '';
  private _currentNode: string = 'auto';
  private _trafficTimer: ReturnType<typeof setInterval> | null = null;
  private _uplinkTotal: number = 0;
  private _downlinkTotal: number = 0;

  getLibBoxVersion(): string {
    // 原生通过 LibboxVersion() / Libbox.version() 返回纯 MAJOR.MINOR.PATCH
    // （无 v 前缀）。镜像该形态，使 getSingBox*Version 系列 helper 能在各端
    // 一致地切分。见上方 WEB_STUB_SING_BOX_VERSION。
    return WEB_STUB_SING_BOX_VERSION;
  }

  async start(config: string): Promise<void> {
    this._lastStartConfig = config;
    console.log('[Web Mock] VPN start called with config:', config);

    // 镜像原生的 "Tunnel" 生命周期日志行，使 web 日志查看器不至于一直为空。
    // onLog（libbox 内核输出）与 onError（启动失败）保持不 mock——web 上没有
    // 内核运行，而制造一个合成的失败属于产品决策，不是 mock 该管的事。
    this.emit('onNativeLog', { level: 'info', tag: 'Tunnel', message: `start() requested, config bytes=${config.length}` });

    this._status = VPN_STATUS.STARTING;
    this.emit('onStatusChange', {
      status: VPN_STATUS.STARTING,
      statusName: 'starting',
      message: 'VPN connecting (mock)',
    });

    await new Promise(resolve => setTimeout(resolve, 800));

    this._status = VPN_STATUS.STARTED;
    this._uplinkTotal = 0;
    this._downlinkTotal = 0;
    this.emit('onStatusChange', {
      status: VPN_STATUS.STARTED,
      statusName: 'started',
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
        memory,
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
      statusName: 'stopping',
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

  // web 上没有 sing-box 内核运行；日志级别过滤是原生侧的事。这里实现为
  // no-op，使 vpn-context.tsx 中共享的 mount effect 在 web 上不会抛错
  // （见 bridge-signature 四层规则）。
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

  async selectProxyNode(tag: string): Promise<boolean> {
    console.log('[Web Mock] selectProxyNode:', tag);
    const exists = MOCK_PROXY_NODE_TAGS.includes(tag);
    if (exists) {
      this._currentNode = tag;
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
    // web 上没有原生工作目录，所以什么都不拷贝。镜像原生的
    // "already exists / skipped" 分支（false），而不是谎报一次并未发生的拷贝
    // ——否则 _layout.tsx 会误记 "copied"。
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

// 一致性闸门：web stub 必须暴露原生模块声明的每一个方法。若某方法
// 加进了 ExpoOneBoxModule.ts 却没在这里镜像，本行会让 tsc 失败——而不是让
// app 在 web 上运行时崩溃（就像当初 setCoreLogLevel 缺失时那样）。仅类型，
// 编译时擦除。
const _webStubConformsToNative = (m: InstanceType<typeof ExpoOneBoxModule>): ExpoOneBoxModuleType => m;
void _webStubConformsToNative;

export default registerWebModule(ExpoOneBoxModule, 'ExpoOneBox');
