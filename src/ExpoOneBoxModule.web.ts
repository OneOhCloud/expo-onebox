import { NativeModule, registerWebModule } from 'expo';

import { ExpoOneBoxModuleEvents, VPN_STATUS } from './ExpoOneBox.types';

class ExpoOneBoxModule extends NativeModule<ExpoOneBoxModuleEvents> {
  PI = Math.PI;
  async setValueAsync(value: string): Promise<void> {
    this.emit('onChange', { value });
  }
  hello() {
    return 'Hello world! 👋';
  } getLibBoxVersion(): string {
    return '1.0.0-web-mock';
  }

  async start(config: string): Promise<void> {
    console.log('[Web Mock] VPN start called with config:', config);
    await new Promise(resolve => setTimeout(resolve, 500));
    this.emit('onStatusChange', {
      status: VPN_STATUS.STARTED,
      statusName: 'connected',
      message: 'VPN connected (mock)'
    });
    // 模拟流量更新
    this.emit('onTrafficUpdate', {
      uplink: 1024,
      downlink: 2048,
      uplinkTotal: 10240,
      downlinkTotal: 20480,
      uplinkDisplay: '1.0 KB/s',
      downlinkDisplay: '2.0 KB/s',
      uplinkTotalDisplay: '10.0 KB',
      downlinkTotalDisplay: '20.0 KB',
      memory: 8388608,
      memoryDisplay: '8.0 MB',
      goroutines: 42,
      connectionsIn: 3,
      connectionsOut: 5,
    });
  }

  async stop(): Promise<void> {
    console.log('[Web Mock] VPN stop called');
    await new Promise(resolve => setTimeout(resolve, 300));
    this.emit('onStatusChange', {
      status: VPN_STATUS.STOPPED,
      statusName: 'stopped',
      message: 'VPN stopped (mock)'
    });
  }

  async checkVpnPermission(): Promise<boolean> {
    return true;
  }

  async requestVpnPermission(): Promise<boolean> {
    return true;
  }

  getStatus(): number {
    return VPN_STATUS.STOPPED;
  }
}

export default registerWebModule(ExpoOneBoxModule, 'ExpoOneBoxModule');
