import {
  EventChannel,
  EventSink,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  StreamHandler
} from '@ohos/flutter_ohos';
import { inputConsumer, KeyCode, KeyEvent } from '@kit.InputKit';
import { BusinessError } from '@kit.BasicServicesKit';
import hilog from '@ohos.hilog';

const TAG: string = 'NexHubVolumeKey';
const CONTROL_CHANNEL: string = 'nexhub/volume_control';
const EVENT_CHANNEL: string = 'nexhub/volume_events';
// KeyPressedConfig.action = 1 表示只订阅按下事件（api 21 起 2 = 按下+抬起）。
const ACTION_PRESS_ONLY: number = 1;

/**
 * 应用级音量键通道（鸿蒙专用），与 Android MainActivity 的同名通道对齐：
 * - nexhub/volume_control：enableInterception / disableInterception；
 * - nexhub/volume_events：拦截期间回传 volume_up / volume_down。
 *
 * 鸿蒙侧用 inputConsumer.on('keyPressed')：应用处于前台焦点窗口时订阅生效，
 * 订阅成功后系统默认音量调节被拦截，因此阅读器可以在不弹音量条的情况下翻页。
 * 事件通道未订阅（sink 为空）时不注册拦截，避免按键被吞且无人处理。
 * 不同按键必须使用不同回调，否则订阅不生效（SDK 约束）。
 */
export default class VolumeKeyPlugin implements FlutterPlugin, MethodCallHandler, StreamHandler {
  private controlChannel: MethodChannel | null = null;
  private eventChannel: EventChannel | null = null;
  private eventSink: EventSink | null = null;
  private interceptionEnabled: boolean = false;
  private listening: boolean = false;

  private readonly volumeUpCallback = (_event: KeyEvent): void => {
    this.emit('volume_up');
  };

  private readonly volumeDownCallback = (_event: KeyEvent): void => {
    this.emit('volume_down');
  };

  getUniqueClassName(): string {
    return 'VolumeKeyPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.controlChannel = new MethodChannel(binding.getBinaryMessenger(), CONTROL_CHANNEL);
    this.controlChannel.setMethodCallHandler(this);
    this.eventChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CHANNEL);
    this.eventChannel.setStreamHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.stopInterception();
    if (this.controlChannel !== null) {
      this.controlChannel.setMethodCallHandler(null);
      this.controlChannel = null;
    }
    if (this.eventChannel !== null) {
      this.eventChannel.setStreamHandler(null);
      this.eventChannel = null;
    }
    this.eventSink = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'enableInterception':
        this.enableInterception(result);
        break;
      case 'disableInterception':
        this.interceptionEnabled = false;
        this.stopInterception();
        result.success(null);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  onListen(args: Object, events: EventSink): void {
    this.eventSink = events;
    // start() 保证先订阅后 enable；这里兜底 enable 先于订阅到达的场景。
    if (this.interceptionEnabled && !this.listening) {
      try {
        this.startInterception();
      } catch (e) {
        this.reportError(events, e);
      }
    }
  }

  onCancel(args: Object): void {
    // Dart 侧 stop() 先取消订阅再 disable；取消订阅时同步停止拦截，
    // 防止 sink 已失效而按键仍被系统拦截。
    this.eventSink = null;
    this.stopInterception();
  }

  private enableInterception(result: MethodResult): void {
    this.interceptionEnabled = true;
    if (this.eventSink === null) {
      // 事件通道尚未订阅：不注册拦截，等 onListen 再启动（按键走系统默认）。
      result.success(null);
      return;
    }
    try {
      this.startInterception();
      result.success(null);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'enableInterception failed: %{public}d %{public}s', err.code, err.message);
      result.error('enable_failed', `${err.code} ${err.message}`, '');
    }
  }

  private startInterception(): void {
    if (this.listening || this.eventSink === null) {
      return;
    }
    const upConfig: inputConsumer.KeyPressedConfig = {
      key: KeyCode.KEYCODE_VOLUME_UP,
      action: ACTION_PRESS_ONLY,
      isRepeat: true
    };
    const downConfig: inputConsumer.KeyPressedConfig = {
      key: KeyCode.KEYCODE_VOLUME_DOWN,
      action: ACTION_PRESS_ONLY,
      isRepeat: true
    };
    inputConsumer.on('keyPressed', upConfig, this.volumeUpCallback);
    try {
      inputConsumer.on('keyPressed', downConfig, this.volumeDownCallback);
    } catch (e) {
      inputConsumer.off('keyPressed', this.volumeUpCallback);
      const err = e as BusinessError;
      throw new Error(`${err.code} ${err.message}`);
    }
    this.listening = true;
    hilog.info(0x0000, TAG, 'volume key interception enabled');
  }

  private stopInterception(): void {
    if (!this.listening) {
      return;
    }
    try {
      inputConsumer.off('keyPressed', this.volumeUpCallback);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'off volume_up failed: %{public}d %{public}s', err.code, err.message);
    }
    try {
      inputConsumer.off('keyPressed', this.volumeDownCallback);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'off volume_down failed: %{public}d %{public}s', err.code, err.message);
    }
    this.listening = false;
    hilog.info(0x0000, TAG, 'volume key interception disabled');
  }

  private emit(event: string): void {
    if (this.eventSink !== null) {
      this.eventSink.success(event);
    }
  }

  private reportError(events: EventSink, e: Object): void {
    const err = e as BusinessError;
    hilog.error(0x0000, TAG, 'subscribe failed: %{public}d %{public}s', err.code, err.message);
    events.error('subscribe_failed', `${err.code} ${err.message}`, '');
  }
}
