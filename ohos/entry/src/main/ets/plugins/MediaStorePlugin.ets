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
import hilog from '@ohos.hilog';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

const TAG: string = 'NexHubMediaStore';

/**
 * 与 Android 侧同名通道（nexhub/media_store）：保存图片到系统相册。
 *
 * 鸿蒙不用 MediaStore：photoAccessHelper.showAssetsCreationDialog（API 12+）
 * 弹系统「保存到相册」确认框，**免任何存储权限**；用户拒绝时返回空数组，
 * 本插件回传空字符串，Dart 侧据此提示未保存。
 *
 * 流程：Dart 传图片字节 → 写沙箱缓存文件 → fileUri 转 URI 交系统确认框 →
 * 用户确认后系统**创建相册资产并授予写权限**（返回目标 URI）→ 应用把
 * 图片内容写进该 URI → 清理沙箱临时文件。沙箱路径入参是官方支持的
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
    // StandardMessageCodec：Dart Uint8List → Uint8Array（个别版本为
    // ArrayBuffer，两种都收）；显式类型声明满足 ArkTS 严格模式。
    const bytesArg: Object | null = call.argument('bytes');
    const fileName: string = call.argument('fileName');
    const context: common.UIAbilityContext | null = this.uiContext;
    if (bytesArg == null || fileName == null || fileName.length === 0 || context == null) {
      hilog.error(0x0000, TAG, 'saveImage bad_args (bytes/fileName/context null)');
      result.error('bad_args', 'bytes/fileName is empty', '');
      return;
    }
    let bytes: Uint8Array;
    if (bytesArg instanceof Uint8Array) {
      bytes = bytesArg;
    } else if (bytesArg instanceof ArrayBuffer) {
      bytes = new Uint8Array(bytesArg);
    } else {
      result.error('bad_args', 'bytes type unsupported', '');
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
      fileIo.writeSync(
        f.fd,
        bytes.buffer as ArrayBuffer,
        { offset: bytes.byteOffset, length: bytes.byteLength }
      );
      fileIo.closeSync(f);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'saveImage write failed: %{public}d %{public}s', err.code, err.message);
      result.error('save_failed', `${err.message}`, '');
      return;
    }
    try {
      const srcUri: string = fileUri.getUriFromPath(dst);
      const helper: photoAccessHelper.PhotoAccessHelper =
        photoAccessHelper.getPhotoAccessHelper(context);
      const config: photoAccessHelper.PhotoCreationConfig = {
        photoType: photoAccessHelper.PhotoType.IMAGE,
        title: title,
        fileNameExtension: ext
      };
      helper.showAssetsCreationDialog([srcUri], [config]).then((uris: Array<string>) => {
        // 关键语义：确认框只是**创建相册资产并授予写权限**，图片内容必须由
        // 应用自行写进返回的 URI（不写就是空资产，图库不可见）。
        if (uris.length === 0) {
          this.cleanupTemp(dst);
          hilog.info(0x0000, TAG, 'saveImage dialog declined by user');
          result.success('');
          return;
        }
        try {
          const target = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE);
          try {
            fileIo.writeSync(
              target.fd,
              bytes.buffer as ArrayBuffer,
              { offset: bytes.byteOffset, length: bytes.byteLength }
            );
          } finally {
            fileIo.closeSync(target);
          }
          this.cleanupTemp(dst);
          hilog.info(0x0000, TAG, 'saveImage wrote %{public}d bytes to asset', bytes.byteLength);
          result.success('系统相册');
        } catch (e) {
          this.cleanupTemp(dst);
          const err = e as BusinessError;
          hilog.error(0x0000, TAG, 'saveImage asset write failed: %{public}d %{public}s', err.code, err.message);
          result.error('save_failed', `${err.code} ${err.message}`, '');
        }
      }).catch((e: BusinessError) => {
        this.cleanupTemp(dst);
        hilog.error(0x0000, TAG, 'saveImage dialog rejected: %{public}d %{public}s', e.code, e.message);
        result.error('save_failed', `${e.code} ${e.message}`, '');
      });
    } catch (e) {
      this.cleanupTemp(dst);
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'saveImage dialog setup failed: %{public}s', err.message);
      result.error('save_failed', `${err.message}`, '');
    }
  }

  private cleanupTemp(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (_) {
      // 清理失败无碍：cacheDir 由系统回收。
    }
  }
}
