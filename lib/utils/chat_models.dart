/// UI labels + provider model ids for the chat composer (Cursor-style picker).
/// [priceInPerM] / [priceOutPerM] are approximate list prices in USD per 1M tokens (same unit as server cost estimates).
class ChatModelChoice {
  final String label;
  final String id;

  /// Short tier hint for subtitle (not exact pricing).
  final String? tier;
  final double priceInPerM;
  final double priceOutPerM;

  const ChatModelChoice({
    required this.label,
    required this.id,
    this.tier,
    required this.priceInPerM,
    required this.priceOutPerM,
  });

  /// e.g. `3.00/15.00 in/out` (USD / 1M tokens).
  String get priceInOutLabel =>
      '${priceInPerM.toStringAsFixed(2)}/${priceOutPerM.toStringAsFixed(2)} in/out';
}

const List<ChatModelChoice> kClaudeChatModels = [
  ChatModelChoice(
    label: 'Sonnet',
    id: 'sonnet',
    tier: 'Balanced',
    priceInPerM: 3.0,
    priceOutPerM: 15.0,
  ),
  ChatModelChoice(
    label: 'Opus',
    id: 'opus',
    tier: 'Premium',
    priceInPerM: 15.0,
    priceOutPerM: 75.0,
  ),
  ChatModelChoice(
    label: 'Haiku',
    id: 'haiku',
    tier: 'Fast',
    priceInPerM: 1.0,
    priceOutPerM: 5.0,
  ),
];

/// Moonshot Open Platform model ids (international). Must match /v1/models for your key region.
const List<ChatModelChoice> kKimiChatModels = [
  ChatModelChoice(
    label: 'Kimi K2.5',
    id: 'kimi-k2.5',
    tier: 'Default',
    priceInPerM: 0.60,
    priceOutPerM: 2.50,
  ),
  ChatModelChoice(
    label: 'Kimi K2.6',
    id: 'kimi-k2.6',
    tier: 'Latest',
    priceInPerM: 0.60,
    priceOutPerM: 2.50,
  ),
  ChatModelChoice(
    label: 'Moonshot V1 8K',
    id: 'moonshot-v1-8k',
    tier: 'Legacy',
    priceInPerM: 0.15,
    priceOutPerM: 0.15,
  ),
  ChatModelChoice(
    label: 'Moonshot V1 32K',
    id: 'moonshot-v1-32k',
    tier: 'Legacy',
    priceInPerM: 0.24,
    priceOutPerM: 0.24,
  ),
  ChatModelChoice(
    label: 'Moonshot V1 128K',
    id: 'moonshot-v1-128k',
    tier: 'Long ctx',
    priceInPerM: 0.30,
    priceOutPerM: 0.30,
  ),
];

const List<ChatModelChoice> kCursorChatModels = [
  ChatModelChoice(
    label: 'Cursor default',
    id: 'cursor-default',
    tier: 'Cursor',
    priceInPerM: 0,
    priceOutPerM: 0,
  ),
];

const List<ChatModelChoice> kCodexChatModels = [
  ChatModelChoice(
    label: 'Codex default',
    id: 'provider-default',
    tier: 'ChatGPT / CLI',
    priceInPerM: 0,
    priceOutPerM: 0,
  ),
  ChatModelChoice(
    label: 'GPT-5.2 Codex',
    id: 'gpt-5.2-codex',
    tier: 'OpenAI API',
    priceInPerM: 3.0,
    priceOutPerM: 15.0,
  ),
];

const List<ChatModelChoice> kProviderDefaultChatModels = [
  ChatModelChoice(
    label: 'Provider default',
    id: 'provider-default',
    tier: 'Default',
    priceInPerM: 0,
    priceOutPerM: 0,
  ),
];
