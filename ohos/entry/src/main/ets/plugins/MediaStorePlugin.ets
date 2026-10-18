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
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

/**
 * 与 Android 侧同名通道（nexhub/media_store）：保存图片到系统相册。
 *
 * 鸿蒙不用 MediaStore：photoAccessHelper.showAssetsCreationDialog（API 12+）
 * 弹系统「保存到相册」确认框，**免任何存储权限**；用户拒绝时返回空数组，
 * 本插件回传空字符串，Dart 侧据此提示未保存。
 *
 * 流程：Dart 传图片字节 → 写沙箱缓存文件 → fileUri 转 URI 交系统确认框 →
 * 系统把图片复制进相册 → 清理沙箱临时文件。沙箱路径入参是官方支持的
 * 用法（仅保存预览图不显示，不影响落盘结果）。
 */
export default class MediaStorePlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private uiContext: common.UIAbilityContext | null = null;

  getUniqueClassName(): string {
    return 'MediaStorePlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'nexhub/media_store');
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
    if (call.method === 'saveImage') {
      this.saveImage(call, result);
      return;
    }
    // sdkInt 等方法为 Android 专属，鸿蒙按未实现处理（Dart 侧有降级）。
    result.notImplemented();
  }

  private saveImage(call: MethodCall, result: MethodResult): void {
    const bytes: Uint8Array = call.argument('bytes');
    const fileName: string = call.argument('fileName');
    const context: common.UIAbilityContext | null = this.uiContext;
    if (bytes == null || fileName == null || bytes.length === 0 || context == null) {
      result.error('bad_args', 'bytes/fileName is empty', '');
      return;
    }
    const dot: number = fileName.lastIndexOf('.');
    const ext: string = dot >= 0 ? fileName.substring(dot + 1) : 'jpg';
    const title: string = dot > 0 ? fileName.substring(0, dot) : fileName;
    const dst: string = `${context.cacheDir}/${fileName}`;
    try {
      const f = fileIo.openSync(
        dst,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      fileIo.writeSync(f.fd, bytes.buffer);
      fileIo.closeSync(f);
    } catch (e) {
      result.error('save_failed', `${(e as BusinessError).message}`, '');
      return;
    }
    const srcUri: string = fileUri.getUriFromPath(dst);
    const helper: photoAccessHelper.PhotoAccessHelper =
      photoAccessHelper.getPhotoAccessHelper(context);
    const config: photoAccessHelper.PhotoCreationConfig = {
      photoType: photoAccessHelper.PhotoType.IMAGE,
      title: title,
      fileNameExtension: ext
    };
    helper.showAssetsCreationDialog([srcUri], [config]).then((uris: Array<string>) => {
      this.cleanupTemp(dst);
      // 用户确认保存 → 回传展示位置；拒绝 → 空数组 → 空字符串。
      result.success(uris.length > 0 ? '系统相册' : '');
    }).catch((e: BusinessError) => {
      this.cleanupTemp(dst);
      result.error('save_failed', `${e.code} ${e.message}`, '');
    });
  }

  private cleanupTemp(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (_) {
      // 清理失败无碍：cacheDir 由系统回收。
    }
  }
}
