
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import ClipboardPlugin from '../plugins/ClipboardPlugin';
import FileExportPlugin from '../plugins/FileExportPlugin';
import MediaStorePlugin from '../plugins/MediaStorePlugin';
import OhosStoragePlugin from '../plugins/OhosStoragePlugin';
import OhosTtsPlugin from '../plugins/OhosTtsPlugin';
import VolumeKeyPlugin from '../plugins/VolumeKeyPlugin';
import WallpaperColorPlugin from '../plugins/WallpaperColorPlugin';

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
    // 应用级原生通道：导出文件到用户可见位置（见 FileExportPlugin 注释）。
    flutterEngine.getPlugins()?.add(new FileExportPlugin())
    // 应用级原生通道：系统下载目录授权与读写（见 OhosStoragePlugin 注释）。
    flutterEngine.getPlugins()?.add(new OhosStoragePlugin())
    // 应用级原生通道：阅读器音量键翻页拦截（见 VolumeKeyPlugin 注释）。
    flutterEngine.getPlugins()?.add(new VolumeKeyPlugin())
    // 应用级原生通道：壁纸主色（莫奈 seed，见 WallpaperColorPlugin 注释）。
    flutterEngine.getPlugins()?.add(new WallpaperColorPlugin())
  }
}
