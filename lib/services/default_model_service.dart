import 'package:shared_preferences/shared_preferences.dart';

class DefaultModelService {
  static const String _defaultModelKey = 'default_model';
  static const String _providerTypeKey = 'ai_provider_type';
  static const String _providerOpenRouter = 'openrouter';
  static const String _providerOpenAICompatible = 'openai_compatible';
  static const String _autoTitleKey = 'auto_title_enabled';
  static const String _systemPromptKey = 'system_prompt';
  static const String _showThinkingKey = 'show_thinking';
  static const String _maxToolCallsKey = 'max_tool_calls';
  static const String _speechEnabledKey = 'speech_enabled';
  static const int _defaultMaxToolCalls = 10;
  static const String _defaultSystemPrompt =
      'You are a helpful assistant.\nUse markdown when rendering your responses.';

  static Future<String?> getDefaultModel() async {
    final prefs = await SharedPreferences.getInstance();
    final providerType = await _providerType(prefs);
    return prefs.getString(_providerDefaultModelKey(providerType)) ??
        (providerType == _providerOpenRouter
            ? prefs.getString(_defaultModelKey)
            : null);
  }

  static Future<void> setDefaultModel(String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _providerDefaultModelKey(await _providerType(prefs)),
      modelId,
    );
    await prefs.setString(_defaultModelKey, modelId);
  }

  static Future<void> clearDefaultModel() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_providerDefaultModelKey(await _providerType(prefs)));
    await prefs.remove(_defaultModelKey);
  }

  static Future<String> _providerType(SharedPreferences prefs) async {
    return prefs.getString(_providerTypeKey) ?? _providerOpenRouter;
  }

  static String _providerDefaultModelKey(String providerType) {
    return providerType == _providerOpenAICompatible
        ? 'default_model_openai_compatible'
        : 'default_model_openrouter';
  }

  static Future<bool> getAutoTitleEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoTitleKey) ?? true; // Default to true
  }

  static Future<void> setAutoTitleEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoTitleKey, enabled);
  }

  static Future<String> getSystemPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_systemPromptKey) ?? _defaultSystemPrompt;
  }

  static Future<void> setSystemPrompt(String prompt) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_systemPromptKey, prompt);
  }

  static Future<void> resetSystemPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_systemPromptKey);
  }

  static Future<bool> getShowThinking() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showThinkingKey) ?? true; // Default to true
  }

  static Future<void> setShowThinking(bool show) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showThinkingKey, show);
  }

  /// Get max tool calls per message. 0 means unlimited.
  static Future<int> getMaxToolCalls() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_maxToolCallsKey) ?? _defaultMaxToolCalls;
  }

  /// Set max tool calls per message. 0 means unlimited.
  static Future<void> setMaxToolCalls(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_maxToolCallsKey, value);
  }

  /// Get whether speech announcement is enabled. Default true.
  static Future<bool> getSpeechEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_speechEnabledKey) ?? true;
  }

  /// Set whether speech announcement is enabled.
  static Future<void> setSpeechEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_speechEnabledKey, enabled);
  }
}
