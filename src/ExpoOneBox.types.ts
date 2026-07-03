// VPN 连接状态
// Status-name vocabulary matches the numeric VPN_STATUS family (stopped=0,
// starting=1, started=2, stopping=3), rather than a separate connect-family, so
// the string and code describe the same lifecycle (audit C20). Diagnostic/log
// use only — no logic branches on these strings.
export type VpnStatus = 'stopped' | 'starting' | 'started' | 'stopping' | 'unknown';

// 状态码常量
export const VPN_STATUS = {
  STOPPED: 0,
  STARTING: 1,
  STARTED: 2,
  STOPPING: 3,
} as const;

// 状态变化事件
export type StatusChangeEventPayload = {
  status: number;
  statusName: VpnStatus;
  message: string;
};

// 错误事件
export type ErrorEventPayload = {
  type: string;
  message: string;
  /** 错误来源: binary=libbox二进制, android=Android平台, module=Expo模块层 */
  source: 'binary' | 'android' | 'module' | 'unknown';
  status?: number; // 错误发生时的状态码（通常是STOPPED）
};

// 日志事件
export type LogEventPayload = {
  message: string;
};

// 流量/状态监控事件（来自 CommandClient StatusMessage）
export type TrafficUpdateEventPayload = {
  /** 上行速度 bytes/s */
  uplink: number;
  /** 下行速度 bytes/s */
  downlink: number;
  /** 累计上行 bytes */
  uplinkTotal: number;
  /** 累计下行 bytes */
  downlinkTotal: number;
  /** 内存使用 bytes */
  memory: number;
  /** Go 协程数量 */
  goroutines: number;
  /** 入站连接数 */
  connectionsIn: number;
  /** 出站连接数 */
  connectionsOut: number;
};

// 代理节点组更新事件（来自 CommandClient SubscribeGroups 流）
export type GroupUpdateEventPayload = {
  /** ExitGateway 下所有节点 */
  all: { tag: string; delay: number }[];
  /** 当前选中的节点 tag */
  now: string;
  /** urltest(auto) 组当前选中的真实节点 tag。三端始终发出此字段，空字符串表示未知/暂未产出。 */
  autoNow: string;
};

export interface ConfigFetchResult {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

export interface VerificationData {
  /** Compile-time + KV-override known domain SHA256 list (approves broader subtrees via suffix). */
  knownSha256List: string[];
  /** Remote-fetched verified domain SHA256 list (TTL-cached in JS, pushed here for bg worker reuse). */
  verifiedSha256List: string[];
}

export interface BackgroundRefreshOptions {
  /** Accelerator base URL from the build-time constant; '' = not configured. */
  accelerateUrl: string;
  /** Dev-only probe: force the primary fetch to fail so the accelerate fallback path runs. */
  testPrimaryUrlUnavailable: boolean;
}

export interface ConfigRefreshResult {
  status: 'success' | 'failed' | 'skipped';
  content?: string;
  profileUpload: number;
  profileDownload: number;
  profileTotal: number;
  profileExpire: number;
  error?: string;
  timestamp: string;
  durationMs: number;
  profileUserinfoHeader?: string;
  method?: 'primary' | 'fallback';
  actualUrl?: string;  // 加速回落时为构造后的完整 URL
}

// 原生层日志事件
// 由 Kotlin / Swift 层在关键生命周期点发出（初始化、VPN 启停、权限请求、
// 后台刷新等）。与 `onLog` 分开——`onLog` 是 sing-box 内核（libbox）的
// 输出，`onNativeLog` 是原生模块自己的代码路径。
export type NativeLogEventPayload = {
  /** 原生层日志级别 —— 对齐 iOS os_log / Android Log 的级别语义 */
  level: 'info' | 'warn' | 'error';
  /** 短标签，用于区分子系统（e.g. "Module", "BoxService", "Tunnel"） */
  tag: string;
  /** 正文 */
  message: string;
};

export type ExpoOneBoxModuleEvents = {
  onStatusChange: (params: StatusChangeEventPayload) => void;
  onError: (params: ErrorEventPayload) => void;
  onLog: (params: LogEventPayload) => void;
  onTrafficUpdate: (params: TrafficUpdateEventPayload) => void;
  onGroupUpdate: (params: GroupUpdateEventPayload) => void;
  onNativeLog: (params: NativeLogEventPayload) => void;
};
