import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import hilog from '@ohos.hilog';

const TAG: string = 'NexHubDeviceForm';
const CHANNEL: string = 'nexhub/device_form';

/**
 * 应用级原生通道：暴露设备形态，供 Dart 区分鸿蒙手机与鸿蒙 PC（2in1）。
 *
 * deviceInfo.deviceType 是系统只读常量（phone / tablet / 2in1 / ...），
 * 比 UA、屏幕尺寸或窗口宽度都可靠；启动期只调用一次并缓存。
 */
export default class DeviceFormPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;

  getUniqueClassName(): string {
    return 'DeviceFormPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'getDeviceType') {
      try {
        const type: string = deviceInfo.deviceType;
        hilog.info(0x0000, TAG, 'deviceType=%{public}s', type);
        result.success(type);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(0x0000, TAG, 'getDeviceType failed: %{public}d %{public}s',
          err.code, err.message);
        result.error('DEVICE_INFO_FAILED', `${err.code} ${err.message}`, '');
      }
      return;
    }
    result.notImplemented();
  }
}
