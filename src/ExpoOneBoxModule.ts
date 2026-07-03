import { NativeModule, requireNativeModule } from 'expo';

import { BackgroundRefreshOptions, ConfigRefreshResult, ExpoOneBoxModuleEvents, ConfigFetchResult, VerificationData } from './ExpoOneBox.types';

declare class ExpoOneBoxModule extends NativeModule<ExpoOneBoxModuleEvents> {
  getLibBoxVersion(): string;
  start(config: string): Promise<void>;
  stop(): Promise<void>;
  checkVpnPermission(): Promise<boolean>;
  requestVpnPermission(): Promise<boolean>;
  /** 仅 Android：若 app 已豁免电池优化则返回 true。 */
  checkBatteryOptimizationExemption(): boolean;
  /** 仅 Android：弹出系统对话框请求电池优化豁免。用户关闭对话框后以最终豁免状态 resolve。 */
  requestBatteryOptimizationExemption(): Promise<boolean>;
  /** 仅 Android：故意让原生进程崩溃，用于验证 Bugsnag。 */
  crashForBugsnagTest(): boolean;
  /** 仅 Android：若旧版本在该路径下创建了文件，则修复 Expo SQLite 数据库目录。 */
  repairSQLiteDirectory(): boolean;
  getStatus(): number;
  /** 同步读取 Extension/Service 写入的最近一次启动错误。空字符串表示无错误。 */
  getStartError(): string;
  /** 返回最近一次传给 start() 的 config JSON 字符串（经原生处理后）。从未启动过则为空字符串。 */
  getStartConfig(): string;
  setCoreLogEnabled(enabled: boolean): void;
  /**
   * 在最早的原生环节（序列化成 JS 事件之前）过滤 sing-box CommandServer
   * 日志流中的条目。
   *
   * 之所以需要，是因为 config 里 sing-box 的 `log.level` 只过滤
   * stdout / observable sink——为该日志流供数的 platform writer 会无条件
   * 收到每个级别。源码指引见 `vpn-context.tsx` 中的块注释。
   *
   * 接受 sing-box 的级别名：trace / debug / info / warn / error / fatal /
   * panic。未知值会被归一为 `info`。
   */
  setCoreLogLevel(level: string): void;
  selectProxyNode(tag: string): Promise<boolean>;
  /** 对指定的 outbound tag 或 group tag（如 "ExitGateway"）触发 URLTest。 */
  triggerURLTest(tag: string): Promise<boolean>;
  getBestDns(): Promise<string>;
  /**
   * 将 sourceUri 指向的 asset 拷贝到原生工作目录并命名为 tun.db。
   * 若目标文件已存在则跳过。
   * Android: <externalFilesDir>/tun.db
   * iOS:     <AppGroup>/Library/Caches/tun.db
   * @param sourceUri 指向打包 asset 的 file:// URI（来自 expo-asset 的 localUri）。
   */
  copy2CacheDbPath(sourceUri: string): Promise<boolean>;

  /** 用 DNS 解析 + 覆盖 SNI 的 HTTPS 拉取 config URL，并可选地走加速器回落。 */
  fetchProfileConfig(
    url: string,
    userAgent: string,
  ): Promise<ConfigFetchResult>;

  /**
   * 将 JS 侧维护的域名 allowlist 推入原生后台 worker 的共享存储。由
   * iOS BGTaskScheduler / Android WorkManager 的刷新任务消费，使其无需
   * 重新拉取远端列表即可校验主机名。时间戳在原生侧记录；缓存有效期
   * 24 小时，之后回落到内置列表。
   */
  setVerificationData(data: VerificationData): Promise<void>;

  /**
   * 将 JS 侧维护的刷新选项镜像到原生后台 worker 的共享存储
   * （AppGroup UserDefaults / SharedPreferences）。worker 绝不能直接读取
   * JS 独占的数据库文件——在同一个 WAL 数据库上再挂一个 SQLite 库会以
   * SIGBUS 崩溃。
   */
  setBackgroundConfigRefreshOptions(options: BackgroundRefreshOptions): Promise<void>;

  /** 注册（或更新）原生周期性后台 config 刷新。 */
  registerBackgroundConfigRefresh(url: string, userAgent: string, intervalSeconds: number): Promise<void>;

  /** 立即执行一次 config 刷新（结果同步返回给 JS）。 */
  executeConfigRefreshNow(url: string, userAgent: string): Promise<ConfigRefreshResult>;

  // 注意：registerBackgroundConfigRefresh 没有对应的 unregister——任务是
  // 就地替换/更新的。不要再加回一个无用的 unregister 方法。

  /**
   * 返回并清空原生后台任务存储的最近一次结果。
   * 自上次读取后若无结果存储，则返回 null。
   */
  getLastConfigRefreshResult(): ConfigRefreshResult | null;

  /** 原生后台刷新任务当前是否已被调度。 */
  isBackgroundConfigRefreshRegistered(): Promise<boolean>;
}

// 该调用从 JSI 加载原生模块对象。
export default requireNativeModule<ExpoOneBoxModule>('ExpoOneBox');

// 原生方法集合，导出为类型，以便 web stub 在编译期断言自己实现了完整集合
// （见 ExpoOneBoxModule.web.ts）。
export type ExpoOneBoxModuleType = ExpoOneBoxModule;
