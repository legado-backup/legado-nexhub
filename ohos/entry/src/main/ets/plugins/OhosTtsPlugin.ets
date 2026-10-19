import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import hilog from '@ohos.hilog';
import { BusinessError } from '@kit.BasicServicesKit';
import { textToSpeech } from '@kit.CoreSpeechKit';

const TAG: string = 'NexHubTts';
const CHANNEL: string = 'nexhub/tts';

/**
 * 小说离线朗读：CoreSpeechKit（@hms.ai.textToSpeech）桥。
 *
 * 与 Dart 侧 `lib/core/novel/novel_tts_engine.dart` 的 OhosTtsEngine 对应：
 * - init：按语言创建引擎（中文默认聆小珊女声；isBackStage 允许后台朗读）
 * - speak：提交一段文本，extraParams 内携带语速 / 播放类型
 * - stop：停止合成与播放（系统引擎没有 pause，Dart 侧暂停即 stop）
 * - shutdown：释放引擎资源
 *
 * 注意：onComplete 同时会上报「合成完成（type=0）」和「播放完成（type=1）」，
 * 只有播放完成才回传 Flutter，否则会自动翻段过早。
 */
export default class OhosTtsPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private creating: Promise<textToSpeech.TextToSpeechEngine> | null = null;
  private language: string = 'zh-CN';
  private activeRequestId: string | null = null;
  private requestSeq: number = 0;
  /**
   * 操作代次：stop / shutdown 自增。用于丢弃「引擎创建期间已被用户停止」的
   * pending speak（首次创建引擎有耗时，用户可能马上点停止）。
   */
  private generation: number = 0;

  getUniqueClassName(): string {
    return 'OhosTtsPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.shutdownEngine();
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'init':
        this.init(call, result);
        return;
      case 'speak':
        this.speak(call, result);
        return;
      case 'stop':
        this.stop(result);
        return;
      case 'shutdown':
        this.shutdown(result);
        return;
      default:
        result.notImplemented();
    }
  }

  private init(call: MethodCall, result: MethodResult): void {
    const language: string = call.argument('language') ?? 'zh-CN';
    if (language !== this.language) {
      // 语种切换需要重建引擎（音色与语种绑定）。
      this.shutdownEngine();
      this.language = language;
    }
    this.ensureEngine()
      .then(() => result.success(null))
      .catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, 'init failed: %{public}d %{public}s', e.code, e.message);
        result.error('tts_init_failed', `${e.code} ${e.message}`, '');
      });
  }

  private speak(call: MethodCall, result: MethodResult): void {
    const text: string = call.argument('text') ?? '';
    const rate: number = call.argument('rate') ?? 1.0;
    if (text.length === 0) {
      result.error('bad_args', 'text is empty', '');
      return;
    }
    const generation: number = this.generation;
    this.ensureEngine()
      .then((engine: textToSpeech.TextToSpeechEngine) => {
        if (generation !== this.generation) {
          // 引擎就绪前已被 stop / shutdown，丢弃本次朗读。
          result.success(null);
          return;
        }
        const requestId: string = `nexhub${++this.requestSeq}`;
        this.activeRequestId = requestId;
        const params: textToSpeech.SpeakParams = {
          requestId: requestId,
          extraParams: {
            'queueMode': 0,
            'speed': rate,
            'volume': 1,
            'pitch': 1,
            'languageContext': this.language,
            'audioType': 'pcm',
            'soundChannel': 3,
            'playType': 1
          }
        };
        try {
          engine.speak(text, params);
          result.success(null);
        } catch (e) {
          this.activeRequestId = null;
          const err = e as BusinessError;
          hilog.error(0x0000, TAG, 'speak failed: %{public}d %{public}s', err.code, err.message);
          result.error('tts_speak_failed', `${err.code} ${err.message}`, '');
        }
      })
      .catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, 'speak init failed: %{public}d %{public}s', e.code, e.message);
        result.error('tts_init_failed', `${e.code} ${e.message}`, '');
      });
  }

  private stop(result: MethodResult): void {
    this.generation++;
    this.activeRequestId = null;
    const engine = this.engine;
    if (engine != null) {
      try {
        engine.stop();
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(0x0000, TAG, 'stop failed: %{public}d %{public}s', err.code, err.message);
      }
    }
    result.success(null);
  }

  private shutdown(result: MethodResult): void {
    this.shutdownEngine();
    result.success(null);
  }

  private shutdownEngine(): void {
    this.generation++;
    this.activeRequestId = null;
    const engine = this.engine;
    this.engine = null;
    if (engine == null) return;
    try {
      engine.stop();
    } catch (_) {
      // 引擎已结束播放时 stop 可能抛错，忽略。
    }
    try {
      engine.shutdown();
    } catch (_) {
      // 重复 shutdown 兜底。
    }
  }

  private ensureEngine(): Promise<textToSpeech.TextToSpeechEngine> {
    const engine = this.engine;
    if (engine != null) {
      return Promise.resolve(engine);
    }
    if (this.creating != null) {
      return this.creating;
    }
    const creating: Promise<textToSpeech.TextToSpeechEngine> = this.createEngine();
    this.creating = creating;
    creating.then(() => {
      this.creating = null;
    }).catch(() => {
      this.creating = null;
    });
    return creating;
  }

  private async createEngine(): Promise<textToSpeech.TextToSpeechEngine> {
    const params: textToSpeech.CreateEngineParams = {
      language: this.language,
      // 中文：13 = 聆小珊女声（内置）；英文：8 = Laura（需先下载音色）。
      person: this.language.toLowerCase().startsWith('en') ? 8 : 13,
      // 0 = 在线（当前系统不支持），1 = 离线。
      online: 1,
      extraParams: {
        'style': 'interaction-broadcast',
        'locate': 'CN',
        'isBackStage': true
      }
    };
    const engine = await textToSpeech.createEngine(params);
    engine.setListener({
      onStart: (requestId: string, response: textToSpeech.StartResponse) => {
      },
      onComplete: (requestId: string, response: textToSpeech.CompleteResponse) => {
        // type=0 合成完成，type=1 播放完成；只上报播放完成。
        if (response.type !== 1 || this.activeRequestId !== requestId) return;
        this.activeRequestId = null;
        this.channel?.invokeMethod('onComplete', '');
      },
      onStop: (requestId: string, response: textToSpeech.StopResponse) => {
        // 主动 stop / 切换段落不触发自动续读。
      },
      onError: (requestId: string, errorCode: number, errorMessage: string) => {
        if (this.activeRequestId !== requestId) return;
        this.activeRequestId = null;
        hilog.error(0x0000, TAG, 'tts error: %{public}d %{public}s', errorCode, errorMessage);
        this.channel?.invokeMethod('onError', `${errorCode} ${errorMessage}`);
      }
    });
    this.engine = engine;
    hilog.info(0x0000, TAG, 'engine ready: language=%{public}s', this.language);
    return engine;
  }
}
