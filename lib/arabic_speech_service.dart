import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

class _WorkerInit {
  final SendPort port;
  final String encoder;
  final String decoder;
  final String tokens;
  const _WorkerInit(this.port, this.encoder, this.decoder, this.tokens);
}

/// يعمل في خيط (Isolate) منفصل حتى لا تتجمد الشاشة أثناء التحويل
void _whisperWorker(_WorkerInit init) {
  sherpa.initBindings();
  final commands = ReceivePort();
  init.port.send(commands.sendPort);

  sherpa.OfflineRecognizer? recognizer;
  try {
    final model = sherpa.OfflineModelConfig(
      whisper: sherpa.OfflineWhisperModelConfig(
        encoder: init.encoder,
        decoder: init.decoder,
        language: 'ar',
        task: 'transcribe',
      ),
      tokens: init.tokens,
      numThreads: 4,
      debug: false,
    );
    recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(model: model),
    );
    init.port.send('ready');
  } catch (e) {
    init.port.send(['error', '$e']);
    return;
  }

  commands.listen((msg) {
    final reply = msg[0] as SendPort;
    final path = msg[1] as String;
    try {
      final wave = sherpa.readWave(path);
      final rec = recognizer!;
      final stream = rec.createStream();
      try {
        stream.acceptWaveform(
          samples: wave.samples,
          sampleRate: wave.sampleRate,
        );
        rec.decode(stream);
        reply.send(rec.getResult(stream).text.trim());
      } finally {
        stream.free();
      }
    } catch (e) {
      reply.send(['error', '$e']);
    }
  });
}

/// تعرّف صوتي بدون إنترنت بنموذج Whisper (small, int8) للعربية.
/// الملفات كبيرة (~375 ميغابايت) فتُنزَّل مرة واحدة إلى مجلد التطبيق.
class ArabicSpeechService {
  Isolate? _isolate;
  SendPort? _worker;
  Future<void>? _starting;

  /// مصادر التنزيل بالترتيب (إن تعذّر الأول نجرّب الثاني)
  static const _baseUrls = [
    'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main/',
    'https://hf-mirror.com/csukuangfj/sherpa-onnx-whisper-small/resolve/main/',
  ];

  /// اسم الملف -> حجمه التقريبي بالبايت (لحساب نسبة التقدم)
  static const Map<String, int> _files = {
    'small-encoder.int8.onnx': 112442483,
    'small-decoder.int8.onnx': 262226114,
    'small-tokens.txt': 816730,
  };

  Future<Directory> _modelDir() async {
    final base = await getExternalStorageDirectory() ??
        await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}whisper_small');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String name) async {
    final dir = await _modelDir();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  /// هل ملفات النموذج موجودة؟
  Future<bool> isModelReady() async {
    for (final name in _files.keys) {
      final f = await _file(name);
      if (!await f.exists() || await f.length() == 0) return false;
    }
    return true;
  }

  /// تنزيل النموذج مع نسبة التقدم (0..1) واسم الملف الجاري تنزيله
  Future<void> downloadModel({
    void Function(double progress, String fileName)? onProgress,
  }) async {
    final total = _files.values.reduce((a, b) => a + b);
    var done = 0;

    for (final e in _files.entries) {
      final target = await _file(e.key);
      if (await target.exists() && await target.length() > 0) {
        done += e.value;
        continue;
      }

      final part = File('${target.path}.part');
      final errors = <String>[];
      var ok = false;

      for (final base in _baseUrls) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 20);
        try {
          final req = await client.getUrl(Uri.parse('$base${e.key}'));
          final res = await req.close();
          if (res.statusCode != 200) {
            throw Exception('HTTP ${res.statusCode}');
          }

          final sink = part.openWrite();
          var received = 0;
          try {
            await for (final chunk in res) {
              sink.add(chunk);
              received += chunk.length;
              onProgress?.call((done + received) / total, e.key);
            }
          } finally {
            await sink.close();
          }

          await part.rename(target.path);
          ok = true;
          break;
        } catch (err) {
          errors.add('${Uri.parse(base).host}: $err');
        } finally {
          client.close(force: true);
        }
      }

      if (!ok) {
        throw Exception('فشل تنزيل ${e.key}\n${errors.join('\n')}');
      }
      done += e.value;
    }
  }

  Future<void> initialize() => _starting ??= _start();

  Future<void> _start() async {
    if (!await isModelReady()) {
      _starting = null;
      throw Exception('نموذج الصوت غير مُنزَّل');
    }

    final encoder = (await _file('small-encoder.int8.onnx')).path;
    final decoder = (await _file('small-decoder.int8.onnx')).path;
    final tokens = (await _file('small-tokens.txt')).path;

    final port = ReceivePort();
    final ready = Completer<void>();
    port.listen((m) {
      if (m is SendPort) {
        _worker = m;
      } else if (m == 'ready') {
        if (!ready.isCompleted) ready.complete();
      } else if (m is List && m.isNotEmpty && m.first == 'error') {
        if (!ready.isCompleted) ready.completeError(Exception('${m[1]}'));
      }
    });

    try {
      _isolate = await Isolate.spawn(
        _whisperWorker,
        _WorkerInit(port.sendPort, encoder, decoder, tokens),
      );
      await ready.future;
    } catch (e) {
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _worker = null;
      _starting = null;
      rethrow;
    } finally {
      port.close();
    }
  }

  Future<String> transcribe(String audioPath) async {
    await initialize();

    if (!await File(audioPath).exists()) {
      throw Exception('ملف التسجيل غير موجود');
    }

    final reply = ReceivePort();
    _worker!.send([reply.sendPort, audioPath]);
    final res = await reply.first;
    reply.close();

    if (res is List && res.isNotEmpty && res.first == 'error') {
      throw Exception('${res[1]}');
    }
    return res as String;
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _worker = null;
    _starting = null;
  }
}