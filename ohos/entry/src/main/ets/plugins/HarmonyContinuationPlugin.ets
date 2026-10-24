import {
  AbilityAware,
  AbilityPluginBinding,
  Any,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import common from '@ohos.app.ability.common';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { BusinessError } from '@kit.BasicServicesKit';
import hilog from '@ohos.hilog';

const TAG: string = 'NexHubContinuation';
const CHANNEL: string = 'nexhub/continuation';

/**
 * 应用级原生通道：跨设备接续（流转）。
 *
 * 方向说明：
 * - 源端：系统 `EntryAbility.onContinue` 调 [getContinuationState]，本插件反向
 *   invoke Dart 的 `getContinuationState` 拉取当前播放/阅读快照（JSON 字符串）；
 *   无持有者时 Dart 返回 null，EntryAbility 据此拒绝本次接续。
 * - 接收端：EntryAbility 从 want.parameters 取出快照后调 [setPendingContinuation]。
 *   热启动（onNewWant）时 Dart 已挂载，直接推送 `onContinuationRestore`；
 *   冷启动不推送（引擎 channel buffer 会在 Dart 注册 handler 的瞬间回放，
 *   此时 Navigator 尚未挂载），由 Dart 首帧后主动 `getPendingContinuation` 拉取。
 * - Dart 通过 `setContinuationActive` 控制本机是否在对端显示「可接续」，
 *   仅在播放器 / 阅读器持有内容时激活，避免无内容时发起接续失败。
 */
export default class HarmonyContinuationPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private uiContext: common.UIAbilityContext | null = null;
  private pendingContinuation: string | null = null;

  getUniqueClassName(): string {
    return 'HarmonyContinuationPlugin';
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
      case 'getPendingContinuation':
        result.success(this.takePending());
        return;
      case 'setContinuationActive': {
        const raw: Any = call.argument('active');
        let active: boolean = false;
        if (typeof raw === 'boolean') {
          active = raw as boolean;
        }
        this.setMissionContinueState(active);
        result.success(true);
        return;
      }
      default:
        result.notImplemented();
    }
  }

  /** 取走暂存快照（仅返回一次，避免重复跳转）。 */
  public takePending(): string | null {
    const data: string | null = this.pendingContinuation;
    this.pendingContinuation = null;
    return data;
  }

  public hasPending(): boolean {
    return this.pendingContinuation != null && this.pendingContinuation.length > 0;
  }

  /**
   * 对端收到接续数据：暂存，并按需通知 Dart（仅热启动）。
   */
  public setPendingContinuation(data: string, notify: boolean): void {
    this.pendingContinuation = data;
    if (notify) {
      this.channel?.invokeMethod('onContinuationRestore', null);
    }
  }

  /**
   * 源端：系统发起接续时向 Dart 拉取当前内容快照。
   *
   * onContinue 有系统时限，1.5s 超时兜底返回 null（拒绝接续），避免流程卡死。
   * 引擎 / Dart 尚未挂载时立即返回 null。
   */
  public getContinuationState(): Promise<string | null> {
    const channel: MethodChannel | null = this.channel;
    if (channel == null) {
      return Promise.resolve(null);
    }
    return new Promise<string | null>((resolve: (value: string | null) => void) => {
      const timer: number = setTimeout(() => resolve(null), 1500);
      const callback: MethodResult = {
        success: (value: Any) => {
          clearTimeout(timer);
          resolve(typeof value === 'string' ? (value as string) : null);
        },
        error: (_code: string, _message: string, _details: Any) => {
          clearTimeout(timer);
          resolve(null);
        },
        notImplemented: () => {
          clearTimeout(timer);
          resolve(null);
        }
      };
      channel.invokeMethod('getContinuationState', null, callback);
    });
  }

  private setMissionContinueState(active: boolean): void {
    const context: common.UIAbilityContext | null = this.uiContext;
    if (context == null) {
      hilog.warn(0x0000, TAG, 'setMissionContinueState skipped: no context');
      return;
    }
    const state: AbilityConstant.ContinueState = active
      ? AbilityConstant.ContinueState.ACTIVE
      : AbilityConstant.ContinueState.INACTIVE;
    context.setMissionContinueState(state).catch((err: BusinessError) => {
      hilog.error(0x0000, TAG, 'setMissionContinueState(%{public}s) failed: %{public}d %{public}s',
        `${active}`, err.code, err.message);
    });
  }
}
