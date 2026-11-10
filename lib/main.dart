import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'arabic_reminder_parser.dart';
import 'arabic_speech_service.dart';
import 'notes_store.dart';
import 'notification_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmartNotesApp());
}

// ---------- ألوان الواجهة الورقية ----------

const _paper = Color(0xFFF5F1E7);
const _paperCard = Color(0xFFFFFDF7);
const _green = Color(0xFF527C65);
const _greenDark = Color(0xFF315541);
const _greenLight = Color(0xFFE1EBDD);
const _blue = Color(0xFF2878E5);
const _ink = Color(0xFF26372E);
const _muted = Color(0xFF899187);
const _line = Color(0xFFE5E0D4);

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

enum _Engine { google, offline }

// ---------- تنسيق التاريخ ----------

String formatDue(DateTime d) {
  const days = {
    1: 'الاثنين',
    2: 'الثلاثاء',
    3: 'الأربعاء',
    4: 'الخميس',
    5: 'الجمعة',
    6: 'السبت',
    7: 'الأحد',
  };

  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');

  return '${days[d.weekday]} ${d.day}/${d.month} - '
      '$h12:$m ${d.hour >= 12 ? 'م' : 'ص'}';
}

// ---------- التطبيق ----------

class SmartNotesApp extends StatelessWidget {
  const SmartNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'مذكرتي الذكية',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: _paper,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _green,
          brightness: Brightness.light,
          surface: _paperCard,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _paper,
          foregroundColor: _ink,
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _paperCard,
          hintStyle: const TextStyle(color: _muted),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
        dialogTheme: const DialogThemeData(backgroundColor: _paperCard),
      ),
      home: const HomePage(),
    );
  }
}

// ---------- الصفحة الرئيسية ----------

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  final ArabicSpeechService _speech = ArabicSpeechService();
  final SpeechToText _google = SpeechToText();

  final ArabicReminderParser _parser = ArabicReminderParser();
  final NotificationService _notifications = NotificationService();
  final NotesStore _store = NotesStore();

  final TextEditingController _textController = TextEditingController();

  final TextEditingController _searchController = TextEditingController();

  List<NoteItem> _notes = [];

  bool _isRecording = false;
  bool _isBusy = false;
  String _status = '';

  bool _useInternet = true;
  bool _skipOnlineOnce = false;
  bool _finishing = false;

  _Engine _engine = _Engine.offline;

  String _liveText = '';
  DateTime _startedAt = DateTime.now();

  String _committed = '';
  String _lastPartial = '';

  bool _modelReady = false;
  bool _downloading = false;

  double _dlProgress = 0;
  String _dlFile = '';

  String _searchQuery = '';

  @override
  void initState() {
    super.initState();

    _loadNotes();
    _initNotifications();
    _checkModel();
  }

  // ---------- الإشعارات ----------

  Future<void> _initNotifications() async {
    try {
      await _notifications.initialize();

      NotificationService.onAlarmOpened = _openAlarm;

      await _notifications.checkLaunchFromNotification();
    } catch (e) {
      debugPrint('خطأ في تهيئة الإشعارات: $e');
    }
  }

  void _openAlarm(int id, String task) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) =>
              AlarmPage(id: id, task: task, service: _notifications),
        ),
      );
    });
  }

  // ---------- تحميل المذكرات ----------

  Future<void> _loadNotes() async {
    final loaded = await _store.load();

    if (!mounted) return;

    setState(() => _notes = List<NoteItem>.of(loaded));
  }

  // ---------- تغيير حالة المهمة ----------

  Future<void> _toggleDone(NoteItem note) async {
    final index = _notes.indexWhere((n) => n.id == note.id);

    if (index == -1) return;

    final updated = note.copyWith(isDone: !note.isDone);

    setState(() {
      _notes[index] = updated;
    });

    try {
      await _store.save(_notes);
    } catch (e) {
      debugPrint('SAVE DONE ERROR: $e');
      _showMessage('تعذر حفظ حالة المهمة');
    }
  }

  // ---------- نموذج الصوت ----------

  Future<void> _checkModel() async {
    final ready = await _speech.isModelReady();

    if (mounted) {
      setState(() => _modelReady = ready);
    }
  }

  Future<void> _downloadModel() async {
    if (_downloading) return;

    setState(() {
      _downloading = true;
      _dlProgress = 0;
      _dlFile = '';
    });

    try {
      var lastShown = -1;

      await _speech.downloadModel(
        onProgress: (p, f) {
          final pct = (p * 100).floor();

          if (pct == lastShown) return;

          lastShown = pct;

          if (mounted) {
            setState(() {
              _dlProgress = p;
              _dlFile = f;
            });
          }
        },
      );

      await _checkModel();

      _showMessage('تم تنزيل النموذج، وصار يعمل بدون إنترنت');
    } catch (e) {
      await _showError('تعذّر تنزيل النموذج', '$e');
    } finally {
      if (mounted) {
        setState(() => _downloading = false);
      }
    }
  }

  // ---------- فحص الإنترنت ----------

  Future<bool> _hasInternet() async {
    try {
      final r = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 2));

      return r.isNotEmpty && r.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // ---------- بدء التسجيل ----------

  Future<void> _startRecording() async {
    if (_isBusy || _isRecording) return;

    setState(() => _isBusy = true);

    try {
      final online = _useInternet && !_skipOnlineOnce && await _hasInternet();

      _skipOnlineOnce = false;

      if (online && await _startGoogle()) return;

      await _startOffline();
    } catch (e) {
      _showMessage('تعذر بدء التسجيل: $e');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  // ---------- التعرف عبر Google ----------

  Future<bool> _startGoogle() async {
    try {
      final ok = await _google.initialize(
        onStatus: _onGoogleStatus,
        onError: _onGoogleError,
      );

      if (!ok) return false;

      _liveText = '';
      _committed = '';
      _lastPartial = '';

      _engine = _Engine.google;
      _startedAt = DateTime.now();

      if (mounted) {
        setState(() => _isRecording = true);
      }

      await _google.listen(
        onResult: (r) {
          final words = r.recognizedWords.trim();

          if (words.isEmpty) return;

          if (!r.finalResult &&
              _lastPartial.length > 8 &&
              words.length < _lastPartial.length * 0.5) {
            _committed = '$_committed $_lastPartial'.trim();
          }

          _lastPartial = words;

          if (r.finalResult) {
            _committed = '$_committed $words'.trim();
            _lastPartial = '';
          }

          if (mounted) {
            setState(() {
              _liveText = '$_committed $_lastPartial'.trim();
            });
          }
        },
        listenOptions: SpeechListenOptions(
          localeId: 'ar_SA',
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 5),
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
      );

      return true;
    } catch (e) {
      debugPrint('GOOGLE START ERROR: $e');

      if (mounted) {
        setState(() => _isRecording = false);
      }

      return false;
    }
  }

  void _onGoogleStatus(String status) {
    debugPrint('GOOGLE STT STATUS: $status');

    final elapsed = DateTime.now().difference(_startedAt);

    if ((status == 'done' || status == 'notListening') &&
        _isRecording &&
        _engine == _Engine.google &&
        elapsed > const Duration(seconds: 2)) {
      _finishGoogle();
    }
  }

  void _onGoogleError(SpeechRecognitionError e) {
    debugPrint('GOOGLE STT ERROR: ${e.errorMsg}');

    if (_engine != _Engine.google || !_isRecording) {
      return;
    }

    if (e.errorMsg == 'error_no_match' ||
        e.errorMsg == 'error_speech_timeout') {
      _finishGoogle(reason: e.errorMsg);
      return;
    }

    _isRecording = false;
    _skipOnlineOnce = true;

    if (mounted) setState(() {});

    _showMessage(
      'تعذّر التعرف عبر الإنترنت (${e.errorMsg}). '
      'اضغط بدء مرة أخرى لاستخدام الوضع بدون إنترنت',
    );
  }

  Future<void> _stopGoogle() async {
    if (!_isRecording) return;

    try {
      await _google.stop();
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 900));

    await _finishGoogle();
  }

  Future<void> _finishGoogle({String reason = ''}) async {
    if (!_isRecording || _finishing) return;

    _finishing = true;

    try {
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isBusy = true;
        });
      }

      final text = _liveText.trim();

      if (text.isEmpty) {
        _showMessage(
          'لم أتعرّف على الكلام'
          '${reason.isEmpty ? '' : ' ($reason)'}، حاول مرة أخرى',
        );
        return;
      }

      final confirmed = await _confirmText(text);

      if (confirmed == null || confirmed.trim().isEmpty) {
        _showMessage('تم إلغاء المذكرة');
        return;
      }

      await _createNote(confirmed.trim());
    } catch (e) {
      _showMessage('تعذر معالجة الكلام: $e');
    } finally {
      _finishing = false;

      if (mounted) {
        setState(() {
          _isBusy = false;
          _status = '';
          _liveText = '';
        });
      }
    }
  }

  // ---------- التسجيل بدون إنترنت ----------

  Future<void> _startOffline() async {
    if (!_modelReady) {
      _showMessage('نزّل نموذج الصوت أولاً لتستخدم الوضع بدون إنترنت');
      return;
    }

    if (!await _recorder.hasPermission()) {
      _showMessage('يرجى السماح للتطبيق باستخدام الميكروفون');
      return;
    }

    final directory = await getApplicationDocumentsDirectory();

    final path =
        '${directory.path}/note_${DateTime.now().millisecondsSinceEpoch}.wav';

    try {
      await _google.cancel();
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 400));

    _engine = _Engine.offline;

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );

    unawaited(
      _speech.initialize().catchError((Object e) {
        debugPrint('WARMUP ERROR: $e');
      }),
    );

    if (!mounted) return;

    setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    if (_engine == _Engine.google) {
      await _stopGoogle();
      return;
    }

    if (_isBusy || !_isRecording) return;

    setState(() => _isBusy = true);

    try {
      final path = await _recorder.stop();

      if (mounted) {
        setState(() => _isRecording = false);
      }

      if (path == null || !await File(path).exists()) {
        _showMessage('لم يتم العثور على ملف التسجيل');
        return;
      }

      if (mounted) {
        setState(() => _status = 'جارٍ تحويل الصوت إلى نص...');
      }

      await Future.delayed(const Duration(milliseconds: 150));

      final text = (await _speech.transcribe(path)).trim();

      if (text.isEmpty) {
        await File(path).delete();

        _showMessage('لم أتعرّف على الكلام، حاول مرة أخرى');
        return;
      }

      if (mounted) {
        setState(() => _status = '');
      }

      final confirmed = await _confirmText(text);

      if (confirmed == null || confirmed.trim().isEmpty) {
        await File(path).delete();

        _showMessage('تم إلغاء المذكرة');
        return;
      }

      await _createNote(confirmed.trim(), audioPath: path);
    } catch (e, st) {
      debugPrint('PROCESS ERROR: $e');
      debugPrintStack(stackTrace: st);

      _showMessage('تعذر معالجة التسجيل: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _isRecording = false;
          _status = '';
        });
      }
    }
  }

  // ---------- مراجعة النص ----------

  Future<String?> _confirmText(String heard) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ConfirmTextDialog(heard: heard, parser: _parser),
    );
  }

  // ---------- إنشاء مذكرة وضبط موعدها ----------

  Future<void> _createNote(String text, {String audioPath = ''}) async {
    final reminders = _parser.parseMultiple(text);

    if (reminders.isEmpty) {
      _showMessage('لم أتمكن من استخراج أي مهمة');
      return;
    }

    final usedIds = _notes.map((note) => note.id).toSet();
    final newNotes = <NoteItem>[];

    var scheduledCount = 0;
    var failedCount = 0;
    var assumedCount = 0;
    var noDateCount = 0;

    String? firstError;
    String? firstWarning;

    for (var i = 0; i < reminders.length; i++) {
      final reminder = reminders[i];
      final due = reminder.dateTime;

      var id = DateTime.now().microsecondsSinceEpoch.remainder(2147483647);

      while (usedIds.contains(id)) {
        id = (id + 1).remainder(2147483647);
      }
      usedIds.add(id);

      var scheduled = false;

      if (due != null) {
        try {
          await _notifications.initialize();

          final level = await _notifications.scheduleReminder(
            id: id,
            task: reminder.task,
            dateTime: due,
          );

          scheduled = true;
          scheduledCount++;

          if (level > 0 && firstWarning == null) {
            firstWarning = _notifications.lastWarning;
          }
        } catch (e) {
          failedCount++;
          firstError ??= '$e';
        }
      } else {
        noDateCount++;
      }

      if (reminder.timeAssumed) {
        assumedCount++;
      }

      final note = NoteItem(
        id: id,
        text: reminder.originalText,
        task: reminder.task,
        dueMs: due?.millisecondsSinceEpoch,
        scheduled: scheduled,
        audioPath: i == 0 ? audioPath : '',
        createdMs: DateTime.now().millisecondsSinceEpoch,
      );

      newNotes.insert(0, note);
    }

    _notes.insertAll(0, newNotes);

    if (mounted) {
      setState(() {});
    }

    try {
      await _store.save(_notes);
    } catch (e) {
      debugPrint('SAVE NOTE ERROR: $e');
      _showMessage('تعذّر حفظ الملاحظات: $e');
      return;
    }

    if (!mounted) return;

    _showMessage(
      'تم حفظ ${newNotes.length} مهام، '
      'وضبط $scheduledCount تنبيهات',
    );

    if (noDateCount > 0) {
      _showMessage('$noDateCount مهام حُفظت دون موعد');
    }

    if (failedCount > 0) {
      await _showError('تعذّر ضبط $failedCount تنبيهات', firstError ?? '');
    } else if (firstWarning != null) {
      await _showError('بعض التنبيهات تعمل بوضع احتياطي', firstWarning);
    }

    if (assumedCount > 0 && mounted) {
      _showMessage(
        'تم افتراض موعد الساعة 9 صباحاً '
        'لـ $assumedCount مهام',
      );
    }
  }

  // ---------- إضافة مذكرة بالكتابة ----------

  Future<void> _addFromText() async {
    final text = _textController.text.trim();

    if (text.isEmpty || _isBusy) return;

    _textController.clear();

    FocusScope.of(context).unfocus();

    await _createNote(text);
  }

  // ---------- تشغيل التسجيل ----------

  Future<void> _play(NoteItem note) async {
    if (note.audioPath.isEmpty || _isRecording || _isBusy) {
      return;
    }

    try {
      final file = File(note.audioPath);

      if (!await file.exists()) {
        _showMessage('ملف التسجيل غير موجود');
        return;
      }

      await _player.stop();
      await _player.play(DeviceFileSource(file.path));
    } catch (e) {
      _showMessage('تعذر تشغيل التسجيل: $e');
    }
  }

  // ---------- حذف المذكرة ----------

  Future<void> _delete(NoteItem note) async {
    if (_isBusy || _isRecording) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _paperCard,
        title: const Text('حذف المذكرة؟', style: TextStyle(color: _ink)),
        content: const Text(
          'سيتم حذف المذكرة والتسجيل الصوتي المرتبط بها.',
          style: TextStyle(color: _ink),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await _player.stop();
      await _notifications.cancel(note.id);

      if (note.audioPath.isNotEmpty) {
        final f = File(note.audioPath);

        if (await f.exists()) {
          await f.delete();
        }
      }
    } catch (e) {
      debugPrint('DELETE ERROR: $e');
    }

    _notes.removeWhere((n) => n.id == note.id);

    await _store.save(_notes);

    if (mounted) {
      setState(() {});
      _showMessage('تم حذف المذكرة');
    }
  }

  // ---------- رسائل الأخطاء ----------

  Future<void> _showError(String title, String details) async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: _paperCard,
          title: Text(title, style: const TextStyle(color: _ink)),
          content: SingleChildScrollView(
            child: SelectableText(details, style: const TextStyle(color: _ink)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('حسناً'),
            ),
          ],
        ),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, textDirection: TextDirection.rtl),
          backgroundColor: _greenDark,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // ---------- تنظيف الموارد ----------

  @override
  void dispose() {
    _recorder.dispose();
    _player.dispose();
    _speech.dispose();
    _google.cancel();
    _textController.dispose();
    _searchController.dispose();

    super.dispose();
  }

  // ---------- رسالة التسجيل ----------

  String _cardMessage() {
    if (_status.isNotEmpty) return _status;

    if (_isRecording) {
      if (_engine == _Engine.google) {
        return _liveText.isEmpty ? 'أسمعك عبر الإنترنت...' : _liveText;
      }

      return 'أسمعك بدون إنترنت... اضغط إيقاف عند الانتهاء';
    }

    return 'قل مثلاً: ذكرني بموعد الطبيب الخميس الساعة 5 مساءً';
  }

  // ---------- بطاقة ورقية للمذكرة ----------

  Widget _noteCard(NoteItem n, int index) {
    final due = n.dueMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(n.dueMs!);

    final passed = due != null && due.isBefore(DateTime.now());

    String badge;
    Color badgeColor;
    IconData badgeIcon;

    if (n.isDone) {
      badge = 'مهمة مكتملة';
      badgeColor = _green;
      badgeIcon = Icons.check_circle;
    } else if (due == null) {
      badge = 'بدون موعد';
      badgeColor = _muted;
      badgeIcon = Icons.event_note;
    } else if (!n.scheduled) {
      badge = '${formatDue(due)} (لم يُضبط التنبيه)';
      badgeColor = Colors.deepOrange;
      badgeIcon = Icons.warning_amber_rounded;
    } else if (passed) {
      badge = formatDue(due);
      badgeColor = _muted;
      badgeIcon = Icons.history;
    } else {
      badge = formatDue(due);
      badgeColor = _green;
      badgeIcon = Icons.alarm;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: _paperCard,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: _line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 7,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 5,
                color: n.isDone ? _green : const Color(0xFFB6C9AC),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.menu_book_rounded,
                            color: _green,
                            size: 20,
                          ),
                          const SizedBox(width: 7),
                          const Text(
                            'مذكرتي',
                            style: TextStyle(
                              color: _green,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          if (n.audioPath.isNotEmpty)
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: 'تشغيل التسجيل',
                              onPressed: () => _play(n),
                              icon: const Icon(
                                Icons.play_circle_fill,
                                color: _blue,
                                size: 25,
                              ),
                            ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'حذف',
                            onPressed: () => _delete(n),
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.redAccent,
                              size: 22,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              n.task.isEmpty ? n.text : n.task,
                              style: GoogleFonts.arefRuqaa(
                                fontSize: 27,
                                height: 1.65,
                                color: n.isDone ? _muted : _ink,
                                decoration: n.isDone
                                    ? TextDecoration.lineThrough
                                    : TextDecoration.none,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Checkbox(
                            value: n.isDone,
                            activeColor: _green,
                            side: const BorderSide(color: _green, width: 1.5),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(5),
                            ),
                            onChanged: (_) => _toggleDone(n),
                          ),
                        ],
                      ),
                      if (n.text != n.task) ...[
                        const SizedBox(height: 5),
                        Text(
                          'النص الأصلي: ${n.text}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: _muted,
                            height: 1.5,
                          ),
                        ),
                      ],
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: Divider(color: _line, height: 1),
                      ),
                      Row(
                        children: [
                          Icon(badgeIcon, color: badgeColor, size: 17),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              badge,
                              style: TextStyle(
                                color: badgeColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- بطاقة الإحصائيات ----------

  Widget _progressCard() {
    final total = _notes.length;
    final completed = _notes.where((n) => n.isDone).length;
    final progress = total == 0 ? 0.0 : completed / total;

    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: _greenLight,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFD3E0D0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, color: _greenDark),
              const SizedBox(width: 8),
              const Text(
                'إنجازاتك اليوم',
                style: TextStyle(
                  color: _greenDark,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              const Spacer(),
              Text(
                '$completed / $total',
                style: const TextStyle(
                  color: _greenDark,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 9,
              backgroundColor: Colors.white,
              color: _green,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            total == 0
                ? 'ابدأ بكتابة أول مهمة لك'
                : completed == total
                ? 'أحسنت! أكملت جميع مهامك'
                : 'استمر، أنت تتقدم بشكل رائع',
            style: const TextStyle(color: _greenDark, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ---------- بطاقة التسجيل الورقية ----------

  Widget _recordingCard() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: _paperCard,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          const Text(
            'دع أفكارك تتحول إلى كلمات',
            style: TextStyle(
              color: _ink,
              fontSize: 19,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 7),
          const Text(
            'دفترك الذكي يستمع إليك وينظم مواعيدك',
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 25),
          GestureDetector(
            onTap: _isBusy
                ? null
                : (_isRecording ? _stopRecording : _startRecording),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 116,
              height: 116,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isRecording ? const Color(0xFFE9B9B4) : _blue,
                boxShadow: [
                  BoxShadow(
                    color: (_isRecording ? Colors.red : _blue).withValues(
                      alpha: 0.18,
                    ),
                    blurRadius: 20,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: Icon(
                _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                color: Colors.white,
                size: 52,
              ),
            ),
          ),
          const SizedBox(height: 17),
          Text(
            _cardMessage(),
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 13, height: 1.7),
          ),
          const SizedBox(height: 19),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _isBusy
                  ? null
                  : (_isRecording ? _stopRecording : _startRecording),
              icon: Icon(_isRecording ? Icons.stop_circle_outlined : Icons.mic),
              label: Text(
                _isBusy
                    ? 'يرجى الانتظار...'
                    : (_isRecording ? 'إيقاف وحفظ' : 'ابدأ تسجيل مذكرتك'),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- إعداد الإنترنت ----------

  Widget _internetCard() {
    return Container(
      decoration: BoxDecoration(
        color: _paperCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: SwitchListTile(
        value: _useInternet,
        activeThumbColor: _green,
        onChanged: _isRecording
            ? null
            : (v) {
                setState(() => _useInternet = v);
              },
        secondary: const Icon(Icons.wifi, color: _green),
        title: const Text(
          'استخدام الإنترنت لدقة أعلى',
          style: TextStyle(
            color: _ink,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: const Text(
          'يعمل دون إنترنت عند عدم توفره',
          style: TextStyle(fontSize: 11, color: _muted),
        ),
      ),
    );
  }

  // ---------- تنزيل نموذج الصوت ----------

  Widget _modelCard() {
    if (_modelReady) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _paperCard,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.cloud_download_outlined, color: _green),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'نموذج الصوت بدون إنترنت',
                  style: TextStyle(color: _ink, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'نزّل النموذج مرة واحدة لاستخدام التعرف الصوتي دون إنترنت.',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          if (_downloading) ...[
            LinearProgressIndicator(
              value: _dlProgress,
              color: _green,
              backgroundColor: _greenLight,
            ),
            const SizedBox(height: 7),
            Text(
              '${(_dlProgress * 100).toStringAsFixed(0)}% $_dlFile',
              style: const TextStyle(color: _ink, fontSize: 12),
            ),
          ] else
            FilledButton.icon(
              onPressed: _downloadModel,
              icon: const Icon(Icons.download),
              label: const Text('تنزيل النموذج'),
              style: FilledButton.styleFrom(backgroundColor: _green),
            ),
        ],
      ),
    );
  }

  // ---------- إدخال مذكرة بالكتابة ----------

  Widget _textEntry() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: _paperCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          const Icon(Icons.edit_note, color: _green, size: 26),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _textController,
              onSubmitted: (_) => _addFromText(),
              style: const TextStyle(color: _ink),
              decoration: const InputDecoration(
                hintText: 'اكتب مذكرة جديدة...',
                hintStyle: TextStyle(color: _muted),
                border: InputBorder.none,
                filled: false,
              ),
            ),
          ),
          IconButton(
            onPressed: _addFromText,
            icon: const Icon(Icons.add_circle, color: _green, size: 32),
          ),
        ],
      ),
    );
  }

  // ---------- البحث ----------

  Widget _searchBox() {
    return Container(
      decoration: BoxDecoration(
        color: _paperCard,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: _line),
      ),
      child: TextField(
        controller: _searchController,
        onChanged: (value) {
          setState(() => _searchQuery = value.trim());
        },
        style: const TextStyle(color: _ink),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search, color: _green),
          hintText: 'ابحث في مذكراتك...',
          border: InputBorder.none,
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                  icon: const Icon(Icons.close, color: _muted),
                ),
        ),
      ),
    );
  }

  // ---------- رأس قائمة المذكرات ----------

  Widget _notesHeader({
    required int upcoming,
    required List<NoteItem> filteredNotes,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'أهلاً بك 👋',
          style: GoogleFonts.arefRuqaa(
            fontSize: 31,
            color: _greenDark,
            fontWeight: FontWeight.bold,
          ),
        ),
        const Text(
          'كل فكرة تستحق أن تُكتب',
          style: TextStyle(color: _muted, fontSize: 13),
        ),
        const SizedBox(height: 19),

        _recordingCard(),
        const SizedBox(height: 15),

        _progressCard(),
        const SizedBox(height: 15),

        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _paperCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _line),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.notifications_active_outlined,
                color: _green,
                size: 25,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'التذكيرات القادمة',
                  style: TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _greenLight,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$upcoming',
                  style: const TextStyle(
                    color: _greenDark,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 13),
        _internetCard(),
        const SizedBox(height: 12),
        _modelCard(),
        const SizedBox(height: 12),
        _textEntry(),
        const SizedBox(height: 27),

        Row(
          children: [
            const Icon(Icons.menu_book_rounded, color: _green, size: 25),
            const SizedBox(width: 8),
            const Text(
              'دفتر مذكراتي',
              style: TextStyle(
                color: _greenDark,
                fontSize: 21,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            Text(
              '${_notes.length} مذكرة',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
          ],
        ),

        const SizedBox(height: 13),
        _searchBox(),
        const SizedBox(height: 15),

        if (filteredNotes.isEmpty)
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: _paperCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _line),
            ),
            child: Column(
              children: [
                const Icon(
                  Icons.auto_stories_outlined,
                  color: _green,
                  size: 48,
                ),
                const SizedBox(height: 12),
                Text(
                  _notes.isEmpty
                      ? 'دفترك ما زال فارغاً'
                      : 'لا توجد نتائج للبحث',
                  style: const TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 7),
                const Text(
                  'ابدأ بتسجيل صوتك وسأحوّله إلى مذكرة مكتوبة',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ---------- الواجهة الرئيسية ----------

  @override
  Widget build(BuildContext context) {
    final filteredNotes = _notes.where((n) {
      if (_searchQuery.isEmpty) return true;

      final q = _searchQuery.toLowerCase();

      return n.text.toLowerCase().contains(q) ||
          n.task.toLowerCase().contains(q);
    }).toList();

    final upcoming = _notes.where((n) {
      if (n.dueMs == null || !n.scheduled || n.isDone) {
        return false;
      }

      return DateTime.fromMillisecondsSinceEpoch(n.dueMs!)
          .isAfter(DateTime.now());
    }).length;

    final itemCount = filteredNotes.isEmpty ? 2 : filteredNotes.length + 2;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: _paper,
        appBar: AppBar(
          backgroundColor: _paper,
          title: Row(
            children: [
              Container(
                width: 43,
                height: 43,
                decoration: BoxDecoration(
                  color: _greenLight,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.task_alt_rounded,
                  color: _greenDark,
                  size: 28,
                ),
              ),
              const SizedBox(width: 11),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'مذكرتي',
                    style: TextStyle(
                      color: _greenDark,
                      fontWeight: FontWeight.bold,
                      fontSize: 21,
                    ),
                  ),
                  const Text(
                    'دفترك الذكي',
                    style: TextStyle(color: _muted, fontSize: 10),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            IconButton(
              onPressed: () {
                _showMessage('مرحباً بك في مذكرتي الذكية');
              },
              icon: const Icon(Icons.info_outline, color: _greenDark),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(17, 8, 17, 25),
            itemCount: itemCount,
            itemBuilder: (context, index) {
              // رأس الصفحة وجميع أدواتها
              if (index == 0) {
                return _KeepAlive(
                  child: _notesHeader(
                    upcoming: upcoming,
                    filteredNotes: filteredNotes,
                  ),
                );
              }

              // بطاقات المذكرات تُبنى عند الحاجة فقط
              if (index <= filteredNotes.length) {
                final noteIndex = index - 1;

                return _noteCard(filteredNotes[noteIndex], noteIndex);
              }

              // تذييل الصفحة
              return Padding(
                padding: const EdgeInsets.only(top: 15, bottom: 8),
                child: Center(
                  child: Text(
                    'مذكرتي الذكية • أفكارك في مكان واحد',
                    style: TextStyle(
                      color: _muted.withValues(alpha: 0.8),
                      fontSize: 11,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------- إبقاء رأس الصفحة حياً أثناء التمرير ----------

class _KeepAlive extends StatefulWidget {
  final Widget child;

  const _KeepAlive({required this.child});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// ---------- نافذة مراجعة النص ----------

class _ConfirmTextDialog extends StatefulWidget {
  final String heard;
  final ArabicReminderParser parser;

  const _ConfirmTextDialog({required this.heard, required this.parser});

  @override
  State<_ConfirmTextDialog> createState() => _ConfirmTextDialogState();
}

class _ConfirmTextDialogState extends State<_ConfirmTextDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.heard);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reminders = widget.parser.parseMultiple(_controller.text);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        backgroundColor: _paperCard,
        title: const Text(
          'راجع المهام قبل الحفظ',
          style: TextStyle(color: _ink),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _controller,
                  autofocus: true,
                  maxLines: null,
                  style: const TextStyle(color: _ink),
                  decoration: const InputDecoration(
                    hintText: 'راجع النص أو عدّله هنا',
                  ),
                  onChanged: (_) {
                    setState(() {});
                  },
                ),
                const SizedBox(height: 18),
                Text(
                  'المهام المستخرجة: ${reminders.length}',
                  style: const TextStyle(
                    color: _green,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 10),

                if (reminders.isEmpty)
                  const Text(
                    'لم يتم استخراج مهام',
                    style: TextStyle(color: _muted),
                  ),

                ...List.generate(reminders.length, (index) {
                  final reminder = reminders[index];

                  final preview = reminder.dateTime == null
                      ? 'بدون موعد'
                      : 'موعد التنبيه: ${formatDue(reminder.dateTime!)}'
                            '${reminder.timeAssumed ? ' (موعد افتراضي)' : ''}';

                  return Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _paper,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _green.withValues(alpha: 0.25)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'المهمة ${index + 1}',
                          style: const TextStyle(
                            color: _green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          reminder.task,
                          style: const TextStyle(color: _ink, fontSize: 15),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          preview,
                          style: TextStyle(
                            color: reminder.dateTime == null ? _muted : _green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _green),
            onPressed: reminders.isEmpty
                ? null
                : () {
                    Navigator.pop(context, _controller.text);
                  },
            child: const Text('حفظ جميع المهام'),
          ),
        ],
      ),
    );
  }
}

// ---------- شاشة المنبّه ----------

class AlarmPage extends StatefulWidget {
  final int id;
  final String task;
  final NotificationService service;

  const AlarmPage({
    super.key,
    required this.id,
    required this.task,
    required this.service,
  });

  @override
  State<AlarmPage> createState() => _AlarmPageState();
}

class _AlarmPageState extends State<AlarmPage> {
  bool _busy = false;

  Future<void> _stop() async {
    if (_busy) return;

    setState(() => _busy = true);

    try {
      await widget.service.cancel(widget.id);

      if (!mounted) return;

      Navigator.of(context).pop();
    } catch (e) {
      debugPrint('STOP ERROR: $e');

      if (!mounted) return;

      setState(() => _busy = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر إيقاف التنبيه. حاول مرة أخرى')),
      );
    }
  }

  // الغفوة: الخدمة نفسها تلغي التنبيه القديم وتعيد جدولة
  // التنبيه بعد خمس دقائق. لا نلغي التنبيه هنا مرة ثانية.
  Future<void> _snooze() async {
    if (_busy) return;

    setState(() => _busy = true);

    try {
      await widget.service.snoozeNow(widget.id, widget.task);

      if (!mounted) return;

      Navigator.of(context).pop();
    } catch (e) {
      debugPrint('SNOOZE ERROR: $e');

      if (!mounted) return;

      setState(() => _busy = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('تعذرت جدولة الغفوة: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: _paper,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 130,
                  height: 130,
                  decoration: const BoxDecoration(
                    color: _greenLight,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.alarm, color: _greenDark, size: 75),
                ),
                const SizedBox(height: 25),
                const Text(
                  'حان موعد التذكير',
                  style: TextStyle(
                    color: _greenDark,
                    fontSize: 21,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  widget.task,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.arefRuqaa(
                    fontSize: 40,
                    height: 1.5,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 48),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _stop,
                    style: FilledButton.styleFrom(
                      backgroundColor: _green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                    ),
                    child: Text(
                      _busy ? 'يرجى الانتظار...' : 'إيقاف',
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _busy ? null : _snooze,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _greenDark,
                      side: const BorderSide(color: _green),
                      padding: const EdgeInsets.symmetric(vertical: 18),
                    ),
                    child: Text(
                      _busy
                          ? 'جارٍ ضبط الغفوة...'
                          : 'غفوة $kSnoozeMinutes دقائق',
                      style: const TextStyle(fontSize: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
