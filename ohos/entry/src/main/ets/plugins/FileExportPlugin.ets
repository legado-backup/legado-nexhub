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
import { fileIo, picker } from '@kit.CoreFileKit';

const TAG: string = 'NexHubFileExport';
const CHANNEL: string = 'nexhub/file_export';

/**
 * 应用级「导出到用户可见位置」通道（鸿蒙专用）。
 *
 * 背景：鸿蒙没有可用的目录选择（file_picker 缺陷 U2），导出曾降级为
 * 「写沙箱 + share_plus 系统分享」。分享链路依赖上游 systemShare 适配，
 * 真机不可靠；改为 DocumentViewPicker 系统「另存为」对话框：由用户选择
 * 目标位置，系统预创建文件并返回 URI，应用把字节写进去。用户取消时返回
 * 空串（Dart 侧按 null 处理）。
 */
export default class FileExportPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private uiContext: common.UIAbilityContext | null = null;

  getUniqueClassName(): string {
    return 'FileExportPlugin';
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
    if (call.method === 'saveFile') {
      this.saveFile(call, result);
      return;
    }
    result.notImplemented();
  }

  private saveFile(call: MethodCall, result: MethodResult): void {
    // StandardMessageCodec：Dart Uint8List → Uint8Array（部分版本为
    // ArrayBuffer，两种都收），与 MediaStorePlugin 保持一致。
    const bytesArg: Object | null = call.argument('bytes');
    const fileName: string = call.argument('fileName');
    const context: common.UIAbilityContext | null = this.uiContext;
    if (bytesArg == null || fileName == null || fileName.length === 0 || context == null) {
      hilog.error(0x0000, TAG, 'saveFile bad_args (bytes/fileName/context null)');
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

    try {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [fileName];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      documentPicker.save(options).then((uris: Array<string>) => {
        if (uris == null || uris.length === 0 || uris[0] == null || uris[0].length === 0) {
          hilog.info(0x0000, TAG, 'saveFile canceled by user');
          result.success('');
          return;
        }
        try {
          // 系统 save 已预创建目标文件，返回的 URI 可直接读写。
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
          hilog.info(0x0000, TAG, 'saveFile wrote %{public}d bytes', bytes.byteLength);
          result.success(uris[0]);
        } catch (e) {
          const err = e as BusinessError;
          hilog.error(0x0000, TAG, 'saveFile write failed: %{public}d %{public}s', err.code, err.message);
          result.error('save_failed', `${err.code} ${err.message}`, '');
        }
      }).catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, 'saveFile picker rejected: %{public}d %{public}s', e.code, e.message);
        result.error('save_failed', `${e.code} ${e.message}`, '');
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'saveFile setup failed: %{public}s', err.message);
      result.error('save_failed', `${err.message}`, '');
    }
  }
}
