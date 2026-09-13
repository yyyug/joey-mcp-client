import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SpeechService {
  static const MethodChannel _channel = MethodChannel(
    'com.kaiserapps.joey/speech',
  );

  static bool get _isSupported => !kIsWeb && Platform.isIOS;

  static Future<void> speak(String text) async {
    if (!_isSupported || text.trim().isEmpty) return;
    try {
      await _channel.invokeMethod<bool>('speak', text);
    } on PlatformException {
      // Silently fail - speech is best-effort
    } on MissingPluginException {
      // Channel not available (e.g. on simulator or non-iOS)
    }
  }

  static Future<void> stop() async {
    if (!_isSupported) return;
    try {
      await _channel.invokeMethod<bool>('stop');
    } on PlatformException {
      // Silently fail
    } on MissingPluginException {
      // Channel not available
    }
  }

  static Future<void> pause() async {
    if (!_isSupported) return;
    try {
      await _channel.invokeMethod<bool>('pause');
    } on PlatformException {
      // Silently fail
    } on MissingPluginException {
      // Channel not available
    }
  }

  static Future<void> resume() async {
    if (!_isSupported) return;
    try {
      await _channel.invokeMethod<bool>('resume');
    } on PlatformException {
      // Silently fail
    } on MissingPluginException {
      // Channel not available
    }
  }

  static Future<bool> isSpeaking() async {
    if (!_isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isSpeaking') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static String stripMarkdown(String text) {
    return text
        .replaceAll(RegExp(r'#{1,6}\s'), '')
        .replaceAll(RegExp(r'\*\*([^*]+)\*\*'), r'$1')
        .replaceAll(RegExp(r'\*([^*]+)\*'), r'$1')
        .replaceAll(RegExp(r'__([^_]+)__'), r'$1')
        .replaceAll(RegExp(r'_([^_]+)_'), r'$1')
        .replaceAll(RegExp(r'`([^`]+)`'), r'$1')
        .replaceAll(RegExp(r'```[\s\S]*?```'), '')
        .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1')
        .replaceAll(RegExp(r'!\[([^\]]*)\]\([^]+)'), '')
        .replaceAll(RegExp(r'^\s*[-*+]\s', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*\d+\.\s', multiLine: true), '')
        .replaceAll(RegExp(r'>\s'), '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }
}
