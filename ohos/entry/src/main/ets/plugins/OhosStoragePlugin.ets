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
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';

const TAG: string = 'NexHubStorage';
const CHANNEL: string = 'nexhub/ohos_storage';
const COPY_CHUNK: number = 1 << 20; // 1 MiB

interface StorageEntry {
  name: string;
  isDir: boolean;
  size: number;
}

interface DownloadDirResult {
  uri: string;
  path: string;
}

interface PickDirectoryResult {
  uri: string;
  path: string;
  name: string;
}

/**
 * 应用级文件存储通道（鸿蒙专用）。
 *
 * 背景：鸿蒙手机不支持文件夹选择（FolderSelection 仅 2in1），公共 Download
 * 目录也不能用 dart:io 直接读写。DocumentViewPicker 的 DOWNLOAD 模式会跳过
 * 文件选择、由系统创建并持久授权 `Download/<bundleName>` 目录，是手机上空
 * 间唯一可写的用户可见位置。
 *
 * 本插件把该目录的读写映射到 MethodChannel：
 * - requestDownloadDir：拉起一次授权，返回目录 URI 与 FileUri 路径；
 * - 文件操作（mkdir/list/exists/delete/write/copy）均以**路径**为入参
 *   （官方 FAQ：FileUri.path 可直接交给 @ohos.file.fs）；
 * - 大文件写入走 openWrite/writeChunk/closeWrite 会话，避免整块数据过通道；
 * - copyToCache 由原生分块拷贝到应用缓存，供 dart:io 读取/播放。
 */
export default class OhosStoragePlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private uiContext: common.UIAbilityContext | null = null;
  private writeFds: Map<string, number> = new Map<string, number>();
  private sessionSeq: number = 0;

  getUniqueClassName(): string {
    return 'OhosStoragePlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.closeAllWrites();
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
      case 'requestDownloadDir':
        this.requestDownloadDir(result);
        return;
      case 'checkPath':
        this.checkPath(call, result);
        return;
      case 'mkdir':
        this.mkdir(call, result);
        return;
      case 'list':
        this.list(call, result);
        return;
      case 'exists':
        this.exists(call, result);
        return;
      case 'delete':
        this.delete(call, result);
        return;
      case 'writeBytes':
        this.writeBytes(call, result);
        return;
      case 'readBytes':
        this.readBytes(call, result);
        return;
      case 'openWrite':
        this.openWrite(call, result);
        return;
      case 'writeChunk':
        this.writeChunk(call, result);
        return;
      case 'closeWrite':
        this.closeWrite(call, result);
        return;
      case 'pickDirectory':
        this.pickDirectory(result);
        return;
      case 'copyDirectoryToImport':
        this.copyDirectoryToImport(call, result);
        return;
      case 'copyToCache':
        this.copyToCache(call, result);
        return;
      default:
        result.notImplemented();
    }
  }

  private requestDownloadDir(result: MethodResult): void {
    const context: common.UIAbilityContext | null = this.uiContext;
    if (context == null) {
      hilog.error(0x0000, TAG, 'requestDownloadDir no ui context');
      result.error('no_context', 'UIAbility context is null', '');
      return;
    }
    try {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      // DOWNLOAD：系统直接创建/返回 Download/<bundleName> 目录，跳过文件选择；
      // 返回目录 URI 自带持久化授权，newFileNames 在该模式下不生效。
      options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      documentPicker.save(options).then((uris: Array<string>) => {
        if (uris == null || uris.length === 0 || uris[0] == null || uris[0].length === 0) {
          hilog.info(0x0000, TAG, 'requestDownloadDir canceled');
          result.success(null);
          return;
        }
        const dirUri: string = uris[0];
        try {
          const dirPath: string = new fileUri.FileUri(dirUri).path;
          if (!fileIo.accessSync(dirPath)) {
            result.error('dir_missing', `cannot access ${dirPath}`, '');
            return;
          }
          const payload: DownloadDirResult = { uri: dirUri, path: dirPath };
          hilog.info(0x0000, TAG, 'requestDownloadDir ok: %{public}s', dirPath);
          result.success(payload);
        } catch (e) {
          const err = e as BusinessError;
          hilog.error(0x0000, TAG, 'requestDownloadDir resolve failure: %{public}d %{public}s',
            err.code, err.message);
          result.error('dir_resolve_failed', `${err.code} ${err.message}`, '');
        }
      }).catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, 'requestDownloadDir rejected: %{public}d %{public}s', e.code, e.message);
        result.error('picker_failed', `${e.code} ${e.message}`, '');
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'requestDownloadDir setup failure: %{public}s', err.message);
      result.error('picker_setup_failed', `${err.message}`, '');
    }
  }

  private pickDirectory(result: MethodResult): void {
    const context: common.UIAbilityContext | null = this.uiContext;
    if (context == null) {
      hilog.error(0x0000, TAG, 'pickDirectory no ui context');
      result.error('no_context', 'UIAbility context is null', '');
      return;
    }
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      // FOLDER 模式仅 2in1 具备；插件不按机型拦截，由 Dart 侧只在 isOHOSPC 调用。
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      options.maxSelectNumber = 1;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      documentPicker.select(options).then((uris: Array<string>) => {
        if (uris == null || uris.length === 0 || uris[0] == null || uris[0].length === 0) {
          hilog.info(0x0000, TAG, 'pickDirectory canceled');
          result.success(null);
          return;
        }
        const dirUri: string = uris[0];
        try {
          const dirPath: string = new fileUri.FileUri(dirUri).path;
          const payload: PickDirectoryResult = {
            uri: dirUri,
            path: dirPath,
            name: baseName(dirPath)
          };
          hilog.info(0x0000, TAG, 'pickDirectory ok: %{public}s', dirPath);
          result.success(payload);
        } catch (e) {
          const err = e as BusinessError;
          hilog.error(0x0000, TAG, 'pickDirectory resolve failure: %{public}d %{public}s',
            err.code, err.message);
          result.error('dir_resolve_failed', `${err.code} ${err.message}`, '');
        }
      }).catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, 'pickDirectory rejected: %{public}d %{public}s', e.code, e.message);
        result.error('picker_failed', `${e.code} ${e.message}`, '');
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'pickDirectory setup failure: %{public}s', err.message);
      result.error('picker_setup_failed', `${err.message}`, '');
    }
  }

  private async copyDirectoryToImport(call: MethodCall, result: MethodResult): Promise<void> {
    const context: common.UIAbilityContext | null = this.uiContext;
    if (context == null) {
      hilog.error(0x0000, TAG, 'copyDirectoryToImport no ui context');
      result.error('no_context', 'UIAbility context is null', '');
      return;
    }
    const srcPath: string = call.argument('srcPath');
    const name: string = call.argument('name');
    if (srcPath == null || srcPath.length === 0) {
      result.error('bad_args', 'srcPath is empty', '');
      return;
    }
    // 时间戳做成父目录、原目录名做最后一段：导入页用 p.basename(dest) 作为
    // 书名 / 媒体名，不能带时间戳；父目录保证重复导入不覆盖。
    const batchDir: string = `${context.filesDir}/imports/${Date.now()}`;
    const dest: string = `${batchDir}/${sanitizeFolderName(name)}`;
    try {
      if (!fileIo.accessSync(srcPath)) {
        result.error('src_missing', `cannot access ${srcPath}`, '');
        return;
      }
      fileIo.mkdirSync(batchDir, true);
      await fileIo.copyDir(srcPath, dest);
      hilog.info(0x0000, TAG, 'copyDirectoryToImport ok: %{public}s -> %{public}s', srcPath, dest);
      result.success(dest);
    } catch (e) {
      // 失败时递归删除本次批次目录，避免沙箱残留半成品。
      try {
        if (fileIo.accessSync(batchDir)) {
          fileIo.rmdirSync(batchDir);
        }
      } catch (cleanupError) {
        const err = cleanupError as BusinessError;
        hilog.warn(0x0000, TAG, 'copy cleanup failed: %{public}d %{public}s',
          err.code, err.message);
      }
      this.fail(result, 'copy_dir_failed', e);
    }
  }

  private checkPath(call: MethodCall, result: MethodResult): void {
    const path: string = call.argument('path');
    if (path == null || path.length === 0) {
      result.error('bad_args', 'path is empty', '');
      return;
    }
    try {
      result.success(fileIo.accessSync(path));
    } catch (e) {
      result.success(false);
    }
  }

  private mkdir(call: MethodCall, result: MethodResult): void {
    const path: string = call.argument('path');
    if (path == null || path.length === 0) {
      result.error('bad_args', 'path is empty', '');
      return;
    }
    try {
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
      result.success(null);
    } catch (e) {
      this.fail(result, 'mkdir_failed', e);
    }
  }

  private list(call: MethodCall, result: MethodResult): void {
    const path: string = call.argument('path');
    if (path == null || path.length === 0) {
      result.error('bad_args', 'path is empty', '');
      return;
    }
    try {
      const names: string[] = fileIo.listFileSync(path);
      const entries: StorageEntry[] = [];
      for (const name of names) {
        try {
          const st = fileIo.statSync(`${path}/${name}`);
          entries.push({ name: name, isDir: st.isDirectory(), size: st.size });
        } catch (e) {
          // 单个条目不可 stat（失效链接/权限）时跳过，不影响整体列举。
        }
      }
      result.success(entries);
    } catch (e) {
      this.fail(result, 'list_failed', e);
    }
  }

  private exists(call: MethodCall, result: MethodResult): void {
    const path: string = call.argument('path');
    if (path == null || path.length === 0) {
      result.success(false);
      return;
    }
    try {
      result.success(fileIo.accessSync(path));
    } catch (e) {
      result.success(false);
    }
  }

  private delete(call: MethodCall, result: MethodResult): void {
    const path: string = call.argument('path');
    if (path == null || path.length === 0) {
      result.error('bad_args', 'path is empty', '');
      return;
    }
    try {
      if (!fileIo.accessSync(path)) {
        result.success(null);
        return;
      }
      const st = fileIo.statSync(path);
      if (st.isDirectory()) {
        fileIo.rmdirSync(path);
      } else {
        fileIo.unlinkSync(path);
      }
      result.success(null);
    } catch (e) {
      this.fail(result, 'delete_failed', e);
    }
  }

  private writeBytes(call: MethodCall, result: MethodResult): void {
    const path: string = call.argument('path');
    const bytesArg: Object | null = call.argument('bytes');
    if (path == null || path.length === 0 || bytesArg == null) {
      result.error('bad_args', 'path/bytes is empty', '');
      return;
    }
    const bytes: Uint8Array | null = this.asBytes(bytesArg);
    if (bytes == null) {
      result.error('bad_args', 'bytes type unsupported', '');
      return;
    }
    try {
      this.ensureParent(path);
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        this.writeView(file.fd, bytes);
      } finally {
        fileIo.closeSync(file);
      }
      result.success(null);
    } catch (e) {
      this.fail(result, 'write_failed', e);
    }
  }

  private readBytes(call: MethodCall, result: MethodResult): void {
    const path: string = call.argument('path');
    if (path == null || path.length === 0) {
      result.error('bad_args', 'path is empty', '');
      return;
    }
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const st = fileIo.statSync(path);
      const size: number = st.size;
      if (size === 0) {
        result.success(new Uint8Array(0).buffer);
        return;
      }
      const target = new Uint8Array(size);
      const chunk: ArrayBuffer = new ArrayBuffer(Math.min(size, COPY_CHUNK));
      let readLen: number = 0;
      while (readLen < size) {
        const n: number = fileIo.readSync(file.fd, chunk);
        if (n <= 0) break;
        target.set(new Uint8Array(chunk, 0, n), readLen);
        readLen += n;
      }
      result.success(readLen === size ? target.buffer : target.slice(0, readLen).buffer);
    } catch (e) {
      this.fail(result, 'read_failed', e);
    } finally {
      if (file != null) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          // 已关闭/失效时忽略。
        }
      }
    }
  }

  private openWrite(call: MethodCall, result: MethodResult): void {
    const path: string = call.argument('path');
    if (path == null || path.length === 0) {
      result.error('bad_args', 'path is empty', '');
      return;
    }
    try {
      this.ensureParent(path);
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const id: string = `w${Date.now()}${++this.sessionSeq}`;
      this.writeFds.set(id, file.fd);
      result.success(id);
    } catch (e) {
      this.fail(result, 'open_write_failed', e);
    }
  }

  private writeChunk(call: MethodCall, result: MethodResult): void {
    const id: string = call.argument('id');
    const bytesArg: Object | null = call.argument('bytes');
    if (id == null || id.length === 0 || bytesArg == null) {
      result.error('bad_args', 'id/bytes is empty', '');
      return;
    }
    const fd: number | undefined = this.writeFds.get(id);
    if (fd === undefined) {
      result.error('bad_session', 'write session not found', '');
      return;
    }
    const bytes: Uint8Array | null = this.asBytes(bytesArg);
    if (bytes == null) {
      result.error('bad_args', 'bytes type unsupported', '');
      return;
    }
    try {
      this.writeView(fd, bytes);
      result.success(null);
    } catch (e) {
      this.closeWriteSession(id);
      this.fail(result, 'write_failed', e);
    }
  }

  private closeWrite(call: MethodCall, result: MethodResult): void {
    const id: string = call.argument('id');
    if (id == null || id.length === 0) {
      result.error('bad_args', 'id is empty', '');
      return;
    }
    try {
      this.closeWriteSession(id);
      result.success(null);
    } catch (e) {
      this.fail(result, 'close_write_failed', e);
    }
  }

  private copyToCache(call: MethodCall, result: MethodResult): void {
    const src: string = call.argument('src');
    const dst: string = call.argument('dst');
    if (src == null || src.length === 0 || dst == null || dst.length === 0) {
      result.error('bad_args', 'src/dst is empty', '');
      return;
    }
    let srcFile: fileIo.File | null = null;
    let dstFile: fileIo.File | null = null;
    try {
      this.ensureParent(dst);
      srcFile = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
      dstFile = fileIo.openSync(dst,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const buffer: ArrayBuffer = new ArrayBuffer(COPY_CHUNK);
      let total: number = 0;
      while (true) {
        const n: number = fileIo.readSync(srcFile.fd, buffer);
        if (n <= 0) break;
        fileIo.writeSync(dstFile.fd, buffer, { length: n });
        total += n;
      }
      result.success(total);
    } catch (e) {
      this.fail(result, 'copy_failed', e);
    } finally {
      if (srcFile != null) {
        try {
          fileIo.closeSync(srcFile);
        } catch (e) {
          // ignore
        }
      }
      if (dstFile != null) {
        try {
          fileIo.closeSync(dstFile);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  private asBytes(value: Object): Uint8Array | null {
    if (value instanceof Uint8Array) {
      return value;
    }
    if (value instanceof ArrayBuffer) {
      return new Uint8Array(value);
    }
    return null;
  }

  /** 写入一个 Uint8Array；byteOffset 非 0 时复制，避免把视图前的字节写进去。 */
  private writeView(fd: number, bytes: Uint8Array): void {
    if (bytes.byteLength === 0) return;
    let buffer: ArrayBuffer = bytes.buffer as ArrayBuffer;
    if (bytes.byteOffset !== 0) {
      buffer = bytes.slice().buffer as ArrayBuffer;
    }
    fileIo.writeSync(fd, buffer, { length: bytes.byteLength });
  }

  private ensureParent(path: string): void {
    const idx: number = path.lastIndexOf('/');
    if (idx <= 0) return;
    const parent: string = path.substring(0, idx);
    if (!fileIo.accessSync(parent)) {
      fileIo.mkdirSync(parent, true);
    }
  }

  private closeWriteSession(id: string): void {
    const fd: number | undefined = this.writeFds.get(id);
    if (fd === undefined) return;
    this.writeFds.delete(id);
    fileIo.closeSync(fd);
  }

  private closeAllWrites(): void {
    for (const id of this.writeFds.keys()) {
      try {
        this.closeWriteSession(id);
      } catch (e) {
        // 进程退出前尽力关闭。
      }
    }
    this.writeFds.clear();
  }

  private fail(result: MethodResult, code: string, e: Object): void {
    const err = e as BusinessError;
    hilog.error(0x0000, TAG, '%{public}s: %{public}d %{public}s', code, err.code, err.message);
    result.error(code, `${err.code} ${err.message}`, '');
  }
}

/** 取路径最后一段（忽略末尾分隔符）。 */
function baseName(path: string): string {
  let normalized: string = path;
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  const idx: number = normalized.lastIndexOf('/');
  return idx >= 0 ? normalized.substring(idx + 1) : normalized;
}

/** 保留 Unicode 字母 / 数字 / 中文 / - / _，其余替换为 _，最长 48 字符。 */
function sanitizeFolderName(name: string): string {
  const raw: string = name == null ? '' : name.trim();
  let out: string = '';
  for (let i = 0; i < raw.length; i++) {
    const ch: string = raw.charAt(i);
    out += /[\p{L}\p{N}_-]/u.test(ch) ? ch : '_';
  }
  out = out.replace(/_+/g, '_').replace(/^_+|_+$/g, '');
  if (out.length === 0) {
    return 'folder';
  }
  return out.length > 48 ? out.substring(0, 48) : out;
}
