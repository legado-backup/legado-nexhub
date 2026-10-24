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
import Want from '@ohos.app.ability.Want';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import hilog from '@ohos.hilog';

const TAG: string = 'NexHubBackgroundTask';
const CHANNEL: string = 'nexhub/background_task';

/**
 * 应用级原生通道：后台长任务（dataTransfer）。
 *
 * 下载队列非空时 Dart 调 `start`，队列清空后调 `stop`；系统在此窗口内不
 * 冻结进程，下载得以在切后台后继续。
 * 需要 module.json5 声明 `backgroundModes: ["dataTransfer"]` 与
 * `ohos.permission.KEEP_BACKGROUND_RUNNING`。
 *
 * start/stop 请求用 Promise 链排队，只按最终期望状态执行实际操作，
 * 消除「快速开始-停止」时的竞态。
 */
export default class BackgroundTaskPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private uiContext: common.UIAbilityContext | null = null;
  private running: boolean = false;
  private wanted: boolean = false;
  private queue: Promise<void> = Promise.resolve();

  getUniqueClassName(): string {
    return 'BackgroundTaskPlugin';
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
      case 'start':
        this.enqueue(true);
        result.success(true);
        return;
      case 'stop':
        this.enqueue(false);
        result.success(true);
        return;
      default:
        result.notImplemented();
    }
  }

  private enqueue(wanted: boolean): void {
    this.wanted = wanted;
    this.queue = this.queue.then(async (): Promise<void> => {
      if (this.wanted) {
        if (this.running) return;
        await this.startTask();
      } else {
        if (!this.running) return;
        await this.stopTask();
      }
    });
  }

  private async startTask(): Promise<void> {
    const context: common.UIAbilityContext | null = this.uiContext;
    if (context == null) {
      hilog.warn(0x0000, TAG, 'start skipped: no ability context');
      return;
    }
    try {
      const want: Want = {
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        context, ['dataTransfer'], agent);
      this.running = true;
      hilog.info(0x0000, TAG, 'background task started (dataTransfer)');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'start failed: %{public}d %{public}s',
        err.code, err.message);
    }
  }

  private async stopTask(): Promise<void> {
    const context: common.UIAbilityContext | null = this.uiContext;
    if (context == null) {
      this.running = false;
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      this.running = false;
      hilog.info(0x0000, TAG, 'background task stopped');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'stop failed: %{public}d %{public}s',
        err.code, err.message);
    }
  }
}
