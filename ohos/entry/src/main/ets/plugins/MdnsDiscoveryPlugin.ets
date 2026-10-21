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
import { mdns } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

const TAG: string = 'NexHubMdns';
const CHANNEL: string = 'nexhub/mdns';
const DEFAULT_SERVICE_TYPE: string = '_googlecast._tcp';
const DEFAULT_TIMEOUT_MS: number = 5000;

interface CastDeviceDto {
  serviceName: string;
  name: string;
  host: string;
  port: number;
  attributes: Map<string, string>;
}

/**
 * 投屏设备发现（Chromecast mDNS）鸿蒙桥。
 *
 * cast 包的设备发现依赖 bonsoir，后者没有鸿蒙平台实现，导致投屏在
 * 鸿蒙上不可用。设备发现改走系统 `@ohos.net.mdns`：
 * - discover：按 serviceType 搜索，resolve 出 host/port/TXT 后回传；
 * - 结果结构与 bonsoir 解析结果对齐（serviceName / 友好名 / host / port / 属性）。
 *
 * 会话建立与媒体控制仍是 cast 包的纯 Dart 实现（TLS 连接 8009 端口），
 * 不经本插件。搜索在 timeoutMs 后自行停止并一次性回传，期间重复调用
 * 会先结束上一次搜索。
 */
export default class MdnsDiscoveryPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private uiContext: common.UIAbilityContext | null = null;
  private service: mdns.DiscoveryService | null = null;
  private pendingResult: MethodResult | null = null;
  private found: Map<string, CastDeviceDto> = new Map<string, CastDeviceDto>();
  private timerId: number = -1;
  private generation: number = 0;
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

  getUniqueClassName(): string {
    return 'MdnsDiscoveryPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.finish();
    if (this.channel !== null) {
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
    if (call.method === 'discover') {
      this.discover(call, result);
      return;
    }
    result.notImplemented();
  }

  private discover(call: MethodCall, result: MethodResult): void {
    const context: common.UIAbilityContext | null = this.uiContext;
    if (context === null) {
      result.error('no_context', 'UIAbility context is null', '');
      return;
    }
    const serviceType: string = call.argument('serviceType') ?? DEFAULT_SERVICE_TYPE;
    const timeoutMs: number = call.argument('timeoutMs') ?? DEFAULT_TIMEOUT_MS;

    // 重复调用：结束上一轮（结果照常回传），再开新一轮。
    this.finish();
    this.pendingResult = result;
    this.found = new Map<string, CastDeviceDto>();
    this.generation++;
    const generation: number = this.generation;

    try {
      const service: mdns.DiscoveryService = mdns.createDiscoveryService(context, serviceType);
      this.service = service;
      service.on('serviceFound', (info: mdns.LocalServiceInfo) => {
        this.resolveService(context, info, generation);
      });
      service.startSearchingMDNS();
      this.timerId = setTimeout(() => {
        this.finish();
      }, timeoutMs);
      hilog.info(0x0000, TAG, 'discover start: %{public}s timeout=%{public}d', serviceType, timeoutMs);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'discover setup failed: %{public}d %{public}s', err.code, err.message);
      this.failWithError(err);
    }
  }

  private resolveService(context: common.UIAbilityContext, info: mdns.LocalServiceInfo, generation: number): void {
    mdns.resolveLocalService(context, info).then((resolved: mdns.LocalServiceInfo) => {
      if (generation !== this.generation) {
        return;
      }
      this.addDevice(resolved);
    }).catch((e: BusinessError) => {
      // 单个服务解析失败（常见为 2204006 超时）不影响整轮发现。
      hilog.warn(0x0000, TAG, 'resolve failed: %{public}d %{public}s', e.code, e.message);
    });
  }

  private addDevice(info: mdns.LocalServiceInfo): void {
    const serviceName: string = info.serviceName ?? '';
    if (serviceName.length === 0 || this.found.has(serviceName)) {
      return;
    }
    const host: string = info.host?.address ?? '';
    const port: number = info.port ?? 0;
    if (host.length === 0 || port <= 0) {
      return;
    }
    const attributes: Map<string, string> = new Map<string, string>();
    const rawAttributes: Array<mdns.ServiceAttribute> | undefined = info.serviceAttribute;
    if (rawAttributes !== undefined) {
      rawAttributes.forEach((attribute: mdns.ServiceAttribute) => {
        try {
          attributes.set(attribute.key, this.decoder.decodeToString(Uint8Array.from(attribute.value)));
        } catch (e) {
          attributes.set(attribute.key, '');
        }
      });
    }
    // Chromecast TXT 记录：md = 型号，fn = 友好名。
    const model: string = attributes.get('md') ?? '';
    const friendlyName: string = attributes.get('fn') ?? '';
    let name: string = serviceName;
    if (model.length > 0 && friendlyName.length > 0) {
      name = `${model} - ${friendlyName}`;
    } else if (friendlyName.length > 0) {
      name = friendlyName;
    } else if (model.length > 0) {
      name = model;
    }
    const device: CastDeviceDto = {
      serviceName: serviceName,
      name: name,
      host: host,
      port: port,
      attributes: attributes
    };
    this.found.set(serviceName, device);
    hilog.info(0x0000, TAG, 'device found: %{public}s (%{public}s:%{public}d)', name, host, port);
  }

  /** 停止搜索并回传已发现设备（无 pending 时仅清理）。 */
  private finish(): void {
    this.generation++;
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    const service: mdns.DiscoveryService | null = this.service;
    this.service = null;
    if (service !== null) {
      try {
        service.stopSearchingMDNS();
      } catch (e) {
        // 已停止 / 未启动，忽略。
      }
      try {
        service.off('serviceFound');
      } catch (e) {
        // 监听已解除，忽略。
      }
    }
    const result: MethodResult | null = this.pendingResult;
    this.pendingResult = null;
    const devices: Array<CastDeviceDto> = new Array<CastDeviceDto>();
    this.found.forEach((device: CastDeviceDto) => {
      devices.push(device);
    });
    this.found = new Map<string, CastDeviceDto>();
    if (result !== null) {
      hilog.info(0x0000, TAG, 'discover done: %{public}d device(s)', devices.length);
      result.success(devices);
    }
  }

  private failWithError(error: BusinessError): void {
    this.generation++;
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    const service: mdns.DiscoveryService | null = this.service;
    this.service = null;
    if (service !== null) {
      try {
        service.stopSearchingMDNS();
      } catch (e) {
        // 忽略清理失败。
      }
    }
    const result: MethodResult | null = this.pendingResult;
    this.pendingResult = null;
    this.found = new Map<string, CastDeviceDto>();
    if (result !== null) {
      result.error('discover_failed', `${error.code} ${error.message}`, '');
    }
  }
}
