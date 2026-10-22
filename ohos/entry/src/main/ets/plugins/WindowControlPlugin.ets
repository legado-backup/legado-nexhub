import {
  AbilityAware,
  AbilityPluginBinding,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import common from '@ohos.app.ability.common';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import hilog from '@ohos.hilog';

const TAG: string = 'NexHubWindow';
const CHANNEL: string = 'nexhub/window_control';

/**
 * 应用级原生窗口通道（鸿蒙 PC / 2in1）。
 *
 * 传统桌面靠 window_manager 做阅读器真窗口全屏；鸿蒙没有该插件，这里用
 * 系统窗口 API 提供最小能力集：
 * - isFullScreen：WindowStatusType == FULL_SCREEN；
 * - setFullScreen：maximize(ENTER_IMMERSIVE) / restore。
 *
 * 不提供置顶 / 无边框 / 尺寸设置：本期不需要，且系统 API 不完整。
 */
export default class WindowControlPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private uiContext: common.UIAbilityContext | null = null;

  getUniqueClassName(): string {
    return 'WindowControlPlugin';
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

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.uiContext = binding.getAbility().context as common.UIAbilityContext;
  }

  onDetachedFromAbility(): void {
    this.uiContext = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'isFullScreen':
        this.isFullScreen(result);
        return;
      case 'setFullScreen':
        this.setFullScreen(call, result);
        return;
      default:
        result.notImplemented();
    }
  }

  private async isFullScreen(result: MethodResult): Promise<void> {
    const context: common.UIAbilityContext | null = this.uiContext;
    if (context == null) {
      hilog.error(0x0000, TAG, 'isFullScreen no ui context');
      result.error('no_context', 'UIAbility context is null', '');
      return;
    }
    try {
      const win: window.Window = await window.getLastWindow(context);
      result.success(win.getWindowStatus() === window.WindowStatusType.FULL_SCREEN);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'isFullScreen failed: %{public}d %{public}s',
        err.code, err.message);
      result.error('window_status_failed', `${err.code} ${err.message}`, '');
    }
  }

  private async setFullScreen(call: MethodCall, result: MethodResult): Promise<void> {
    const context: common.UIAbilityContext | null = this.uiContext;
    if (context == null) {
      hilog.error(0x0000, TAG, 'setFullScreen no ui context');
      result.error('no_context', 'UIAbility context is null', '');
      return;
    }
    const enabled: boolean = call.argument('enabled');
    try {
      const win: window.Window = await window.getLastWindow(context);
      if (enabled) {
        await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
      } else {
        await win.restore();
      }
      hilog.info(0x0000, TAG, 'setFullScreen(%{public}s) ok', `${enabled}`);
      result.success(null);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'setFullScreen(%{public}s) failed: %{public}d %{public}s',
        `${enabled}`, err.code, err.message);
      result.error('window_fullscreen_failed', `${err.code} ${err.message}`, '');
    }
  }
}
