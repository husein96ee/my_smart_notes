
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class NoteItem {
  final int id;
  final String text;
  final String task;
  final int? dueMs;
  final bool scheduled;
  final String audioPath;
  final int createdMs;
  final bool isDone;

  const NoteItem({
    required this.id,
    required this.text,
    required this.task,
    required this.dueMs,
    required this.scheduled,
    required this.audioPath,
    required this.createdMs,
    this.isDone = false,
  });

  NoteItem copyWith({
    bool? isDone,
    bool? scheduled,
    int? dueMs,
  }) {
    return NoteItem(
      id: id,
      text: text,
      task: task,
      dueMs: dueMs ?? this.dueMs,
      scheduled: scheduled ?? this.scheduled,
      audioPath: audioPath,
      createdMs: createdMs,
      isDone: isDone ?? this.isDone,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'task': task,
        'dueMs': dueMs,
        'scheduled': scheduled,
        'audioPath': audioPath,
        'createdMs': createdMs,
        'isDone': isDone,
      };

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  static bool _toBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      return value.toLowerCase() == 'true' || value == '1';
    }
    return false;
  }

  factory NoteItem.fromJson(Map<String, dynamic> j) {
    final id = _toInt(j['id']);

    if (id == null) {
      throw const FormatException(
        'المذكرة لا تحتوي على رقم تعريف صحيح',
      );
    }

    return NoteItem(
      id: id,
      text: j['text']?.toString() ?? '',
      task: j['task']?.toString() ??
          j['text']?.toString() ?? '',
      dueMs: _toInt(j['dueMs']),
      scheduled: _toBool(j['scheduled']),
      audioPath: j['audioPath']?.toString() ?? '',
      createdMs: _toInt(j['createdMs']) ?? 0,
      isDone: _toBool(j['isDone']),
    );
  }
}

class NotesStore {
  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();

    return File(
      '${dir.path}${Platform.pathSeparator}notes_data.json',
    );
  }

  Future<List<NoteItem>> _readNotes(File file) async {
    final content = await file.readAsString();

    if (content.trim().isEmpty) return [];

    final decoded = jsonDecode(content);

    if (decoded is! List) {
      throw const FormatException(
        'تنسيق ملف المذكرات غير صحيح',
      );
    }

    final notes = <NoteItem>[];

    for (final item in decoded) {
      try {
        if (item is Map) {
          notes.add(
            NoteItem.fromJson(
              Map<String, dynamic>.from(item),
            ),
          );
        }
      } catch (e) {
        debugPrint('تعذر قراءة مذكرة واحدة: $e');
      }
    }

    return notes;
  }

  Future<List<NoteItem>> load() async {
    final file = await _file();

    if (!await file.exists()) return [];

    try {
      return await _readNotes(file);
    } catch (e) {
      debugPrint('خطأ في قراءة المذكرات: $e');

      final backup = File('${file.path}.bak');

      if (await backup.exists()) {
        try {
          final recovered = await _readNotes(backup);
          debugPrint(
            'تمت استعادة المذكرات من النسخة الاحتياطية',
          );
          return recovered;
        } catch (backupError) {
          debugPrint(
            'تعذرت قراءة النسخة الاحتياطية: $backupError',
          );
        }
      }

      rethrow;
    }
  }

  Future<void> save(List<NoteItem> notes) async {
    final file = await _file();
    final tempFile = File('${file.path}.tmp');
    final backupFile = File('${file.path}.bak');

    final json = jsonEncode(
      notes.map((note) => note.toJson()).toList(),
    );

    await tempFile.writeAsString(json, flush: true);

    if (await file.exists()) {
      await file.copy(backupFile.path);
    }

    await tempFile.rename(file.path);
  }
}
