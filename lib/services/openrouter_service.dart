import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import 'dart:math';

/// Redact large base64 data (images/audio) from request data before logging
String _redactedRequestBody(Map<String, dynamic> requestData) {
  final redacted = jsonDecode(jsonEncode(requestData));
  if (redacted['messages'] is List) {
    for (final msg in redacted['messages']) {
      final content = msg['content'];
      if (content is List) {
        for (final part in content) {
          if (part is Map) {
            // Redact image_url data URIs
            if (part['type'] == 'image_url' && part['image_url'] is Map) {
              final url = part['image_url']['url'] as String? ?? '';
              if (url.startsWith('data:')) {
                part['image_url']['url'] =
                    '${url.substring(0, url.indexOf(',') + 1)}[REDACTED ${url.length} chars]';
              }
            }
            // Redact input_audio data
            if (part['type'] == 'input_audio' && part['input_audio'] is Map) {
              final data = part['input_audio']['data'] as String? ?? '';
              part['input_audio']['data'] = '[REDACTED ${data.length} chars]';
            }
          }
        }
      }
    }
  }
  return jsonEncode(redacted);
}

/// Extract a human-readable error message from an API error body.
///
/// Accepts either a decoded JSON value or the raw response body string, and
/// understands the shapes used by OpenRouter and OpenAI-compatible providers:
/// `{"error": {"message": "..."}}`, `{"error": {"metadata": {"raw": "..."}}}`,
/// and plain `{"message": "..."}`. Returns null when nothing useful is found.
String? _extractApiErrorMessage(dynamic data) {
  dynamic decoded = data;
  if (decoded is String) {
    final trimmed = decoded.trim();
    if (trimmed.isEmpty) return null;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return trimmed;
    }
  }

  if (decoded is Map) {
    final error = decoded['error'];
    if (error is Map) {
      final raw = error['metadata']?['raw'];
      if (raw is String && raw.trim().isNotEmpty) return raw.trim();
      final message = error['message'];
      if (message is String && message.trim().isNotEmpty) {
        return message.trim();
      }
    }
    if (error is String && error.trim().isNotEmpty) return error.trim();
    final message = decoded['message'];
    if (message is String && message.trim().isNotEmpty) return message.trim();
  }

  return null;
}

/// Exception thrown when authentication fails (e.g., expired token)
class OpenRouterAuthException implements Exception {
  final String message;
  OpenRouterAuthException(this.message);

  @override
  String toString() => 'OpenRouterAuthException: $message';
}

/// Exception thrown when the user has insufficient credits (HTTP 402)
class OpenRouterPaymentRequiredException implements Exception {
  final String message;
  OpenRouterPaymentRequiredException(this.message);

  @override
  String toString() => 'OpenRouterPaymentRequiredException: $message';
}

/// Exception thrown when a rate limit is hit (HTTP 429)
class OpenRouterRateLimitException implements Exception {
  final String message;
  OpenRouterRateLimitException(this.message);

  @override
  String toString() => 'OpenRouterRateLimitException: $message';
}

class OpenRouterService {
  static const String _apiKeyKey = 'openrouter_api_key';
  static const String _providerTypeKey = 'ai_provider_type';
  static const String _byoBaseUrlKey = 'byo_openai_base_url';
  static const String _byoTokenKey = 'byo_openai_token';
  static const String _byoHeadersKey = 'byo_openai_headers';
  static const String _providerOpenRouter = 'openrouter';
  static const String _providerOpenAICompatible = 'openai_compatible';
  static const String _authUrl = 'https://openrouter.ai/auth';
  static const String _keysUrl = 'https://openrouter.ai/api/v1/auth/keys';
  static const String _callbackUrl =
      'https://openrouterauth.benkaiser.dev/api/auth';

  final Dio _dio = Dio();
  String? _codeVerifier;

  /// Check if user is authenticated
  Future<bool> isAuthenticated() async {
    final prefs = await SharedPreferences.getInstance();
    final provider = prefs.getString(_providerTypeKey) ?? _providerOpenRouter;
    if (provider == _providerOpenAICompatible) {
      final baseUrl = prefs.getString(_byoBaseUrlKey);
      return baseUrl != null && baseUrl.trim().isNotEmpty;
    }
    final apiKey = prefs.getString(_apiKeyKey);
    return apiKey != null && apiKey.isNotEmpty;
  }

  Future<bool> isUsingOpenAICompatibleProvider() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_providerTypeKey) == _providerOpenAICompatible;
  }

  Future<String> getProviderDisplayName() async {
    return await isUsingOpenAICompatibleProvider()
        ? 'OpenAI Compatible API'
        : 'OpenRouter';
  }

  Future<Map<String, dynamic>?> getOpenAICompatibleConfigForDisplay() async {
    if (!await isUsingOpenAICompatibleProvider()) return null;
    final config = await _getOpenAICompatibleConfig();
    return {
      'baseUrl': config.baseUrl,
      'bearerToken': config.bearerToken,
      'headers': config.headers,
    };
  }

  /// Get the stored API key
  Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_apiKeyKey);
  }

  /// Clear the stored API key (logout)
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_apiKeyKey);
    await prefs.remove(_providerTypeKey);
    await prefs.remove(_byoBaseUrlKey);
    await prefs.remove(_byoTokenKey);
    await prefs.remove(_byoHeadersKey);
  }

  Future<void> saveOpenAICompatibleConfig({
    required String baseUrl,
    String? bearerToken,
    Map<String, String>? headers,
  }) async {
    final normalizedBaseUrl = _normalizeBaseUrl(baseUrl);
    await validateOpenAICompatibleConfig(
      baseUrl: normalizedBaseUrl,
      bearerToken: bearerToken,
      headers: headers,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_providerTypeKey, _providerOpenAICompatible);
    await prefs.setString(_byoBaseUrlKey, normalizedBaseUrl);
    if (bearerToken != null && bearerToken.trim().isNotEmpty) {
      await prefs.setString(_byoTokenKey, bearerToken.trim());
    } else {
      await prefs.remove(_byoTokenKey);
    }
    if (headers != null && headers.isNotEmpty) {
      await prefs.setString(_byoHeadersKey, jsonEncode(headers));
    } else {
      await prefs.remove(_byoHeadersKey);
    }
  }

  Future<List<Map<String, dynamic>>> validateOpenAICompatibleConfig({
    required String baseUrl,
    String? bearerToken,
    Map<String, String>? headers,
  }) async {
    final normalizedBaseUrl = _normalizeBaseUrl(baseUrl);
    final response = await _dio.get(
      _endpointUrl(normalizedBaseUrl, 'models'),
      options: Options(
        headers: _providerHeaders(
          provider: _providerOpenAICompatible,
          bearerToken: bearerToken,
          customHeaders: headers,
        ),
      ),
    );
    return _parseModelsResponse(response.data);
  }

  /// Generate a random code verifier (43-128 characters)
  String _generateCodeVerifier() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(
      128,
      (index) => chars[random.nextInt(chars.length)],
    ).join();
  }

  /// Generate SHA-256 code challenge from code verifier
  String _generateCodeChallenge(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes);
    // Convert to base64url (RFC 4648)
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  /// Start the OAuth flow and return the authorization URL
  String startAuthFlow() {
    // Generate and store code verifier
    _codeVerifier = _generateCodeVerifier();

    // Generate code challenge
    final codeChallenge = _generateCodeChallenge(_codeVerifier!);

    // Build authorization URL
    final encodedCallbackUrl = Uri.encodeComponent(_callbackUrl);
    final url =
        '$_authUrl?callback_url=$encodedCallbackUrl&code_challenge=$codeChallenge&code_challenge_method=S256';

    return url;
  }

  /// Exchange authorization code for API key
  Future<String> exchangeCodeForKey(String code) async {
    if (_codeVerifier == null) {
      throw Exception('Code verifier not found. Please restart the auth flow.');
    }

    try {
      final response = await _dio.post(
        _keysUrl,
        data: {
          'code': code,
          'code_verifier': _codeVerifier,
          'code_challenge_method': 'S256',
        },
        options: Options(headers: {'Content-Type': 'application/json'}),
      );

      if (response.statusCode == 200 && response.data != null) {
        final key = response.data['key'] as String?;
        if (key == null || key.isEmpty) {
          print(
            'OpenRouter: exchangeCodeForKey failed - no key in response: ${response.data}',
          );
          throw Exception('Invalid response: API key not found');
        }

        // Store the API key
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_apiKeyKey, key);
        await prefs.setString(_providerTypeKey, _providerOpenRouter);

        // Clear the code verifier
        _codeVerifier = null;

        return key;
      } else {
        print(
          'OpenRouter: exchangeCodeForKey failed with status ${response.statusCode}: ${response.data}',
        );
        throw Exception('Failed to exchange code: ${response.statusCode}');
      }
    } on DioException catch (e) {
      print('OpenRouter: exchangeCodeForKey DioException:');
      print('  Status: ${e.response?.statusCode}');
      print('  Response: ${e.response?.data}');
      print('  Message: ${e.message}');
      throw Exception('Error exchanging code for key: ${e.message}');
    } catch (e) {
      print('OpenRouter: exchangeCodeForKey unexpected error: $e');
      throw Exception('Error exchanging code for key: $e');
    }
  }

  /// Make a chat completion request to OpenRouter
  Future<Map<String, dynamic>> chatCompletion({
    required String model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    dynamic toolChoice,
    bool stream = false,
    int? maxTokens,
  }) async {
    final apiKey = await getApiKey();
    final provider = await _getProviderType();
    final byoConfig = provider == _providerOpenAICompatible
        ? await _getOpenAICompatibleConfig()
        : null;
    if (provider == _providerOpenRouter && apiKey == null) {
      throw Exception('Not authenticated. Please log in first.');
    }

    try {
      final requestData = {
        'model': model,
        'messages': messages,
        'stream': stream,
      };

      if (tools != null && tools.isNotEmpty) {
        requestData['tools'] = tools;
      }

      if (toolChoice != null) {
        requestData['tool_choice'] = toolChoice;
      }

      if (maxTokens != null) {
        requestData['max_tokens'] = maxTokens;
      }

      print(
        'OpenRouter: Full request body: ${_redactedRequestBody(requestData)}',
      );

      final response = await _dio.post(
        _chatCompletionsUrl(provider, byoConfig?.baseUrl),
        data: requestData,
        options: Options(
          headers: _providerHeaders(
            provider: provider,
            apiKey: apiKey,
            bearerToken: byoConfig?.bearerToken,
            customHeaders: byoConfig?.headers,
          ),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        return response.data as Map<String, dynamic>;
      } else {
        print(
          'OpenRouter: chatCompletion failed with status ${response.statusCode}: ${response.data}',
        );
        throw Exception('Chat completion failed: ${response.statusCode}');
      }
    } on DioException catch (e) {
      print('OpenRouter: chatCompletion DioException:');
      print('  Status: ${e.response?.statusCode}');
      print('  Response: ${e.response?.data}');
      print('  Message: ${e.message}');
      if (e.response?.statusCode == 401) {
        // Token expired or invalid - clear it and prompt re-auth
        print('OpenRouter: 401 Unauthorized - clearing token');
        await logout();
        throw OpenRouterAuthException(
          'Authentication expired. Please log in again.',
        );
      }
      if (e.response?.statusCode == 402) {
        print('OpenRouter: 402 Payment Required - insufficient credits');
        throw OpenRouterPaymentRequiredException(
          'Insufficient credits. Please add credits to your OpenRouter account.',
        );
      }
      if (e.response?.statusCode == 429) {
        print('OpenRouter: 429 Rate Limited');
        String message = 'Rate limited. Please wait a moment and try again.';
        try {
          final responseData = e.response?.data;
          if (responseData is Map) {
            final raw = responseData['error']?['metadata']?['raw'];
            if (raw is String && raw.isNotEmpty) {
              message = raw;
            }
          }
        } catch (_) {}
        throw OpenRouterRateLimitException(message);
      }
      final serverMessage = _extractApiErrorMessage(e.response?.data);
      if (serverMessage != null) {
        final status = e.response?.statusCode;
        throw Exception(
          'Chat completion failed${status != null ? ' ($status)' : ''}: $serverMessage',
        );
      }
      throw Exception('Error making chat completion request: ${e.message}');
    } catch (e) {
      print('OpenRouter: chatCompletion unexpected error: $e');
      throw Exception('Error making chat completion request: $e');
    }
  }

  /// Make a streaming chat completion request to OpenRouter
  Stream<String> chatCompletionStream({
    required String model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async* {
    final apiKey = await getApiKey();
    final provider = await _getProviderType();
    final byoConfig = provider == _providerOpenAICompatible
        ? await _getOpenAICompatibleConfig()
        : null;
    if (provider == _providerOpenRouter && apiKey == null) {
      throw Exception('Not authenticated. Please log in first.');
    }

    try {
      final requestData = {
        'model': model,
        'messages': messages,
        'stream': true,
      };

      if (tools != null && tools.isNotEmpty) {
        requestData['tools'] = tools;
      }

      print(
        'OpenRouter: Full request body: ${_redactedRequestBody(requestData)}',
      );

      final response = await _dio.post<ResponseBody>(
        _chatCompletionsUrl(provider, byoConfig?.baseUrl),
        data: requestData,
        options: Options(
          headers: _providerHeaders(
            provider: provider,
            apiKey: apiKey,
            bearerToken: byoConfig?.bearerToken,
            customHeaders: byoConfig?.headers,
          ),
          responseType: ResponseType.stream,
        ),
        cancelToken: cancelToken,
      );

      if (response.statusCode == 200 && response.data != null) {
        final stream = response.data!.stream;
        String buffer = '';
        List<Map<String, dynamic>> accumulatedToolCalls = [];
        Map<String, dynamic>? lastUsage;
        bool contentFinished = false;

        await for (final chunk in stream) {
          final text = utf8.decode(chunk);
          buffer += text;

          // Process complete lines
          final lines = buffer.split('\n');
          buffer = lines.last; // Keep incomplete line in buffer

          for (int i = 0; i < lines.length - 1; i++) {
            final line = lines[i].trim();

            // Skip keep-alive comments and empty lines
            if (line.isEmpty ||
                line == ': OPENROUTER PROCESSING' ||
                !line.startsWith('data: ')) {
              continue;
            }

            final data = line.substring(6); // Remove 'data: ' prefix
            if (data == '[DONE]') {
              // Emit accumulated tool calls if any
              if (accumulatedToolCalls.isNotEmpty) {
                yield 'TOOL_CALLS:${jsonEncode(accumulatedToolCalls)}';
                accumulatedToolCalls = [];
              }
              // Emit usage data if captured
              if (lastUsage != null) {
                yield 'USAGE:${jsonEncode(lastUsage)}';
              }
              return; // Stream is done, exit the generator
            }

            try {
              final json = jsonDecode(data) as Map<String, dynamic>;

              // Check for errors in the chunk
              final error = json['error'];
              if (error != null) {
                throw Exception('Provider error: ${jsonEncode(error)}');
              }

              // Capture usage data from any chunk.
              // OpenRouter sends usage in a separate final chunk with empty
              // choices[], right before [DONE]. We must not exit early on
              // finishReason so we can still receive this chunk.
              final usage = json['usage'] as Map<String, dynamic>?;
              if (usage != null) {
                lastUsage = usage;
              }

              // If content is already finished, skip choices processing
              // (we're just waiting for usage / [DONE])
              if (contentFinished) continue;

              final choices = json['choices'] as List<dynamic>?;
              if (choices != null && choices.isNotEmpty) {
                final choice = choices[0] as Map<String, dynamic>;
                final delta = choice['delta'] as Map<String, dynamic>?;
                final finishReason = choice['finish_reason'];

                // Check for tool calls in delta
                final toolCallsDeltas = delta?['tool_calls'] as List<dynamic>?;
                if (toolCallsDeltas != null && toolCallsDeltas.isNotEmpty) {
                  for (final toolCallDelta in toolCallsDeltas) {
                    final tcMap = toolCallDelta as Map<String, dynamic>;
                    final index = tcMap['index'] as int? ?? 0;

                    // Ensure we have space in the array
                    while (accumulatedToolCalls.length <= index) {
                      accumulatedToolCalls.add({
                        'id': '',
                        'type': 'function',
                        'function': {'name': '', 'arguments': ''},
                      });
                    }

                    // Accumulate tool call data
                    if (tcMap['id'] != null) {
                      accumulatedToolCalls[index]['id'] = tcMap['id'];
                    }
                    if (tcMap['type'] != null) {
                      accumulatedToolCalls[index]['type'] = tcMap['type'];
                    }

                    final functionDelta =
                        tcMap['function'] as Map<String, dynamic>?;
                    if (functionDelta != null) {
                      final currentFunction =
                          accumulatedToolCalls[index]['function']
                              as Map<String, dynamic>;
                      if (functionDelta['name'] != null) {
                        currentFunction['name'] =
                            (currentFunction['name'] as String) +
                            (functionDelta['name'] as String);
                      }
                      if (functionDelta['arguments'] != null) {
                        currentFunction['arguments'] =
                            (currentFunction['arguments'] as String) +
                            (functionDelta['arguments'] as String);
                      }
                    }
                  }
                }

                // Check for reasoning_details array (OpenRouter's structured format)
                final reasoningDetails =
                    delta?['reasoning_details'] as List<dynamic>?;
                if (reasoningDetails != null && reasoningDetails.isNotEmpty) {
                  for (final detail in reasoningDetails) {
                    final detailMap = detail as Map<String, dynamic>;
                    final type = detailMap['type'] as String?;

                    // Extract text from different reasoning types
                    String? reasoningText;
                    if (type == 'reasoning.text') {
                      reasoningText = detailMap['text'] as String?;
                    } else if (type == 'reasoning.summary') {
                      reasoningText = detailMap['summary'] as String?;
                    }

                    if (reasoningText != null && reasoningText.isNotEmpty) {
                      yield 'REASONING:$reasoningText';
                    }
                  }
                }

                // Check for reasoning_content field (used by some models like DeepSeek)
                final reasoningContent = delta?['reasoning_content'] as String?;
                if (reasoningContent != null && reasoningContent.isNotEmpty) {
                  yield 'REASONING:$reasoningContent';
                }

                // Also check for regular content
                final content = delta?['content'] as String?;
                if (content != null && content.isNotEmpty) {
                  yield content;
                }

                // When finishReason is set, content streaming is done but
                // we must NOT return yet — the usage chunk with empty choices
                // arrives after this. Mark content as finished and continue
                // the loop to capture usage before [DONE].
                if (finishReason != null) {
                  contentFinished = true;
                }
              }
            } catch (e) {
              print('OpenRouter: Failed to parse JSON line: $line');
              print('  Error: $e');
              // Skip invalid JSON lines
              continue;
            }
          }
        }

        // Stream ended without [DONE] — emit anything still pending
        if (accumulatedToolCalls.isNotEmpty) {
          yield 'TOOL_CALLS:${jsonEncode(accumulatedToolCalls)}';
        }
        if (lastUsage != null) {
          yield 'USAGE:${jsonEncode(lastUsage)}';
        }
      } else {
        print(
          'OpenRouter: chatCompletionStream failed with status ${response.statusCode}',
        );
        throw Exception('Chat completion failed: ${response.statusCode}');
      }
    } on DioException catch (e) {
      // Handle cancellation gracefully - don't throw an error
      if (e.type == DioExceptionType.cancel) {
        print('OpenRouter: Request cancelled by user');
        return; // Exit the stream generator without error
      }

      print('OpenRouter: chatCompletionStream DioException:');
      print('  Status: ${e.response?.statusCode}');
      print('  Response type: ${e.response?.data.runtimeType}');

      // Try to read the response body if it's a stream
      String? errorBodyText;
      if (e.response?.data is ResponseBody) {
        try {
          final responseBody = e.response!.data as ResponseBody;
          final chunks = await responseBody.stream.toList();
          final bytes = chunks.expand((chunk) => chunk).toList();
          errorBodyText = utf8.decode(bytes);
          print('  Response body: $errorBodyText');
        } catch (readError) {
          print('  Failed to read response body: $readError');
        }
      } else {
        print('  Response data: ${e.response?.data}');
      }

      print('  Message: ${e.message}');
      print('  Request data: ${e.requestOptions.data}');

      if (e.response?.statusCode == 401) {
        // Token expired or invalid - clear it and prompt re-auth
        print('OpenRouter: 401 Unauthorized - clearing token');
        await logout();
        throw OpenRouterAuthException(
          'Authentication expired. Please log in again.',
        );
      }
      if (e.response?.statusCode == 402) {
        print('OpenRouter: 402 Payment Required - insufficient credits');
        throw OpenRouterPaymentRequiredException(
          'Insufficient credits. Please add credits to your OpenRouter account.',
        );
      }
      if (e.response?.statusCode == 429) {
        print('OpenRouter: 429 Rate Limited');
        final message =
            _extractApiErrorMessage(errorBodyText ?? e.response?.data) ??
            'Rate limited. Please wait a moment and try again.';
        throw OpenRouterRateLimitException(message);
      }
      final serverMessage = _extractApiErrorMessage(
        errorBodyText ?? e.response?.data,
      );
      if (serverMessage != null) {
        final status = e.response?.statusCode;
        throw Exception(
          'Chat completion failed${status != null ? ' ($status)' : ''}: $serverMessage',
        );
      }
      throw Exception(
        'Error making streaming chat completion request: ${e.message}',
      );
    } catch (e) {
      print('OpenRouter: chatCompletionStream unexpected error: $e');
      throw Exception('Error making streaming chat completion request: $e');
    }
  }

  /// Fetch available models from OpenRouter
  Future<List<Map<String, dynamic>>> getModels() async {
    final apiKey = await getApiKey();
    final provider = await _getProviderType();
    final byoConfig = provider == _providerOpenAICompatible
        ? await _getOpenAICompatibleConfig()
        : null;
    if (provider == _providerOpenRouter && apiKey == null) {
      throw Exception('Not authenticated. Please log in first.');
    }

    try {
      final response = await _dio.get(
        _modelsUrl(provider, byoConfig?.baseUrl),
        options: Options(
          headers: _providerHeaders(
            provider: provider,
            apiKey: apiKey,
            bearerToken: byoConfig?.bearerToken,
            customHeaders: byoConfig?.headers,
          ),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        return _parseModelsResponse(response.data);
      } else {
        print(
          'OpenRouter: getModels failed with status ${response.statusCode}: ${response.data}',
        );
        throw Exception('Failed to fetch models: ${response.statusCode}');
      }
    } on DioException catch (e) {
      print('OpenRouter: getModels DioException:');
      print('  Status: ${e.response?.statusCode}');
      print('  Response: ${e.response?.data}');
      print('  Message: ${e.message}');
      if (e.response?.statusCode == 401) {
        // Token expired or invalid - clear it and prompt re-auth
        print('OpenRouter: 401 Unauthorized - clearing token');
        await logout();
        throw OpenRouterAuthException(
          'Authentication expired. Please log in again.',
        );
      }
      throw Exception('Error fetching models: ${e.message}');
    } catch (e) {
      print('OpenRouter: getModels unexpected error: $e');
      throw Exception('Error fetching models: $e');
    }
  }

  Future<String> _getProviderType() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_providerTypeKey) ?? _providerOpenRouter;
  }

  Future<_OpenAICompatibleConfig> _getOpenAICompatibleConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = prefs.getString(_byoBaseUrlKey);
    if (baseUrl == null || baseUrl.trim().isEmpty) {
      throw Exception('OpenAI-compatible API is not configured.');
    }
    final headersJson = prefs.getString(_byoHeadersKey);
    Map<String, String> headers = {};
    if (headersJson != null && headersJson.isNotEmpty) {
      final decoded = jsonDecode(headersJson) as Map<String, dynamic>;
      headers = decoded.map((key, value) => MapEntry(key, value.toString()));
    }
    return _OpenAICompatibleConfig(
      baseUrl: baseUrl,
      bearerToken: prefs.getString(_byoTokenKey),
      headers: headers,
    );
  }

  String _normalizeBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      throw Exception('Base URL is required.');
    }
    final uri = Uri.parse(trimmed);
    if (!uri.hasScheme || !uri.hasAuthority) {
      throw Exception('Base URL must include a scheme and host.');
    }
    return trimmed.replaceAll(RegExp(r'/+$'), '');
  }

  String _endpointUrl(String baseUrl, String endpoint) {
    return '${_normalizeBaseUrl(baseUrl)}/$endpoint';
  }

  String _chatCompletionsUrl(String provider, String? baseUrl) {
    if (provider == _providerOpenAICompatible) {
      return _endpointUrl(baseUrl!, 'chat/completions');
    }
    return 'https://openrouter.ai/api/v1/chat/completions';
  }

  String _modelsUrl(String provider, String? baseUrl) {
    if (provider == _providerOpenAICompatible) {
      return _endpointUrl(baseUrl!, 'models');
    }
    return 'https://openrouter.ai/api/v1/models';
  }

  Map<String, String> _providerHeaders({
    required String provider,
    String? apiKey,
    String? bearerToken,
    Map<String, String>? customHeaders,
  }) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (provider == _providerOpenAICompatible) {
      if (bearerToken != null && bearerToken.trim().isNotEmpty) {
        headers['Authorization'] = 'Bearer ${bearerToken.trim()}';
      }
      headers.addAll(customHeaders ?? {});
    } else {
      if (apiKey != null) {
        headers['Authorization'] = 'Bearer $apiKey';
      }
      headers['HTTP-Referer'] =
          'https://github.com/benkaiser/joey-mcp-client-flutter';
      headers['X-Title'] = 'Joey MCP Client';
    }
    return headers;
  }

  List<Map<String, dynamic>> _parseModelsResponse(dynamic responseData) {
    if (responseData is! Map || responseData['data'] is! List) {
      throw Exception('Invalid models response: expected data array.');
    }
    final data = responseData['data'] as List<dynamic>;
    return data.map((raw) {
      final model = Map<String, dynamic>.from(raw as Map);
      final id = model['id']?.toString() ?? model['name']?.toString();
      if (id == null || id.isEmpty) {
        throw Exception('Invalid model entry: missing id.');
      }
      model['id'] = id;
      model['name'] ??= id;
      model['architecture'] ??= {
        'input_modalities': ['text'],
        'output_modalities': ['text'],
      };
      return model;
    }).toList();
  }
}

class _OpenAICompatibleConfig {
  final String baseUrl;
  final String? bearerToken;
  final Map<String, String> headers;

  _OpenAICompatibleConfig({
    required this.baseUrl,
    required this.bearerToken,
    required this.headers,
  });
}
