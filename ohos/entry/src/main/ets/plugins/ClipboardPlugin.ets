import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import hilog from '@ohos.hilog';

const TAG: string = 'NexHubClipboard';

/**
 * 应用级原生通道 nexhub/clipboard：把图片字节写入系统剪贴板。
 *
 * `super_clipboard` 的底座 `super_native_extensions` 没有 ohos 原生实现，
 * 鸿蒙侧改由本插件完成真复制。系统剪贴板的图片记录类型是 PixelMap
 * （MIMETYPE_PIXELMAP）而非 PNG 字节，故先用 ImageKit 解码再交给
 * pasteboard.setData；setData 成功后系统剪贴板服务持有自己的副本，本地
 * 解码资源可立即释放。
 */
export default class ClipboardPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;

  getUniqueClassName(): string {
    return 'ClipboardPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'nexhub/clipboard');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'copyImage') {
      this.copyImage(call, result);
      return;
    }
    result.notImplemented();
  }

  private async copyImage(call: MethodCall, result: MethodResult): Promise<void> {
    // StandardMessageCodec：Dart Uint8List → Uint8Array（个别版本为
    // ArrayBuffer，两种都收）；显式类型声明满足 ArkTS 严格模式。
    const bytesArg: Object | null = call.argument('bytes');
    let bytes: Uint8Array;
    if (bytesArg instanceof Uint8Array) {
      bytes = bytesArg;
    } else if (bytesArg instanceof ArrayBuffer) {
      bytes = new Uint8Array(bytesArg);
    } else {
      result.error('bad_args', 'bytes is empty', '');
      return;
    }
    // 只切出本视图对应的区间，避免把底层缓冲区的无关字节一起解码。
    const buffer: ArrayBuffer =
      bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    try {
      source = image.createImageSource(buffer);
      pixelMap = await source.createPixelMap();
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pixelMap);
      await pasteboard.getSystemPasteboard().setData(data);
      hilog.info(0x0000, TAG, 'copyImage wrote %{public}d bytes', bytes.byteLength);
      result.success(true);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'copyImage failed: %{public}d %{public}s', err.code, err.message);
      result.error('copy_failed', `${err.code} ${err.message}`, '');
    } finally {
      // 释放失败不应影响本次复制结果，忽略异常。
      if (pixelMap != null) {
        try {
          await pixelMap.release();
        } catch (_) {
        }
      }
      if (source != null) {
        try {
          await source.release();
        } catch (_) {
        }
      }
    }
  }
}
