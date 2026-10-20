
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import ClipboardPlugin from '../plugins/ClipboardPlugin';
import MediaStorePlugin from '../plugins/MediaStorePlugin';
import OhosTtsPlugin from '../plugins/OhosTtsPlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // 应用级原生通道：保存图片到系统相册（见 MediaStorePlugin 注释）。
    flutterEngine.getPlugins()?.add(new MediaStorePlugin())
    // 应用级原生通道：离线朗读（CoreSpeechKit，见 OhosTtsPlugin 注释）。
    flutterEngine.getPlugins()?.add(new OhosTtsPlugin())
    // 应用级原生通道：图片写入系统剪贴板（见 ClipboardPlugin 注释）。
    flutterEngine.getPlugins()?.add(new ClipboardPlugin())
  }
}
