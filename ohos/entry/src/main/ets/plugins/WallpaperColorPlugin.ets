import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { BusinessError, wallpaper } from '@kit.BasicServicesKit';
import hilog from '@ohos.hilog';

const TAG: string = 'NexHubWallpaperColor';

/**
 * 应用级原生通道 nexhub/wallpaper_color：读取壁纸主色（Material You seed）。
 *
 * `dynamic_color` 的上游实现只有 android / linux / macos / windows，鸿蒙端
 * `DynamicColorBuilder` 恒为 null，莫奈取色因此静默回退默认主题。鸿蒙没有
 * 公开的 Material You 配色 API，但壁纸服务会把系统壁纸的提取主色缓存下来，
 * `wallpaper.getColors(WALLPAPER_SYSTEM)` 对三方应用原样返回该值（服务端
 * GetColors 无权限校验；GetColorsV9 才要求系统应用）。该接口自 API 9 起标记
 * deprecated，但仍是唯一对三方应用开放的壁纸取色入口。
 *
 * 返回 [r, g, b, a]（各 0-255）；取不到（无壁纸 / 颜色未初始化 / 异常）时
 * 回传 null，Dart 侧据此保持原有默认主题，不产生任何行为变化。
 *
 * 同时监听系统壁纸颜色变化事件，把新主色实时推给 Dart（通道反向调用），
 * 壁纸切换后无需重启即可换肤。
 */
export default class WallpaperColorPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;

  private readonly colorChangeCallback =
    (colors: wallpaper.RgbaColor[], wallpaperType: wallpaper.WallpaperType): void => {
      const rgba = toRgba(colors);
      // 诊断：动态壁纸（如「入画」）颜色可能只在推送里出现，静态 getColors 为空。
      hilog.info(0x0000, TAG, 'colorChange push: type=%{public}d -> %{public}s',
        wallpaperType, JSON.stringify(rgba));
      if (rgba === null || this.channel === null) {
        return;
      }
      this.channel.invokeMethod('onWallpaperColorChanged', rgba);
    };

  getUniqueClassName(): string {
    return 'WallpaperColorPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'nexhub/wallpaper_color');
    this.channel.setMethodCallHandler(this);
    try {
      wallpaper.on('colorChange', this.colorChangeCallback);
      hilog.info(0x0000, TAG, 'colorChange subscribed');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'colorChange subscribe failed: %{public}d %{public}s', err.code, err.message);
    }
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    try {
      wallpaper.off('colorChange', this.colorChangeCallback);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'colorChange unsubscribe failed: %{public}d %{public}s', err.code, err.message);
    }
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'getWallpaperColors') {
      this.getWallpaperColors(result);
      return;
    }
    result.notImplemented();
  }

  private async getWallpaperColors(result: MethodResult): Promise<void> {
    try {
      const colors: wallpaper.RgbaColor[] =
        await wallpaper.getColors(wallpaper.WallpaperType.WALLPAPER_SYSTEM);
      const rgba = toRgba(colors);
      // 诊断：确认启动期静态取色是否有值（首帧主题是否直接带壁纸色取决于它）。
      hilog.info(0x0000, TAG, 'getColors: %{public}d colors -> %{public}s',
        colors?.length ?? -1, JSON.stringify(rgba));
      result.success(rgba);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'getColors failed: %{public}d %{public}s', err.code, err.message);
      result.success(null);
    }
  }
}

function toRgba(colors: wallpaper.RgbaColor[] | null | undefined): number[] | null {
  if (colors === null || colors === undefined || colors.length === 0) {
    return null;
  }
  const main: wallpaper.RgbaColor = colors[0];
  if (main.alpha <= 0) {
    return null;
  }
  return [main.red, main.green, main.blue, main.alpha];
}
