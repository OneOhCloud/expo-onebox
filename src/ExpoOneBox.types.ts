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

export type OnLoadEventPayload = {
  url: string;
};

export type ExpoOneBoxModuleEvents = {
  onStatusChange: (params: StatusChangeEventPayload) => void;
  onError: (params: ErrorEventPayload) => void;
  onLog: (params: LogEventPayload) => void;
  onTrafficUpdate: (params: TrafficUpdateEventPayload) => void;
  onChange: (params: ChangeEventPayload) => void;
};

export type ChangeEventPayload = {
  value: string;
};

export type ExpoOneBoxViewProps = {
  url: string;
  onLoad: (event: { nativeEvent: OnLoadEventPayload }) => void;
  style?: StyleProp<ViewStyle>;
};
