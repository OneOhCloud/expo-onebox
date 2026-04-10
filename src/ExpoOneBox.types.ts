import type { StyleProp, ViewStyle } from 'react-native';


// VPN 连接状态
export type VpnStatus = 'stopped' | 'connecting' | 'connected' | 'disconnecting' | 'unknown';

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
  /** 上行速度（格式化显示） */
  uplinkDisplay: string;
  /** 下行速度（格式化显示） */
  downlinkDisplay: string;
  /** 累计上行（格式化显示） */
  uplinkTotalDisplay: string;
  /** 累计下行（格式化显示） */
  downlinkTotalDisplay: string;
  /** 内存使用 bytes */
  memory: number;
  /** 内存使用（格式化显示） */
  memoryDisplay: string;
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
};

export type OnLoadEventPayload = {
  url: string;
};

export interface SubscriptionFetchResult {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

export interface VerificationData {
  knownSha256: string;
  verifiedSha256List: string[];
}

export interface ConfigRefreshResult {
  status: 'success' | 'failed' | 'skipped';
  content?: string;
  subscriptionUpload: number;
  subscriptionDownload: number;
  subscriptionTotal: number;
  subscriptionExpire: number;
  error?: string;
  timestamp: string;
  durationMs: number;
  subscriptionUserinfoHeader?: string;  // 原始 subscription-userinfo 响应头
  method?: 'primary' | 'accelerated' | 'fallback' | 'test_mode';  // 实际使用的加载方式
}

export type ExpoOneBoxModuleEvents = {
  onStatusChange: (params: StatusChangeEventPayload) => void;
  onError: (params: ErrorEventPayload) => void;
  onLog: (params: LogEventPayload) => void;
  onTrafficUpdate: (params: TrafficUpdateEventPayload) => void;
  onGroupUpdate: (params: GroupUpdateEventPayload) => void;
  onChange: (params: ChangeEventPayload) => void;
  onConfigRefreshResult: (params: ConfigRefreshResult) => void;
};

export type ChangeEventPayload = {
  value: string;
};

export type ExpoOneBoxViewProps = {
  url: string;
  onLoad: (event: { nativeEvent: OnLoadEventPayload }) => void;
  style?: StyleProp<ViewStyle>;
};
